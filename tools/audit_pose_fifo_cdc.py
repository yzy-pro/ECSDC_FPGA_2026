"""Fail unless both routed PDS corner reports cover and pass all FIFO Gray bits.

PDS 2025.2 can report 'All Constraints Met' in its text timing summary despite
a negative max-skew slack. Inspect its XML report database explicitly instead.
Generate it with report_max_skew enabled and max_path/nworst at least 64.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


DEST = re.compile(r"(u_capture_fifo|u_display_fifo)/(wr_gray_rd1|rd_gray_wr1)\[(\d+)\]/")


def audit(report_dir, addr_bits=9, limit_ns=6.734):
    expected = {(fifo, sync) for fifo in ("u_capture_fifo", "u_display_fifo")
                for sync in ("wr_gray_rd1", "rd_gray_wr1")}
    result = {"limit_ns": limit_ns, "pointer_bits": addr_bits + 1, "corners": {}}
    for corner in ("slow", "fast"):
        filename = report_dir / f"report_timing_{corner}_path_max_skew.db"
        if not filename.is_file():
            raise ValueError(f"Missing routed {corner} max-skew XML: {filename}")
        table = ET.parse(filename).getroot().find("table")
        if table is None:
            raise ValueError(f"No max-skew table in {filename}")
        groups = {}
        for row in table.findall("row"):
            fields = [item.text or "" for item in row.findall("data")]
            paths = row.findall("row/row")
            keys, bits, sources, data_delays = set(), set(), set(), []
            for path in paths:
                values = [item.text or "" for item in path.findall("data")]
                if len(values) < 12:
                    continue
                match = DEST.search(values[5])
                if not match:
                    continue
                fifo, sync, bit_text = match.groups()
                bit = int(bit_text)
                prefix = "wr" if sync == "wr_gray_rd1" else "rd"
                source_pattern = rf"{fifo}/{prefix}_(?:gray|binary)\[{bit}\]/"
                if not re.search(source_pattern, values[4]):
                    raise ValueError(f"Wrong source for {values[5]}: {values[4]}")
                keys.add((fifo, sync)); bits.add(bit); sources.add(values[4])
                data_delays.append(float(values[9]))
            if not keys:
                continue
            if len(keys) != 1:
                raise ValueError("Independent FIFO Gray buses were combined into one skew group")
            key = keys.pop()
            if key in groups:
                raise ValueError(f"Duplicate {corner} skew group: {key}")
            if bits != set(range(addr_bits + 1)):
                raise ValueError(f"Incomplete {corner} Gray-bit coverage for {key}: {sorted(bits)}; "
                                 "enable report max_path/nworst >= 64")
            if len(fields) < 12:
                raise ValueError(f"Missing skew summary for {key}")
            slack, required, actual = float(fields[1]), float(fields[10]), float(fields[11])
            if not (0 < required <= limit_ns) or slack < 0 or actual > required:
                raise ValueError(f"FAIL {corner} {key}: actual={actual} ns, "
                                 f"required={required} ns, slack={slack} ns")
            spread = max(data_delays) - min(data_delays)
            if spread > limit_ns:
                raise ValueError(f"FAIL {corner} {key}: routed data-delay spread {spread} ns")
            groups[key] = {"fifo": key[0], "synchronizer": key[1], "bits": sorted(bits),
                           "required_ns": required, "actual_skew_ns": actual,
                           "slack_ns": slack, "data_delay_min_ns": min(data_delays),
                           "data_delay_max_ns": max(data_delays), "sources": sorted(sources)}
        if set(groups) != expected:
            raise ValueError(f"Missing {corner} FIFO skew groups: {sorted(expected - set(groups))}")
        result["corners"][corner] = list(groups.values())
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report_dir", type=Path, help="PDS report_timing/report_db directory")
    parser.add_argument("--addr-bits", type=int, default=9)
    parser.add_argument("--limit-ns", type=float, default=6.734)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        result = audit(args.report_dir, args.addr_bits, args.limit_ns)
    except (ValueError, ET.ParseError, OSError) as error:
        print(f"FIFO CDC audit failed: {error}", file=sys.stderr)
        return 1
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    maximum = max(group["actual_skew_ns"] for groups in result["corners"].values() for group in groups)
    print(f"PASS FIFO CDC: 4 Gray buses, {4 * (args.addr_bits + 1)} destination bits per corner, "
          f"slow+fast corners, worst skew {maximum:.3f} ns <= {args.limit_ns:.3f} ns")
    return 0


if __name__ == "__main__":
    sys.exit(main())

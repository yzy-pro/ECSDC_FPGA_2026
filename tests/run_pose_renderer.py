"""Exercise real projection, DDR source sampling and RGB565 renderer writes."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(command, timeout=90):
    result = subprocess.run(list(map(str, command)), cwd=ROOT, text=True,
                            capture_output=True, timeout=timeout)
    if result.returncode or re.search(r"\*\* (?:Fatal|Error):", result.stdout):
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--modelsim", type=Path)
    parser.add_argument("--full-frame", action="store_true",
                        help="Check all 1920x1080 nearest-neighbor pixels at +30/-20 degrees")
    parser.add_argument("--cache-index-bits", type=int, default=10,
                        help="Renderer cache address bits (8=256, 9=512, 10=1024 entries)")
    parser.add_argument("--cache-line-words", type=int, default=1,
                        help="Adjacent 256-bit source words fetched per cache miss")
    parser.add_argument("--reciprocal-lut", action="store_true",
                        help="Exercise the experimental reciprocal LUT projection path")
    args = parser.parse_args()
    directory = ROOT / "build_rebuilt" / "pose_renderer_dma_regression"
    directory.mkdir(parents=True, exist_ok=True)
    sources = [ROOT / "tests/tb_pose_renderer_dma.sv",
               ROOT / "src/video/pose/pose_renderer_dma.v",
               ROOT / "src/video/pose/pose_inverse_project_q14.v",
               ROOT / "src/video/pose/pose_reciprocal_lut.v"]
    if args.modelsim:
        library = directory / "work"
        if not library.exists():
            run([args.modelsim / "vlib.exe", library])
        run([args.modelsim / "vlog.exe", "-sv", "-work", library, *sources])
        for mode in ((1,) if args.full_frame else (1, 0)):
            overrides = (["-gWIDTH=1920", "-gHEIGHT=1080", "-gFULL_FRAME_RUN=1"]
                         if args.full_frame else [])
            overrides.append(f"-gCACHE_INDEX_BITS={args.cache_index_bits}")
            overrides.append(f"-gCACHE_LINE_WORDS={args.cache_line_words}")
            overrides.append(f"-gRECIPROCAL_LUT_ENABLE={int(args.reciprocal_lut)}")
            label = "full1080p" if args.full_frame else f"mode_{mode}"
            output = run([args.modelsim / "vsim.exe", "-c", "-quiet", "-lib", library.relative_to(ROOT).as_posix(),
                          "-vopt", "tb_pose_renderer_dma", f"-gINTERPOLATION_MODE={mode}", *overrides,
                          "-l", directory / f"{label}.log", "-do",
                          "onerror {quit -code 1}; run -all; quit -f"],
                         timeout=3600 if args.full_frame else 90)
            if "PASS" not in output:
                raise AssertionError(output)
            print("\n".join(line for line in output.splitlines() if "PASS" in line or "MEASURE" in line))
    else:
        compiler, simulator = shutil.which("iverilog"), shutil.which("vvp")
        if not compiler or not simulator:
            parser.error("Icarus is required, or supply --modelsim <win64 directory>")
        for mode in ((1,) if args.full_frame else (1, 0)):
            executable = directory / f"mode_{mode}.vvp"
            overrides = (["-Ptb_pose_renderer_dma.WIDTH=1920", "-Ptb_pose_renderer_dma.HEIGHT=1080",
                          "-Ptb_pose_renderer_dma.FULL_FRAME_RUN=1"] if args.full_frame else [])
            overrides.append(f"-Ptb_pose_renderer_dma.CACHE_INDEX_BITS={args.cache_index_bits}")
            overrides.append(f"-Ptb_pose_renderer_dma.CACHE_LINE_WORDS={args.cache_line_words}")
            overrides.append(f"-Ptb_pose_renderer_dma.RECIPROCAL_LUT_ENABLE={int(args.reciprocal_lut)}")
            run([compiler, "-g2012", "-s", "tb_pose_renderer_dma",
                 f"-Ptb_pose_renderer_dma.INTERPOLATION_MODE={mode}",
                 *overrides, "-o", executable, *sources])
            output = run([simulator, executable], timeout=3600 if args.full_frame else 90)
            label = "full1080p" if args.full_frame else f"mode_{mode}"
            (directory / f"{label}.log").write_text(output, encoding="utf-8")
            if "PASS" not in output:
                raise AssertionError(output)
            print("\n".join(line for line in output.splitlines() if "PASS" in line or "MEASURE" in line))


if __name__ == "__main__":
    main()

"""Dependency-free checks for the Brown-Conrady tangential terms."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RTL = (ROOT / "src" / "video" / "undistort_rd_buf.v").read_text(encoding="ascii")
FRAME_BUF = (ROOT / "src" / "video" / "fram_buf_undistort.v").read_text(encoding="ascii")
TOP = (ROOT / "src" / "hdmi_ddr3_top.v").read_text(encoding="ascii")
FRAC_BITS = 14


def q14(value: float) -> int:
    return int(round(value * (1 << FRAC_BITS)))


def tangential_terms(x_q14: int, y_q14: int, p1_q14: int, p2_q14: int):
    x2_q14 = (x_q14 * x_q14) >> FRAC_BITS
    y2_q14 = (y_q14 * y_q14) >> FRAC_BITS
    xy_q14 = (x_q14 * y_q14) >> FRAC_BITS
    r2_q14 = x2_q14 + y2_q14
    x_term = ((2 * p1_q14 * xy_q14) >> FRAC_BITS) + (
        p2_q14 * (r2_q14 + (x2_q14 << 1)) >> FRAC_BITS
    )
    y_term = (p1_q14 * (r2_q14 + (y2_q14 << 1)) >> FRAC_BITS) + (
        (2 * p2_q14 * xy_q14) >> FRAC_BITS
    )
    return x_term, y_term


def main() -> None:
    for token in (
        "parameter signed [17:0] P1_Q14",
        "parameter signed [17:0] P2_Q14",
        "tan_x_base_d3",
        "tan_y_base_d3",
        "tan_x1_term4",
        "tan_x2_term4",
        "tan_y1_term4",
        "tan_y2_term4",
    ):
        assert token in RTL, token
    assert ".P1_Q14(P1_Q14)" in FRAME_BUF
    assert ".P2_Q14(P2_Q14)" in FRAME_BUF
    assert ".P1_Q14             (DIST_P1_Q14)" in TOP
    assert ".P2_Q14             (DIST_P2_Q14)" in TOP
    x_q14, y_q14 = q14(0.42), q14(-0.31)
    assert tangential_terms(x_q14, y_q14, 0, 0) == (0, 0)
    p1_q14, p2_q14 = q14(0.0012), q14(-0.0008)
    x_term, y_term = tangential_terms(x_q14, y_q14, p1_q14, p2_q14)
    assert x_term != 0 and y_term != 0
    print("tangential distortion checks passed")


if __name__ == "__main__":
    main()

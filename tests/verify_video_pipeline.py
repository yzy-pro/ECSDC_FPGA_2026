"""Software checks for the 1920/1440 FPGA video pipeline."""

from pathlib import Path
import re

import numpy as np
from scipy.io import loadmat


ROOT = Path(__file__).resolve().parents[1]
RTL_PATH = ROOT / "src" / "video" / "undistort" / "undistort_rd_buf.v"
LUT_PATH = ROOT / "reference" / "EmbFPGA" / "lut_1440_1080_5.mat"
TOP_PATH = ROOT / "src" / "top" / "hdmi_ddr3_top.v"
PLL_PATH = ROOT / "ipcore" / "video_pll" / "pll.v"
FDC_PATH = ROOT / "src" / "constraints" / "hdmi_ddr3_top.fdc"
WR_BUF_PATH = ROOT / "src" / "video" / "frame_buffer" / "wr_buf.v"
FRAME_BUF_PATH = ROOT / "src" / "video" / "undistort" / "fram_buf_undistort.v"
LINEAR_FRAME_BUF_PATH = ROOT / "src" / "video" / "frame_buffer" / "fram_buf_linear.v"
UNDISTORT_PATH = ROOT / "src" / "video" / "undistort" / "undistort_rd_buf.v"
RD_BUF_PATH = ROOT / "src" / "video" / "frame_buffer" / "rd_buf.v"

WIDTH = 1440
HEIGHT = 1080
FRAC_BITS = 14


def hardware_coordinates():
    """Reproduce the integer coordinate pipeline in undistort_rd_buf.v."""
    x_norm = (-3_884_883 + np.arange(WIDTH, dtype=np.int64) * 5_077) >> 8
    y_norm = (-2_842_003 + np.arange(HEIGHT, dtype=np.int64) * 5_072) >> 8
    x_norm = x_norm[np.newaxis, :]
    y_norm = y_norm[:, np.newaxis]

    radius2 = (x_norm * x_norm + y_norm * y_norm) >> FRAC_BITS
    radius4 = (radius2 * radius2) >> FRAC_BITS
    scale = (
        (1 << FRAC_BITS)
        + ((-4_687 * radius2) >> FRAC_BITS)
        + ((1_455 * radius4) >> FRAC_BITS)
    )
    x_source_q14 = ((x_norm * scale) >> FRAC_BITS) * 826 + 12_552_715
    y_source_q14 = ((y_norm * scale) >> FRAC_BITS) * 827 + 9_197_458

    x_integer = x_source_q14 >> FRAC_BITS
    y_integer = y_source_q14 >> FRAC_BITS
    x_fraction = (x_source_q14 & ((1 << FRAC_BITS) - 1)) >> 9
    y_fraction = (y_source_q14 & ((1 << FRAC_BITS) - 1)) >> 9
    return x_integer, y_integer, x_fraction, y_fraction


def check_scalers():
    host_source_x = (np.arange(1920) * 3) // 4
    fpga_kept_x = np.arange(1920)[np.arange(1920) % 4 != 1]
    recovered_source_x = host_source_x[fpga_kept_x]
    np.testing.assert_array_equal(recovered_source_x, np.arange(WIDTH))


def check_fixed_point_accuracy():
    matlab_lut = loadmat(LUT_PATH)["lut"].astype(np.int64)
    x_integer, y_integer, x_fraction, y_fraction = hardware_coordinates()

    hardware_x = x_integer + x_fraction / 32.0
    hardware_y = y_integer + y_fraction / 32.0
    matlab_x = matlab_lut[:, :, 0] + matlab_lut[:, :, 2] / 32.0
    matlab_y = matlab_lut[:, :, 1] + matlab_lut[:, :, 3] / 32.0

    x_error = np.abs(hardware_x - matlab_x)
    y_error = np.abs(hardware_y - matlab_y)
    assert x_error.max() <= 0.30
    assert y_error.max() <= 0.15
    return float(x_error.max()), float(y_error.max())


def check_cache_windows():
    rtl = RTL_PATH.read_text(encoding="ascii")
    pattern = re.compile(
        r"11'd(\d+): window_bounds = \{11'd(\d+), 11'd(\d+), 7'd(\d+)\}"
    )
    rows = [tuple(map(int, match)) for match in pattern.findall(rtl)]
    assert len(rows) == HEIGHT
    assert all(row[0] == index for index, row in enumerate(rows))

    x_integer, y_integer, _, _ = hardware_coordinates()
    source_x = np.clip(x_integer - 1, 0, WIDTH - 1)
    source_y = np.clip(y_integer - 1, 0, HEIGHT - 1)

    # The DDR cache fetches source x=128..1343, including the x+1 sample.
    assert source_x.min() >= 128
    assert (source_x + 1).max() <= 1343

    for output_y, first_line, last_line, first_slot in rows:
        required_first = int(source_y[output_y].min())
        required_last = int(np.minimum(source_y[output_y] + 1, HEIGHT - 1).max())
        assert first_line <= required_first
        assert last_line >= required_last
        assert first_slot == first_line % 66

    # The RTL uses a compressed one/two-line advance table at run time rather
    # than the large window_bounds case statement.  Prove that the compressed
    # table reconstructs every maximum source line exactly.
    step_hex = re.search(
        r"MAX_Y_STEP_GE1 = 1079'h([0-9a-fA-F]+)", rtl
    ).group(1)
    step_bits = int(step_hex, 16)
    runtime_max = rows[0][2]
    for output_y in range(HEIGHT - 1):
        step = 2 if output_y == 563 else (step_bits >> output_y) & 1
        runtime_max += step
        assert runtime_max == rows[output_y + 1][2], (
            output_y,
            runtime_max,
            rows[output_y + 1][2],
        )

    # At every output line, all source lines used by the four-tap bilinear
    # sample must be inside the 66-line circular cache window.
    for output_y, first_line, last_line, _ in rows:
        required = source_y[output_y]
        assert np.all(required >= first_line)
        assert np.all(required + 1 <= last_line)
        assert last_line - first_line + 1 <= 66


def check_mapping_has_no_holes():
    """Inverse mapping must cover every output pixel without folds/black gaps."""
    x_integer, y_integer, x_fraction, y_fraction = hardware_coordinates()
    source_x = x_integer + x_fraction / 32.0
    source_y = y_integer + y_fraction / 32.0

    assert source_x.shape == (HEIGHT, WIDTH)
    assert source_y.shape == (HEIGHT, WIDTH)
    assert np.all((source_x >= 0) & (source_x <= WIDTH - 1))
    assert np.all((source_y >= 0) & (source_y <= HEIGHT - 1))
    assert np.all(np.diff(source_x, axis=1) > 0)
    assert np.all(np.diff(source_y, axis=0) > 0)

    source_rows = np.arange(HEIGHT, dtype=np.int64)
    quotient = (source_rows * 993) >> 16
    remainder = source_rows - quotient * 66
    np.testing.assert_array_equal(remainder, source_rows % 66)


def check_pipeline_alignment():
    """Prove both readers exactly fill their matching delayed 1920-pixel DE."""
    prefix = 32
    suffix = 64
    timing_de = [False] * prefix + [True] * 1920 + [False] * suffix
    x_mod4 = 0
    requests = []
    for active in timing_de:
        requests.append(active and x_mod4 != 1)
        if not active:
            x_mod4 = 0
        else:
            x_mod4 = (x_mod4 + 1) & 3

    # PIPE_DELAY=18 represents 17 cycles through undistort_rd_buf;
    # PIPE_DELAY=2 represents one cycle through the sequential rd_buf.
    for latency in (17, 1):
        frame_de = [False] * latency + requests[:-latency]
        output_de = [False] * latency + timing_de[:-latency]
        active_valids = [v for v, active in zip(frame_de, output_de) if active]
        assert len(active_valids) == 1920
        assert sum(active_valids) == WIDTH

        source_index = -1
        held_index = None
        expanded = []
        for valid, active in zip(frame_de, output_de):
            if valid:
                source_index += 1
                held_index = source_index
            if active:
                assert held_index is not None
                expanded.append(held_index)
        np.testing.assert_array_equal(expanded, (np.arange(1920) * 3) // 4)


def check_ddr_pixel_order():
    # A DDR beat stores pixel 0 in bits 15:0 and pixel 15 in bits 255:240.
    previous_beat = sum(pixel << (16 * pixel) for pixel in range(16))
    next_beat = sum(pixel << (16 * (pixel - 16)) for pixel in range(16, 32))
    cache_word = ((next_beat & 0xFFFF) << 256) | previous_beat
    unpacked = [(cache_word >> (16 * index)) & 0xFFFF for index in range(17)]
    assert unpacked == list(range(17))


def check_rgb565_interpolation():
    """Bilinear RGB565 arithmetic must retain the complete weighted sum."""
    for maximum in (31, 63):
        for left in range(maximum + 1):
            for right in range(maximum + 1):
                for fraction in range(33):
                    weighted = left * (32 - fraction) + right * fraction
                    assert weighted <= 2016
                    result = weighted >> 5
                    assert 0 <= result <= maximum

    rtl = UNDISTORT_PATH.read_text(encoding="ascii")
    for multiplier in ("mul17x17", "mul18x18", "mul17x18"):
        assert f"function automatic signed" in rtl
        assert multiplier in rtl
    for weighted_sum in ("h_r0_sum", "h_g0_sum", "h_b0_sum"):
        assert f"wire [10:0] {weighted_sum}" in rtl
    for weighted_sum in ("v_r_sum", "v_g_sum", "v_b_sum"):
        assert f"wire [13:0] {weighted_sum}" in rtl
    assert "reg [12:0] vr0_prod, vr1_prod" in rtl
    assert "vout_de <= v13" in rtl


def check_frame_bank_allocator():
    """Writer must never enter the bank locked for the current output frame."""
    writer_bank = 0
    display_bank = 0
    completed_bank = None

    # Exercise drifting frame boundaries: input sometimes leads, output
    # sometimes repeats, and some boundaries land in the same scheduling slot.
    events = "IIOIIOIOIIOOIOIIIOIOOIIIOIOIIOO" * 8
    for event in events:
        if event == "I":
            completed_bank = writer_bank
            candidate = (writer_bank + 1) % 3
            if candidate == display_bank:
                candidate = (candidate + 1) % 3
            writer_bank = candidate
        elif completed_bank is not None:
            display_bank = completed_bank
        assert writer_bank != display_bank

    # On a shared DDR-clock edge the reader sees the previously completed
    # bank, while the writer completes its current bank.  The writer must
    # protect the reader's pending selection rather than the old frame_sel.
    writer_bank = 1
    display_bank = 0
    completed_bank = 2
    just_completed_bank = writer_bank
    pending_display_bank = completed_bank
    candidate = (writer_bank + 1) % 3
    if candidate == pending_display_bank:
        candidate = (candidate + 1) % 3
    writer_bank = candidate
    display_bank = pending_display_bank
    completed_bank = just_completed_bank
    assert writer_bank != display_bank
    assert completed_bank != display_bank

    wr_buf = WR_BUF_PATH.read_text(encoding="ascii")
    frame_buf = FRAME_BUF_PATH.read_text(encoding="ascii")
    linear_frame_buf = LINEAR_FRAME_BUF_PATH.read_text(encoding="ascii")
    undistort = UNDISTORT_PATH.read_text(encoding="ascii")
    linear_reader = RD_BUF_PATH.read_text(encoding="ascii")
    assert "input  [1:0]                  display_frame_bank" in wr_buf
    assert "next_write_frame_bank" in wr_buf
    assert "sequential_next_bank == display_frame_bank" in wr_buf
    assert "reg [1:0] completed_frame_bank" in frame_buf
    assert "reg [1:0] completed_frame_bank" in linear_frame_buf
    assert "completed_frame_bank(completed_frame_bank)" in linear_frame_buf
    assert "if (!rd_active)" in linear_reader
    assert "else if(rd_en)" in linear_reader
    assert "output [1:0]                  display_frame_bank" in undistort
    assert "ddr_frame_start ? completed_frame_bank" in undistort
    assert "frame_restart_pending ? pending_frame_sel : frame_sel" in undistort
    assert "selected_frame_base" in undistort


def check_clock_plan():
    """Keep the DDR and exact-rate video references on their board pins."""
    top = TOP_PATH.read_text(encoding="ascii")
    pll = PLL_PATH.read_text(encoding="ascii")
    fdc = FDC_PATH.read_text(encoding="ascii")

    assert ".clkin1  (video_ref_clk)" in top
    assert "assign pixclk_out = pixel_clk;" in top
    assert "always @(negedge pixel_clk)" not in top
    assert ".active_out(wr_active_1440)" in top
    assert ".wr_active    (wr_active_1440)" in top
    assert "parameter UNDISTORT_ENABLE  = 1'b1" in top
    assert "FRAME_PIPE_DELAY = UNDISTORT_ENABLE ? 18 : 2" in top
    assert "if (UNDISTORT_ENABLE)" in top
    assert "fram_buf_linear" in top
    assert "scale_out_1440_to_1920 #(.PIPE_DELAY(FRAME_PIPE_DELAY))" in top
    assert "vs_out   <= vs_delay[FRAME_PIPE_DELAY-1]" in top
    assert "hs_out   <= hs_delay[FRAME_PIPE_DELAY-1]" in top
    assert "{scaled_rgb565[15:11], scaled_rgb565[15:13]}" in top
    assert "{scaled_rgb565[10:5],  scaled_rgb565[10:9]}" in top
    assert "{scaled_rgb565[4:0],   scaled_rgb565[4:2]}" in top
    assert "set_lvcmos33_input sys_clk P20" in fdc
    assert "set_lvcmos33_input video_ref_clk K21" in fdc
    assert "pixclk_in AA12" in fdc
    assert "HSTL15_I" in fdc
    assert "HSTL15D_I" in fdc
    assert "SSTL15_I" not in fdc
    assert "PAP_IO_DRIVE} {8}" in fdc
    io_register_block = re.search(
        r"foreach port \{(?P<ports>.*?)\}\s*\{\s*"
        r'define_attribute "p:\$\{port\}" \{PAP_IO_REGISTER\} \{TRUE\}',
        fdc,
        re.DOTALL,
    )
    assert io_register_block is not None
    registered_ports = io_register_block.group("ports")
    for signal in ("vs_out", "hs_out", "de_out"):
        assert signal in registered_ports
    for channel in ("r", "g", "b"):
        for bit in range(8):
            assert f"{{{channel}_out[{bit}]}}" in registered_ports

    input_mhz = float(re.search(r"CLKIN_FREQ\s*=\s*([0-9.]+)", pll).group(1))
    input_div = int(re.search(r"STATIC_RATIOI\s*=\s*(\d+)", pll).group(1))
    output_div = int(re.search(r"STATIC_RATIO0\s*=\s*(\d+)", pll).group(1))
    feedback = int(re.search(r"STATIC_RATIOF\s*=\s*(\d+)", pll).group(1))
    assert input_mhz == 27.0
    assert input_mhz * feedback / input_div / output_div == 148.5


def check_cache_validity_protocol():
    """Frame changes must be atomic and must never remove individual pixels."""
    rtl = UNDISTORT_PATH.read_text(encoding="ascii")
    assert "cache_wr_line_done" in rtl
    assert "cache_prefill_ready <= 1'b1" in rtl
    assert "wire vout_pipeline_ready = vout_ready_sync[1];" in rtl
    assert "v8 <= v7b;" in rtl
    assert "addr_cache_valid" not in rtl
    assert "cache_line_tag" not in rtl
    assert "cache_line_valid" not in rtl
    assert "frame_restart_pending <= 1'b1" in rtl
    assert "frame_restart_pending && req_state == 0" in rtl
    assert "!flush_pending && !cache_wr_en && !cache_wr_line_done" in rtl
    assert "frame_cache_valid <= cache_ready_sync[1]" in rtl
    assert "vout_data <= frame_cache_valid" in rtl

    # Model the modulo-66 tags for a complete output frame. Loading the next
    # maximum source row must never evict a row still needed by that output.
    rows = [
        tuple(map(int, match))
        for match in re.findall(
            r"11'd(\d+): window_bounds = \{11'd(\d+), 11'd(\d+), 7'd(\d+)\}",
            rtl,
        )
    ]
    tags = {}
    for source_y in range(rows[0][1], rows[0][2] + 1):
        tags[source_y % 66] = source_y

    for output_y, first_line, last_line, _ in rows:
        for source_y in range(first_line, last_line + 1):
            assert tags[source_y % 66] == source_y, (output_y, source_y)
        if output_y + 1 < len(rows):
            next_last = rows[output_y + 1][2]
            for source_y in range(last_line + 1, next_last + 1):
                tags[source_y % 66] = source_y


def main():
    check_scalers()
    max_x_error, max_y_error = check_fixed_point_accuracy()
    check_cache_windows()
    check_mapping_has_no_holes()
    check_pipeline_alignment()
    check_ddr_pixel_order()
    check_rgb565_interpolation()
    check_frame_bank_allocator()
    check_clock_plan()
    check_cache_validity_protocol()
    print("video pipeline checks passed")
    print(f"maximum LUT error: x={max_x_error:.5f} px, y={max_y_error:.5f} px")


if __name__ == "__main__":
    main()

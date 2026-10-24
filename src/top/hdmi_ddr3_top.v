`timescale 1ns / 1ps

// HDMI video pipeline for the Logos PGL50H-FBG484 (BG484) board:
//
//   MS7200 RGB888 -> source preprocessing -> RGB565 -> source DDR frame
//   -> yaw/pitch projection and sampling -> corrected DDR frame -> MS7210.
// The tiled path overlaps capture into source slots 0/3 with rendering into
// output slots 1/2. Completed frames are handed over at VS after reads drain.
// Output timing remains 1080p60; it repeats each completed 30fps result.
// Legacy static-band and linear frame readers remain parameter-selectable.
module hdmi_ddr3_top #(
    parameter MEM_ROW_WIDTH  = 15,
    parameter MEM_COL_WIDTH  = 10,
    parameter MEM_BANK_WIDTH = 3,
    parameter MEM_DQ_WIDTH   = 32,
    // OUTPUT_BYPASS selects the direct 06_hdmi_loop-style HDMI path and skips
    // DDR3 completely.  With DDR enabled, UNDISTORT_ENABLE selects either the
    // algorithm reader or a linear reader used to verify DDR3 independently.
    parameter OUTPUT_BYPASS     = 1'b0,
    parameter UNDISTORT_ENABLE  = 1'b1,
    // Complete-frame yaw/pitch projection with arbitrary source reads.
    // HDMI is 60 Hz; correction frames update when rendering completes.
    parameter POSE_CORRECTION_ENABLE = 1'b1,
    // Legacy inverse 2.2 display gamma; bypassed when automatic input gamma
    // is active so the two curves do not compound.
    parameter GAMMA_ENABLE      = 1'b1,
    // 0 bypass, 1 fixed gain, 2 external LUT, 3 automatic frame gamma.
    parameter ADAPTIVE_PREPROCESS_ENABLE = 1'b1,
    parameter [1:0] ADAPTIVE_PREPROCESS_MODE = 2'd3,
    parameter [9:0] ADAPTIVE_GAIN_Q8 = 10'd256,
    parameter signed [8:0] ADAPTIVE_OFFSET = 9'sd0,
    // 0 = bilinear, 1 = nearest-neighbor (sharper default).
    parameter INTERPOLATION_MODE = 1,
    // Direct-mapped source word cache; 8 means 256 x 256-bit entries.
    parameter POSE_CACHE_INDEX_BITS = 10,
    // Exact tile renderer with overlapping source capture; nearest sampling.
    parameter POSE_TILED_ENABLE = 1'b1,
    // Runtime CP2102 switches are supported by the default tiled path.
    parameter PC_CONTROL_ENABLE = 1'b1,
    // Number of adjacent 256-bit source words fetched on a cache miss.
    parameter POSE_CACHE_LINE_WORDS = 1,
    // 1 selects the experimental normalized reciprocal ROM in place of the
    // exact restoring divider. Keep disabled until board timing is measured.
    parameter POSE_RECIPROCAL_LUT_ENABLE = 1'b0,
    parameter ATTITUDE_WARP_ENABLE = 1'b1,
    // Defaults reproduce September 19 radial math; retain calibration tooling.
    parameter signed [17:0] DIST_P1_Q14 = 18'sd0,
    parameter signed [17:0] DIST_P2_Q14 = 18'sd0
)(
    // The board's 50 MHz clock is the DDR3 controller reference.
    input                              sys_clk,
    // TTL UART from the IMU/STM32 board, 921600 baud, 8-N-1.
    input                              imu_uart_rx,
    // Board CP2102: R8 receives from the PC; R9 transmits to the PC.
    input                              pc_uart_rx,
    output                             pc_uart_tx,
    output [7:0]                       sys_led,

    // The independent 27 MHz oscillator feeds the video PLL.  Keeping video
    // timing off the DDR reference permits an exact 148.5 MHz 1080p60 clock.
    input                              video_ref_clk,

    // DDR3 pins.
    output                             mem_rst_n,
    output                             mem_ck,
    output                             mem_ck_n,
    output                             mem_cke,
    output                             mem_cs_n,
    output                             mem_ras_n,
    output                             mem_cas_n,
    output                             mem_we_n,
    output                             mem_odt,
    output [MEM_ROW_WIDTH-1:0]         mem_a,
    output [MEM_BANK_WIDTH-1:0]        mem_ba,
    inout  [MEM_DQ_WIDTH/8-1:0]        mem_dqs,
    inout  [MEM_DQ_WIDTH/8-1:0]        mem_dqs_n,
    inout  [MEM_DQ_WIDTH-1:0]          mem_dq,
    output [MEM_DQ_WIDTH/8-1:0]        mem_dm,

    // MS7200/MS7210 reset and I2C configuration pins.
    output                             rstn_out,
    output                             iic_scl,
    inout                              iic_sda,
    output                             iic_tx_scl,
    inout                              iic_tx_sda,

    // Parallel RGB888 from the MS7200 HDMI receiver.
    input                              pixclk_in,
    input                              vs_in,
    input                              hs_in,
    input                              de_in,
    input  [7:0]                       r_in,
    input  [7:0]                       g_in,
    input  [7:0]                       b_in,

    // Parallel RGB888 to the MS7210 HDMI transmitter.
    output                             pixclk_out,
    output reg                         vs_out,
    output reg                         hs_out,
    output reg                         de_out,
    output reg [7:0]                   r_out,
    output reg [7:0]                   g_out,
    output reg [7:0]                   b_out
);

    localparam CTRL_ADDR_WIDTH = MEM_ROW_WIDTH + MEM_COL_WIDTH + MEM_BANK_WIDTH;

    wire pixel_clk;
    wire cfg_clk;
    wire video_pll_lock;
    wire video_reset_n;
    reg [1:0] imu_reset_sync = 2'b00;
    always @(posedge sys_clk or negedge rstn_out) begin
        if (!rstn_out) imu_reset_sync <= 2'b00;
        else imu_reset_sync <= {imu_reset_sync[0],1'b1};
    end

    wire [15:0] imu_yaw_sys, imu_pitch_sys, imu_roll_sys;
    wire imu_attitude_valid_sys, imu_attitude_toggle_sys;
    wire [15:0] imu_yaw_pix, imu_pitch_pix, imu_roll_pix;
    wire imu_attitude_valid_pix;

    imu_protocol_50m u_imu_protocol (
        .clk(sys_clk), .rstn(imu_reset_sync[1]), .uart_rx(imu_uart_rx),
        .yaw(imu_yaw_sys), .pitch(imu_pitch_sys), .roll(imu_roll_sys),
        .attitude_valid(imu_attitude_valid_sys),
        .attitude_toggle(imu_attitude_toggle_sys)
    );

    attitude_cdc u_imu_cdc (
        .src_clk(sys_clk), .src_rstn(imu_reset_sync[1]),
        .src_yaw(imu_yaw_sys), .src_pitch(imu_pitch_sys), .src_roll(imu_roll_sys),
        .src_toggle(imu_attitude_toggle_sys),
        .dst_clk(pixel_clk), .dst_rstn(video_reset_n),
        .dst_yaw(imu_yaw_pix), .dst_pitch(imu_pitch_pix), .dst_roll(imu_roll_pix),
        .dst_valid(imu_attitude_valid_pix)
    );

    // From the board's 27 MHz oscillator, the integer PLL generates exactly
    // 148.5 MHz for 1080p60 and about 9.983 MHz for I2C configuration.
    pll u_video_pll (
        .clkin1  (video_ref_clk),
        .clkout0 (pixel_clk),
        .clkout1 (cfg_clk),
        .pll_lock(video_pll_lock)
    );

    // Hold both HDMI bridge chips and the DDR controller in reset for about
    // 1 ms after the video PLL locks. The slow release also gives board power
    // rails and oscillators time to settle.
    reg [15:0] startup_count = 16'd0;
    always @(posedge cfg_clk) begin
        if (!video_pll_lock)
            startup_count <= 16'd0;
        else if (startup_count < 16'd10000)
            startup_count <= startup_count + 1'b1;
    end

    assign rstn_out = (startup_count == 16'd10000);

    wire hdmi_tx_init_done;
    ms72xx_ctl u_ms72xx_ctl (
        .clk        (cfg_clk),
        .rst_n      (rstn_out),
        .init_over  (hdmi_tx_init_done),
        .iic_tx_scl (iic_tx_scl),
        .iic_tx_sda (iic_tx_sda),
        .iic_scl    (iic_scl),
        .iic_sda    (iic_sda)
    );

    wire ddr_core_clk;
    wire ddr_init_done;
    wire ddr_pll_lock;
    wire ddr_dll_lock;
    wire frame_init_done;

    // These status flags are generated in three different clock domains and
    // remain asserted once initialization completes.  Synchronize them before
    // using them in the pixel clock domain; in particular, never use an
    // asynchronous DDR calibration flag as the reset of the video timing
    // generator.
    reg [1:0] video_reset_sync = 2'b00;
    reg [1:0] ddr_init_sync    = 2'b00;
    reg [1:0] ddr_pll_sync     = 2'b00;
    reg [1:0] ddr_dll_sync     = 2'b00;
    reg [1:0] tx_init_sync     = 2'b00;
    reg [1:0] frame_init_sync  = 2'b00;
    always @(posedge pixel_clk or negedge rstn_out) begin
        if (!rstn_out) begin
            video_reset_sync <= 2'b00;
            ddr_init_sync    <= 2'b00;
            ddr_pll_sync     <= 2'b00;
            ddr_dll_sync     <= 2'b00;
            tx_init_sync     <= 2'b00;
            frame_init_sync  <= 2'b00;
        end else begin
            video_reset_sync <= {video_reset_sync[0], 1'b1};
            ddr_init_sync    <= {ddr_init_sync[0], ddr_init_done};
            ddr_pll_sync     <= {ddr_pll_sync[0], ddr_pll_lock};
            ddr_dll_sync     <= {ddr_dll_sync[0], ddr_dll_lock};
            tx_init_sync     <= {tx_init_sync[0], hdmi_tx_init_done};
            frame_init_sync  <= {frame_init_sync[0], frame_init_done};
        end
    end

    assign video_reset_n = video_reset_sync[1];
    wire ddr_ready     = ddr_init_sync[1];
    wire ddr_pll_ready = ddr_pll_sync[1];
    wire ddr_dll_ready = ddr_dll_sync[1];
    wire tx_ready      = tx_init_sync[1];
    wire frame_ready   = frame_init_sync[1];

    // Simplified AXI-like interface used by the Pango DDR3 controller.
    wire [CTRL_ADDR_WIDTH-1:0] axi_awaddr;
    wire [3:0]                 axi_awid;
    wire [3:0]                 axi_awlen;
    wire                       axi_awready;
    wire                       axi_awvalid;
    wire [MEM_DQ_WIDTH*8-1:0]  axi_wdata;
    wire [MEM_DQ_WIDTH-1:0]    axi_wstrb;
    wire                       axi_wready;
    wire                       axi_wlast;
    wire [CTRL_ADDR_WIDTH-1:0] axi_araddr;
    wire [3:0]                 axi_arid;
    wire [3:0]                 axi_arlen;
    wire                       axi_arready;
    wire                       axi_arvalid;
    wire [MEM_DQ_WIDTH*8-1:0]  axi_rdata;
    wire [3:0]                 axi_rid;
    wire                       axi_rlast;
    wire                       axi_rvalid;

    wire [15:0] rgb565_in;
    wire        wr_en_1920;
    wire        wr_active_1920;
    wire        input_vs;

    // rstn_out is generated in the cfg_clk domain.  Assert reset
    // asynchronously, then release it through two pixclk_in flip-flops so
    // the input converter never starts on a metastable reset edge.
    reg [1:0] input_reset_sync = 2'b00;
    always @(posedge pixclk_in or negedge rstn_out) begin
        if (!rstn_out)
            input_reset_sync <= 2'b00;
        else
            input_reset_sync <= {input_reset_sync[0], 1'b1};
    end
    wire input_reset_n = input_reset_sync[1];

    localparam PC_GEOMETRY = PC_CONTROL_ENABLE && UNDISTORT_ENABLE &&
        POSE_CORRECTION_ENABLE && POSE_TILED_ENABLE && INTERPOLATION_MODE==1 && !OUTPUT_BYPASS;
    localparam PC_GAMMA = PC_CONTROL_ENABLE && ADAPTIVE_PREPROCESS_ENABLE &&
        ADAPTIVE_PREPROCESS_MODE==2'd3 && !OUTPUT_BYPASS;
    localparam [2:0] PC_AVAILABLE = {PC_GAMMA,PC_GEOMETRY,PC_GEOMETRY};
    localparam [2:0] PC_DEFAULT = {PC_GAMMA,PC_GEOMETRY && ATTITUDE_WARP_ENABLE,PC_GEOMETRY};
    wire [2:0] requested_mask,applied_mask,source_mask,control_mask,next_source_mask;
    wire control_busy,control_valid,stream_enabled;
    wire [31:0] pc_receive_errors;
    wire telemetry_sys_valid;
    wire [223:0] telemetry_sys_data;
    wire control_vs;
    reg control_vs_d;
    always @(posedge pixclk_in or negedge input_reset_n)
        if(!input_reset_n) control_vs_d<=1'b0;
        else control_vs_d<=control_vs;
    // Only use the registered VS inside the FPGA: pad-to-control logic would
    // violate the source-synchronous zero-cycle input setup constraint.
    video_control_cdc #(.DEFAULT_MASK(PC_DEFAULT)) u_pc_control_cdc (
        .sys_clk(sys_clk),.vin_clk(pixclk_in),.rstn(rstn_out),
        .frame_start(control_vs && !control_vs_d),.command_valid(control_valid),.command_mask(control_mask),
        .busy(control_busy),.requested_mask(requested_mask),.applied_mask_sys(applied_mask),
        .applied_mask_vin(source_mask),.next_mask_vin(next_source_mask));
    cp2102_control #(.AVAILABLE_MASK(PC_AVAILABLE)) u_pc_control (
        .clk(sys_clk),.rstn(imu_reset_sync[1]),.rx(pc_uart_rx),.tx(pc_uart_tx),
        .control_busy(control_busy),.requested_mask(requested_mask),.applied_mask(applied_mask),
        .control_valid(control_valid),.control_mask(control_mask),
        .sample_valid(telemetry_sys_valid),.sample_data(telemetry_sys_data),
        .stream_enabled(stream_enabled),.receive_errors(pc_receive_errors));
    // LED1..3: applied source-frame lens/pose/gamma enables. Remaining user
    // LEDs are reserved and off. A completed older result can still display.
    assign sys_led={5'd0,applied_mask};

    wire gamma_stats_valid,gamma_stats_enabled;
    wire [2:0] gamma_active_curve,gamma_target_curve,gamma_stats_curve,gamma_stats_target;
    wire [31:0] gamma_luma_sum,gamma_pixel_count,gamma_dark_count,gamma_highlight_count;
    wire gamma_sample_valid;
    wire [223:0] gamma_sample_data;
    cdc_snapshot #(.WIDTH(224)) u_gamma_cdc (
        .src_clk(pixclk_in),.dst_clk(sys_clk),.rstn(rstn_out),
        .src_valid(gamma_sample_valid),.src_data(gamma_sample_data),.src_busy(),
        .dst_valid(telemetry_sys_valid),.dst_data(telemetry_sys_data));

    wire [7:0] preprocess_r, preprocess_g, preprocess_b;
    wire preprocess_de;
    localparam AUTO_GAMMA = ADAPTIVE_PREPROCESS_ENABLE && ADAPTIVE_PREPROCESS_MODE==2'd3;
    // With gamma, the converter SOF is later than the control commit. In
    // manual modes the converter and control see the registered SOF together.
    wire [2:0] geometry_mask=AUTO_GAMMA ? source_mask : next_source_mask;
    wire [7:0] preprocess_source_r,preprocess_source_g,preprocess_source_b;
    wire preprocess_source_vs,preprocess_source_de;
    generate if(AUTO_GAMMA) begin : g_auto_gamma
        // Preserve source-synchronous pad capture before the gamma pipeline.
        // Every source control follows the same registered path as RGB.
        reg [7:0] input_r /* synthesis syn_useioff = 1 */;
        reg [7:0] input_g /* synthesis syn_useioff = 1 */;
        reg [7:0] input_b /* synthesis syn_useioff = 1 */;
        reg input_de /* synthesis syn_useioff = 1 */;
        reg input_vs_q /* synthesis syn_useioff = 1 */;
        always @(posedge pixclk_in) begin
            if(!input_reset_n) begin
                input_r<=0;input_g<=0;input_b<=0;input_de<=0;input_vs_q<=1;
            end else begin
                input_r<=r_in;input_g<=g_in;input_b<=b_in;input_de<=de_in;input_vs_q<=vs_in;
            end
        end
        wire gamma_frame_sync;
        assign control_vs=!input_vs_q;
        adaptive_gamma_stream u_auto_gamma (
            .clk(pixclk_in),.rstn(input_reset_n),.in_vs(!input_vs_q),.in_de(input_de),
            .in_r(input_r),.in_g(input_g),.in_b(input_b),.enable(!PC_CONTROL_ENABLE || next_source_mask[2]),
            .out_vs(gamma_frame_sync),.out_de(preprocess_source_de),
            .out_r(preprocess_source_r),.out_g(preprocess_source_g),.out_b(preprocess_source_b),
            .active_curve(gamma_active_curve),.target_curve(gamma_target_curve),
            .stats_valid(gamma_stats_valid),.luma_sum(gamma_luma_sum),.pixel_count(gamma_pixel_count),
            .dark_count(gamma_dark_count),.highlight_count(gamma_highlight_count),
            .stats_curve(gamma_stats_curve),.stats_target(gamma_stats_target),.stats_enabled(gamma_stats_enabled)
        );
        gamma_telemetry u_gamma_telemetry (
            .clk(pixclk_in),.rstn(input_reset_n),.stats_valid(gamma_stats_valid),
            .out_vs(gamma_frame_sync),.out_de(preprocess_source_de),
            .out_r(preprocess_source_r),.out_g(preprocess_source_g),.out_b(preprocess_source_b),
            .luma_sum(gamma_luma_sum),.pixel_count(gamma_pixel_count),
            .dark_count(gamma_dark_count),.highlight_count(gamma_highlight_count),
            .stats_curve(gamma_stats_curve),.stats_target(gamma_stats_target),
            .stats_enabled(gamma_stats_enabled),.frame_mask(source_mask),
            .sample_valid(gamma_sample_valid),.sample_data(gamma_sample_data));
        // HDMI VS is active low; the adaptive module uses positive SOF.
        assign preprocess_source_vs=!gamma_frame_sync;
    end else begin : g_manual_preprocess
        reg control_vs_q /* synthesis syn_useioff = 1 */;
        always @(posedge pixclk_in)
            if(!input_reset_n) control_vs_q<=1'b1;
            else control_vs_q<=vs_in;
        assign control_vs=!control_vs_q;
        assign gamma_sample_valid=1'b0;
        assign gamma_sample_data=224'd0;
        assign preprocess_source_r=r_in;
        assign preprocess_source_g=g_in;
        assign preprocess_source_b=b_in;
        assign preprocess_source_de=de_in;
        assign preprocess_source_vs=vs_in;
    end endgenerate
    wire [31:0] preprocess_luma_sum, preprocess_pixel_count;
    wire preprocess_stats_valid;
    reg preprocess_vs_d;
    always @(posedge pixclk_in or negedge input_reset_n)
        if(!input_reset_n) preprocess_vs_d<=1'b0;
        else preprocess_vs_d<=preprocess_source_vs;
    // Preprocessing operates on source RGB888 before quantization and DDR.
    // Manual gain/LUT modes retain the existing combinational interface.
    adaptive_preprocess_stream u_adaptive_preprocess (
        .clk(pixclk_in),.rstn(input_reset_n),
        .frame_start(preprocess_source_vs && !preprocess_vs_d),.in_de(preprocess_source_de),
        .in_r(preprocess_source_r),.in_g(preprocess_source_g),.in_b(preprocess_source_b),
        .enable(ADAPTIVE_PREPROCESS_ENABLE && !AUTO_GAMMA),.mode(ADAPTIVE_PREPROCESS_MODE),
        .gain_q8(ADAPTIVE_GAIN_Q8),.offset(ADAPTIVE_OFFSET),
        .lut_we(1'b0),.lut_addr(8'd0),
        .lut_r_data(8'd0),.lut_g_data(8'd0),.lut_b_data(8'd0),
        .out_r(preprocess_r),.out_g(preprocess_g),.out_b(preprocess_b),
        .out_de(preprocess_de),.luma_sum(preprocess_luma_sum),
        .pixel_count(preprocess_pixel_count),.stats_valid(preprocess_stats_valid)
    );

    rgb888_to_rgb565 u_rgb888_to_rgb565 (
        .clk    (pixclk_in),
        .rstn   (input_reset_n),
        .vs_in  (preprocess_source_vs),
        .vs_out (input_vs),
        .de_in  (preprocess_de),
        .r_in   (preprocess_r),
        .g_in   (preprocess_g),
        .b_in   (preprocess_b),
        .active_out(wr_active_1920),
        .wr_en  (wr_en_1920),
        .wr_data(rgb565_in)
    );
    wire [15:0] rgb565_out;

    wire timing_vs;
    wire timing_hs;
    wire timing_de;
    wire timing_de_early;
    wire alg_rd_en;
    wire display_de;
    wire gamma_de;
    wire [7:0] gamma_r;
    wire [7:0] gamma_g;
    wire [7:0] gamma_b;
    wire rgb888_de;
    wire [7:0] rgb888_r;
    wire [7:0] rgb888_g;
    wire [7:0] rgb888_b;

    // Use standard 1920x1080@60 physical HDMI timing. The frame buffer and
    // undistortion algorithm are 1920 pixels wide.
    sync_vg #(
        .X_BITS  (12),
        .Y_BITS  (12),
        .V_TOTAL (1125),
        .V_FP    (4),
        .V_BP    (36),
        .V_SYNC  (5),
        .V_ACT   (1080),
        .H_TOTAL (2200),
        .H_FP    (88),
        .H_BP    (148),
        .H_SYNC  (44),
        .H_ACT   (1920)
    ) u_output_timing (
        .clk    (pixel_clk),
        // Keep a valid 1080p60 raster running even while DDR3 or the HDMI
        // transmitter is initializing.  Gating HS/VS/DE with ddr_init_done
        // left the transmitter with a clock but no video format whenever DDR
        // calibration failed, which displays as "unsupported format".
        .rstn   (video_reset_n),
        .vs_out (timing_vs),
        .hs_out (timing_hs),
        .de_out (timing_de),
        .de_re  (timing_de_early),
        .x_act  (),
        .y_act  ()
    );

    wire frame_de;
    localparam integer FRAME_PIPE_DELAY = (UNDISTORT_ENABLE && !POSE_CORRECTION_ENABLE) ? 23 : 2;

    generate
    if (UNDISTORT_ENABLE && POSE_CORRECTION_ENABLE) begin : g_pose_frame_buffer
        wire [15:0] imu_yaw_capture,imu_pitch_capture;
        wire imu_valid_capture;
        attitude_cdc u_imu_capture_cdc (
            .src_clk(sys_clk),.src_rstn(imu_reset_sync[1]),
            .src_yaw(imu_yaw_sys),.src_pitch(imu_pitch_sys),.src_roll(imu_roll_sys),
            .src_toggle(imu_attitude_toggle_sys),.dst_clk(pixclk_in),.dst_rstn(input_reset_n),
            .dst_yaw(imu_yaw_capture),.dst_pitch(imu_pitch_capture),.dst_roll(),.dst_valid(imu_valid_capture)
        );
        fram_buf_pose #(.ADDR_WIDTH(CTRL_ADDR_WIDTH),.H_NUM(1920),.V_NUM(1080),
            .INTERPOLATION_MODE(INTERPOLATION_MODE),
            .CACHE_INDEX_BITS(POSE_CACHE_INDEX_BITS),
            .TILED_ENABLE(POSE_TILED_ENABLE),
            .RUNTIME_CONTROL(PC_GEOMETRY),
            .CACHE_LINE_WORDS(POSE_CACHE_LINE_WORDS),
            .RECIPROCAL_LUT_ENABLE(POSE_RECIPROCAL_LUT_ENABLE),
            .P1_Q14(DIST_P1_Q14),.P2_Q14(DIST_P2_Q14)) u_frame_buffer (
            .ddr_clk(ddr_core_clk),.ddr_rstn(ddr_init_done),
            .vin_clk(pixclk_in),.wr_fsync(~input_vs),.wr_en(wr_en_1920),.wr_data(rgb565_in),
            .vout_clk(pixel_clk),.rd_fsync(timing_vs),.rd_en(alg_rd_en),
            .lens_enable(!PC_GEOMETRY || geometry_mask[0]),
            .imu_yaw((PC_GEOMETRY ? geometry_mask[1] : ATTITUDE_WARP_ENABLE) ? imu_yaw_capture : 16'd0),
            .imu_pitch((PC_GEOMETRY ? geometry_mask[1] : ATTITUDE_WARP_ENABLE) ? imu_pitch_capture : 16'd0),
            .vout_de(frame_de),.vout_data(rgb565_out),.init_done(frame_init_done),
            .axi_awaddr(axi_awaddr),.axi_awid(axi_awid),.axi_awlen(axi_awlen),
            .axi_awvalid(axi_awvalid),.axi_awready(axi_awready),
            .axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),.axi_wready(axi_wready),.axi_wlast(axi_wlast),
            .axi_araddr(axi_araddr),.axi_arid(axi_arid),.axi_arlen(axi_arlen),
            .axi_arvalid(axi_arvalid),.axi_arready(axi_arready),
            .axi_rdata(axi_rdata),.axi_rvalid(axi_rvalid),.axi_rlast(axi_rlast),.axi_rid(axi_rid),
            .captured_frames(),.rendered_frames(),.displayed_frames(),.rejected_captures(),
            .display_underrun(),.pose_clamped(),.protocol_error()
        );
    end else if (UNDISTORT_ENABLE) begin : g_undistort_frame_buffer
        fram_buf_undistort #(
            .MEM_ROW_WIDTH    (MEM_ROW_WIDTH),
            .MEM_COLUMN_WIDTH (MEM_COL_WIDTH),
            .MEM_BANK_WIDTH   (MEM_BANK_WIDTH),
            .MEM_DQ_WIDTH     (MEM_DQ_WIDTH),
            .H_NUM            (1920),
            .V_NUM            (1080),
            .PIX_WIDTH        (16),
            .INTERPOLATION_MODE (INTERPOLATION_MODE),
            .ATTITUDE_WARP_ENABLE (ATTITUDE_WARP_ENABLE),
            .P1_Q14 (DIST_P1_Q14), .P2_Q14 (DIST_P2_Q14)
        ) u_frame_buffer (
            .ddr_clk      (ddr_core_clk),
            .ddr_rstn     (ddr_init_done),
            .vin_clk      (pixclk_in),
            .wr_fsync     (~input_vs),
            .wr_active    (wr_active_1920),
            .wr_en        (wr_en_1920),
            .wr_data      (rgb565_in),
            .vout_clk     (pixel_clk),
            .rd_fsync     (timing_vs),
            .rd_active    (timing_de),
            .rd_en        (alg_rd_en),
            .imu_yaw      (imu_yaw_pix),
            .imu_pitch    (imu_pitch_pix),
            .imu_roll     (imu_roll_pix),
            .imu_valid    (imu_attitude_valid_pix),
            .vout_de      (frame_de),
            .vout_data    (rgb565_out),
            .init_done    (frame_init_done),
            .axi_awaddr   (axi_awaddr),
            .axi_awid     (axi_awid),
            .axi_awlen    (axi_awlen),
            .axi_awsize   (),
            .axi_awburst  (),
            .axi_awready  (axi_awready),
            .axi_awvalid  (axi_awvalid),
            .axi_wdata    (axi_wdata),
            .axi_wstrb    (axi_wstrb),
            .axi_wlast    (axi_wlast),
            .axi_wvalid   (),
            .axi_wready   (axi_wready),
            .axi_bid      (4'd0),
            .axi_araddr   (axi_araddr),
            .axi_arid     (axi_arid),
            .axi_arlen    (axi_arlen),
            .axi_arsize   (),
            .axi_arburst  (),
            .axi_arvalid  (axi_arvalid),
            .axi_arready  (axi_arready),
            .axi_rready   (),
            .axi_rdata    (axi_rdata),
            .axi_rvalid   (axi_rvalid),
            .axi_rlast    (axi_rlast),
            .axi_rid      (axi_rid)
        );
    end else begin : g_linear_frame_buffer
        fram_buf_linear #(
            .MEM_ROW_WIDTH    (MEM_ROW_WIDTH),
            .MEM_COLUMN_WIDTH (MEM_COL_WIDTH),
            .MEM_BANK_WIDTH   (MEM_BANK_WIDTH),
            .MEM_DQ_WIDTH     (MEM_DQ_WIDTH),
            .H_NUM            (1920),
            .V_NUM            (1080),
            .PIX_WIDTH        (16)
        ) u_frame_buffer (
        .ddr_clk      (ddr_core_clk),
        .ddr_rstn     (ddr_init_done),
        .vin_clk      (pixclk_in),
        .wr_fsync     (~input_vs),
        .wr_active    (wr_active_1920),
        .wr_en        (wr_en_1920),
        .wr_data      (rgb565_in),
        .vout_clk     (pixel_clk),
        .rd_fsync     (timing_vs),
        .rd_active    (timing_de),
        .rd_en        (alg_rd_en),
        .vout_de      (frame_de),
        .vout_data    (rgb565_out),
        .init_done    (frame_init_done),
        .axi_awaddr   (axi_awaddr),
        .axi_awid     (axi_awid),
        .axi_awlen    (axi_awlen),
        .axi_awsize   (),
        .axi_awburst  (),
        .axi_awready  (axi_awready),
        .axi_awvalid  (axi_awvalid),
        .axi_wdata    (axi_wdata),
        .axi_wstrb    (axi_wstrb),
        .axi_wlast    (axi_wlast),
        .axi_wvalid   (),
        .axi_wready   (axi_wready),
        .axi_bid      (4'd0),
        .axi_araddr   (axi_araddr),
        .axi_arid     (axi_arid),
        .axi_arlen    (axi_arlen),
        .axi_arsize   (),
        .axi_arburst  (),
        .axi_arvalid  (axi_arvalid),
        .axi_arready  (axi_arready),
        .axi_rready   (),
        .axi_rdata    (axi_rdata),
        .axi_rvalid   (axi_rvalid),
        .axi_rlast    (axi_rlast),
        .axi_rid      (axi_rid)
        );
    end
    endgenerate

    // Preserve the September 19 scaler's independent raster-DE delay, but
    // request every pixel and perform no horizontal resampling.
    video_raster_delay #(.PIPE_DELAY(FRAME_PIPE_DELAY)) u_display_raster (
        .clk(pixel_clk), .rstn(video_reset_n), .timing_de(timing_de),
        .display_de(display_de)
    );
    assign alg_rd_en = timing_de;

    // Convert the processed RGB565 stream to RGB888 before gamma. The
    // conversion is combinational; gamma remains the only added register.
    rgb565_to_rgb888 u_rgb565_to_rgb888 (
        .rgb565_in (rgb565_out),
        .de_in     (display_de),
        .r_out     (rgb888_r),
        .g_out     (rgb888_g),
        .b_out     (rgb888_b),
        .de_out    (rgb888_de)
    );

    gamma_correct_rgb888 #(.GAMMA_ENABLE(GAMMA_ENABLE && !AUTO_GAMMA)) u_gamma (
        .clk       (pixel_clk),
        .rstn      (video_reset_n),
        .de_in     (rgb888_de),
        .r_in      (rgb888_r),
        .g_in      (rgb888_g),
        .b_in      (rgb888_b),
        .de_out    (gamma_de),
        .r_out     (gamma_r),
        .g_out     (gamma_g),
        .b_out     (gamma_b)
    );

    // Select either the known-good 06_hdmi_loop path or the processed path at
    // synthesis time.  Keeping this as a parameter makes the baseline easy to
    // reproduce without editing clocks or video data by hand.
    generate
        if (OUTPUT_BYPASS) begin : g_hdmi_passthrough
            assign pixclk_out = pixclk_in;

            always @(posedge pixclk_in) begin
                if (!hdmi_tx_init_done) begin
                    vs_out <= 1'b0;
                    hs_out <= 1'b0;
                    de_out <= 1'b0;
                    r_out  <= 8'd0;
                    g_out  <= 8'd0;
                    b_out  <= 8'd0;
                end else begin
                    vs_out <= vs_in;
                    hs_out <= hs_in;
                    de_out <= de_in;
                    r_out  <= r_in;
                    g_out  <= g_in;
                    b_out  <= b_in;
                end
            end
        end else begin : g_ddr_video
            // Delay sync by the selected frame-reader latency. de_out gains
            // the same final output register stage below.
            localparam integer OUTPUT_SYNC_DELAY = FRAME_PIPE_DELAY + 1;
            reg [OUTPUT_SYNC_DELAY:0] hs_delay = 0;
            reg [OUTPUT_SYNC_DELAY:0] vs_delay = 0;

            // Preserve the board-demo convention: normal pixel-clock polarity,
            // with RGB/control updated on the rising edge. The MS7210 input is
            // configured to sample the parallel bus on the falling edge.
            assign pixclk_out = pixel_clk;

            always @(posedge pixel_clk) begin
                if (!video_reset_n) begin
                    hs_delay <= 0;
                    vs_delay <= 0;
                    vs_out   <= 1'b0;
                    hs_out   <= 1'b0;
                    de_out   <= 1'b0;
                    r_out    <= 8'd0;
                    g_out    <= 8'd0;
                    b_out    <= 8'd0;
                end else begin
                    hs_delay <= {hs_delay[OUTPUT_SYNC_DELAY-1:0], timing_hs};
                    vs_delay <= {vs_delay[OUTPUT_SYNC_DELAY-1:0], timing_vs};
                    vs_out   <= vs_delay[OUTPUT_SYNC_DELAY-1];
                    hs_out   <= hs_delay[OUTPUT_SYNC_DELAY-1];
                    de_out   <= gamma_de;
                    if (!gamma_de) begin
                        r_out <= 8'd0;
                        g_out <= 8'd0;
                        b_out <= 8'd0;
                    end else if (!tx_ready) begin
                        // Magenta: MS7210 I2C initialization did not complete.
                        r_out <= 8'hff;
                        g_out <= 8'h00;
                        b_out <= 8'hff;
                    end else if (!ddr_pll_ready) begin
                        // Blue: the DDR controller PLL did not lock.
                        r_out <= 8'h00;
                        g_out <= 8'h00;
                        b_out <= 8'hff;
                    end else if (!ddr_dll_ready) begin
                        // Cyan: the DDR PHY DLL did not lock.
                        r_out <= 8'h00;
                        g_out <= 8'hff;
                        b_out <= 8'hff;
                    end else if (!ddr_ready) begin
                        // Red: clocks locked, but DDR calibration did not finish.
                        r_out <= 8'hff;
                        g_out <= 8'h00;
                        b_out <= 8'h00;
                    end else if (!frame_ready) begin
                        // Yellow: DDR works, but no complete input frame arrived.
                        r_out <= 8'hff;
                        g_out <= 8'hff;
                        b_out <= 8'h00;
                    end else begin
                        // RGB888 values have already been produced by the conversion/gamma stages.
                        // Bit replication avoids the dark bias of zero fill
                        // (whose maximum would be only 248/252/248).
                        r_out <= gamma_r;
                        g_out <= gamma_g;
                        b_out <= gamma_b;
                    end
                end
            end
        end
    endgenerate

    // DDR3 controller generated specifically for Logos PGL50H-FBG484.
    DDR3_50H u_ddr3 (
        .ref_clk                (sys_clk),
        .resetn                 (rstn_out),
        .ddrphy_clkin           (ddr_core_clk),
        .pll_lock               (ddr_pll_lock),
        .ddr_init_done          (ddr_init_done),
        .axi_awaddr             (axi_awaddr),
        .axi_awuser_ap          (1'b0),
        .axi_awuser_id          (axi_awid),
        .axi_awlen              (axi_awlen),
        .axi_awready            (axi_awready),
        .axi_awvalid            (axi_awvalid),
        .axi_wdata              (axi_wdata),
        .axi_wstrb              (axi_wstrb),
        .axi_wready             (axi_wready),
        .axi_wusero_id          (),
        .axi_wusero_last        (axi_wlast),
        .axi_araddr             (axi_araddr),
        .axi_aruser_ap          (1'b0),
        .axi_aruser_id          (axi_arid),
        .axi_arlen              (axi_arlen),
        .axi_arready            (axi_arready),
        .axi_arvalid            (axi_arvalid),
        .axi_rdata              (axi_rdata),
        .axi_rid                (axi_rid),
        .axi_rlast              (axi_rlast),
        .axi_rvalid             (axi_rvalid),
        .apb_clk                (1'b0),
        .apb_rst_n              (1'b1),
        .apb_sel                (1'b0),
        .apb_enable             (1'b0),
        .apb_addr               (8'd0),
        .apb_write              (1'b0),
        .apb_ready              (),
        .apb_wdata              (16'd0),
        .apb_rdata              (),
        .apb_int                (),
        .debug_data             (),
        .debug_slice_state      (),
        .debug_calib_ctrl       (),
        .ck_dly_set_bin         (),
        .force_ck_dly_en        (1'b0),
        .force_ck_dly_set_bin   (8'd0),
        .dll_step               (),
        .dll_lock               (ddr_dll_lock),
        .init_read_clk_ctrl     (2'd0),
        .init_slip_step         (4'd0),
        .force_read_clk_ctrl    (1'b0),
        .ddrphy_gate_update_en  (1'b0),
        .update_com_val_err_flag(),
        .rd_fake_stop           (1'b0),
        .mem_cs_n               (mem_cs_n),
        .mem_rst_n              (mem_rst_n),
        .mem_ck                 (mem_ck),
        .mem_ck_n               (mem_ck_n),
        .mem_cke                (mem_cke),
        .mem_ras_n              (mem_ras_n),
        .mem_cas_n              (mem_cas_n),
        .mem_we_n               (mem_we_n),
        .mem_odt                (mem_odt),
        .mem_a                  (mem_a),
        .mem_ba                 (mem_ba),
        .mem_dqs                (mem_dqs),
        .mem_dqs_n              (mem_dqs_n),
        .mem_dq                 (mem_dq),
        .mem_dm                 (mem_dm)
    );

endmodule




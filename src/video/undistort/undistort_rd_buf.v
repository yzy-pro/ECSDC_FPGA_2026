`timescale 1ns / 1ps

module undistort_rd_buf #(
    parameter ADDR_WIDTH      = 28,
    parameter ADDR_OFFSET     = 32'h0000_0000,
    parameter H_NUM           = 1920,
    parameter V_NUM           = 1080,
    parameter DQ_WIDTH        = 32,
    parameter LEN_WIDTH       = 32,
    parameter PIX_WIDTH       = 16,
    parameter LINE_ADDR_WIDTH = 22,
    parameter FRAME_CNT_WIDTH = 8,
    // 0 = bilinear interpolation, 1 = nearest-neighbor.
    parameter INTERPOLATION_MODE = 1,
    // Tangential distortion coefficients in the same Q14 format as K1/K2.
    // They are compile-time parameters so a calibration build can use the
    // measured p1/p2 values without adding a run-time control bus.
    parameter signed [17:0] P1_Q14 = 18'sd0,
    parameter signed [17:0] P2_Q14 = 18'sd0,
    parameter ATTITUDE_WARP_ENABLE = 1'b1
) (
    input                         ddr_clk,
    input                         ddr_rstn,
    input                         vout_clk,
    input                         rd_fsync,
    input                         rd_active,
    input                         rd_en,
    input  [15:0]                 imu_yaw,
    input  [15:0]                 imu_pitch,
    input  [15:0]                 imu_roll,
    input                         imu_valid,
    output reg                    vout_de,
    output reg [PIX_WIDTH-1:0]    vout_data,
    input                         init_done,
    input  [1:0]                  completed_frame_bank,
    output [1:0]                  display_frame_bank,
    output                        ddr_rreq,
    output     [ADDR_WIDTH-1:0]   ddr_raddr,
    output      [LEN_WIDTH-1:0]   ddr_rd_len,
    input                         ddr_rrdy,
    input                         ddr_rdone,
    input  [8*DQ_WIDTH-1:0]       ddr_rdata,
    input                         ddr_rdata_en
);

    localparam integer CACHE_WORD_WIDTH = 272;
    localparam integer FRAC_BITS = 14;
    localparam signed [31:0] FX_Q14 = 32'sd12262554;
    localparam signed [31:0] FY_Q14 = 32'sd12256498;
    localparam signed [31:0] CX_Q14 = 32'sd15481296;
    localparam signed [31:0] CY_Q14 = 32'sd8558941;
    localparam signed [17:0] K1_Q14 = 18'sd162;
    localparam signed [17:0] K2_Q14 = -18'sd711;
    localparam signed [23:0] XN_START_Q22 = -24'sd5289644;
    localparam signed [23:0] YN_START_Q22 = -24'sd2923354;
    localparam signed [23:0] XN_STEP_Q22 = 24'sd5604;
    localparam signed [23:0] YN_STEP_Q22 = 24'sd5607;
    localparam signed [17:0] CACHE_P1_Q14 = 18'sd0;
    localparam signed [17:0] CACHE_P2_Q14 = 18'sd0;
    generate
        if(P1_Q14!=CACHE_P1_Q14 || P2_Q14!=CACHE_P2_Q14) begin : g_bad_cache_calibration
            REGENERATE_UNDISTORT_CACHE_FOR_P1_P2 invalid_calibration();
        end
    endgenerate
    wire cache_prefill_ready,cache_underrun;
    wire [1:0] frame_sel;
    wire [CACHE_WORD_WIDTH-1:0] even_word,odd_word;

    reg [11:0] x_count;
    reg [10:0] y_count;
    reg signed [23:0] xn_acc_q22, yn_acc_q22;
    reg signed [16:0] xn0, yn0, xn1, yn1, xn2, yn2, xn3, yn3, xn4, yn4, xn4a, yn4a;
    reg signed [33:0] x_sq1, y_sq1, xy1;
    // The squared coordinates need the same two register stages as r2.
    // Keeping x_sq1 directly into the d3 registers makes the tangential
    // terms one pixel ahead of r2_d3 because r2 itself passes through r20.
    reg signed [17:0] r20, r2_d3, r40;
    reg signed [17:0] x2_d2, y2_d2, xy_d2, xy_d3;
    reg signed [17:0] tan_x_base_d3, tan_y_base_d3;
    reg signed [17:0] k1_term4, k2_term4, scale1;
    reg signed [17:0] tan_x1_term4, tan_x2_term4;
    reg signed [17:0] tan_y1_term4, tan_y2_term4;
    reg signed [17:0] tan_x4a, tan_y4a;
    reg signed [17:0] xdist3, ydist3;
    reg signed [31:0] xsrc2, ysrc2;
    reg signed [31:0] fx_integer, fy_integer;
    reg signed [35:0] fx_fraction, fy_fraction;
    reg v6a;
    reg [2:0] affine_valid;
    reg v7c;
    reg [10:0] src_x0, src_y0;
    reg [3:0]  src_x_mod0;
    reg [4:0]  frac_x0, frac_y0;
    reg pix_rd_active_d, pix_rd_fsync_d;
    reg v0, v1, v2, v3, v4, v4a, v5, v6, v7, v7a, v7b, v8, v9, v10, v11, v12, v13;
    reg [6:0] cache_slot0;
    reg [10:0] cache_src_x0;
    reg [10:0] cache_src_y0;
    reg [3:0] cache_src_x_mod0;
    reg [4:0] cache_frac_x0, cache_frac_y0;
    reg        addr_y_odd;
    reg [3:0]  addr_x_mod;
    reg [4:0]  addr_fx, addr_fy;
    reg        addr_y_odd_d;
    reg [3:0]  addr_x_mod_d;
    reg [4:0]  addr_fx_d, addr_fy_d;
    reg [3:0] read_x_mod;
    reg [4:0] read_fx, read_fy;
    reg       read_y_odd;
    reg [3:0] select_x_mod;
    reg [4:0] select_fx, select_fy;
    reg       select_y_odd;
    reg [15:0] p00, p01, p10, p11;
    reg [4:0] interp_fx, interp_fy, interp_fy_d;
    reg [6:0] hr0, hg0, hb0, hr1, hg1, hb1;
    reg [4:0] nearest_r0, nearest_r1, nearest_b0, nearest_b1;
    reg [5:0] nearest_g0, nearest_g1;
    reg [12:0] vr0_prod, vr1_prod, vg0_prod, vg1_prod, vb0_prod, vb1_prod;
    reg [6:0] vr, vg, vb;
    reg frame_cache_valid;
    reg signed [15:0] yaw_hold, pitch_hold;
    reg signed [15:0] yaw_pending, pitch_pending;

    wire signed [31:0] affine_x_q14, affine_y_q14;
    wire signed [31:0] sample_x_q14 = affine_x_q14;
    wire signed [31:0] sample_y_q14 = affine_y_q14;
    imu_affine_q14 u_imu_affine (
        .clk(vout_clk),.src_x_q14(xsrc2),.src_y_q14(ysrc2),
        .yaw(ATTITUDE_WARP_ENABLE ? yaw_hold : 16'd0),
        .pitch(ATTITUDE_WARP_ENABLE ? pitch_hold : 16'd0),
        .roll(16'd0), // Roll remains in the UART packet but is ignored.
        .dst_x_q14(affine_x_q14),.dst_y_q14(affine_y_q14)
    );

    // init_done is generated in the DDR clock domain. Reset assertion may be
    // asynchronous, but both readiness signals are released through these
    // two pixel-clocked stages before the output pipeline starts.
    reg [1:0] vout_ready_sync;
    reg [1:0] cache_ready_sync;
    always @(posedge vout_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            vout_ready_sync <= 2'b00;
            cache_ready_sync <= 2'b00;
        end else begin
            vout_ready_sync <= {vout_ready_sync[0], init_done};
            cache_ready_sync <= {cache_ready_sync[0], cache_prefill_ready};
        end
    end
    // Cache readiness is deliberately not part of the pipeline reset. It is
    // cleared once per frame while the first source rows are fetched. If a
    // prefetch ever runs late, resetting the x/y accumulators in active video
    // would restart the mapping in the middle of a physical line.
    wire vout_pipeline_ready = vout_ready_sync[1];

    wire [5:0] inv_interp_fx = 6'd32 - {1'b0, interp_fx};
    wire [5:0] inv_interp_fy = 6'd32 - {1'b0, interp_fy_d};

    // Verilog multiplication otherwise inherits the operand width. Preserve
    // the complete product before the Q14 shift; truncating it here changes
    // the distortion curve rather than merely reducing precision.
    function automatic signed [33:0] mul17x17;
        input signed [16:0] a;
        input signed [16:0] b;
        reg signed [33:0] a_wide;
        begin
            a_wide = a;
            mul17x17 = a_wide * b;
        end
    endfunction

    function automatic signed [35:0] mul18x18;
        input signed [17:0] a;
        input signed [17:0] b;
        reg signed [35:0] a_wide;
        begin
            a_wide = a;
            mul18x18 = a_wide * b;
        end
    endfunction

    function automatic signed [35:0] mul17x18;
        input signed [16:0] a;
        input signed [17:0] b;
        reg signed [35:0] a_wide;
        begin
            a_wide = a;
            mul17x18 = a_wide * b;
        end
    endfunction

    // Eleven bits hold the largest weighted RGB565 channel sum
    // (63 * 32 = 2016). Explicitly widening each color operand prevents the
    // bilinear products from being evaluated at only 6 or 7 bits.
    wire [10:0] h_r0_sum = {6'd0, p00[15:11]} * inv_interp_fx +
                           {6'd0, p01[15:11]} * {1'b0, interp_fx};
    wire [10:0] h_g0_sum = {5'd0, p00[10:5]}  * inv_interp_fx +
                           {5'd0, p01[10:5]}  * {1'b0, interp_fx};
    wire [10:0] h_b0_sum = {6'd0, p00[4:0]}   * inv_interp_fx +
                           {6'd0, p01[4:0]}   * {1'b0, interp_fx};
    wire [10:0] h_r1_sum = {6'd0, p10[15:11]} * inv_interp_fx +
                           {6'd0, p11[15:11]} * {1'b0, interp_fx};
    wire [10:0] h_g1_sum = {5'd0, p10[10:5]}  * inv_interp_fx +
                           {5'd0, p11[10:5]}  * {1'b0, interp_fx};
    wire [10:0] h_b1_sum = {6'd0, p10[4:0]}   * inv_interp_fx +
                           {6'd0, p11[4:0]}   * {1'b0, interp_fx};
    // Register both vertical products before adding them.  Without this
    // boundary PDS cascades two APM multipliers and an adder in one 6.734 ns
    // pixel-clock period, which fails timing at 148.5 MHz.
    wire [13:0] v_r_sum = {1'b0, vr0_prod} + {1'b0, vr1_prod};
    wire [13:0] v_g_sum = {1'b0, vg0_prod} + {1'b0, vg1_prod};
    wire [13:0] v_b_sum = {1'b0, vb0_prod} + {1'b0, vb1_prod};


    undistort_band_cache #(.ADDR_WIDTH(ADDR_WIDTH),.ADDR_OFFSET(ADDR_OFFSET),
        .LINE_ADDR_WIDTH(LINE_ADDR_WIDTH)) u_band_cache (
        .ddr_clk(ddr_clk),.ddr_rstn(ddr_rstn),.vout_clk(vout_clk),
        .rd_fsync(rd_fsync),.rd_active(rd_active),.init_done(init_done),
        .completed_frame_bank(completed_frame_bank),.display_frame_bank(display_frame_bank),
        .frame_sel(frame_sel),.ddr_rreq(ddr_rreq),.ddr_raddr(ddr_raddr),.ddr_rd_len(ddr_rd_len),
        .ddr_rrdy(ddr_rrdy),.ddr_rdone(ddr_rdone),.ddr_rdata(ddr_rdata),.ddr_rdata_en(ddr_rdata_en),
        .cache_prefill_ready(cache_prefill_ready),.cache_underrun(cache_underrun),
        .src_x(src_x0),.src_y(src_y0),.even_word(even_word),.odd_word(odd_word)
    );

    always @(posedge vout_clk) begin
        if (!vout_pipeline_ready) begin
            x_count <= 0; y_count <= 0; pix_rd_active_d <= 0; pix_rd_fsync_d <= 0;
            frame_cache_valid <= 1'b0;
            xn_acc_q22 <= XN_START_Q22;
            yn_acc_q22 <= YN_START_Q22;
            v0 <= 0; v1 <= 0; v2 <= 0; v3 <= 0; v4 <= 0; v4a <= 0; v5 <= 0;
            v6 <= 0; v6a <= 0; v7 <= 0; v7a <= 0; v7b <= 0; v7c <= 0; v8 <= 0; v9 <= 0; v10 <= 0; v11 <= 0; v12 <= 0; v13 <= 0;
            vout_de <= 0; vout_data <= 0;
            yaw_hold <= 0; pitch_hold <= 0;
            yaw_pending <= 0; pitch_pending <= 0;
            affine_valid <= 0;
        end else begin
            if (imu_valid && ATTITUDE_WARP_ENABLE) begin
                yaw_pending <= imu_yaw;
                pitch_pending <= imu_pitch;
            end
            pix_rd_active_d <= rd_active;
            pix_rd_fsync_d <= rd_fsync;
            if (rd_fsync && !pix_rd_fsync_d) begin
                // One coherent attitude for the whole output frame. If a
                // packet arrives at VS, consume that packet immediately.
                yaw_hold <= (imu_valid && ATTITUDE_WARP_ENABLE) ? imu_yaw : yaw_pending;
                pitch_hold <= (imu_valid && ATTITUDE_WARP_ENABLE) ? imu_pitch : pitch_pending;
                x_count <= 0;
                y_count <= 0;
                xn_acc_q22 <= XN_START_Q22;
                yn_acc_q22 <= YN_START_Q22;
            end else if (rd_en) begin
                if (x_count < H_NUM-1) begin
                    x_count <= x_count + 1'b1;
                    xn_acc_q22 <= xn_acc_q22 + XN_STEP_Q22;
                end else begin
                    x_count <= 0;
                    xn_acc_q22 <= XN_START_Q22;
                end
            end else if (pix_rd_active_d && !rd_active) begin
                if (y_count < V_NUM-1) begin
                    y_count <= y_count + 1'b1;
                    yn_acc_q22 <= yn_acc_q22 + YN_STEP_Q22;
                end
            end

            // September 19 startup latch. This does NOT preserve a full old
            // frame if prefetch is late: the cache deadline must still hold
            // on every frame (checked by the full-raster regression).
            if (!frame_cache_valid && rd_active && !pix_rd_active_d && y_count == 0)
                frame_cache_valid <= cache_ready_sync[1];

            v0 <= rd_en;
            xn0 <= xn_acc_q22 >>> 8;
            yn0 <= yn_acc_q22 >>> 8;
            v1 <= v0;
            xn1 <= xn0;
            yn1 <= yn0;
            x_sq1 <= mul17x17(xn0, xn0);
            y_sq1 <= mul17x17(yn0, yn0);
            xy1 <= mul17x17(xn0, yn0);

            v2 <= v1;
            xn2 <= xn1;
            yn2 <= yn1;
            r20 <= (x_sq1 + y_sq1) >>> FRAC_BITS;
            x2_d2 <= x_sq1 >>> FRAC_BITS;
            y2_d2 <= y_sq1 >>> FRAC_BITS;
            xy_d2 <= xy1 >>> FRAC_BITS;

            v3 <= v2;
            xn3 <= xn2;
            yn3 <= yn2;
            r2_d3 <= r20;
            r40 <= mul18x18(r20, r20) >>> FRAC_BITS;
            xy_d3 <= xy_d2;
            // Register the tangential quadratic bases before their coefficient
            // multipliers. This keeps the r2+2*x^2/y^2 adder out of the same
            // 6.734 ns stage as the 18x18 multiplier.
            tan_x_base_d3 <= r20 + (x2_d2 <<< 1);
            tan_y_base_d3 <= r20 + (y2_d2 <<< 1);

            v4 <= v3;
            xn4 <= xn3;
            yn4 <= yn3;
            k1_term4 <= mul18x18(K1_Q14, r2_d3) >>> FRAC_BITS;
            k2_term4 <= mul18x18(K2_Q14, r40) >>> FRAC_BITS;
            // The doubled terms use a one-bit smaller shift so the factor 2
            // is included without an additional multiplier or pipeline stage.
            tan_x1_term4 <= mul18x18(P1_Q14, xy_d3) >>> (FRAC_BITS - 1);
            tan_x2_term4 <= mul18x18(P2_Q14, tan_x_base_d3) >>> FRAC_BITS;
            tan_y1_term4 <= mul18x18(P1_Q14, tan_y_base_d3) >>> FRAC_BITS;
            tan_y2_term4 <= mul18x18(P2_Q14, xy_d3) >>> (FRAC_BITS - 1);

            v4a <= v4;
            xn4a <= xn4;
            yn4a <= yn4;
            scale1 <= (1 <<< FRAC_BITS) + k1_term4 + k2_term4;
            tan_x4a <= tan_x1_term4 + tan_x2_term4;
            tan_y4a <= tan_y1_term4 + tan_y2_term4;

            v5 <= v4a;
            xdist3 <= (mul17x18(xn4a, scale1) >>> FRAC_BITS) + tan_x4a;
            ydist3 <= (mul17x18(yn4a, scale1) >>> FRAC_BITS) + tan_y4a;

            v6 <= v5;
            // Parallel 18x18 products, then a separate projection add stage.
            // Exact Q14 focal constants: 748*16384+7322 and +1266.
            fx_integer <= mul18x18(xdist3, 18'sd748);
            fy_integer <= mul18x18(ydist3, 18'sd748);
            fx_fraction <= mul18x18(xdist3, 18'sd7322);
            fy_fraction <= mul18x18(ydist3, 18'sd1266);
            v6a <= v6;
            xsrc2 <= fx_integer + (fx_fraction >>> FRAC_BITS) + CX_Q14;
            ysrc2 <= fy_integer + (fy_fraction >>> FRAC_BITS) + CY_Q14;

            affine_valid <= {affine_valid[1:0],v6a};
            v7 <= affine_valid[2];
            if ((sample_x_q14 >>> FRAC_BITS) <= 1) begin src_x0 <= 0; src_x_mod0 <= 0; frac_x0 <= 0; end
            else if ((sample_x_q14 >>> FRAC_BITS) >= H_NUM) begin src_x0 <= H_NUM-1; src_x_mod0 <= (H_NUM-1) & 4'hf; frac_x0 <= 0; end
            else begin src_x0 <= (sample_x_q14 >>> FRAC_BITS) - 1; src_x_mod0 <= ((sample_x_q14 >>> FRAC_BITS) - 1) & 4'hf; frac_x0 <= sample_x_q14[FRAC_BITS-1 -: 5]; end
            if ((sample_y_q14 >>> FRAC_BITS) <= 1) begin src_y0 <= 0; frac_y0 <= 0; end
            else if ((sample_y_q14 >>> FRAC_BITS) >= V_NUM) begin src_y0 <= V_NUM-1; frac_y0 <= 0; end
            else begin src_y0 <= (sample_y_q14 >>> FRAC_BITS) - 1; frac_y0 <= sample_y_q14[FRAC_BITS-1 -: 5]; end

            v7a <= v7;
            cache_slot0 <= {6'd0,src_y0[0]};
            cache_src_x0 <= src_x0;
            cache_src_y0 <= src_y0;
            cache_src_x_mod0 <= src_x_mod0;
            cache_frac_x0 <= frac_x0;
            cache_frac_y0 <= frac_y0;

            // Keep interpolation metadata aligned with the band cache pipeline.
            v7b <= v7a;

            addr_y_odd <= cache_slot0[0];
            addr_x_mod <= cache_src_x_mod0;
            addr_fx <= cache_frac_x0;
            addr_fy <= cache_frac_y0;



            v7c <= v7b;
            addr_y_odd_d <= addr_y_odd;
            addr_x_mod_d <= addr_x_mod;
            addr_fx_d <= addr_fx;
            addr_fy_d <= addr_fy;
            read_y_odd <= addr_y_odd_d;
            read_x_mod <= addr_x_mod_d;
            read_fx <= addr_fx_d;
            read_fy <= addr_fy_d;
            // Every rd_en must produce exactly one output-valid pulse. The
            // scaler treats each pulse as the next x coordinate, so dropping
            // one would shift every following pixel to the right.
            v8 <= v7c;

            v9 <= v8;

            select_y_odd <= read_y_odd;
            select_x_mod <= read_x_mod;
            select_fx <= read_fx;
            select_fy <= read_fy;

            v10 <= v9;
            interp_fx <= select_fx;
            interp_fy <= select_fy;
            if (select_y_odd) begin
                p00 <= pixel_at(odd_word, {1'b0, select_x_mod});
                p01 <= pixel_at(odd_word, {1'b0, select_x_mod} + 1'b1);
                p10 <= pixel_at(even_word, {1'b0, select_x_mod});
                p11 <= pixel_at(even_word, {1'b0, select_x_mod} + 1'b1);
            end else begin
                p00 <= pixel_at(even_word, {1'b0, select_x_mod});
                p01 <= pixel_at(even_word, {1'b0, select_x_mod} + 1'b1);
                p10 <= pixel_at(odd_word, {1'b0, select_x_mod});
                p11 <= pixel_at(odd_word, {1'b0, select_x_mod} + 1'b1);
            end

            v11 <= v10;
            interp_fy_d <= interp_fy;
            hr0 <= h_r0_sum >> 5;
            hg0 <= h_g0_sum >> 5;
            hb0 <= h_b0_sum >> 5;
            hr1 <= h_r1_sum >> 5;
            hg1 <= h_g1_sum >> 5;
            hb1 <= h_b1_sum >> 5;
            // Nearest-neighbor uses the closest source sample instead of
            // averaging four taps. Keep it in the same pipeline stage so
            // DE/HS/VS latency does not change when comparing modes.
            if (interp_fx < 5'd16) begin
                nearest_r0 <= p00[15:11];
                nearest_g0 <= p00[10:5];
                nearest_b0 <= p00[4:0];
                nearest_r1 <= p10[15:11];
                nearest_g1 <= p10[10:5];
                nearest_b1 <= p10[4:0];
            end else begin
                nearest_r0 <= p01[15:11];
                nearest_g0 <= p01[10:5];
                nearest_b0 <= p01[4:0];
                nearest_r1 <= p11[15:11];
                nearest_g1 <= p11[10:5];
                nearest_b1 <= p11[4:0];
            end

            v12 <= v11;
            if (INTERPOLATION_MODE == 0) begin
                vr0_prod <= {6'd0, hr0} * inv_interp_fy;
                vr1_prod <= {6'd0, hr1} * {1'b0, interp_fy_d};
                vg0_prod <= {6'd0, hg0} * inv_interp_fy;
                vg1_prod <= {6'd0, hg1} * {1'b0, interp_fy_d};
                vb0_prod <= {6'd0, hb0} * inv_interp_fy;
                vb1_prod <= {6'd0, hb1} * {1'b0, interp_fy_d};
            end else if (interp_fy_d < 5'd16) begin
                vr0_prod <= {nearest_r0, 5'd0};
                vr1_prod <= 13'd0;
                vg0_prod <= {nearest_g0, 5'd0};
                vg1_prod <= 13'd0;
                vb0_prod <= {nearest_b0, 5'd0};
                vb1_prod <= 13'd0;
            end else begin
                vr0_prod <= {nearest_r1, 5'd0};
                vr1_prod <= 13'd0;
                vg0_prod <= {nearest_g1, 5'd0};
                vg1_prod <= 13'd0;
                vb0_prod <= {nearest_b1, 5'd0};
                vb1_prod <= 13'd0;
            end

            v13 <= v12;
            vr <= v_r_sum >> 5;
            vg <= v_g_sum >> 5;
            vb <= v_b_sum >> 5;

            vout_de <= v13;
            // A late prefetch produces deterministic black pixels while line
            // length and coordinate phase remain intact. Normally this flag
            // becomes true during vertical blanking, before active video.
            vout_data <= frame_cache_valid
                       ? {vr[4:0], vg[5:0], vb[4:0]}
                       : 16'h0000;
        end
    end

    function automatic [15:0] pixel_at;
        input [CACHE_WORD_WIDTH-1:0] word;
        input [4:0] index;
        begin
            pixel_at = word[index*16 +: 16];
        end
    endfunction


endmodule


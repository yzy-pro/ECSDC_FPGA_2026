`timescale 1ns / 1ps

// Inverse yaw/pitch camera projection for the tile renderer.
//
// Coordinate convention:
//   * dst_x/dst_y are zero-based output pixel coordinates.
//   * src_x_q14/src_y_q14 are zero-based source coordinates in Q14.
//   * yaw/pitch are signed Q2048 radians. Roll is intentionally absent.
//   * positive yaw is a right-handed turn about up; positive pitch is down.
//
// The pose is sampled only when pose_load is asserted. Wait for pose_ready
// before the first in_valid pixel of a rendered frame. The
// divider is fully pipelined, so this module accepts one input pixel per
// clock after reset. map_valid is false for rays behind the camera, rays
// beyond the calibrated radial support, or coordinates without all four
// bilinear source taps. Downstream logic must emit black for map_valid=0;
// this module never clamps an out-of-range coordinate to an image edge.
module pose_inverse_project_q14 #(
    parameter integer H_NUM = 1920,
    parameter integer V_NUM = 1080,
    parameter signed [15:0] POSE_LIMIT_Q2048 = 16'sd1251,
    parameter signed [31:0] FX_Q14 = 32'sd12262554,
    parameter signed [31:0] FY_Q14 = 32'sd12256498,
    parameter signed [31:0] CX_Q14 = 32'sd15481296,
    parameter signed [31:0] CY_Q14 = 32'sd8558941,
    parameter signed [17:0] K1_Q14 = 18'sd162,
    parameter signed [17:0] K2_Q14 = -18'sd711,
    parameter signed [17:0] P1_Q14 = 18'sd0,
    parameter signed [17:0] P2_Q14 = 18'sd0,
    // Keep the exact restoring divider as the compatibility default.  The
    // LUT path is intended for measured error/resource comparison and can be
    // enabled by the top-level build once its timing is accepted.
    parameter integer RECIPROCAL_LUT_ENABLE = 0,
    parameter integer RUNTIME_CONTROL = 0
) (
    input                         clk,
    input                         rstn,

    input                         pose_load,
    // Sampled at pose_load; ignored in compatibility configurations.
    input                         lens_enable,
    input signed [15:0]           pose_yaw_q2048,
    input signed [15:0]           pose_pitch_q2048,
    output reg                    pose_clamped,
    output reg                    pose_ready,

    input                         in_valid,
    input [10:0]                  dst_x,
    input [10:0]                  dst_y,

    output reg                    out_valid,
    output reg                    map_valid,
    output reg signed [31:0]      src_x_q14,
    output reg signed [31:0]      src_y_q14
);

    localparam integer NORM_FRAC = 18;
    reg frame_lens_enable;
    localparam integer NORM_WIDTH = 24;
    localparam integer DIVIDEND_WIDTH = NORM_WIDTH + NORM_FRAC;
    localparam integer DIV_STAGES = DIVIDEND_WIDTH;

    // The inverse focal values are Q22. They retain substantially more
    // precision than the old Q22 raster accumulator after conversion to Q18.
    localparam signed [23:0] INV_FX_Q22 = (64'd68719476736 + FX_Q14/2) / FX_Q14;
    localparam signed [23:0] INV_FY_Q22 = (64'd68719476736 + FY_Q14/2) / FY_Q14;
    localparam signed [23:0] Z_EPS_Q18 = 24'sd1024;
    // Numerical radial support guard prevents polynomial extrapolation from
    // folding back. This is not an independently measured lens field of view.
    localparam signed [31:0] MAX_RADIUS2_Q18 = 32'sd600000;
    localparam signed [31:0] MAX_SOURCE_X_Q14 = (H_NUM-1) * 16384;
    localparam signed [31:0] MAX_SOURCE_Y_Q14 = (V_NUM-1) * 16384;

    reg signed [15:0] sin_yaw_q14, cos_yaw_q14;
    reg signed [15:0] sin_pitch_q14, cos_pitch_q14;
    reg [3:0] trig_valid;
    reg [15:0] trig0_yaw_abs, trig0_pitch_abs;
    reg [3:0] trig_yaw_negative, trig_pitch_negative;
    reg [31:0] trig1_yaw_degrees, trig1_pitch_degrees;
    reg signed [15:0] trig2_sy_low,trig2_cy_low,trig2_sp_low,trig2_cp_low;
    reg signed [15:0] trig2_sy_delta,trig2_cy_delta,trig2_sp_delta,trig2_cp_delta;
    reg [9:0] trig2_yaw_fraction,trig2_pitch_fraction;
    reg signed [15:0] trig3_sy_low,trig3_cy_low,trig3_sp_low,trig3_cp_low;
    reg signed [25:0] trig3_sy_delta,trig3_cy_delta,trig3_sp_delta,trig3_cp_delta;

    // A one-degree table with linear interpolation has less than 0.04 pixel
    // ray error at the configured +/-35 degree bound. The conversion constant
    // maps Q2048 radians to Q10 degrees: 180*1024/(pi*2048).
    function automatic signed [15:0] sin_deg_q14;
        input [5:0] degree;
        begin
            case (degree)
                0: sin_deg_q14 = 16'sd0;
                1: sin_deg_q14 = 16'sd286;
                2: sin_deg_q14 = 16'sd572;
                3: sin_deg_q14 = 16'sd857;
                4: sin_deg_q14 = 16'sd1143;
                5: sin_deg_q14 = 16'sd1428;
                6: sin_deg_q14 = 16'sd1713;
                7: sin_deg_q14 = 16'sd1997;
                8: sin_deg_q14 = 16'sd2280;
                9: sin_deg_q14 = 16'sd2563;
                10: sin_deg_q14 = 16'sd2845;
                11: sin_deg_q14 = 16'sd3126;
                12: sin_deg_q14 = 16'sd3406;
                13: sin_deg_q14 = 16'sd3686;
                14: sin_deg_q14 = 16'sd3964;
                15: sin_deg_q14 = 16'sd4240;
                16: sin_deg_q14 = 16'sd4516;
                17: sin_deg_q14 = 16'sd4790;
                18: sin_deg_q14 = 16'sd5063;
                19: sin_deg_q14 = 16'sd5334;
                20: sin_deg_q14 = 16'sd5604;
                21: sin_deg_q14 = 16'sd5872;
                22: sin_deg_q14 = 16'sd6138;
                23: sin_deg_q14 = 16'sd6402;
                24: sin_deg_q14 = 16'sd6664;
                25: sin_deg_q14 = 16'sd6924;
                26: sin_deg_q14 = 16'sd7182;
                27: sin_deg_q14 = 16'sd7438;
                28: sin_deg_q14 = 16'sd7692;
                29: sin_deg_q14 = 16'sd7943;
                30: sin_deg_q14 = 16'sd8192;
                31: sin_deg_q14 = 16'sd8438;
                32: sin_deg_q14 = 16'sd8682;
                33: sin_deg_q14 = 16'sd8923;
                34: sin_deg_q14 = 16'sd9162;
                35: sin_deg_q14 = 16'sd9397;
                36: sin_deg_q14 = 16'sd9630;
                default: sin_deg_q14 = 16'sd9630;
            endcase
        end
    endfunction

    function automatic signed [15:0] cos_deg_q14;
        input [5:0] degree;
        begin
            case (degree)
                0: cos_deg_q14 = 16'sd16384;
                1: cos_deg_q14 = 16'sd16382;
                2: cos_deg_q14 = 16'sd16374;
                3: cos_deg_q14 = 16'sd16362;
                4: cos_deg_q14 = 16'sd16344;
                5: cos_deg_q14 = 16'sd16322;
                6: cos_deg_q14 = 16'sd16294;
                7: cos_deg_q14 = 16'sd16262;
                8: cos_deg_q14 = 16'sd16225;
                9: cos_deg_q14 = 16'sd16182;
                10: cos_deg_q14 = 16'sd16135;
                11: cos_deg_q14 = 16'sd16083;
                12: cos_deg_q14 = 16'sd16026;
                13: cos_deg_q14 = 16'sd15964;
                14: cos_deg_q14 = 16'sd15897;
                15: cos_deg_q14 = 16'sd15826;
                16: cos_deg_q14 = 16'sd15749;
                17: cos_deg_q14 = 16'sd15668;
                18: cos_deg_q14 = 16'sd15582;
                19: cos_deg_q14 = 16'sd15491;
                20: cos_deg_q14 = 16'sd15396;
                21: cos_deg_q14 = 16'sd15296;
                22: cos_deg_q14 = 16'sd15191;
                23: cos_deg_q14 = 16'sd15082;
                24: cos_deg_q14 = 16'sd14968;
                25: cos_deg_q14 = 16'sd14849;
                26: cos_deg_q14 = 16'sd14726;
                27: cos_deg_q14 = 16'sd14598;
                28: cos_deg_q14 = 16'sd14466;
                29: cos_deg_q14 = 16'sd14330;
                30: cos_deg_q14 = 16'sd14189;
                31: cos_deg_q14 = 16'sd14044;
                32: cos_deg_q14 = 16'sd13894;
                33: cos_deg_q14 = 16'sd13741;
                34: cos_deg_q14 = 16'sd13583;
                35: cos_deg_q14 = 16'sd13421;
                36: cos_deg_q14 = 16'sd13255;
                default: cos_deg_q14 = 16'sd13255;
            endcase
        end
    endfunction

    function automatic [15:0] bounded_abs_q2048;
        input signed [15:0] angle;
        begin
            if (angle > POSE_LIMIT_Q2048 || angle < -POSE_LIMIT_Q2048)
                bounded_abs_q2048 = POSE_LIMIT_Q2048;
            else if (angle[15])
                bounded_abs_q2048 = -angle;
            else
                bounded_abs_q2048 = angle;
        end
    endfunction

    function automatic signed [15:0] interp_sin_q14;
        input [15:0] angle_abs_q2048;
        reg [31:0] degree_q10;
        reg [5:0] degree_int;
        reg [9:0] degree_frac;
        reg signed [15:0] low, high;
        reg signed [25:0] delta_product;
        begin
            degree_q10 = (angle_abs_q2048 * 16'd29335) >> 10;
            degree_int = degree_q10 >> 10;
            degree_frac = degree_q10[9:0];
            low = sin_deg_q14(degree_int);
            high = sin_deg_q14(degree_int + 1'b1);
            delta_product = (high-low) * $signed({1'b0,degree_frac});
            interp_sin_q14 = low + (delta_product >>> 10);
        end
    endfunction

    function automatic signed [15:0] interp_cos_q14;
        input [15:0] angle_abs_q2048;
        reg [31:0] degree_q10;
        reg [5:0] degree_int;
        reg [9:0] degree_frac;
        reg signed [15:0] low, high;
        reg signed [25:0] delta_product;
        begin
            degree_q10 = (angle_abs_q2048 * 16'd29335) >> 10;
            degree_int = degree_q10 >> 10;
            degree_frac = degree_q10[9:0];
            low = cos_deg_q14(degree_int);
            high = cos_deg_q14(degree_int + 1'b1);
            delta_product = (high-low) * $signed({1'b0,degree_frac});
            interp_cos_q14 = low + (delta_product >>> 10);
        end
    endfunction

    function automatic [23:0] abs_q18;
        input signed [23:0] value;
        begin
            abs_q18 = value[23] ? -value : value;
        end
    endfunction

    function automatic signed [23:0] apply_sign_q18;
        input sign;
        input [23:0] magnitude;
        begin
            apply_sign_q18 = sign ? -$signed({1'b0,magnitude[22:0]}) :
                                      $signed({1'b0,magnitude[22:0]});
        end
    endfunction

    function automatic signed [49:0] mul18x32;
        input signed [17:0] a;
        input signed [31:0] b;
        reg signed [49:0] a_wide;
        begin
            a_wide = a;
            mul18x32 = a_wide * b;
        end
    endfunction

    function automatic signed [57:0] mul18x40;
        input signed [17:0] a;
        input signed [39:0] b;
        reg signed [57:0] a_wide;
        begin
            a_wide = a;
            mul18x40 = a_wide * b;
        end
    endfunction

    function automatic signed [55:0] mul24x32;
        input signed [23:0] a;
        input signed [31:0] b;
        reg signed [55:0] a_wide;
        begin
            a_wide = a;
            mul24x32 = a_wide * b;
        end
    endfunction

    function automatic signed [63:0] mul32x32;
        input signed [31:0] a;
        input signed [31:0] b;
        reg signed [63:0] a_wide;
        begin
            a_wide = a;
            mul32x32 = a_wide * b;
        end
    endfunction

    // Convert the requested output pixel centre to an ideal Q18 ray.
    wire signed [31:0] dst_x_center_q14 =
        ($signed({1'b0,dst_x}) <<< 14) + 32'sd16384 - CX_Q14;
    wire signed [31:0] dst_y_center_q14 =
        ($signed({1'b0,dst_y}) <<< 14) + 32'sd16384 - CY_Q14;
    wire signed [55:0] xn_product = dst_x_center_q14 * INV_FX_Q22;
    wire signed [55:0] yn_product = dst_y_center_q14 * INV_FY_Q22;
    // Five front-end stages isolate normalization, yaw products, yaw sums,
    // pitch products and pitch sums. The prior combinational chain crossed
    // three multipliers before the divider input. Each accepted coordinate
    // carries its own trigonometric snapshot, including across pose_load.
    reg norm_valid, yaw_mul_valid, yaw_sum_valid, pitch_mul_valid, ray_valid;
    reg signed [23:0] xn_q18, yn_q18;
    reg signed [15:0] norm_sy, norm_cy, norm_sp, norm_cp;
    reg signed [39:0] rx_cos_product, yawz_sin_product;
    reg signed [23:0] yaw_mul_y;
    reg signed [15:0] yaw_mul_sy, yaw_mul_cy, yaw_mul_sp, yaw_mul_cp;
    reg signed [23:0] yaw_ray_x_q18, yaw_z_q18, yaw_sum_y;
    reg signed [15:0] yaw_sum_sp, yaw_sum_cp;
    reg signed [39:0] ry_cos_product, ry_sin_product, rz_sin_product, rz_cos_product;
    reg signed [23:0] pitch_mul_x;
    reg signed [23:0] ray_x_q18, ray_y_q18, ray_z_q18;

    wire lut_valid;
    wire lut_candidate;
    wire signed [23:0] lut_x_q18, lut_y_q18;

    // C = Ry(-yaw) Rx(-pitch), matching tools/audit_rotation_tiles.py.
    // Sign-extend before changing Q14 trig values to Q18.  A shift on the
    // native 16-bit value would discard the upper four bits at large angles.
    wire signed [23:0] sin_yaw_q18 =
        $signed({{8{yaw_mul_sy[15]}}, yaw_mul_sy}) <<< 4;
    wire signed [23:0] cos_yaw_q18 =
        $signed({{8{yaw_mul_cy[15]}}, yaw_mul_cy}) <<< 4;

    wire ray_depth_valid = (ray_z_q18 > Z_EPS_Q18);
    // A ratio above two cannot map inside this calibrated sensor. Keeping it
    // out of the divider also bounds every later fixed-point product.
    wire [24:0] ray_z_twice = {ray_z_q18[23:0],1'b0};
    wire ray_ratio_bounded = (abs_q18(ray_x_q18) < ray_z_twice) &&
                             (abs_q18(ray_y_q18) < ray_z_twice);

    pose_reciprocal_lut u_reciprocal_lut (
        .x_q18(ray_x_q18), .y_q18(ray_y_q18), .z_q18(ray_z_q18),
        .in_valid(ray_valid),
        .in_candidate(ray_valid && ray_depth_valid && ray_ratio_bounded),
        .out_valid(lut_valid), .out_candidate(lut_candidate),
        .x_over_z_q18(lut_x_q18), .y_over_z_q18(lut_y_q18)
    );

    // Two parallel restoring dividers calculate x/z and y/z. Each stage
    // consumes one dividend bit; no '/' operator is inferred.
    reg [23:0] div_den [0:DIV_STAGES];
    reg [DIVIDEND_WIDTH-1:0] div_num_x [0:DIV_STAGES];
    reg [DIVIDEND_WIDTH-1:0] div_num_y [0:DIV_STAGES];
    reg [24:0] div_rem_x [0:DIV_STAGES];
    reg [24:0] div_rem_y [0:DIV_STAGES];
    reg [DIVIDEND_WIDTH-1:0] div_q_x [0:DIV_STAGES];
    reg [DIVIDEND_WIDTH-1:0] div_q_y [0:DIV_STAGES];
    reg div_valid [0:DIV_STAGES];
    reg div_candidate [0:DIV_STAGES];
    reg div_x_negative [0:DIV_STAGES];
    reg div_y_negative [0:DIV_STAGES];

    // Lens pipeline. Q18 is used for normalized rays, r2, and tangential
    // terms; the radial scale remains Q14 to match the calibration file.
    reg l0_valid, l0_candidate;
    reg signed [23:0] l0_x_q18, l0_y_q18;
    reg l1_valid, l1_candidate;
    reg signed [23:0] l1_x_q18, l1_y_q18;
    reg signed [47:0] l1_x2_q36, l1_y2_q36, l1_xy_q36;
    reg l2_valid, l2_candidate;
    reg signed [23:0] l2_x_q18, l2_y_q18;
    reg signed [31:0] l2_r2_q18, l2_x2_q18, l2_y2_q18, l2_xy_q18;
    reg l3_valid, l3_candidate;
    reg signed [23:0] l3_x_q18, l3_y_q18;
    reg signed [31:0] l3_r2_q18, l3_x2_q18, l3_y2_q18, l3_xy_q18;
    reg signed [39:0] l3_r4_q18;
    // Every publishable ray has 0 <= r2 <= 600000 < 2**20. Retain
    // the full r2 for the final guard, but square only its unsigned low
    // 20 bits. Out-of-support rays may have a different unused r4; their
    // original full r2 still rejects them. Valid results are bit-exact.
    wire [39:0] radius_square_q36 = l2_r2_q18[19:0] * l2_r2_q18[19:0];
    reg l3p_valid,l3p_candidate;
    reg signed [23:0] l3p_x_q18,l3p_y_q18;
    reg signed [31:0] l3p_r2_q18;
    reg signed [49:0] l3p_k1,l3p_p1xy,l3p_p2xx,l3p_p1yy,l3p_p2xy;
    reg signed [57:0] l3p_k2;
    reg l4_valid, l4_candidate;
    reg signed [23:0] l4_x_q18, l4_y_q18;
    reg signed [31:0] l4_r2_q18, l4_scale_q14, l4_tan_x_q18, l4_tan_y_q18;
    reg l4p_valid,l4p_candidate;
    reg signed [31:0] l4p_r2_q18,l4p_tan_x_q18,l4p_tan_y_q18;
    reg signed [55:0] l4p_x_product,l4p_y_product;
    reg l5_valid, l5_candidate;
    reg signed [31:0] l5_r2_q18, l5_xdist_q18, l5_ydist_q18;

    // Split each signed 32x32 focal multiply into four single-DSP partial
    // products. Register the cross-term sum, the assembled product, and the
    // principal-point addition independently before range validation.
    reg [3:0] focal_valid,focal_candidate;
    reg signed [33:0] focal_x_ll,focal_y_ll;
    reg signed [32:0] focal_x_lh,focal_x_hl,focal_y_lh,focal_y_hl;
    reg signed [31:0] focal_x_hh,focal_y_hh;
    reg signed [33:0] focal_x_cross,focal_y_cross;
    reg signed [63:0] focal_x_base,focal_y_base;
    reg signed [63:0] mapped_x_product,mapped_y_product;
    reg signed [63:0] mapped_x_q14,mapped_y_q14;
    wire signed [63:0] focal_x_cross_wide={{30{focal_x_cross[33]}},focal_x_cross};
    wire signed [63:0] focal_y_cross_wide={{30{focal_y_cross[33]}},focal_y_cross};

    integer i;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            frame_lens_enable <= 1'b1;
            sin_yaw_q14 <= 0;
            cos_yaw_q14 <= 16'sd16384;
            sin_pitch_q14 <= 0;
            cos_pitch_q14 <= 16'sd16384;
            pose_clamped <= 1'b0;
            pose_ready <= 1'b0; trig_valid <= 0;
            trig0_yaw_abs <= 0; trig0_pitch_abs <= 0;
            trig_yaw_negative <= 0; trig_pitch_negative <= 0;
            trig1_yaw_degrees <= 0; trig1_pitch_degrees <= 0;
            trig2_sy_low<=0; trig2_cy_low<=0; trig2_sp_low<=0; trig2_cp_low<=0;
            trig2_sy_delta<=0; trig2_cy_delta<=0; trig2_sp_delta<=0; trig2_cp_delta<=0;
            trig2_yaw_fraction<=0; trig2_pitch_fraction<=0;
            trig3_sy_low<=0; trig3_cy_low<=0; trig3_sp_low<=0; trig3_cp_low<=0;
            trig3_sy_delta<=0; trig3_cy_delta<=0; trig3_sp_delta<=0; trig3_cp_delta<=0;
            norm_valid <= 0; yaw_mul_valid <= 0; yaw_sum_valid <= 0;
            pitch_mul_valid <= 0; ray_valid <= 0;
            xn_q18 <= 0; yn_q18 <= 0;
            norm_sy <= 0; norm_cy <= 0; norm_sp <= 0; norm_cp <= 0;
            rx_cos_product <= 0; yawz_sin_product <= 0; yaw_mul_y <= 0;
            yaw_mul_sy <= 0; yaw_mul_cy <= 0; yaw_mul_sp <= 0; yaw_mul_cp <= 0;
            yaw_ray_x_q18 <= 0; yaw_z_q18 <= 0; yaw_sum_y <= 0;
            yaw_sum_sp <= 0; yaw_sum_cp <= 0;
            ry_cos_product <= 0; ry_sin_product <= 0;
            rz_sin_product <= 0; rz_cos_product <= 0; pitch_mul_x <= 0;
            ray_x_q18 <= 0; ray_y_q18 <= 0; ray_z_q18 <= 0;
            for (i=0; i<=DIV_STAGES; i=i+1) begin
                div_den[i] <= 0;
                div_num_x[i] <= 0;
                div_num_y[i] <= 0;
                div_rem_x[i] <= 0;
                div_rem_y[i] <= 0;
                div_q_x[i] <= 0;
                div_q_y[i] <= 0;
                div_valid[i] <= 1'b0;
                div_candidate[i] <= 1'b0;
                div_x_negative[i] <= 1'b0;
                div_y_negative[i] <= 1'b0;
            end
            l0_valid <= 0; l0_candidate <= 0; l0_x_q18 <= 0; l0_y_q18 <= 0;
            l1_valid <= 0; l1_candidate <= 0; l1_x_q18 <= 0; l1_y_q18 <= 0;
            l1_x2_q36 <= 0; l1_y2_q36 <= 0; l1_xy_q36 <= 0;
            l2_valid <= 0; l2_candidate <= 0; l2_x_q18 <= 0; l2_y_q18 <= 0;
            l2_r2_q18 <= 0; l2_x2_q18 <= 0; l2_y2_q18 <= 0; l2_xy_q18 <= 0;
            l3_valid <= 0; l3_candidate <= 0; l3_x_q18 <= 0; l3_y_q18 <= 0;
            l3_r2_q18 <= 0; l3_x2_q18 <= 0; l3_y2_q18 <= 0; l3_xy_q18 <= 0;
            l3_r4_q18 <= 0;
            l3p_valid<=0; l3p_candidate<=0; l3p_x_q18<=0; l3p_y_q18<=0; l3p_r2_q18<=0;
            l3p_k1<=0; l3p_k2<=0; l3p_p1xy<=0; l3p_p2xx<=0; l3p_p1yy<=0; l3p_p2xy<=0;
            l4_valid <= 0; l4_candidate <= 0; l4_x_q18 <= 0; l4_y_q18 <= 0;
            l4_r2_q18 <= 0; l4_scale_q14 <= 0; l4_tan_x_q18 <= 0; l4_tan_y_q18 <= 0;
            l4p_valid<=0; l4p_candidate<=0; l4p_r2_q18<=0;
            l4p_tan_x_q18<=0; l4p_tan_y_q18<=0; l4p_x_product<=0; l4p_y_product<=0;
            l5_valid <= 0; l5_candidate <= 0; l5_r2_q18 <= 0;
            l5_xdist_q18 <= 0; l5_ydist_q18 <= 0;
            focal_valid<=0; focal_candidate<=0;
            focal_x_ll<=0; focal_y_ll<=0; focal_x_lh<=0; focal_x_hl<=0; focal_y_lh<=0; focal_y_hl<=0;
            focal_x_hh<=0; focal_y_hh<=0; focal_x_cross<=0; focal_y_cross<=0;
            focal_x_base<=0; focal_y_base<=0; mapped_x_product<=0; mapped_y_product<=0;
            mapped_x_q14<=0; mapped_y_q14<=0;
            out_valid <= 0;
            map_valid <= 0;
            src_x_q14 <= 0;
            src_y_q14 <= 0;
        end else begin
            // Pose preparation: bounded magnitude -> degrees -> adjacent
            // table values -> interpolation products -> signed coefficients.
            // This is also clocked; a frame cannot begin until pose_ready.
            trig_valid <= {trig_valid[2:0],pose_load};
            trig_yaw_negative <= {trig_yaw_negative[2:0],pose_yaw_q2048[15]};
            trig_pitch_negative <= {trig_pitch_negative[2:0],pose_pitch_q2048[15]};
            if (pose_load) begin
                frame_lens_enable <= !RUNTIME_CONTROL || lens_enable;
                trig0_yaw_abs <= bounded_abs_q2048(pose_yaw_q2048);
                trig0_pitch_abs <= bounded_abs_q2048(pose_pitch_q2048);
                pose_clamped <= (pose_yaw_q2048 > POSE_LIMIT_Q2048) ||
                                (pose_yaw_q2048 < -POSE_LIMIT_Q2048) ||
                                (pose_pitch_q2048 > POSE_LIMIT_Q2048) ||
                                (pose_pitch_q2048 < -POSE_LIMIT_Q2048);
                pose_ready <= 1'b0;
            end
            trig1_yaw_degrees <= (trig0_yaw_abs * 16'd29335) >> 10;
            trig1_pitch_degrees <= (trig0_pitch_abs * 16'd29335) >> 10;
            trig2_sy_low <= sin_deg_q14(trig1_yaw_degrees[15:10]);
            trig2_cy_low <= cos_deg_q14(trig1_yaw_degrees[15:10]);
            trig2_sp_low <= sin_deg_q14(trig1_pitch_degrees[15:10]);
            trig2_cp_low <= cos_deg_q14(trig1_pitch_degrees[15:10]);
            trig2_sy_delta <= sin_deg_q14(trig1_yaw_degrees[15:10]+1'b1)-sin_deg_q14(trig1_yaw_degrees[15:10]);
            trig2_cy_delta <= cos_deg_q14(trig1_yaw_degrees[15:10]+1'b1)-cos_deg_q14(trig1_yaw_degrees[15:10]);
            trig2_sp_delta <= sin_deg_q14(trig1_pitch_degrees[15:10]+1'b1)-sin_deg_q14(trig1_pitch_degrees[15:10]);
            trig2_cp_delta <= cos_deg_q14(trig1_pitch_degrees[15:10]+1'b1)-cos_deg_q14(trig1_pitch_degrees[15:10]);
            trig2_yaw_fraction <= trig1_yaw_degrees[9:0];
            trig2_pitch_fraction <= trig1_pitch_degrees[9:0];
            trig3_sy_low<=trig2_sy_low; trig3_cy_low<=trig2_cy_low;
            trig3_sp_low<=trig2_sp_low; trig3_cp_low<=trig2_cp_low;
            trig3_sy_delta <= trig2_sy_delta * $signed({1'b0,trig2_yaw_fraction});
            trig3_cy_delta <= trig2_cy_delta * $signed({1'b0,trig2_yaw_fraction});
            trig3_sp_delta <= trig2_sp_delta * $signed({1'b0,trig2_pitch_fraction});
            trig3_cp_delta <= trig2_cp_delta * $signed({1'b0,trig2_pitch_fraction});
            if (trig_valid[3]) begin
                sin_yaw_q14 <= trig_yaw_negative[3] ?
                    -(trig3_sy_low + (trig3_sy_delta >>> 10)) :
                     (trig3_sy_low + (trig3_sy_delta >>> 10));
                cos_yaw_q14 <= trig3_cy_low + (trig3_cy_delta >>> 10);
                sin_pitch_q14 <= trig_pitch_negative[3] ?
                    -(trig3_sp_low + (trig3_sp_delta >>> 10)) :
                     (trig3_sp_low + (trig3_sp_delta >>> 10));
                cos_pitch_q14 <= trig3_cp_low + (trig3_cp_delta >>> 10);
                if (!pose_load && trig_valid[2:0]==0) pose_ready <= 1'b1;
            end

            norm_valid <= in_valid;
            xn_q18 <= xn_product >>> 18;
            yn_q18 <= yn_product >>> 18;
            norm_sy <= sin_yaw_q14; norm_cy <= cos_yaw_q14;
            norm_sp <= sin_pitch_q14; norm_cp <= cos_pitch_q14;

            yaw_mul_valid <= norm_valid;
            rx_cos_product <= norm_cy * xn_q18;
            yawz_sin_product <= norm_sy * xn_q18;
            yaw_mul_y <= yn_q18;
            yaw_mul_sy <= norm_sy; yaw_mul_cy <= norm_cy;
            yaw_mul_sp <= norm_sp; yaw_mul_cp <= norm_cp;

            yaw_sum_valid <= yaw_mul_valid;
            yaw_ray_x_q18 <= (rx_cos_product >>> 14) + sin_yaw_q18;
            yaw_z_q18 <= cos_yaw_q18 - (yawz_sin_product >>> 14);
            yaw_sum_y <= yaw_mul_y;
            yaw_sum_sp <= yaw_mul_sp; yaw_sum_cp <= yaw_mul_cp;

            pitch_mul_valid <= yaw_sum_valid;
            ry_cos_product <= yaw_sum_cp * yaw_sum_y;
            ry_sin_product <= yaw_sum_sp * yaw_z_q18;
            rz_sin_product <= yaw_sum_sp * yaw_sum_y;
            rz_cos_product <= yaw_sum_cp * yaw_z_q18;
            pitch_mul_x <= yaw_ray_x_q18;

            ray_valid <= pitch_mul_valid;
            ray_x_q18 <= pitch_mul_x;
            ray_y_q18 <= (ry_cos_product >>> 14) - (ry_sin_product >>> 14);
            ray_z_q18 <= (rz_sin_product >>> 14) + (rz_cos_product >>> 14);

            if (!RECIPROCAL_LUT_ENABLE) begin
                div_den[0] <= ray_depth_valid ? ray_z_q18 : Z_EPS_Q18;
                div_num_x[0] <= (ray_depth_valid && ray_ratio_bounded) ?
                                {abs_q18(ray_x_q18),{NORM_FRAC{1'b0}}} : 0;
                div_num_y[0] <= (ray_depth_valid && ray_ratio_bounded) ?
                                {abs_q18(ray_y_q18),{NORM_FRAC{1'b0}}} : 0;
                div_rem_x[0] <= 0;
                div_rem_y[0] <= 0;
                div_q_x[0] <= 0;
                div_q_y[0] <= 0;
                div_valid[0] <= ray_valid;
                div_candidate[0] <= ray_valid && ray_depth_valid && ray_ratio_bounded;
                div_x_negative[0] <= ray_x_q18[23];
                div_y_negative[0] <= ray_y_q18[23];

                for (i=0; i<DIV_STAGES; i=i+1) begin
                    div_den[i+1] <= div_den[i];
                    div_num_x[i+1] <= div_num_x[i];
                    div_num_y[i+1] <= div_num_y[i];
                    div_valid[i+1] <= div_valid[i];
                    div_candidate[i+1] <= div_candidate[i];
                    div_x_negative[i+1] <= div_x_negative[i];
                    div_y_negative[i+1] <= div_y_negative[i];
                    if ({div_rem_x[i][23:0],div_num_x[i][DIVIDEND_WIDTH-1-i]} >=
                        {1'b0,div_den[i]}) begin
                        div_rem_x[i+1] <= {div_rem_x[i][23:0],div_num_x[i][DIVIDEND_WIDTH-1-i]} -
                                            {1'b0,div_den[i]};
                        div_q_x[i+1] <= {div_q_x[i][DIVIDEND_WIDTH-2:0],1'b1};
                    end else begin
                        div_rem_x[i+1] <= {div_rem_x[i][23:0],div_num_x[i][DIVIDEND_WIDTH-1-i]};
                        div_q_x[i+1] <= {div_q_x[i][DIVIDEND_WIDTH-2:0],1'b0};
                    end
                    if ({div_rem_y[i][23:0],div_num_y[i][DIVIDEND_WIDTH-1-i]} >=
                        {1'b0,div_den[i]}) begin
                        div_rem_y[i+1] <= {div_rem_y[i][23:0],div_num_y[i][DIVIDEND_WIDTH-1-i]} -
                                            {1'b0,div_den[i]};
                        div_q_y[i+1] <= {div_q_y[i][DIVIDEND_WIDTH-2:0],1'b1};
                    end else begin
                        div_rem_y[i+1] <= {div_rem_y[i][23:0],div_num_y[i][DIVIDEND_WIDTH-1-i]};
                        div_q_y[i+1] <= {div_q_y[i][DIVIDEND_WIDTH-2:0],1'b0};
                    end
                end

                l0_valid <= div_valid[DIV_STAGES];
                l0_candidate <= div_candidate[DIV_STAGES];
                l0_x_q18 <= apply_sign_q18(div_x_negative[DIV_STAGES],div_q_x[DIV_STAGES][23:0]);
                l0_y_q18 <= apply_sign_q18(div_y_negative[DIV_STAGES],div_q_y[DIV_STAGES][23:0]);
            end else begin
                l0_valid <= lut_valid;
                l0_candidate <= lut_candidate;
                l0_x_q18 <= lut_x_q18;
                l0_y_q18 <= lut_y_q18;
            end

            l1_valid <= l0_valid;
            l1_candidate <= l0_candidate;
            l1_x_q18 <= l0_x_q18;
            l1_y_q18 <= l0_y_q18;
            // The divider admits |ray component / depth| < 2 only, so
            // every Q18 quotient fits signed20 bits. Rejected rays divide
            // a zero numerator. These narrowed operands are therefore exact
            // for all reachable samples and avoid a long24x24 DSP chain.
            l1_x2_q36 <= $signed(l0_x_q18[19:0]) * $signed(l0_x_q18[19:0]);
            l1_y2_q36 <= $signed(l0_y_q18[19:0]) * $signed(l0_y_q18[19:0]);
            l1_xy_q36 <= $signed(l0_x_q18[19:0]) * $signed(l0_y_q18[19:0]);

            l2_valid <= l1_valid;
            l2_candidate <= l1_candidate;
            l2_x_q18 <= l1_x_q18;
            l2_y_q18 <= l1_y_q18;
            l2_r2_q18 <= (l1_x2_q36 + l1_y2_q36) >>> NORM_FRAC;
            l2_x2_q18 <= l1_x2_q36 >>> NORM_FRAC;
            l2_y2_q18 <= l1_y2_q36 >>> NORM_FRAC;
            l2_xy_q18 <= l1_xy_q36 >>> NORM_FRAC;

            l3_valid <= l2_valid;
            l3_candidate <= l2_candidate;
            l3_x_q18 <= l2_x_q18;
            l3_y_q18 <= l2_y_q18;
            l3_r2_q18 <= l2_r2_q18;
            l3_x2_q18 <= l2_x2_q18;
            l3_y2_q18 <= l2_y2_q18;
            l3_xy_q18 <= l2_xy_q18;
            l3_r4_q18 <= radius_square_q36 >> NORM_FRAC;

            l3p_valid<=l3_valid; l3p_candidate<=l3_candidate;
            l3p_x_q18<=l3_x_q18; l3p_y_q18<=l3_y_q18; l3p_r2_q18<=l3_r2_q18;
            l3p_k1<=mul18x32(K1_Q14,l3_r2_q18);
            l3p_k2<=mul18x40(K2_Q14,l3_r4_q18);
            l3p_p1xy<=mul18x32(P1_Q14,l3_xy_q18);
            l3p_p2xx<=mul18x32(P2_Q14,l3_r2_q18+(l3_x2_q18<<<1));
            l3p_p1yy<=mul18x32(P1_Q14,l3_r2_q18+(l3_y2_q18<<<1));
            l3p_p2xy<=mul18x32(P2_Q14,l3_xy_q18);

            l4_valid <= l3p_valid;
            l4_candidate <= l3p_candidate;
            l4_x_q18 <= l3p_x_q18;
            l4_y_q18 <= l3p_y_q18;
            l4_r2_q18 <= l3p_r2_q18;
            l4_scale_q14 <= (!RUNTIME_CONTROL || frame_lens_enable) ?
                32'sd16384 + (l3p_k1 >>> NORM_FRAC) + (l3p_k2 >>> NORM_FRAC) : 32'sd16384;
            l4_tan_x_q18 <= (!RUNTIME_CONTROL || frame_lens_enable) ?
                (l3p_p1xy >>> 13) + (l3p_p2xx >>> 14) : 32'sd0;
            l4_tan_y_q18 <= (!RUNTIME_CONTROL || frame_lens_enable) ?
                (l3p_p1yy >>> 14) + (l3p_p2xy >>> 13) : 32'sd0;

            l4p_valid<=l4_valid; l4p_candidate<=l4_candidate; l4p_r2_q18<=l4_r2_q18;
            l4p_x_product<=mul24x32(l4_x_q18,l4_scale_q14);
            l4p_y_product<=mul24x32(l4_y_q18,l4_scale_q14);
            l4p_tan_x_q18<=l4_tan_x_q18; l4p_tan_y_q18<=l4_tan_y_q18;
            l5_valid <= l4p_valid;
            l5_candidate <= l4p_candidate;
            l5_r2_q18 <= l4p_r2_q18;
            l5_xdist_q18 <= (l4p_x_product >>> 14) + l4p_tan_x_q18;
            l5_ydist_q18 <= (l4p_y_product >>> 14) + l4p_tan_y_q18;

            focal_valid<={focal_valid[2:0],l5_valid};
            focal_candidate<={focal_candidate[2:0],l5_candidate &&
                ((RUNTIME_CONTROL && !frame_lens_enable) || l5_r2_q18<=MAX_RADIUS2_Q18)};
            focal_x_ll <= $signed({1'b0,l5_xdist_q18[15:0]}) * $signed({1'b0,FX_Q14[15:0]});
            focal_x_lh <= $signed({1'b0,l5_xdist_q18[15:0]}) * $signed(FX_Q14[31:16]);
            focal_x_hl <= $signed(l5_xdist_q18[31:16]) * $signed({1'b0,FX_Q14[15:0]});
            focal_x_hh <= $signed(l5_xdist_q18[31:16]) * $signed(FX_Q14[31:16]);
            focal_y_ll <= $signed({1'b0,l5_ydist_q18[15:0]}) * $signed({1'b0,FY_Q14[15:0]});
            focal_y_lh <= $signed({1'b0,l5_ydist_q18[15:0]}) * $signed(FY_Q14[31:16]);
            focal_y_hl <= $signed(l5_ydist_q18[31:16]) * $signed({1'b0,FY_Q14[15:0]});
            focal_y_hh <= $signed(l5_ydist_q18[31:16]) * $signed(FY_Q14[31:16]);
            focal_x_cross<=focal_x_lh+focal_x_hl;
            focal_y_cross<=focal_y_lh+focal_y_hl;
            focal_x_base<={focal_x_hh,focal_x_ll[31:0]};
            focal_y_base<={focal_y_hh,focal_y_ll[31:0]};
            mapped_x_product<=focal_x_base+(focal_x_cross_wide<<<16);
            mapped_y_product<=focal_y_base+(focal_y_cross_wide<<<16);
            mapped_x_q14<=(mapped_x_product>>>NORM_FRAC)+CX_Q14-32'sd16384;
            mapped_y_q14<=(mapped_y_product>>>NORM_FRAC)+CY_Q14-32'sd16384;

            out_valid <= focal_valid[3];
            if (focal_valid[3] && focal_candidate[3] &&
                mapped_x_q14 >= 0 && mapped_x_q14 < MAX_SOURCE_X_Q14 &&
                mapped_y_q14 >= 0 && mapped_y_q14 < MAX_SOURCE_Y_Q14) begin
                map_valid <= 1'b1;
                src_x_q14 <= mapped_x_q14[31:0];
                src_y_q14 <= mapped_y_q14[31:0];
            end else begin
                map_valid <= 1'b0;
                src_x_q14 <= 0;
                src_y_q14 <= 0;
            end
        end
    end
endmodule

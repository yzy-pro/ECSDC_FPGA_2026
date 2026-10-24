`timescale 1ns/1ps
// Frame-adaptive gamma before RGB565 quantization / geometric correction.
// RGB, DE and the full VS level have exactly two registered stages; II=1.
// Curves use y=round(255*(x/255)^exponent), exponents .50,.65,.80,1,1.25,1.55,1.90.
// Raw input statistics drive open-loop illumination adaptation. Two identical
// classifications are required to change target; the active curve moves at
// most one level at each VS rising edge. The first frame is identity.
// Statistics become valid when the NEXT frame starts, excluding blanking.
// Curve decisions therefore affect a later complete frame, never part of one.
module adaptive_gamma_stream (
    input clk, rstn,
    input in_vs, in_de,
    input [7:0] in_r, in_g, in_b,
    input enable,
    output reg out_vs, out_de,
    output [7:0] out_r, out_g, out_b,
    output reg [2:0] active_curve, target_curve,
    output reg stats_valid,
    output reg [31:0] luma_sum, pixel_count, dark_count, highlight_count,
    // Metadata belongs to the completed statistics frame, not the new curve.
    output reg [2:0] stats_curve, stats_target,
    output reg stats_enabled
);
    reg vs_d, vs0, de0, sof0, enable0;
    reg [7:0] r0,g0,b0,luma0;
    wire [9:0] luma_wide={2'b0,in_r}+{1'b0,in_g,1'b0}+{2'b0,in_b};
    reg frame_enable, enable1;
    reg [7:0] bypass_r,bypass_g,bypass_b;
    wire [2:0] stepped_curve=(active_curve<target_curve) ? active_curve+3'd1 :
                             (active_curve>target_curve) ? active_curve-3'd1 : active_curve;
    wire [2:0] pixel_curve=sof0 ? stepped_curve : active_curve;
    wire [7:0] gamma_r,gamma_g,gamma_b;
    adaptive_gamma_lut u_r(.clk(clk),.curve(pixel_curve),.value(r0),.result(gamma_r));
    adaptive_gamma_lut u_g(.clk(clk),.curve(pixel_curve),.value(g0),.result(gamma_g));
    adaptive_gamma_lut u_b(.clk(clk),.curve(pixel_curve),.value(b0),.result(gamma_b));
    assign out_r=enable1 ? gamma_r : bypass_r;
    assign out_g=enable1 ? gamma_g : bypass_g;
    assign out_b=enable1 ? gamma_b : bypass_b;

    // 22-bit counts / 30-bit luma cover at least 4,194,303 RGB888 pixels.
    // In particular 1080p is 2,073,600 pixels, maximum sum 528,768,000.
    reg [29:0] running_luma;
    reg [21:0] running_count,running_dark,running_highlight;
    reg frame_seen;
    reg classify_valid;
    reg very_dark,dim,slightly_dim,slightly_bright,bright,very_bright,mixed_light;
    reg [2:0] candidate_curve;
    reg candidate_seen;
    wire [31:0] count32=pixel_count;
    // Fixed threshold products synthesize to shifts/adds, no runtime division.
    wire [31:0] count48=(count32<<5)+(count32<<4);
    wire [31:0] count80=(count32<<6)+(count32<<4);
    wire [31:0] count112=(count32<<7)-(count32<<4);
    wire [31:0] count144=(count32<<7)+(count32<<4);
    wire [31:0] count176=(count32<<7)+(count32<<5)+(count32<<4);
    wire [31:0] count208=(count32<<8)-(count32<<5)-(count32<<4);
    wire [2:0] classified_curve=mixed_light ? 3'd2 :
        very_dark ? 3'd0 : dim ? 3'd1 : slightly_dim ? 3'd2 :
        very_bright ? 3'd6 : bright ? 3'd5 : slightly_bright ? 3'd4 : 3'd3;

    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            vs_d<=0;vs0<=0;de0<=0;sof0<=0;enable0<=0;
            r0<=0;g0<=0;b0<=0;luma0<=0;
            out_vs<=0;out_de<=0;bypass_r<=0;bypass_g<=0;bypass_b<=0;
            frame_enable<=0;enable1<=0;active_curve<=3;target_curve<=3;
            running_luma<=0;running_count<=0;running_dark<=0;running_highlight<=0;
            frame_seen<=0;stats_valid<=0;luma_sum<=0;pixel_count<=0;dark_count<=0;highlight_count<=0;
            stats_curve<=3;stats_target<=3;stats_enabled<=0;
            classify_valid<=0;very_dark<=0;dim<=0;slightly_dim<=0;
            slightly_bright<=0;bright<=0;very_bright<=0;mixed_light<=0;
            candidate_curve<=3;candidate_seen<=0;
        end else begin
            vs_d<=in_vs;vs0<=in_vs;de0<=in_de;sof0<=in_vs&&!vs_d;enable0<=enable;
            r0<=in_r;g0<=in_g;b0<=in_b;luma0<=luma_wide[9:2];
            out_vs<=vs0;out_de<=de0;bypass_r<=r0;bypass_g<=g0;bypass_b<=b0;
            enable1<=sof0 ? enable0 : frame_enable;
            if(sof0) begin frame_enable<=enable0;active_curve<=stepped_curve;end

            stats_valid<=0;
            if(sof0) begin
                luma_sum<={2'b0,running_luma};pixel_count<={10'b0,running_count};
                dark_count<={10'b0,running_dark};highlight_count<={10'b0,running_highlight};
                stats_valid<=frame_seen && running_count!=0;
                stats_curve<=active_curve;stats_target<=target_curve;stats_enabled<=frame_enable;
                frame_seen<=1;
                // The first active pixel belongs to the new frame, including
                // when DE and VS rise on the same source clock.
                running_luma<=de0 ? luma0 : 0;running_count<=de0 ? 1 : 0;
                running_dark<=de0 && luma0<48 ? 1 : 0;
                running_highlight<=de0 && luma0>=208 ? 1 : 0;
            end else if(de0 && frame_seen) begin
                running_luma<=running_luma+luma0;running_count<=running_count+1'b1;
                if(luma0<48) running_dark<=running_dark+1'b1;
                if(luma0>=208) running_highlight<=running_highlight+1'b1;
            end

            classify_valid<=stats_valid;
            if(stats_valid) begin
                very_dark<=luma_sum<count48;dim<=luma_sum<count80;slightly_dim<=luma_sum<count112;
                slightly_bright<=luma_sum>count144;bright<=luma_sum>count176;very_bright<=luma_sum>count208;
                // A substantial shadow and highlight population signals a
                // mixed/backlit scene. Mild lifting protects bright details.
                mixed_light<=(dark_count<<3)>=pixel_count && (highlight_count<<3)>=pixel_count;
            end
            if(classify_valid) begin
                if(candidate_seen && candidate_curve==classified_curve)
                    target_curve<=classified_curve;
                candidate_curve<=classified_curve;candidate_seen<=1;
            end
        end
    end
endmodule

`timescale 1ns/1ps
// Streaming preprocessing boundary for the future adaptive stage.
// mode 0: bypass; mode 1: per-channel gain/offset; mode 2: programmable LUT.
// The current video path can leave enable low and incur no data latency.
module adaptive_preprocess_stream #(
    parameter PIXEL_WIDTH = 8
) (
    input                    clk,
    input                    rstn,
    input                    frame_start,
    input                    in_de,
    input  [PIXEL_WIDTH-1:0] in_r,
    input  [PIXEL_WIDTH-1:0] in_g,
    input  [PIXEL_WIDTH-1:0] in_b,
    input                    enable,
    input  [1:0]              mode,
    input  [PIXEL_WIDTH+1:0]  gain_q8,
    input  signed [PIXEL_WIDTH:0] offset,
    input                    lut_we,
    input  [PIXEL_WIDTH-1:0] lut_addr,
    input  [PIXEL_WIDTH-1:0] lut_r_data,
    input  [PIXEL_WIDTH-1:0] lut_g_data,
    input  [PIXEL_WIDTH-1:0] lut_b_data,
    output [PIXEL_WIDTH-1:0] out_r,
    output [PIXEL_WIDTH-1:0] out_g,
    output [PIXEL_WIDTH-1:0] out_b,
    output                   out_de,
    output reg [31:0]        luma_sum,
    output reg [31:0]        pixel_count,
    output reg               stats_valid
);
    reg [PIXEL_WIDTH-1:0] lut_r [0:(1<<PIXEL_WIDTH)-1];
    reg [PIXEL_WIDTH-1:0] lut_g [0:(1<<PIXEL_WIDTH)-1];
    reg [PIXEL_WIDTH-1:0] lut_b [0:(1<<PIXEL_WIDTH)-1];
    integer i;

    function automatic [PIXEL_WIDTH-1:0] clamp_pixel(input signed [2*PIXEL_WIDTH+2:0] value);
        begin
            if (value < 0) clamp_pixel = {PIXEL_WIDTH{1'b0}};
            else if (value > ((1<<PIXEL_WIDTH)-1))
                clamp_pixel = {PIXEL_WIDTH{1'b1}};
            else clamp_pixel = value[PIXEL_WIDTH-1:0];
        end
    endfunction

    function automatic [PIXEL_WIDTH-1:0] adjust_pixel(
        input [PIXEL_WIDTH-1:0] value,
        input [PIXEL_WIDTH+1:0] gain,
        input signed [PIXEL_WIDTH:0] add_offset
    );
        reg signed [2*PIXEL_WIDTH+2:0] product;
        reg signed [2*PIXEL_WIDTH+2:0] value_wide;
        reg signed [2*PIXEL_WIDTH+2:0] gain_wide;
        begin
            value_wide = value;
            gain_wide = gain;
            product = value_wide * gain_wide;
            adjust_pixel = clamp_pixel((product >>> 8) + add_offset);
        end
    endfunction

    wire [PIXEL_WIDTH-1:0] gain_r = adjust_pixel(in_r, gain_q8, offset);
    wire [PIXEL_WIDTH-1:0] gain_g = adjust_pixel(in_g, gain_q8, offset);
    wire [PIXEL_WIDTH-1:0] gain_b = adjust_pixel(in_b, gain_q8, offset);
    assign out_r = (!enable || mode == 0) ? in_r :
                   (mode == 2'd2 ? lut_r[in_r] : gain_r);
    assign out_g = (!enable || mode == 0) ? in_g :
                   (mode == 2'd2 ? lut_g[in_g] : gain_g);
    assign out_b = (!enable || mode == 0) ? in_b :
                   (mode == 2'd2 ? lut_b[in_b] : gain_b);
    assign out_de = in_de;

    reg [31:0] running_luma, running_count;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            luma_sum <= 0;
            pixel_count <= 0;
            stats_valid <= 1'b0;
            running_luma <= 0;
            running_count <= 0;
            for (i=0; i<(1<<PIXEL_WIDTH); i=i+1) begin
                lut_r[i] <= i[PIXEL_WIDTH-1:0];
                lut_g[i] <= i[PIXEL_WIDTH-1:0];
                lut_b[i] <= i[PIXEL_WIDTH-1:0];
            end
        end else begin
            stats_valid <= 1'b0;
            if (lut_we) begin
                lut_r[lut_addr] <= lut_r_data;
                lut_g[lut_addr] <= lut_g_data;
                lut_b[lut_addr] <= lut_b_data;
            end
            if (frame_start) begin
                luma_sum <= running_luma;
                pixel_count <= running_count;
                running_luma <= in_de ? ((in_r * 77 + in_g * 150 + in_b * 29) >> 8) : 0;
                running_count <= in_de ? 1 : 0;
                stats_valid <= 1'b1;
            end else if (in_de) begin
                running_luma <= running_luma + ((in_r * 77 + in_g * 150 + in_b * 29) >> 8);
                running_count <= running_count + 1'b1;
            end
        end
    end
endmodule

`timescale 1ns / 1ps

// Explicit RGB565 to RGB888 expansion. This is deliberately kept separate
// from gamma so the color format conversion can be tested or bypassed alone.
module rgb565_to_rgb888 (
    input  [15:0] rgb565_in,
    input         de_in,
    output [7:0]  r_out,
    output [7:0]  g_out,
    output [7:0]  b_out,
    output        de_out
);
    assign r_out  = {rgb565_in[15:11], rgb565_in[15:13]};
    assign g_out  = {rgb565_in[10:5],  rgb565_in[10:9]};
    assign b_out  = {rgb565_in[4:0],   rgb565_in[4:2]};
    assign de_out = de_in;
endmodule

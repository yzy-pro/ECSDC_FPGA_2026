`timescale 1ns / 1ps

// Select one pixel from every 1920-pixel input line.  The host expands a
// 1440-pixel line with src_x = floor(dst_x*3/4).  The first occurrence of
// each source pixel is at all positions except dst_x == 1 (mod 4).
module scale_in_1920_to_1440 #(
    parameter X_WIDTH = 12
) (
    input                  clk,
    input                  rstn,
    input                  de_in,
    input  [7:0]           r_in,
    input  [7:0]           g_in,
    input  [7:0]           b_in,
    output reg             active_out,
    output reg             wr_en,
    output reg [15:0]      wr_data
);
    reg [1:0] x_mod4;

    always @(posedge clk) begin
        if (!rstn) begin
            x_mod4 <= 2'd0;
            active_out <= 1'b0;
            wr_en <= 1'b0;
            wr_data <= 16'd0;
        end else begin
            // Register the complete write interface at the HDMI input edge.
            // This keeps the external DE/RGB pins out of the frame-buffer
            // control cone and preserves their alignment through the delay.
            active_out <= de_in;
            wr_en <= de_in && (x_mod4 != 2'd1);
            wr_data <= {r_in[7:3], g_in[7:2], b_in[7:3]};

            if (!de_in)
                x_mod4 <= 2'd0;
            else if (x_mod4 == 2'd3)
                x_mod4 <= 2'd0;
            else
                x_mod4 <= x_mod4 + 1'b1;
        end
    end
endmodule

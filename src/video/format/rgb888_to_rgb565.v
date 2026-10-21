`timescale 1ns / 1ps

// September 19 rising-edge input stage, with column dropping removed.
// FDC models same-launch-cycle pad capture; keep this register in the IOL.
// VS is captured alongside RGB/DE, not allowed into downstream reset logic.
module rgb888_to_rgb565 (
    input                  clk,
    input                  rstn,
    input                  vs_in,
    input                  de_in,
    input  [7:0]           r_in,
    input  [7:0]           g_in,
    input  [7:0]           b_in,
    output reg             vs_out /* synthesis syn_useioff = 1 */,
    output reg             active_out /* synthesis syn_useioff = 1 */,
    output reg             wr_en /* synthesis syn_useioff = 1 */,
    output reg [15:0]      wr_data /* synthesis syn_useioff = 1 */
);

    always @(posedge clk) begin
        if (!rstn) begin
            vs_out <= 1'b1;
            active_out <= 1'b0;
            wr_en <= 1'b0;
            wr_data <= 16'd0;
        end else begin
            vs_out <= vs_in;
            // Register the complete write interface at the HDMI input edge.
            // This keeps the external DE/RGB pins out of the frame-buffer
            // control cone and preserves their alignment through the delay.
            active_out <= de_in;
            wr_en <= de_in;
            wr_data <= {r_in[7:3], g_in[7:2], b_in[7:3]};

        end
    end
endmodule

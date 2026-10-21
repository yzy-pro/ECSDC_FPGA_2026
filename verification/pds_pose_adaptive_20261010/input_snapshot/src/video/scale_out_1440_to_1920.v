`timescale 1ns / 1ps

// Generate 1440 read requests during a 1920-pixel active line and expand the
// processed stream back to 1920 pixels.  The source pixel is requested at
// x=0,2,3,4,6,7,...; x=1,5,9,... repeats the previous source pixel.
// PIPE_DELAY must equal the latency from rd_en to frame_de in the
// undistortion/read pipeline, including its output register alignment.
module scale_out_1440_to_1920 #(
    parameter PIPE_DELAY = 17
) (
    input                  clk,
    input                  rstn,
    input                  timing_de,
    input                  frame_de,
    input  [15:0]          frame_data,
    output                 alg_rd_en,
    output                 out_de,
    output [15:0]          out_data
);
    reg [1:0] x_mod4;
    reg [PIPE_DELAY-1:0] de_pipe;
    reg [15:0] last_pixel;

    always @(posedge clk) begin
        if (!rstn) begin
            x_mod4    <= 2'd0;
            de_pipe   <= {PIPE_DELAY{1'b0}};
            last_pixel <= 16'd0;
        end else begin
            if (!timing_de)
                x_mod4 <= 2'd0;
            else if (x_mod4 == 2'd3)
                x_mod4 <= 2'd0;
            else
                x_mod4 <= x_mod4 + 1'b1;

            de_pipe <= {de_pipe[PIPE_DELAY-2:0], timing_de};

            // frame_de is asserted only on requested source pixels.  Holding
            // the previous value on the other cycles performs the 3:4 expand.
            if (frame_de)
                last_pixel <= frame_data;
        end
    end

    assign alg_rd_en = timing_de && (x_mod4 != 2'd1);
    assign out_de    = de_pipe[PIPE_DELAY-1];
    // Select a newly completed pipeline pixel without adding another clock of
    // latency; otherwise the first active output pixel would still be stale.
    assign out_data  = frame_de ? frame_data : last_pixel;
endmodule

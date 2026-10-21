`timescale 1ns/1ps
// September 19 output scaler's DE pipeline, without dropping/repeating pixels.
// Never gate the physical HDMI raster with DDR initialization or cache status.
module video_raster_delay #(parameter integer PIPE_DELAY = 23) (
    input clk, input rstn, input timing_de, output display_de
);
    reg [PIPE_DELAY-1:0] de_pipe;
    integer i;
    always @(posedge clk) begin
        if (!rstn) de_pipe <= 0;
        else begin
            de_pipe[0] <= timing_de;
            for (i=1; i<PIPE_DELAY; i=i+1) de_pipe[i] <= de_pipe[i-1];
        end
    end
    assign display_de = de_pipe[PIPE_DELAY-1];
endmodule

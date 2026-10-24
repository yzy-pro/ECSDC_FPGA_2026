`timescale 1ns/1ps
// 8-N-1, idle high. valid/ready accepts exactly one byte; stop lasts a full bit.
module uart_tx #(
    parameter integer CLK_HZ=50000000, BAUD=115200
) (
    input clk, rstn, valid,
    input [7:0] data,
    output ready, tx
);
    localparam integer DIVISOR=(CLK_HZ+BAUD/2)/BAUD;
    reg [31:0] count;
    reg [9:0] shift;
    reg [3:0] remaining;
    assign ready=remaining==0;
    assign tx=ready ? 1'b1 : shift[0];
    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin count<=0;shift<=10'h3ff;remaining<=0;end
        else if(ready) begin
            if(valid) begin
                shift<={1'b1,data,1'b0};remaining<=10;count<=DIVISOR-1;
            end
        end else if(count==0) begin
            shift<={1'b1,shift[9:1]};remaining<=remaining-1'b1;count<=DIVISOR-1;
        end else count<=count-1'b1;
    end
endmodule

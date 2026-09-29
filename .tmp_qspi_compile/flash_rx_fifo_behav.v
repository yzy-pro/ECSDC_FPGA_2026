`timescale 1ns/1ps
module flash_rx_fifo (
    input  wire        wr_clk,
    input  wire        wr_rst,
    input  wire        wr_en,
    input  wire [31:0] wr_data,
    output wire        wr_full,
    output wire        almost_full,
    input  wire        rd_clk,
    input  wire        rd_rst,
    input  wire        rd_en,
    output reg  [31:0] rd_data,
    output wire        rd_empty,
    output wire        almost_empty
);
    reg [31:0] mem [0:31];
    reg [5:0] wr_ptr, rd_ptr;
    assign wr_full = (wr_ptr[4:0] == rd_ptr[4:0]) && (wr_ptr[5] != rd_ptr[5]);
    assign rd_empty = (wr_ptr == rd_ptr);
    assign almost_full = 1'b0;
    assign almost_empty = rd_empty;
    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) wr_ptr <= 6'd0;
        else if (wr_en && !wr_full) begin
            mem[wr_ptr[4:0]] <= wr_data;
            wr_ptr <= wr_ptr + 1'b1;
        end
    end
    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) begin
            rd_ptr <= 6'd0;
            rd_data <= 32'd0;
        end else if (rd_en && !rd_empty) begin
            rd_data <= mem[rd_ptr[4:0]];
            rd_ptr <= rd_ptr + 1'b1;
        end
    end
endmodule

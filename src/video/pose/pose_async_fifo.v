`timescale 1ns/1ps

// Dual-clock ready/valid FIFO, with exactly 2**ADDR_BITS entries (ADDR_BITS>=1).
// Pointers cross clock domains as Gray code through two synchronizer stages.
// Assert rstn globally; its release is synchronized separately in each domain.
// A reset discards every entry. rd_data is meaningful only when rd_valid=1.
//
// The synchronous RAM read prefetches the current/next head into rd_data.
// The read pointer advances only on a consumer handshake, so the prefetched
// word remains included in occupancy and cannot be overwritten while stalled.
// Both interfaces can transfer one word per clock after initial prefetch.
// wr_free is a conservative write-domain credit count; rd_count is a
// conservative read-domain occupancy, including the prefetched output word.
// Counts become current only after the remote pointer crosses the synchronizer.
module pose_async_fifo #(
    parameter integer WIDTH = 256,
    parameter integer ADDR_BITS = 9
) (
    input wr_clk,
    input rd_clk,
    input rstn,
    input wr_valid,
    output wr_ready,
    input [WIDTH-1:0] wr_data,
    output rd_valid,
    input rd_ready,
    output reg [WIDTH-1:0] rd_data,
    output [ADDR_BITS:0] wr_free,
    output [ADDR_BITS:0] rd_count
);
    localparam integer DEPTH = 1 << ADDR_BITS;
    localparam [ADDR_BITS:0] CAPACITY = DEPTH;
    localparam [ADDR_BITS:0] FULL_XOR = (1 << ADDR_BITS) |
                                                 (1 << (ADDR_BITS-1));

    // No reset on the memory or its read data register: retain block RAM
    // inference with one write port and one registered, independent-clock port.
    reg [WIDTH-1:0] memory [0:DEPTH-1];
    reg [ADDR_BITS:0] wr_binary, wr_gray;
    reg [ADDR_BITS:0] rd_binary, rd_gray;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_BITS:0] rd_gray_wr1 /* synthesis PAP_ASYNC_REG=1 */;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_BITS:0] rd_gray_wr2 /* synthesis PAP_ASYNC_REG=1 */;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_BITS:0] wr_gray_rd1 /* synthesis PAP_ASYNC_REG=1 */;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_BITS:0] wr_gray_rd2 /* synthesis PAP_ASYNC_REG=1 */;
    (* ASYNC_REG = "TRUE" *) reg [1:0] wr_reset_sync /* synthesis PAP_ASYNC_REG=1 */;
    (* ASYNC_REG = "TRUE" *) reg [1:0] rd_reset_sync /* synthesis PAP_ASYNC_REG=1 */;
    reg wr_full, rd_valid_q;

    function [ADDR_BITS:0] gray_to_binary;
        input [ADDR_BITS:0] gray;
        integer bit_index;
        begin
            gray_to_binary[ADDR_BITS] = gray[ADDR_BITS];
            for (bit_index=ADDR_BITS-1; bit_index>=0; bit_index=bit_index-1)
                gray_to_binary[bit_index] =
                    gray_to_binary[bit_index+1] ^ gray[bit_index];
        end
    endfunction

    wire wr_running = rstn && wr_reset_sync[1];
    wire rd_running = rstn && rd_reset_sync[1];
    wire wr_take = wr_valid && wr_ready;
    wire rd_take = rd_valid && rd_ready;
    wire [ADDR_BITS:0] wr_next = wr_binary + wr_take;
    wire [ADDR_BITS:0] rd_next = rd_binary + rd_take;
    wire [ADDR_BITS:0] wr_gray_next = (wr_next >> 1) ^ wr_next;
    wire [ADDR_BITS:0] rd_gray_next = (rd_next >> 1) ^ rd_next;
    wire next_head_available = rd_gray_next != wr_gray_rd2;
    wire prefetch = rd_running && (!rd_valid_q || rd_ready) &&
                    next_head_available;
    wire [ADDR_BITS:0] wr_used = wr_binary - gray_to_binary(rd_gray_wr2);

    assign wr_ready = wr_running && !wr_full;
    assign rd_valid = rd_running && rd_valid_q;
    assign wr_free = wr_running ? CAPACITY - wr_used : {ADDR_BITS+1{1'b0}};
    assign rd_count = rd_running ? gray_to_binary(wr_gray_rd2) - rd_binary :
                                  {ADDR_BITS+1{1'b0}};

    always @(posedge wr_clk or negedge rstn) begin
        if (!rstn) begin
            wr_reset_sync <= 0;
            rd_gray_wr1 <= 0;
            rd_gray_wr2 <= 0;
        end else begin
            wr_reset_sync <= {wr_reset_sync[0],1'b1};
            rd_gray_wr1 <= rd_gray;
            rd_gray_wr2 <= rd_gray_wr1;
        end
    end

    always @(posedge rd_clk or negedge rstn) begin
        if (!rstn) begin
            rd_reset_sync <= 0;
            wr_gray_rd1 <= 0;
            wr_gray_rd2 <= 0;
        end else begin
            rd_reset_sync <= {rd_reset_sync[0],1'b1};
            wr_gray_rd1 <= wr_gray;
            wr_gray_rd2 <= wr_gray_rd1;
        end
    end

    always @(posedge wr_clk) begin
        if (wr_take)
            memory[wr_binary[ADDR_BITS-1:0]] <= wr_data;
    end

    always @(posedge wr_clk or negedge rstn) begin
        if (!rstn) begin
            wr_binary <= 0;
            wr_gray <= 0;
            wr_full <= 0;
        end else if (wr_running) begin
            wr_binary <= wr_next;
            wr_gray <= wr_gray_next;
            wr_full <= wr_gray_next == (rd_gray_wr2 ^ FULL_XOR);
        end
    end

    always @(posedge rd_clk) begin
        if (prefetch)
            rd_data <= memory[rd_next[ADDR_BITS-1:0]];
    end

    always @(posedge rd_clk or negedge rstn) begin
        if (!rstn) begin
            rd_binary <= 0;
            rd_gray <= 0;
            rd_valid_q <= 0;
        end else if (rd_running) begin
            rd_binary <= rd_next;
            rd_gray <= rd_gray_next;
            if (!rd_valid_q || rd_ready)
                rd_valid_q <= next_head_available;
        end
    end
endmodule

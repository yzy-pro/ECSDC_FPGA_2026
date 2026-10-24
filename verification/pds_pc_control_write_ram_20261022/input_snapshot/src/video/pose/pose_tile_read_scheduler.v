`timescale 1ns/1ps
// Read scheduler for the arbitrary yaw/pitch tile path.
// A descriptor is an inclusive source rectangle. Each source row is split
// into aligned 256-bit words and 1..MAX_BURST beat commands. Data gaps are
// legal; only accepted data beats advance the command counter.
module pose_tile_read_scheduler #(
    parameter ADDR_WIDTH = 28,
    parameter MAX_BURST = 16,
    parameter ROW_ADDR_STRIDE = 960,
    parameter ADDR_UNIT_PER_BEAT = 8,
    parameter TILE_WORD_STRIDE = 128
) (
    input                   clk,
    input                   rstn,
    input                   tile_start,
    input  [1:0]            source_bank,
    input  [10:0]           source_x0,
    input  [10:0]           source_x1,
    input  [10:0]           source_y0,
    input  [10:0]           source_y1,
    output reg              tile_ready,
    output reg              tile_done,
    output reg              cmd_valid,
    input                   cmd_ready,
    output reg [ADDR_WIDTH-1:0] cmd_addr,
    output reg [4:0]        cmd_len,
    input                   data_valid,
    input  [MAX_BURST*256-1:0] data,
    input                   data_last,
    output reg              tile_data_valid,
    output reg [13:0]       tile_data_addr,
    output reg [255:0]      tile_data,
    output reg              tile_data_last,
    output reg              busy,
    output reg              error
);
    localparam S_IDLE=2'd0, S_CMD=2'd1, S_DATA=2'd2;
    reg [1:0] state;
    reg [1:0] bank_q;
    reg [10:0] x0_q, x1_q, y0_q, y1_q, row_q;
    reg [8:0] first_word_q, last_word_q, next_word_q;
    reg [4:0] expected_beats, received_beats;
    reg [8:0] row_words_q;
    reg [13:0] tile_row_base_q;
    integer i;

    wire [10:0] aligned_x0 = {source_x0[10:4],4'd0};
    wire [10:0] aligned_x1 = {source_x1[10:4],4'd0};
    wire [8:0] first_word = aligned_x0[10:4];
    wire [8:0] last_word = aligned_x1[10:4];

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE;
            tile_ready <= 1'b1;
            tile_done <= 1'b0;
            cmd_valid <= 1'b0;
            cmd_addr <= 0;
            cmd_len <= 0;
            tile_data_valid <= 1'b0;
            tile_data_addr <= 0;
            tile_data <= 0;
            tile_data_last <= 1'b0;
            busy <= 1'b0;
            error <= 1'b0;
            bank_q <= 0; x0_q <= 0; x1_q <= 0; y0_q <= 0; y1_q <= 0; row_q <= 0;
            first_word_q <= 0; last_word_q <= 0; next_word_q <= 0;
            expected_beats <= 0; received_beats <= 0; row_words_q <= 0;
            tile_row_base_q <= 0;
        end else begin
            tile_done <= 1'b0;
            tile_data_valid <= 1'b0;
            tile_data_last <= 1'b0;
            if (state == S_IDLE) begin
                tile_ready <= 1'b1;
                cmd_valid <= 1'b0;
                busy <= 1'b0;
                if (tile_start && source_x0 <= source_x1 && source_y0 <= source_y1 &&
                    source_x1 < 1920 && source_y1 < 1080) begin
                    bank_q <= source_bank;
                    x0_q <= aligned_x0; x1_q <= aligned_x1;
                    y0_q <= source_y0; y1_q <= source_y1; row_q <= source_y0;
                    first_word_q <= first_word; last_word_q <= last_word;
                    next_word_q <= first_word;
                    row_words_q <= last_word-first_word+1'b1;
                    tile_row_base_q <= 0;
                    tile_ready <= 1'b0; busy <= 1'b1; error <= 1'b0;
                    state <= S_CMD;
                end else if (tile_start) begin
                    error <= 1'b1;
                end
            end else if (state == S_CMD) begin
                tile_ready <= 1'b0;
                busy <= 1'b1;
                // Keep command addresses in the same logical unit used by
                // wr_cmd_trans: eight address units per 256-bit beat.
                cmd_addr <= (bank_q << 22) + row_q*ROW_ADDR_STRIDE +
                            next_word_q*ADDR_UNIT_PER_BEAT;
                if ((last_word_q-next_word_q+1) > MAX_BURST)
                    cmd_len <= MAX_BURST;
                else cmd_len <= last_word_q-next_word_q+1;
                if (!cmd_valid) begin
                    cmd_valid <= 1'b1;
                end else if (cmd_ready) begin
                    cmd_valid <= 1'b0;
                    expected_beats <= ((last_word_q-next_word_q+1) > MAX_BURST) ? MAX_BURST :
                                      (last_word_q-next_word_q+1);
                    received_beats <= 0;
                    state <= S_DATA;
                end
            end else begin
                tile_ready <= 1'b0;
                busy <= 1'b1;
                if (data_valid) begin
                    if (received_beats >= expected_beats) begin
                        error <= 1'b1;
                    end else begin
                        tile_data_valid <= 1'b1;
                        tile_data <= data[received_beats*256 +: 256];
                        tile_data_addr <= tile_row_base_q +
                            (next_word_q-first_word_q) + received_beats;
                        tile_data_last <= (received_beats == expected_beats-1) &&
                                          (next_word_q + expected_beats-1 == last_word_q) &&
                                          (row_q == y1_q);
                        if (received_beats + 1'b1 >= expected_beats) begin
                            if (next_word_q + expected_beats >= last_word_q+1) begin
                                if (row_q == y1_q) begin
                                    tile_done <= 1'b1;
                                    state <= S_IDLE;
                                    tile_ready <= 1'b1;
                                    busy <= 1'b0;
                                end else begin
                                    row_q <= row_q + 1'b1;
                                    next_word_q <= first_word_q;
                                    tile_row_base_q <= tile_row_base_q + TILE_WORD_STRIDE;
                                    state <= S_CMD;
                                end
                            end else begin
                                next_word_q <= next_word_q + expected_beats;
                                state <= S_CMD;
                            end
                            received_beats <= 0;
                        end else begin
                            received_beats <= received_beats + 1'b1;
                        end
                    end
                end
                // `data_last` is advisory; the command length is authoritative
                // because the vendor return channel may insert gaps.
            end
        end
    end
endmodule

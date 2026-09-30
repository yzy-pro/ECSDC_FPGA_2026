// CP2102 packet transmitter.
//
// The write side accepts eight little-endian 32-bit words from the flash
// reader. The read side sends one frame:
//   AA 55 <32 payload bytes> <XOR of payload bytes> 0D
module cp2102 #(
    parameter integer SYS_CLK_FREQ = 50_000_000,
    parameter integer UART_CLK_FREQ = 14_743_589,
    parameter integer BAUD_RATE = 921_600,
    parameter integer DATA_BITS = 8,
    parameter PARITY = "NONE",
    parameter integer STOP_BITS = 1,
    parameter integer PAYLOAD_WORDS = 8
) (
    input wire sys_clk_50mhz,
    input wire uart_clk,
    input wire sys_rst_n,
    input wire uart_rst_n,
    input wire [31:0] fifo_wr_data,
    input wire fifo_wr_en,
    output wire fifo_wr_full,
    output wire sys_uart_tx,
    output reg tx_activity_toggle,
    output reg frame_done
);
    localparam integer WORD_COUNT_WIDTH = (PAYLOAD_WORDS < 2) ? 1 : $clog2(PAYLOAD_WORDS + 1);

    wire tx_fifo_full;
    wire tx_fifo_rd_empty;
    wire tx_fifo_almost_full;
    wire tx_fifo_almost_empty;
    wire [31:0] tx_fifo_rd_data;
    wire tx_fifo_wr_en;
    wire tx_fifo_rd_en;
    reg [WORD_COUNT_WIDTH-1:0] payload_word_count;
    reg frame_ready_sys;

    assign tx_fifo_wr_en = fifo_wr_en && !tx_fifo_full && !frame_ready_sys;
    assign fifo_wr_full = tx_fifo_full;

    cp2102_tx_fifo u_cp2102_tx_fifo (
        .wr_clk(sys_clk_50mhz),
        .wr_rst(!sys_rst_n),
        .wr_en(tx_fifo_wr_en),
        .wr_data(fifo_wr_data),
        .wr_full(tx_fifo_full),
        .almost_full(tx_fifo_almost_full),
        .rd_clk(uart_clk),
        .rd_rst(!uart_rst_n),
        .rd_en(tx_fifo_rd_en),
        .rd_data(tx_fifo_rd_data),
        .rd_empty(tx_fifo_rd_empty),
        .almost_empty(tx_fifo_almost_empty)
    );

    always @(posedge sys_clk_50mhz or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            payload_word_count <= {WORD_COUNT_WIDTH{1'b0}};
            frame_ready_sys <= 1'b0;
        end else if (tx_fifo_wr_en) begin
            if (payload_word_count == PAYLOAD_WORDS - 1) begin
                frame_ready_sys <= 1'b1;
            end else begin
                payload_word_count <= payload_word_count + 1'b1;
            end
        end
    end

    reg frame_ready_meta;
    reg frame_ready_uart;
    always @(posedge uart_clk or negedge uart_rst_n) begin
        if (!uart_rst_n) begin
            frame_ready_meta <= 1'b0;
            frame_ready_uart <= 1'b0;
        end else begin
            frame_ready_meta <= frame_ready_sys;
            frame_ready_uart <= frame_ready_meta;
        end
    end

    localparam [3:0] TX_IDLE        = 4'd0;
    localparam [3:0] TX_HEADER      = 4'd1;
    localparam [3:0] TX_WAIT_BUSY   = 4'd2;
    localparam [3:0] TX_WAIT_IDLE   = 4'd3;
    localparam [3:0] TX_READ_REQ    = 4'd4;
    localparam [3:0] TX_READ_WAIT   = 4'd5;
    localparam [3:0] TX_PAYLOAD     = 4'd6;
    localparam [3:0] TX_CHECKSUM    = 4'd7;
    localparam [3:0] TX_TAIL        = 4'd8;
    localparam [1:0] MODE_HEADER    = 2'd0;
    localparam [1:0] MODE_PAYLOAD   = 2'd1;
    localparam [1:0] MODE_CHECKSUM  = 2'd2;
    localparam [1:0] MODE_TAIL      = 2'd3;

    reg [3:0] tx_state;
    reg [1:0] tx_mode;
    reg header_byte_index;
    reg [1:0] payload_byte_index;
    reg [WORD_COUNT_WIDTH-1:0] payload_word_index;
    reg [31:0] payload_word;
    reg [7:0] frame_checksum;
    reg frame_sent;
    wire uart_busy;
    wire [7:0] uart_data_tx;
    wire uart_data_valid_tx;

    assign tx_fifo_rd_en = (tx_state == TX_READ_REQ) && !tx_fifo_rd_empty;
    assign uart_data_valid_tx = ((tx_state == TX_HEADER) ||
                                 (tx_state == TX_PAYLOAD) ||
                                 (tx_state == TX_CHECKSUM) ||
                                 (tx_state == TX_TAIL)) && !uart_busy;

    assign uart_data_tx = (tx_state == TX_HEADER) ?
                          (header_byte_index ? 8'h55 : 8'hAA) :
                          (tx_state == TX_PAYLOAD) ?
                          (payload_byte_index == 2'd0 ? payload_word[7:0] :
                           payload_byte_index == 2'd1 ? payload_word[15:8] :
                           payload_byte_index == 2'd2 ? payload_word[23:16] :
                                                        payload_word[31:24]) :
                          (tx_state == TX_CHECKSUM) ? frame_checksum :
                          (tx_state == TX_TAIL) ? 8'h0D : 8'h00;

    cp2102_uart_tx #(
        .UART_CLK_FREQ(UART_CLK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .DATA_BITS(DATA_BITS),
        .PARITY(PARITY),
        .STOP_BITS(STOP_BITS)
    ) u_uart_tx (
        .uart_clk(uart_clk),
        .uart_rst_n(uart_rst_n),
        .sys_uart_tx(sys_uart_tx),
        .uart_data_tx(uart_data_tx),
        .uart_data_valid_tx(uart_data_valid_tx),
        .uart_busy(uart_busy)
    );

    always @(posedge uart_clk or negedge uart_rst_n) begin
        if (!uart_rst_n) begin
            tx_state <= TX_IDLE;
            tx_mode <= MODE_HEADER;
            header_byte_index <= 1'b0;
            payload_byte_index <= 2'd0;
            payload_word_index <= {WORD_COUNT_WIDTH{1'b0}};
            payload_word <= 32'd0;
            frame_checksum <= 8'd0;
            frame_sent <= 1'b0;
            tx_activity_toggle <= 1'b0;
            frame_done <= 1'b0;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    if (frame_ready_uart && !frame_sent) begin
                        tx_mode <= MODE_HEADER;
                        header_byte_index <= 1'b0;
                        payload_word_index <= {WORD_COUNT_WIDTH{1'b0}};
                        frame_checksum <= 8'd0;
                        tx_state <= TX_HEADER;
                    end
                end

                TX_HEADER, TX_PAYLOAD, TX_CHECKSUM, TX_TAIL: begin
                    if (!uart_busy)
                        tx_state <= TX_WAIT_BUSY;
                end

                TX_WAIT_BUSY: begin
                    if (uart_busy)
                        tx_state <= TX_WAIT_IDLE;
                end

                TX_WAIT_IDLE: begin
                    if (!uart_busy) begin
                        case (tx_mode)
                            MODE_HEADER: begin
                                if (header_byte_index) begin
                                    tx_mode <= MODE_PAYLOAD;
                                    tx_state <= TX_READ_REQ;
                                end else begin
                                    header_byte_index <= 1'b1;
                                    tx_state <= TX_HEADER;
                                end
                            end
                            MODE_PAYLOAD: begin
                                if (payload_byte_index == 2'd3) begin
                                    if (payload_word_index == PAYLOAD_WORDS - 1) begin
                                        tx_mode <= MODE_CHECKSUM;
                                        tx_state <= TX_CHECKSUM;
                                    end else begin
                                        payload_word_index <= payload_word_index + 1'b1;
                                        tx_state <= TX_READ_REQ;
                                    end
                                end else begin
                                    payload_byte_index <= payload_byte_index + 1'b1;
                                    tx_state <= TX_PAYLOAD;
                                end
                            end
                            MODE_CHECKSUM: begin
                                tx_mode <= MODE_TAIL;
                                tx_state <= TX_TAIL;
                            end
                            default: begin
                                frame_sent <= 1'b1;
                                frame_done <= 1'b1;
                                tx_activity_toggle <= ~tx_activity_toggle;
                                tx_state <= TX_IDLE;
                            end
                        endcase
                    end
                end

                TX_READ_REQ: begin
                    if (!tx_fifo_rd_empty) begin
                        tx_state <= TX_READ_WAIT;
                    end
                end

                TX_READ_WAIT: begin
                    payload_word <= tx_fifo_rd_data;
                    frame_checksum <= frame_checksum ^ tx_fifo_rd_data[7:0] ^
                                      tx_fifo_rd_data[15:8] ^ tx_fifo_rd_data[23:16] ^
                                      tx_fifo_rd_data[31:24];
                    payload_byte_index <= 2'd0;
                    tx_mode <= MODE_PAYLOAD;
                    tx_state <= TX_PAYLOAD;
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end
endmodule

module cp2102_uart_tx #(
    parameter integer UART_CLK_FREQ = 14_743_589,
    parameter integer BAUD_RATE = 921_600,
    parameter integer DATA_BITS = 8,
    parameter PARITY = "NONE",
    parameter integer STOP_BITS = 1
) (
    input wire uart_clk,
    input wire uart_rst_n,
    output wire sys_uart_tx,
    input wire [7:0] uart_data_tx,
    input wire uart_data_valid_tx,
    output wire uart_busy
);
    localparam integer CLKS_PER_BIT = (UART_CLK_FREQ + (BAUD_RATE / 2)) / BAUD_RATE;
    localparam integer PARITY_EN = (PARITY != "NONE");
    localparam [2:0] UART_IDLE = 3'd0;
    localparam [2:0] UART_START = 3'd1;
    localparam [2:0] UART_DATA = 3'd2;
    localparam [2:0] UART_PARITY = 3'd3;
    localparam [2:0] UART_STOP = 3'd4;

    reg [2:0] uart_state;
    reg [7:0] uart_data_latch;
    reg parity_bit;
    reg [31:0] clock_count;
    reg [3:0] data_bit_index;
    reg [3:0] stop_bit_index;
    wire bit_done = (clock_count == CLKS_PER_BIT - 1);

    assign uart_busy = (uart_state != UART_IDLE);
    assign sys_uart_tx = (uart_state == UART_START) ? 1'b0 :
                         (uart_state == UART_DATA) ?
                             ((uart_data_latch >> data_bit_index) & 8'h01) :
                         (uart_state == UART_PARITY) ? parity_bit : 1'b1;

    always @(posedge uart_clk or negedge uart_rst_n) begin
        if (!uart_rst_n) begin
            uart_state <= UART_IDLE;
            uart_data_latch <= 8'd0;
            parity_bit <= 1'b0;
            clock_count <= 32'd0;
            data_bit_index <= 4'd0;
            stop_bit_index <= 4'd0;
        end else begin
            case (uart_state)
                UART_IDLE: begin
                    clock_count <= 32'd0;
                    data_bit_index <= 4'd0;
                    stop_bit_index <= 4'd0;
                    if (uart_data_valid_tx) begin
                        uart_data_latch <= uart_data_tx;
                        parity_bit <= (PARITY == "ODD") ?
                                      ~(^uart_data_tx[DATA_BITS-1:0]) :
                                      ^uart_data_tx[DATA_BITS-1:0];
                        uart_state <= UART_START;
                    end
                end
                UART_START: begin
                    if (bit_done) begin
                        clock_count <= 32'd0;
                        uart_state <= UART_DATA;
                    end else begin
                        clock_count <= clock_count + 1'b1;
                    end
                end
                UART_DATA: begin
                    if (bit_done) begin
                        clock_count <= 32'd0;
                        if (data_bit_index == DATA_BITS - 1) begin
                            if (PARITY_EN)
                                uart_state <= UART_PARITY;
                            else
                                uart_state <= UART_STOP;
                        end else begin
                            data_bit_index <= data_bit_index + 1'b1;
                        end
                    end else begin
                        clock_count <= clock_count + 1'b1;
                    end
                end
                UART_PARITY: begin
                    if (bit_done) begin
                        clock_count <= 32'd0;
                        uart_state <= UART_STOP;
                    end else begin
                        clock_count <= clock_count + 1'b1;
                    end
                end
                UART_STOP: begin
                    if (bit_done) begin
                        clock_count <= 32'd0;
                        if (stop_bit_index == STOP_BITS - 1) begin
                            uart_state <= UART_IDLE;
                        end else begin
                            stop_bit_index <= stop_bit_index + 1'b1;
                        end
                    end else begin
                        clock_count <= clock_count + 1'b1;
                    end
                end
                default: begin
                    uart_state <= UART_IDLE;
                    clock_count <= 32'd0;
                end
            endcase
        end
    end
endmodule

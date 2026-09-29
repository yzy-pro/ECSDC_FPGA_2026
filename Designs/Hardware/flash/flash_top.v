// Flash 哈希读取顶层。
// 读取一个 32 位小端字，经过异步 FIFO 后通过 UART 发送 4 个字节。
module flash_top #(
    parameter integer QSPI_CLK_FREQ = 50_000_000,
    parameter integer QSPI_SCK_FREQ = 12_500_000,
    parameter integer QSPI_MODE = 0,
    parameter [7:0] FLASH_READ_OPCODE = 8'h6B,
    parameter [23:0] HASH_ADDRESS = 24'h20_2000,
    parameter [7:0] FLASH_DUMMY_CYCLES = 8'd8,
    parameter integer UART_BAUD_RATE = 921_600
) (
    input wire sys_clk_50mhz,
    input wire sys_rst_n,
    output wire sys_uart_tx,
    output wire sys_qspi_csn,
    inout wire [3:0] sys_qspi_dq,
    output wire sys_qspi_sck,
    output wire [7:0] sys_led
);
    localparam integer UART_DIV = (QSPI_CLK_FREQ + (UART_BAUD_RATE / 2)) / UART_BAUD_RATE;
    localparam integer UART_DIV_WIDTH = (UART_DIV < 2) ? 1 : $clog2(UART_DIV);

    wire fifo_wr_en;
    wire [31:0] fifo_wr_data;
    wire fifo_wr_full;
    wire fifo_rd_empty;
    wire fifo_almost_empty;
    reg fifo_rd_en;
    wire [31:0] fifo_rd_data;

    wire flash_busy;
    wire flash_done;
    wire flash_overflow;
    wire [31:0] flash_word_count;

    reg [1:0] fifo_state;
    reg [31:0] hash_word;
    reg [1:0] uart_byte_index;
    reg uart_request;
    reg uart_busy;
    reg [9:0] uart_shift;
    reg [3:0] uart_bit_index;
    reg [UART_DIV_WIDTH-1:0] uart_div_count;
    reg hash_sent;

    localparam [1:0] FIFO_IDLE = 2'd0;
    localparam [1:0] FIFO_READ = 2'd1;
    localparam [1:0] FIFO_CAPTURE = 2'd2;

    flash_driver #(
        .QSPI_CLK_FREQ(QSPI_CLK_FREQ),
        .QSPI_SCK_FREQ(QSPI_SCK_FREQ),
        .QSPI_MODE(QSPI_MODE),
        .FLASH_READ_OPCODE(FLASH_READ_OPCODE),
        .FLASH_START_ADDRESS(HASH_ADDRESS),
        .FLASH_DUMMY_CYCLES(FLASH_DUMMY_CYCLES),
        .FLASH_BYTE_COUNT(4)
    ) u_flash_driver (
        .qspi_clk(sys_clk_50mhz),
        .sys_rst_n(sys_rst_n),
        .sys_qspi_csn(sys_qspi_csn),
        .sys_qspi_dq(sys_qspi_dq),
        .sys_qspi_sck(sys_qspi_sck),
        .fifo_wr_en(fifo_wr_en),
        .fifo_wr_data(fifo_wr_data),
        .fifo_wr_full(fifo_wr_full),
        .busy(flash_busy),
        .done(flash_done),
        .overflow(flash_overflow),
        .word_count(flash_word_count)
    );

    // 当前 UART 与 QSPI 共用系统时钟；保留异步 FIFO 接口，便于以后替换为独立 UART 时钟。
    flash_rx_fifo u_flash_rx_fifo (
        .wr_clk(sys_clk_50mhz),
        .wr_rst(!sys_rst_n),
        .wr_en(fifo_wr_en),
        .wr_data(fifo_wr_data),
        .wr_full(fifo_wr_full),
        .almost_full(),
        .rd_clk(sys_clk_50mhz),
        .rd_rst(!sys_rst_n),
        .rd_en(fifo_rd_en),
        .rd_data(fifo_rd_data),
        .rd_empty(fifo_rd_empty),
        .almost_empty(fifo_almost_empty)
    );

    assign sys_uart_tx = uart_busy ? uart_shift[0] : 1'b1;
    assign sys_led = {3'b000, hash_sent, uart_busy, flash_overflow, flash_done, flash_busy};

    // FIFO 读出延迟一个时钟后锁存哈希字，再启动串口发送。
    always @(posedge sys_clk_50mhz or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            fifo_state <= FIFO_IDLE;
            fifo_rd_en <= 1'b0;
            hash_word <= 32'd0;
            uart_byte_index <= 2'd0;
            uart_request <= 1'b0;
            uart_busy <= 1'b0;
            uart_shift <= 10'b11_1111_1111;
            uart_bit_index <= 4'd0;
            uart_div_count <= {UART_DIV_WIDTH{1'b0}};
            hash_sent <= 1'b0;
        end else begin
            fifo_rd_en <= 1'b0;

            case (fifo_state)
                FIFO_IDLE: begin
                    if (!fifo_rd_empty && !hash_sent)
                        fifo_state <= FIFO_READ;
                end
                FIFO_READ: begin
                    fifo_rd_en <= 1'b1;
                    fifo_state <= FIFO_CAPTURE;
                end
                FIFO_CAPTURE: begin
                    hash_word <= fifo_rd_data;
                    uart_byte_index <= 2'd0;
                    uart_request <= 1'b1;
                    fifo_state <= FIFO_IDLE;
                end
                default: fifo_state <= FIFO_IDLE;
            endcase

            if (uart_request && !uart_busy) begin
                // UART 帧：1 个起始位、8 个数据位（低位先发）、1 个停止位。
                case (uart_byte_index)
                    2'd0: uart_shift <= {1'b1, hash_word[7:0], 1'b0};
                    2'd1: uart_shift <= {1'b1, hash_word[15:8], 1'b0};
                    2'd2: uart_shift <= {1'b1, hash_word[23:16], 1'b0};
                    default: uart_shift <= {1'b1, hash_word[31:24], 1'b0};
                endcase
                uart_request <= 1'b0;
                uart_busy <= 1'b1;
                uart_bit_index <= 4'd0;
                uart_div_count <= {UART_DIV_WIDTH{1'b0}};
            end else if (uart_busy) begin
                if (uart_div_count == UART_DIV - 1) begin
                    uart_div_count <= {UART_DIV_WIDTH{1'b0}};
                    if (uart_bit_index == 4'd9) begin
                        uart_busy <= 1'b0;
                        if (uart_byte_index == 2'd3) begin
                            hash_sent <= 1'b1;
                        end else begin
                            uart_byte_index <= uart_byte_index + 1'b1;
                            uart_request <= 1'b1;
                        end
                    end else begin
                        uart_shift <= {1'b1, uart_shift[9:1]};
                        uart_bit_index <= uart_bit_index + 1'b1;
                    end
                end else begin
                    uart_div_count <= uart_div_count + 1'b1;
                end
            end
        end
    end
endmodule

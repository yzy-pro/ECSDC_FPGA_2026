// Flash 读取驱动。
// qspi_master_rx 输出连续的 8 位字节，本模块将每 4 个字节组装成一个
// 小端 32 位字，并通过 FIFO 写接口送往后级 DDR 控制器。
module flash_driver #(
    parameter integer QSPI_CLK_FREQ      = 50_000_000,
    parameter integer QSPI_SCK_FREQ      = 12_500_000,
    parameter integer QSPI_MODE          = 0,
    parameter [7:0]  FLASH_READ_OPCODE   = 8'h6B,
    parameter [23:0] FLASH_START_ADDRESS = 24'h02_0200,
    parameter [7:0]  FLASH_DUMMY_CYCLES  = 8'd8,
    parameter integer FLASH_BYTE_COUNT   = 32
) (
    input  wire        qspi_clk,
    input  wire        sys_rst_n,
    output wire        sys_qspi_csn,
    inout  wire [3:0]  sys_qspi_dq,
    output wire        sys_qspi_sck,
    output wire        fifo_wr_en,
    output wire [31:0] fifo_wr_data,
    input  wire        fifo_wr_full,
    output wire        busy,
    output wire        done,
    output wire        overflow,
    output wire [31:0] word_count
);
    localparam integer BYTE_COUNT_WIDTH = (FLASH_BYTE_COUNT < 2) ? 1 : $clog2(FLASH_BYTE_COUNT + 1);
    wire qspi_csn;
    wire qspi_sck;
    wire rx_data_valid;
    wire [7:0] rx_data;
    reg [1:0] byte_index;
    reg [7:0] byte0_reg, byte1_reg, byte2_reg;
    reg [BYTE_COUNT_WIDTH-1:0] byte_count_reg;
    reg [31:0] word_count_reg;
    reg done_reg, overflow_reg;

    qspi_master_rx #(
        .QSPI_CLK_FREQ(QSPI_CLK_FREQ), .QSPI_SCK_FREQ(QSPI_SCK_FREQ), .QSPI_MODE(QSPI_MODE),
        .READ_OPCODE(FLASH_READ_OPCODE), .READ_START_ADDRESS(FLASH_START_ADDRESS),
        .READ_DUMMY_CYCLES(FLASH_DUMMY_CYCLES)
    ) u_qspi_master_rx (
        .qspi_clk(qspi_clk), .sys_rstn(sys_rst_n), .sys_qspi_csn(qspi_csn),
        .sys_qspi_dq(sys_qspi_dq), .sys_qspi_sck(qspi_sck),
        .rx_data_valid(rx_data_valid), .rx_data(rx_data),
        .read_opcode(FLASH_READ_OPCODE),
        .read_start_address(FLASH_START_ADDRESS),
        .read_dummy_cycles(FLASH_DUMMY_CYCLES)
    );

    // rx_data_valid 拉高期间数据保持稳定，FIFO 在随后的 qspi_clk 上升沿采样。
    assign sys_qspi_csn = done_reg ? 1'b1 : qspi_csn;
    assign sys_qspi_sck = qspi_sck;
    assign fifo_wr_en = rx_data_valid && !done_reg && (byte_index == 2'd3) && !fifo_wr_full;
    assign fifo_wr_data = {rx_data, byte2_reg, byte1_reg, byte0_reg};
    assign busy = !done_reg;
    assign done = done_reg;
    assign overflow = overflow_reg;
    assign word_count = word_count_reg;

    // qspi_master_rx 没有 ready/暂停接口，因此 FIFO 满时记录溢出状态。
    always @(posedge qspi_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            byte_index <= 2'd0;
            byte0_reg <= 8'd0; byte1_reg <= 8'd0; byte2_reg <= 8'd0;
            byte_count_reg <= {BYTE_COUNT_WIDTH{1'b0}};
            word_count_reg <= 32'd0; done_reg <= 1'b0; overflow_reg <= 1'b0;
        end else begin
            if (!done_reg && rx_data_valid) begin
                if (byte_count_reg < FLASH_BYTE_COUNT) begin
                    byte_count_reg <= byte_count_reg + 1'b1;
                    case (byte_index)
                        2'd0: begin byte0_reg <= rx_data; byte_index <= 2'd1; end
                        2'd1: begin byte1_reg <= rx_data; byte_index <= 2'd2; end
                        2'd2: begin byte2_reg <= rx_data; byte_index <= 2'd3; end
                        default: begin
                            // BIN 文件为小端序，第一个字节放在 [7:0]。
                            byte_index <= 2'd0;
                            if (!fifo_wr_full) begin
                                word_count_reg <= word_count_reg + 1'b1;
                            end else begin
                                overflow_reg <= 1'b1;
                            end
                        end
                    endcase
                    if (byte_count_reg == FLASH_BYTE_COUNT - 1)
                        done_reg <= 1'b1;
                end else begin
                    done_reg <= 1'b1;
                end
            end
        end
    end
endmodule

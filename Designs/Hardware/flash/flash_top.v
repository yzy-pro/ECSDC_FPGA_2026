// Flash subsystem: read a fixed byte range and provide 32-bit words.
module flash_top #(
    parameter integer QSPI_CLK_FREQ = 50_000_000,
    parameter integer QSPI_SCK_FREQ = 12_500_000,
    parameter integer QSPI_MODE = 0,
    parameter [7:0] FLASH_READ_OPCODE = 8'h6B,
    parameter [23:0] HASH_ADDRESS = 24'h02_0200,
    parameter [7:0] FLASH_DUMMY_CYCLES = 8'd8,
    parameter integer FLASH_BYTE_COUNT = 32
) (
    input wire sys_clk_50mhz,
    input wire sys_rst_n,
    output wire sys_qspi_csn,
    inout wire [3:0] sys_qspi_dq,
    output wire sys_qspi_sck,
    output wire fifo_wr_en,
    output wire [31:0] fifo_wr_data,
    input wire fifo_wr_full,
    output wire busy,
    output wire done,
    output wire overflow,
    output wire [31:0] word_count
);
    flash_driver #(
        .QSPI_CLK_FREQ(QSPI_CLK_FREQ),
        .QSPI_SCK_FREQ(QSPI_SCK_FREQ),
        .QSPI_MODE(QSPI_MODE),
        .FLASH_READ_OPCODE(FLASH_READ_OPCODE),
        .FLASH_START_ADDRESS(HASH_ADDRESS),
        .FLASH_DUMMY_CYCLES(FLASH_DUMMY_CYCLES),
        .FLASH_BYTE_COUNT(FLASH_BYTE_COUNT)
    ) u_flash_driver (
        .qspi_clk(sys_clk_50mhz),
        .sys_rst_n(sys_rst_n),
        .sys_qspi_csn(sys_qspi_csn),
        .sys_qspi_dq(sys_qspi_dq),
        .sys_qspi_sck(sys_qspi_sck),
        .fifo_wr_en(fifo_wr_en),
        .fifo_wr_data(fifo_wr_data),
        .fifo_wr_full(fifo_wr_full),
        .busy(busy),
        .done(done),
        .overflow(overflow),
        .word_count(word_count)
    );
endmodule

// Board top: connect the Flash, CP2102, and LED subsystems.
module flash_read_top (
    input wire sys_clk_50mhz,
    input wire sys_rstn,

    output wire sys_cp2102_tx,

    output wire sys_qspi_csn,
    inout wire [3:0] sys_qspi_dq,
    output wire sys_qspi_sck,

    output wire [7:0] sys_led
);

    localparam integer FLASH_BYTE_COUNT = 32;

    wire flash_fifo_wr_en;
    wire [31:0] flash_fifo_wr_data;
    wire flash_fifo_wr_full;
    wire flash_busy;
    wire flash_done;
    wire flash_overflow;
    wire [31:0] flash_word_count;
    wire tx_activity_toggle;
    wire frame_done;

    flash_top #(
        .FLASH_READ_OPCODE(8'h6B),
        .HASH_ADDRESS(24'h20_2000),
        .FLASH_BYTE_COUNT(FLASH_BYTE_COUNT)
    ) u_flash_top (
        .sys_clk_50mhz(sys_clk_50mhz),
        .sys_rst_n(sys_rstn),
        .sys_qspi_csn(sys_qspi_csn),
        .sys_qspi_dq(sys_qspi_dq),
        .sys_qspi_sck(sys_qspi_sck),
        .fifo_wr_en(flash_fifo_wr_en),
        .fifo_wr_data(flash_fifo_wr_data),
        .fifo_wr_full(flash_fifo_wr_full),
        .busy(flash_busy),
        .done(flash_done),
        .overflow(flash_overflow),
        .word_count(flash_word_count)
    );

    cp2102_top #(
        .PAYLOAD_WORDS(FLASH_BYTE_COUNT / 4),
        .UART_CLK_FREQ(50_000_000),
        .UART_BAUD_RATE(921_600)
    ) u_cp2102_top (
        .sys_clk_50mhz(sys_clk_50mhz),
        .sys_rst_n(sys_rstn),
        .sys_uart_tx(sys_cp2102_tx),
        .fifo_wr_data(flash_fifo_wr_data),
        .fifo_wr_en(flash_fifo_wr_en),
        .fifo_wr_full(flash_fifo_wr_full),
        .tx_activity_toggle(tx_activity_toggle),
        .frame_done(frame_done)
    );

    led_top u_led_top (
        .flash_fifo_wr_full(flash_fifo_wr_full),
        .flash_busy(flash_busy),
        .flash_done(flash_done),
        .flash_overflow(flash_overflow),
        .tx_activity_toggle(tx_activity_toggle),
        .frame_done(frame_done),
        .sys_led(sys_led)
    );

endmodule

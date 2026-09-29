// 从 Flash 读取一个 32 位哈希值，通过 UART 发送到上位机。
module flash_read_top (
    input wire sys_clk_50mhz,
    input wire sys_rst_n,

    output wire sys_uart_tx,

    output wire sys_qspi_csn,
    inout wire [3:0] sys_qspi_dq,
    output wire sys_qspi_sck,

    output wire [7:0] sys_led
);

    flash_top #(
        .HASH_ADDRESS(24'h20_2000),
        .UART_BAUD_RATE(921_600)
    ) u_flash_top (
        .sys_clk_50mhz(sys_clk_50mhz),
        .sys_rst_n(sys_rst_n),
        .sys_uart_tx(sys_uart_tx),
        .sys_qspi_csn(sys_qspi_csn),
        .sys_qspi_dq(sys_qspi_dq),
        .sys_qspi_sck(sys_qspi_sck),
        .sys_led(sys_led)
    );

endmodule

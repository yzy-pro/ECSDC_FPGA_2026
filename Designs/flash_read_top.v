//从flash读取一个8Mb的数据，通过串口模块（CP2102）发送到上位机，波特率921600
//数据格式参考Debug/lut_bin_format.md
module flash_read_top (
    input wire sys_clk_50mhz,
    input wire sys_rst_n,

    output wire sys_uart_tx,

    output wire sys_qspi_csn,
    inout wire [3:0] sys_qspi_dq,
    output wire sys_qspi_sck,

    output wire [7:0] sys_led
);

endmodule

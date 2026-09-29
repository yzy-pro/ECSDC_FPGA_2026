//qspi读取驱动模块
module qspi_master_rx #(
    parameter integer QSPI_CLK_FREQ = 50_000_000,
    parameter integer QSPI_SCK_FREQ = 12_500_000,
    parameter integer QSPI_MODE = 0
) (
    input wire qspi_clk,
    input wire sys_rstn,

    output wire sys_qspi_csn,
    inout wire [3:0] sys_qspi_dq,
    output wire sys_qspi_sck,

    output wire rx_data_valid,
    output wire [7:0] rx_data
);

endmodule

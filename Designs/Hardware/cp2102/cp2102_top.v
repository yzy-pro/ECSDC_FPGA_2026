// CP2102 transmitter interface for a 32-bit word stream.
module cp2102_top #(
    parameter integer UART_CLK_FREQ = 50_000_000,
    parameter integer UART_BAUD_RATE = 921_600,
    parameter integer PAYLOAD_WORDS = 8
) (
    input wire sys_clk_50mhz,
    input wire sys_rst_n,
    input wire [31:0] fifo_wr_data,
    input wire fifo_wr_en,
    output wire fifo_wr_full,
    output wire sys_uart_tx,
    output wire tx_activity_toggle,
    output wire frame_done
);
    cp2102 #(
        .SYS_CLK_FREQ(50_000_000),
        .UART_CLK_FREQ(UART_CLK_FREQ),
        .BAUD_RATE(UART_BAUD_RATE),
        .PAYLOAD_WORDS(PAYLOAD_WORDS)
    ) u_cp2102 (
        .sys_clk_50mhz(sys_clk_50mhz),
        .uart_clk(sys_clk_50mhz),
        .sys_rst_n(sys_rst_n),
        .uart_rst_n(sys_rst_n),
        .fifo_wr_data(fifo_wr_data),
        .fifo_wr_en(fifo_wr_en),
        .fifo_wr_full(fifo_wr_full),
        .sys_uart_tx(sys_uart_tx),
        .tx_activity_toggle(tx_activity_toggle),
        .frame_done(frame_done)
    );

endmodule

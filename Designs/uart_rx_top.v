module uart_rx_top (
    input wire sys_clk_50mhz,
    input wire rst_n,

    input wire uart_rx,
    output wire uart_tx,

    input wire [7:0] key_in,
    output wire [7:0] led_out
);
    assign uart_tx = 1'b1;

    wire [7:0] data;
    wire pll_clk_50mhz;
    wire uart_clk_921600;
    wire pll_lock;

    pll_50mhz u_pll_50mhz (
        .clkin1(sys_clk_50mhz),
        .clkout0(pll_clk_50mhz),
        .clkout1(uart_clk_921600),

        .pll_lock()
    );

    uart_rx u_uart_rx (
        .clk(uart_clk_921600),
        .rst_n(rst_n),
        .data_in(uart_rx),
        .data_out(data),
        .data_valid()
    );

    led u_led (
        .clk(pll_clk_50mhz),
        .rst_n(rst_n),
        .led_data(data),
        .led_out(led_out)
    );

endmodule

module uart_txrx_top (
    input wire sys_clk_50mhz,
    input wire rst_n,

    input wire uart_rx,
    output wire uart_tx,

    input wire [7:0] key_in,
    output wire [7:0] led_out
);

    reg [7:0] led_data_in;
    wire [7:0] uart_data_out;
    wire uart_data_valid;
    wire pll_clk_50mhz;
    wire uart_clk_14m7456;
    wire pll_lock;

    always @(posedge pll_clk_50mhz or negedge rst_n) begin
        if (!rst_n) begin
            led_data_in <= 8'd0;
        end
        else begin
            if (uart_data_valid) begin
                led_data_in <= (uart_data_out);
            end
        end
    end

    pll_50mhz u_pll_50mhz (
        .clkin1(sys_clk_50mhz),
        .clkout0(pll_clk_50mhz),
        .clkout1(uart_clk_14m7456),

        .pll_lock()
    );

    uart_rx u_uart_rx (
        .clk(uart_clk_14m7456),
        .rst_n(rst_n),

        .data_in(uart_rx),
        .data_out(uart_data_out),

        .data_valid(uart_data_valid)
    );

    uart_tx u_uart_tx (
        .clk(uart_clk_14m7456),
        .rst_n(rst_n),

        .data_in(uart_data_out),
        .data_valid(uart_data_valid),

        .data_out(uart_tx)
    );

    led u_led (
        .clk(pll_clk_50mhz),
        .rst_n(rst_n),
        .led_data(led_data_in),
        .led_out(led_out)
    );

endmodule

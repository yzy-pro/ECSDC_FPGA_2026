module led_top #(
    parameter integer LED_SYSCLK_FREQ = 50_000_000,
    parameter integer LED_WIDTH = 8,
    parameter integer KEY_SYSCLK_FREQ = 50_000_000,
    parameter integer KEY_WIDTH = 8
) (
    input wire io_sys_clk_50mhz,
    input wire io_rst_n,
    input wire [7:0] io_key_in,  //按键低电平有效
    output wire [7:0] io_led_out
);

    wire [7:0] key_data;

    key_controller #(
        .KEY_SYSCLK_FREQ(KEY_SYSCLK_FREQ),
        .KEY_WIDTH(KEY_WIDTH)
    ) key (
        .clk(io_sys_clk_50mhz),
        .io_rst_n(io_rst_n),
        .io_key_in(io_key_in),
        .key_data(key_data)
    );

    led_controller #(
        .LED_SYSCLK_FREQ(LED_SYSCLK_FREQ),
        .LED_WIDTH(LED_WIDTH)
    ) led (
        .clk(io_sys_clk_50mhz),
        .io_rst_n(io_rst_n),
        .led_data(key_data),
        .io_led_out(io_led_out)
    );

endmodule

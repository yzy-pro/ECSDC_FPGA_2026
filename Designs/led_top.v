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

    //当按键按下时，翻转对应的LED灯状态
    reg [7:0] led_data;
    reg [7:0] last_key_data;
    reg [3:0] i;
    always @(posedge io_sys_clk_50mhz or negedge io_rst_n) begin
        if (!io_rst_n) begin
            led_data <= 8'b0;
            last_key_data <= 8'b0;
        end
        else begin
            last_key_data <= key_data;

            for (i = 0; i < LED_WIDTH; i = i + 1) begin
                if (!last_key_data[i] && key_data[i]) begin
                    led_data[i] <= ~led_data[i];
                end
            end
        end
    end

    led_controller #(
        .LED_SYSCLK_FREQ(LED_SYSCLK_FREQ),
        .LED_WIDTH(LED_WIDTH)
    ) led (
        .clk(io_sys_clk_50mhz),
        .io_rst_n(io_rst_n),
        .led_data(led_data),
        .io_led_out(io_led_out)
    );

endmodule

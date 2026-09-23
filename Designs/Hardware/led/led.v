// LED 模块，接收数据输入信号并控制 LED 输出。
module led #(
    parameter integer LED_SYSCLK_FREQ = 50_000_000,
    parameter integer LED_WIDTH = 8
) (
    input wire clk,
    input wire rst_n,
    input wire [LED_WIDTH - 1:0] led_data,
    output reg [LED_WIDTH - 1:0] led_out
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            led_out <= 0;
        end
        else begin
            led_out <= led_data;
        end
    end

endmodule

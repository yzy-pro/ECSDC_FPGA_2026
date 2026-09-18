module led_controller #(
    parameter integer LED_SYSCLK_FREQ = 50_000_000,
    parameter integer LED_WIDTH = 8
) (
    input wire clk,
    input wire io_rst_n,
    input wire [7:0] led_data,
    output reg [7:0] io_led_out
);
    always @(posedge clk or negedge io_rst_n) begin
        if (!io_rst_n) begin
            io_led_out <= 8'b0;
        end
        else begin
            io_led_out <= led_data;
        end
    end

endmodule

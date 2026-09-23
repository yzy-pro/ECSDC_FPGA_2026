// key.v
// 按键模块，接收按键输入信号并消抖处理后转为数据输出
module key #(
    parameter integer KEY_SYSCLK_FREQ = 50_000_000,
    parameter integer KEY_WIDTH = 8
) (
    input wire clk,
    input wire rst_n,
    input wire [KEY_WIDTH - 1:0] key_in,  //按键低电平有效
    output reg [KEY_WIDTH - 1:0] key_data
);

    localparam integer KeyDetectFreq  = 10;
    localparam integer KeyDetectCount = KEY_SYSCLK_FREQ / KeyDetectFreq;

    // 在系统时钟域内采样低电平有效的按键。
    // 使用时钟使能，避免为按键逻辑生成第二个逻辑时钟。
    reg [31:0] cnt_detect;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_detect <= 32'd0;
            key_data <= 0;
        end
        else if (cnt_detect == KeyDetectCount - 1) begin
            cnt_detect <= 32'd0;
            key_data <= ~key_in;
        end
        else begin
            cnt_detect <= cnt_detect + 32'd1;
        end
    end

endmodule

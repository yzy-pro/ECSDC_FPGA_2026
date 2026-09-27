//led驱动模块
//根据输入的led_cmd信号控制板载LED指示灯的状态，led高电平点亮，低电平熄灭

module led #(
    parameter LED_NUMBER = 8  //板载LED指示灯数量
) (
    input wire sys_clk_50mhz,  //系统时钟输入
    input wire sys_rst_n,  //系统复位输入，低电平有效

    input wire [LED_NUMBER - 1:0] led_cmd,  //LED控制命令输入
    output reg [LED_NUMBER - 1:0] sys_led  //板载LED指示灯
);

    always @(posedge sys_clk_50mhz or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            sys_led <= {LED_NUMBER{1'b0}};  //复位时，所有LED熄灭
        end
        else begin
            sys_led <= led_cmd;  //根据led_cmd信号控制LED状态
        end
    end

endmodule

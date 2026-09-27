`timescale 1ns / 1ps
`define HDMI_1920_1080
module hdmi_loop (
    input wire sys_clk,  // 输入系统时钟 50MHz,FPGA_GCLK_50M

    output rstn_out,  //MS7200 硬件复位信号，低电平有效

    output iic_scl,
    inout iic_sda,
    output iic_tx_scl,
    inout iic_tx_sda,

    input pixclk_in,  //FPGA_GCLK_27M
    input vs_in,
    input hs_in,
    input de_in,
    input [7:0] r_in,
    input [7:0] g_in,
    input [7:0] b_in,

    output pixclk_out,  //HDMI显示图像像素时钟
    output reg vs_out,
    output reg hs_out,
    output reg de_out,
    output reg [7:0] r_out,
    output reg [7:0] g_out,
    output reg [7:0] b_out,

    output led_int  //LED1
);

    parameter X_WIDTH = 4'd12;
    parameter Y_WIDTH = 4'd12;
    // 1080p 模式参数
`ifdef HDMI_1920_1080
    parameter V_TOTAL = 12'd1125;
    parameter V_FP = 12'd4;
    parameter V_BP = 12'd36;
    parameter V_SYNC = 12'd5;
    parameter V_ACT = 12'd1080;
    parameter H_TOTAL = 12'd2200;
    parameter H_FP = 12'd88;
    parameter H_BP = 12'd148;
    parameter H_SYNC = 12'd44;
    parameter H_ACT = 12'd1920;
    parameter HV_OFFSET = 12'd0;
`elsif HDMI_1440_1080
    parameter V_TOTAL = 12'd1125;
    parameter V_FP = 12'd4;
    parameter V_BP = 12'd36;
    parameter V_SYNC = 12'd5;
    parameter V_ACT = 12'd1080;
    parameter H_TOTAL = 12'd1650;
    parameter H_FP = 12'd88;
    parameter H_BP = 12'd148;
    parameter H_SYNC = 12'd44;
    parameter H_ACT = 12'd1440;
    parameter HV_OFFSET = 12'd240;
`endif


    reg [15:0] rstn_1ms;
    wire pix_clk;
    wire cfg_clk;
    wire locked;

    PLL u_pll (
        .clkin1(sys_clk),  // 输入 50MHz
        .pll_lock(locked),  // 输出锁定信号
        .clkout0(cfg_clk)  // 输出 10MHz
    );

    ms72xx_ctl ms72xx_ctl (
        .clk(cfg_clk),  // 输入时钟
        .rst_n(rstn_out),  // 输入复位

        .init_over(init_over),  // 输出初始化完成信号

        .iic_tx_scl(iic_tx_scl),  // 输出发送端 IIC 时钟
        .iic_tx_sda(iic_tx_sda),  // 双向发送端 IIC 数据
        .iic_scl(iic_scl),  // 输出 IIC 时钟
        .iic_sda(iic_sda)  // 双向 IIC 数据
    );

    assign led_int = init_over;

    always @(posedge cfg_clk) begin
        if (!locked) rstn_1ms <= 16'd0;
        else begin
            if (rstn_1ms == 16'h2710) rstn_1ms <= rstn_1ms;
            else rstn_1ms <= rstn_1ms + 1'b1;
        end
    end

    assign rstn_out = (rstn_1ms == 16'h2710);

    // HDMI 输出直通 HDMI 输入
    assign pixclk_out = pixclk_in;

    always @(posedge pixclk_out) begin
        if (!init_over) begin
            vs_out <= 1'b0;
            hs_out <= 1'b0;
            de_out <= 1'b0;
            r_out <= 8'b0;
            g_out <= 8'b0;
            b_out <= 8'b0;
        end
        else begin
            vs_out <= vs_in;
            hs_out <= hs_in;
            de_out <= de_in;
            r_out <= r_in;
            g_out <= g_in;
            b_out <= b_in;
        end
    end

endmodule

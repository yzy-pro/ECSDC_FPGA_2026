`timescale 1ns / 1ps

`define UD #1

module i2c_eeprom_test (
    input clk,
    input [2:0] key,
    input rstn,

    output [7:0] led,
    output scl,
    inout sda
);

    // 按键消抖模块
    wire [2:0] btn_deb;
    btn_deb_fix #(
        .BTN_WIDTH(4'd3),  // 参数：按键宽度，默认 BTN_WIDTH = 4'd8
        .BTN_DELAY(20'h7_ffff)
    ) u_btn_deb (
        .clk(clk),  // 输入：系统时钟
        .btn_in(key),  // 输入：原始按键信号

        .btn_deb_fix(btn_deb)  // 输出：消抖后的按键信号
    );

    // 按键消抖寄存器
    reg [2:0] btn_deb_reg;
    always @(posedge clk) begin
        btn_deb_reg <= btn_deb;
    end

    // 读写控制寄存器
    reg wr;  //1'b1:写入EEPROM, 1'b0:读取EEPROM
    always @(posedge clk) begin
        if (!rstn) wr <= 1'b1;
        else if (!btn_deb[0] && btn_deb_reg[0]) wr <= 1'b1;
        else if (!btn_deb[1] && btn_deb_reg[1]) wr <= 1'b0;
        else wr <= wr;
    end

    // I2C 操作触发脉冲
    reg iic_pluse;
    always @(posedge clk) begin
        if (!rstn) iic_pluse <= 1'b0;
        else if (!btn_deb[2] && btn_deb_reg[2]) iic_pluse <= 1'b1;
        else iic_pluse <= 1'b0;
    end


    wire busy;
    wire byte_over;
    wire [7:0] data_out;
    wire sda_in;
    wire sda_out;
    wire sda_out_en;

    iic_driver #(
        .CLK_FRE(27'd50_000_000),  // 参数：系统时钟频率
        .IIC_FREQ(20'd400_000),  // 参数：I2C 总线频率
        .T_WR(10'd5),  // 参数：EEPROM 写入等待时间
        .DEVICE_ID(8'hA0),  // 参数：I2C 设备地址
        .ADDR_BYTE(2'd1),  // 参数：EEPROM 地址字节数
        .LEN_WIDTH(8'd8),  // 参数：传输长度计数位宽
        .DATA_BYTE(2'd1)  // 参数：单次数据字节数
    ) iic_dri (
        .clk(clk),  // 输入：系统时钟
        .rstn(rstn),  // 输入：低有效复位
        .pluse(iic_pluse),  // 输入：I2C 操作启动脉冲
        .w_r(wr),  // 输入：读写控制
        .byte_len(8'd8),  // 输入：传输字节长度

        .addr(8'd0),  // 输入：EEPROM 起始地址
        .data_in(8'b10101010),  // 输入：写入数据

        .busy(busy),  // 输出：I2C 忙标志
        .byte_over(byte_over),  // 输出：单字节传输完成标志

        .data_out(data_out),  // 输出：读取数据

        .scl(scl),  // 输出：I2C 时钟线
        .sda_in(sda_in),  // 输入：SDA 采样信号
        .sda_out(sda_out),  // 输出：SDA 驱动数据
        .sda_out_en(sda_out_en)  // 输出：SDA 输出使能
    );

    // IOBUF 实例化，用于 SDA 双向引脚
    GTP_IOBUF #(
        .IOSTANDARD("DEFAULT"),
        .SLEW_RATE("SLOW"),
        .DRIVE_STRENGTH("8"),
        .TERM_DDR("ON")
    ) iobuf (
        .IO(sda),  // 双向：外部 SDA 引脚
        .O(sda_in),  // 输出：送入 FPGA 内部的 SDA 采样值
        .I(sda_out),  // 输入：FPGA 内部要驱动到 SDA 的数据
        .T(~sda_out_en)  // 输入：三态控制，高电平为高阻
    );

    assign led = data_out;

endmodule

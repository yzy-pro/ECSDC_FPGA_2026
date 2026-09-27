//hdmi回环测试顶层模块，将hdmi输入信号直接输出到hdmi输出端口
//ms7200初始化完成
module hdmi_loop_top (
    //系统时钟与复位信号
    input wire sys_clk_50mhz,  // 输入系统时钟 50MHz,FPGA_GCLK_50M
    input wire sys_rstn,  // 输入系统复位信号，低电平有效

    //hdmi输入配置
    //ms7200,hdmi输入i2c接口
    output wire sys_ms7200_iic_scl,
    inout wire sys_ms7200_iic_sda,
    output wire sys_ms7200_rstn,  //MS7200 硬件复位信号，低电平有效
    //hdmi输入信号
    input wire sys_hdmi_in_pixclk,
    input wire sys_hdmi_in_vsync,
    input wire sys_hdmi_in_hsync,
    input wire sys_hdmi_in_de,
    input wire [7:0] sys_hdmi_in_r,
    input wire [7:0] sys_hdmi_in_g,
    input wire [7:0] sys_hdmi_in_b,

    //hdmi输出配置
    //ms7210,hdmi输出i2c接口
    output wire sys_ms7210_iic_scl,
    inout wire sys_ms7210_iic_sda,
    output wire sys_ms7210_rstn,  //MS7200 硬件复位信号，低电平有效
    //hdmi输出信号
    output wire sys_hdmi_out_pixclk,  //HDMI显示图像像素时钟
    output reg sys_hdmi_out_vsync,
    output reg sys_hdmi_out_hsync,
    output reg sys_hdmi_out_de,
    output reg [7:0] sys_hdmi_out_r,
    output reg [7:0] sys_hdmi_out_g,
    output reg [7:0] sys_hdmi_out_b,

    // 系统状态指示灯
    output reg [7:0] sys_led
);

    //ms7200初始化完成标志
    wire sys_ms7200_done;
    //ms7210初始化完成标志
    wire sys_ms7210_done;

    //out1: 50MHz时钟输出,稳定系统50mhz输入，作为系统时钟
    //out2: 1.6MHz时钟输出,作为I2C工作时钟
    pll_50mhz pll_50mhz_instance (
        .clkin1(sys_clk_50mhz),  // input 50.0MHz
        .pll_lock(pll_lock),  // output
        .clkout0(pll_clk_50mhz),  // output 50.0MHz
        .clkout1(iic_clk_1m6hz)  // output 1.6MHz
    );

    //ms7200初始化模块
    ms7200_top ms7200_top_inst (
        .sys_clk(pll_clk_50mhz),
        .sys_rstn(sys_rstn),
        .ms7200_rstn(sys_ms7200_rstn),
        .iic_clk(iic_clk_1m6hz),
        .sys_ms7200_iic_scl(sys_ms7200_iic_scl),
        .sys_ms7200_iic_sda(sys_ms7200_iic_sda),
        .sys_ms7200_done(sys_ms7200_done)
    );

    //ms7210初始化模块
    ms7210_top ms7210_top_inst (
        .sys_clk(pll_clk_50mhz),
        .sys_rstn(sys_rstn),
        .ms7200_rstn(sys_ms7210_rstn),
        .iic_clk(iic_clk_1m6hz),
        .sys_ms7210_iic_scl(sys_ms7210_iic_scl),
        .sys_ms7210_iic_sda(sys_ms7210_iic_sda),
        .sys_ms7210_done(sys_ms7210_done)
    );

    //hdmi信号回环模块
    assign sys_hdmi_out_pixclk = sys_hdmi_in_pixclk;
    always @(posedge sys_hdmi_in_pixclk or negedge sys_rstn) begin
        if (!sys_rstn) begin
            sys_hdmi_out_vsync <= 1'b0;
            sys_hdmi_out_hsync <= 1'b0;
            sys_hdmi_out_de <= 1'b0;
            sys_hdmi_out_r <= 8'b0;
            sys_hdmi_out_g <= 8'b0;
            sys_hdmi_out_b <= 8'b0;
        end
        else begin
            sys_hdmi_out_vsync <= sys_hdmi_in_vsync;
            sys_hdmi_out_hsync <= sys_hdmi_in_hsync;
            sys_hdmi_out_de <= sys_hdmi_in_de;
            sys_hdmi_out_r <= sys_hdmi_in_r;
            sys_hdmi_out_g <= sys_hdmi_in_g;
            sys_hdmi_out_b <= sys_hdmi_in_b;
        end
    end
endmodule

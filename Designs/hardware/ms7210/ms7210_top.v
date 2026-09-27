//ms7210初始化顶层模块,
module ms7210_top (
    input sys_clk,  //系统时钟
    input sys_rstn,  //系统复位信号，低电平有效

    input ms7200_rstn,  //MS7200 硬件复位信号，低电平有效
    input iic_clk,  // I2C 时钟信号
    output sys_ms7210_iic_scl,  //MS7210 I2C SCL 信号
    inout sys_ms7210_iic_sda,  //MS7210 I2C SDA 信号

    output sys_ms7210_done  //MS7210 初始化完成标志，高电平表示初始化完成
);
    //ms7210驱动模块,初始化配置ms7210芯片寄存器
    ms7210_driver ms7210_driver_instance (
        .sys_clk(sys_clk),
        .sys_rstn(sys_rstn),


    );

    //ms7210 iic驱动模块，将ms7210_driver_instance中的初始化配置通过iic写入芯片
    iic_master ms7210_iic_instance (
        .clk(iic_clk),
        .rst_n(sys_rstn),
        .iic_scl(sys_ms7210_iic_scl),
        .iic_sda(sys_ms7210_iic_sda)
    );
endmodule

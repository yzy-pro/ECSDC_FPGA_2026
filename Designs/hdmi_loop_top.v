module hdmi_loop_top #(
    parameter integer SYS_CLK_FREQ_HZ = 50_000_000,
    parameter integer IIC_CLK_FREQ_HZ = 1_600_000,
    parameter integer IIC_SCL_FREQ_HZ = 400_000
) (
    // 系统时钟与低有效异步复位
    input wire sys_clk_50mhz,
    input wire sys_rstn,

    output wire sys_ms72xx_rstn,  //ms7200和ms7210共用的硬件复位引脚

    // MS7200 HDMI 接收芯片。两颗 MS72xx 共用该硬件复位引脚。
    output wire sys_ms7200_iic_scl,
    inout wire sys_ms7200_iic_sda,


    // MS7200 输出的并行 RGB888 视频信号
    input wire sys_hdmi_in_pixclk,
    input wire sys_hdmi_in_vsync,
    input wire sys_hdmi_in_hsync,
    input wire sys_hdmi_in_de,
    input wire [7:0] sys_hdmi_in_r,
    input wire [7:0] sys_hdmi_in_g,
    input wire [7:0] sys_hdmi_in_b,

    // MS7210 HDMI 发送芯片 I2C 接口
    output wire sys_ms7210_iic_scl,
    inout wire sys_ms7210_iic_sda,

    // 送往 MS7210 的并行 RGB888 视频信号
    output wire sys_hdmi_out_pixclk,
    output reg sys_hdmi_out_vsync,
    output reg sys_hdmi_out_hsync,
    output reg sys_hdmi_out_de,
    output reg [7:0] sys_hdmi_out_r,
    output reg [7:0] sys_hdmi_out_g,
    output reg [7:0] sys_hdmi_out_b,

    // 高电平点亮的系统状态指示灯
    output wire [7:0] sys_led
);

    localparam [1:0] ST_WAIT_PLL  = 2'd0;
    localparam [1:0] ST_CONFIG_RX = 2'd1;
    localparam [1:0] ST_CONFIG_TX = 2'd2;
    localparam [1:0] ST_RUN       = 2'd3;

    wire pll_clk_50mhz;
    wire iic_clk_1m6hz;
    wire pll_lock;

    // PLL 锁定信号采用异步置复位、同步释放方式进入系统控制时钟域。
    reg pll_ready_meta;
    reg pll_ready_sync;
    wire control_rstn;

    reg [1:0] state_current;
    reg [1:0] state_next;
    reg ms7200_enable;
    reg ms7210_enable;

    wire ms7200_control_rstn;
    wire ms7210_control_rstn;
    wire sys_ms7200_done;
    wire sys_ms7210_done;
    wire ms7210_rstn_unused;

    // 视频使能从系统控制时钟域同步到输入像素时钟域。
    wire video_enable_request;
    reg video_enable_meta;
    reg video_enable_sync;

    // 顶层只生成LED状态命令，具体驱动时序统一由led模块实现。
    wire [7:0] led_cmd;

    pll_50mhz u_pll_50mhz (
        .clkin1(sys_clk_50mhz),
        .clkout0(pll_clk_50mhz),
        .clkout1(iic_clk_1m6hz),
        .pll_lock(pll_lock)
    );

    // PLL 失锁或外部复位时异步复位；PLL 稳定后经过两级寄存器同步释放。
    always @(posedge pll_clk_50mhz or negedge sys_rstn or negedge pll_lock) begin
        if (!sys_rstn || !pll_lock) begin
            pll_ready_meta <= 1'b0;
            pll_ready_sync <= 1'b0;
        end
        else begin
            pll_ready_meta <= 1'b1;
            pll_ready_sync <= pll_ready_meta;
        end
    end

    assign control_rstn = sys_rstn && pll_ready_sync;
    assign ms7200_control_rstn = control_rstn && ms7200_enable;
    assign ms7210_control_rstn = control_rstn && ms7210_enable;
    assign video_enable_request = (state_current == ST_RUN) && sys_ms7200_done && sys_ms7210_done;

    // 第一段：系统启动顺序状态寄存器。
    always @(posedge pll_clk_50mhz or negedge control_rstn) begin
        if (!control_rstn) state_current <= ST_WAIT_PLL;
        else state_current <= state_next;
    end

    // 第二段：系统启动顺序次态组合逻辑。
    always @(*) begin
        state_next = state_current;

        case (state_current)
            ST_WAIT_PLL: state_next = ST_CONFIG_RX;
            ST_CONFIG_RX: begin
                if (sys_ms7200_done) state_next = ST_CONFIG_TX;
            end
            ST_CONFIG_TX: begin
                if (sys_ms7210_done) state_next = ST_RUN;
            end
            ST_RUN: state_next = ST_RUN;
            default: state_next = ST_WAIT_PLL;
        endcase
    end

    // 第三段：根据系统状态依次释放接收端和发送端配置模块。
    always @(posedge pll_clk_50mhz or negedge control_rstn) begin
        if (!control_rstn) begin
            ms7200_enable <= 1'b0;
            ms7210_enable <= 1'b0;
        end
        else begin
            case (state_current)
                ST_WAIT_PLL: begin
                    ms7200_enable <= 1'b0;
                    ms7210_enable <= 1'b0;
                end
                ST_CONFIG_RX: begin
                    ms7200_enable <= 1'b1;
                    ms7210_enable <= 1'b0;
                end
                ST_CONFIG_TX, ST_RUN: begin
                    ms7200_enable <= 1'b1;
                    ms7210_enable <= 1'b1;
                end
                default: begin
                    ms7200_enable <= 1'b0;
                    ms7210_enable <= 1'b0;
                end
            endcase
        end
    end

    // MS7200 首先完成硬件复位、寄存器初始化和输入状态检测。
    // 其硬件复位输出直接连接到两颗 MS72xx 共用的板级复位引脚。
    ms7200_top #(
        .SYS_CLK_FREQ_HZ(SYS_CLK_FREQ_HZ),
        .IIC_CLK_FREQ_HZ(IIC_CLK_FREQ_HZ),
        .IIC_SCL_FREQ_HZ(IIC_SCL_FREQ_HZ)
    ) u_ms7200_top (
        .sys_clk(pll_clk_50mhz),
        .sys_rstn(ms7200_control_rstn),
        .ms7200_rstn(sys_ms72xx_rstn),
        .iic_clk(iic_clk_1m6hz),
        .sys_ms7200_iic_scl(sys_ms7200_iic_scl),
        .sys_ms7200_iic_sda(sys_ms7200_iic_sda),
        .sys_ms7200_done(sys_ms7200_done)
    );

    // MS7210 在 MS7200 完成后开始配置。其复位输出不再连接到管脚，
    // 因为板上 MS7200 与 MS7210 已由 sys_ms72xx_rstn 共用同一硬件复位线。
    ms7210_top #(
        .SYS_CLK_FREQ_HZ(SYS_CLK_FREQ_HZ),
        .IIC_CLK_FREQ_HZ(IIC_CLK_FREQ_HZ),
        .IIC_SCL_FREQ_HZ(IIC_SCL_FREQ_HZ)
    ) u_ms7210_top (
        .sys_clk(pll_clk_50mhz),
        .sys_rstn(ms7210_control_rstn),
        .ms7210_rstn(ms7210_rstn_unused),
        .iic_clk(iic_clk_1m6hz),
        .sys_ms7210_iic_scl(sys_ms7210_iic_scl),
        .sys_ms7210_iic_sda(sys_ms7210_iic_sda),
        .sys_ms7210_done(sys_ms7210_done)
    );

    // 像素时钟直接转发，避免使用普通逻辑门控高速时钟。
    assign sys_hdmi_out_pixclk = sys_hdmi_in_pixclk;

    // 配置完成标志跨入像素时钟域，连续两拍稳定后才允许输出有效视频。
    always @(posedge sys_hdmi_in_pixclk or negedge sys_rstn) begin
        if (!sys_rstn) begin
            video_enable_meta <= 1'b0;
            video_enable_sync <= 1'b0;
        end
        else begin
            video_enable_meta <= video_enable_request;
            video_enable_sync <= video_enable_meta;
        end
    end

    // RGB、同步和数据有效信号统一寄存一级，保持各通道时序一致。
    always @(posedge sys_hdmi_in_pixclk or negedge sys_rstn) begin
        if (!sys_rstn) begin
            sys_hdmi_out_vsync <= 1'b0;
            sys_hdmi_out_hsync <= 1'b0;
            sys_hdmi_out_de <= 1'b0;
            sys_hdmi_out_r <= 8'd0;
            sys_hdmi_out_g <= 8'd0;
            sys_hdmi_out_b <= 8'd0;
        end
        else if (!video_enable_sync) begin
            sys_hdmi_out_vsync <= 1'b0;
            sys_hdmi_out_hsync <= 1'b0;
            sys_hdmi_out_de <= 1'b0;
            sys_hdmi_out_r <= 8'd0;
            sys_hdmi_out_g <= 8'd0;
            sys_hdmi_out_b <= 8'd0;
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

    // LED0：PLL稳定；LED1：共享硬件复位已释放；LED4：视频回环已启用；
    // LED7：MS7200初始化完成；LED6：MS7210初始化完成；其余LED保留。
    assign led_cmd = {
        sys_ms7200_done,  // LED7
        sys_ms7210_done,  // LED6
        1'b0,  // LED5
        video_enable_request,  // LED4
        1'b0,  // LED3
        1'b0,  // LED2
        sys_ms72xx_rstn,  // LED1
        control_rstn  // LED0
    };

    led #(
        .LED_NUMBER(8)
    ) u_led (
        .sys_clk_50mhz(pll_clk_50mhz),
        .sys_rst_n(control_rstn),
        .led_cmd(led_cmd),
        .sys_led(sys_led)
    );

endmodule

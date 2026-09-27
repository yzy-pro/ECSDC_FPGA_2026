module ms7200_top #(
    parameter integer SYS_CLK_FREQ_HZ = 50_000_000,
    parameter integer IIC_CLK_FREQ_HZ = 1_600_000,
    parameter integer IIC_SCL_FREQ_HZ = 400_000,
    parameter integer RESET_HOLD_MS = 1,
    parameter integer RESET_RELEASE_MS = 1
) (
    // 系统控制时钟与低有效异步复位
    input  wire sys_clk,
    input  wire sys_rstn,

    // MS7200 硬件复位与 I2C 引脚
    output reg  ms7200_rstn,
    input  wire iic_clk,
    output wire sys_ms7200_iic_scl,
    inout  wire sys_ms7200_iic_sda,

    // MS7200 配置完成标志
    output reg  sys_ms7200_done
);

    localparam [1:0] ST_RESET_HOLD = 2'd0;
    localparam [1:0] ST_RESET_WAIT = 2'd1;
    localparam [1:0] ST_CONFIG     = 2'd2;
    localparam [1:0] ST_DONE       = 2'd3;

    localparam integer RESET_HOLD_CYCLES_RAW =
        (SYS_CLK_FREQ_HZ / 1000) * RESET_HOLD_MS;
    localparam integer RESET_WAIT_CYCLES_RAW =
        (SYS_CLK_FREQ_HZ / 1000) * RESET_RELEASE_MS;
    localparam integer RESET_HOLD_CYCLES =
        (RESET_HOLD_CYCLES_RAW < 1) ? 1 : RESET_HOLD_CYCLES_RAW;
    localparam integer RESET_WAIT_CYCLES =
        (RESET_WAIT_CYCLES_RAW < 1) ? 1 : RESET_WAIT_CYCLES_RAW;

    reg [1:0] state_current;
    reg [1:0] state_next;
    reg [31:0] delay_counter;
    reg config_enable;

    // 配置驱动输出的 I2C 事务信息，均在 sys_clk 时钟域产生。
    wire [7:0]  driver_device_id;
    wire        driver_iic_start;
    wire        driver_iic_dir;
    wire [15:0] driver_iic_addr;
    wire [7:0]  driver_iic_wr_data;
    wire [7:0]  iic_rd_data;
    wire        iic_done;
    wire        iic_busy;
    wire        iic_error;
    wire        driver_done;

    // 配置状态释放后，分别为两个时钟域生成复位。
    wire driver_rstn;
    reg  iic_reset_meta;
    reg  iic_reset_sync;
    wire iic_master_rstn;

    assign driver_rstn = sys_rstn && config_enable;
    assign iic_master_rstn = iic_reset_sync;

    // I2C 主机位于 iic_clk 域，其复位释放必须同步到 iic_clk。
    // 异步复位仍由 sys_rstn 直接保证，系统复位时会立即释放 I2C 总线。
    always @(posedge iic_clk or negedge sys_rstn) begin
        if (!sys_rstn) begin
            iic_reset_meta <= 1'b0;
            iic_reset_sync <= 1'b0;
        end
        else begin
            iic_reset_meta <= config_enable;
            iic_reset_sync <= iic_reset_meta;
        end
    end

    // 第一段：顶层控制状态寄存器。
    always @(posedge sys_clk or negedge sys_rstn) begin
        if (!sys_rstn) state_current <= ST_RESET_HOLD;
        else state_current <= state_next;
    end

    // 第二段：顶层控制次态组合逻辑。
    always @(*) begin
        state_next = state_current;

        case (state_current)
            ST_RESET_HOLD: begin
                if (delay_counter >= RESET_HOLD_CYCLES - 1)
                    state_next = ST_RESET_WAIT;
            end

            ST_RESET_WAIT: begin
                if (delay_counter >= RESET_WAIT_CYCLES - 1)
                    state_next = ST_CONFIG;
            end

            ST_CONFIG: begin
                if (driver_done) state_next = ST_DONE;
            end

            ST_DONE: state_next = ST_DONE;
            default: state_next = ST_RESET_HOLD;
        endcase
    end

    // 第三段：硬件复位、配置使能、延时计数和完成标志。
    always @(posedge sys_clk or negedge sys_rstn) begin
        if (!sys_rstn) begin
            delay_counter <= 32'd0;
            ms7200_rstn <= 1'b0;
            config_enable <= 1'b0;
            sys_ms7200_done <= 1'b0;
        end
        else begin
            case (state_current)
                ST_RESET_HOLD: begin
                    ms7200_rstn <= 1'b0;
                    config_enable <= 1'b0;
                    sys_ms7200_done <= 1'b0;

                    if (state_next != ST_RESET_HOLD)
                        delay_counter <= 32'd0;
                    else
                        delay_counter <= delay_counter + 1'b1;
                end

                ST_RESET_WAIT: begin
                    ms7200_rstn <= 1'b1;
                    config_enable <= 1'b0;
                    sys_ms7200_done <= 1'b0;

                    if (state_next != ST_RESET_WAIT)
                        delay_counter <= 32'd0;
                    else
                        delay_counter <= delay_counter + 1'b1;
                end

                ST_CONFIG: begin
                    delay_counter <= 32'd0;
                    ms7200_rstn <= 1'b1;
                    config_enable <= 1'b1;
                    sys_ms7200_done <= driver_done;
                end

                ST_DONE: begin
                    delay_counter <= 32'd0;
                    ms7200_rstn <= 1'b1;
                    config_enable <= 1'b1;
                    sys_ms7200_done <= 1'b1;
                end

                default: begin
                    delay_counter <= 32'd0;
                    ms7200_rstn <= 1'b0;
                    config_enable <= 1'b0;
                    sys_ms7200_done <= 1'b0;
                end
            endcase
        end
    end

    // 配置状态机工作在 sys_clk 域。启动请求保持到 iic_busy 返回；
    // 地址、方向和写数据在事务结束前保持稳定，使用电平握手完成跨时钟域传输。
    ms7200_driver ms7200_driver_instance (
        .sys_clk    (sys_clk),
        .sys_rstn   (driver_rstn),
        .device_id  (driver_device_id),
        .iic_start  (driver_iic_start),
        .iic_dir    (driver_iic_dir),
        .iic_addr   (driver_iic_addr),
        .iic_wr_data(driver_iic_wr_data),
        .iic_rd_data(iic_rd_data),
        .iic_done   (iic_done),
        .iic_busy   (iic_busy),
        .ms7200_done(driver_done)
    );

    // MS7200 的 8 位地址字节为 8'h56，对应 7 位设备地址 7'h2B。
    iic_master #(
        .DEVICE_ADDR (7'h2B),
        .IIC_CLK_FREQ(IIC_CLK_FREQ_HZ),
        .IIC_SCL_FREQ(IIC_SCL_FREQ_HZ)
    ) ms7200_iic_instance (
        .clk        (iic_clk),
        .sys_rstn   (iic_master_rstn),
        .wr_en      (driver_iic_dir),
        .rd_en      (!driver_iic_dir),
        .addr_length(1'b1),
        .addr       (driver_iic_addr),
        .wr_data    (driver_iic_wr_data),
        .rd_data    (iic_rd_data),
        .iic_start  (driver_iic_start),
        .iic_done   (iic_done),
        .iic_busy   (iic_busy),
        .iic_error  (iic_error),
        .scl        (sys_ms7200_iic_scl),
        .sda        (sys_ms7200_iic_sda)
    );

endmodule

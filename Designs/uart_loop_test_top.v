// UART收发回环测试顶层模块。
// 将串口接收到的字节原样发送回去。
// LED7用于指示接收活动，LED6用于指示发送活动。

module uart_loop_test_top #(
    parameter SYS_CLK_FREQ = 50_000_000,
    // PLL产生的UART时钟实际频率为14.743589743 MHz。
    // UART驱动对分频结果进行四舍五入，每个串口数据位对应16个时钟周期。
    parameter UART_CLK_FREQ = 14_743_589,
    parameter BAUD_RATE = 921600,
    parameter DATA_BITS = 8,
    parameter PARITY = "NONE",
    parameter STOP_BITS = 1,
    parameter LED_ON_MS = 100
) (
    input wire sys_clk_50mhz,
    input wire sys_rst_n,

    input wire sys_uart_rx,
    output wire sys_uart_tx,

    output wire [7:0] sys_led
);

    localparam integer LED_ON_CYCLES = (SYS_CLK_FREQ / 1000) * LED_ON_MS;

    wire pll_lock;
    wire pll_sys_clk_50mhz;
    wire uart_clk;
    wire pll_reset_n;
    wire sys_domain_rst_n;
    wire uart_domain_rst_n;

    reg [1:0] sys_reset_sync;
    reg [1:0] uart_reset_sync;

    wire [7:0] uart_data_rx;
    wire uart_data_valid_rx;
    wire tx_start;

    reg [7:0] tx_data_buffer;
    reg tx_pending;

    reg rx_activity_toggle;
    reg tx_activity_toggle;
    reg rx_toggle_meta;
    reg rx_toggle_sync;
    reg rx_toggle_delay;
    reg tx_toggle_meta;
    reg tx_toggle_sync;
    reg tx_toggle_delay;
    integer rx_led_count;
    integer tx_led_count;
    reg [7:0] led_cmd;

    // 实例化PLL时钟IP核。
    pll_50mhz u_pll_50mhz (
        .clkin1(sys_clk_50mhz),
        .pll_lock(pll_lock),
        .clkout0(pll_sys_clk_50mhz),
        .clkout1(uart_clk)
    );

    // 在系统时钟域和UART时钟域中分别实现异步复位、同步释放。
    assign pll_reset_n = sys_rst_n & pll_lock;

    always @(posedge pll_sys_clk_50mhz or negedge pll_reset_n) begin
        if (!pll_reset_n) sys_reset_sync <= 2'b00;
        else sys_reset_sync <= {sys_reset_sync[0], 1'b1};
    end

    always @(posedge uart_clk or negedge pll_reset_n) begin
        if (!pll_reset_n) uart_reset_sync <= 2'b00;
        else uart_reset_sync <= {uart_reset_sync[0], 1'b1};
    end

    assign sys_domain_rst_n = sys_reset_sync[1];
    assign uart_domain_rst_n = uart_reset_sync[1];

    uart_rx #(
        .SYS_CLK_FREQ(SYS_CLK_FREQ),
        .UART_CLK_FREQ(UART_CLK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .DATA_BITS(DATA_BITS),
        .PARITY(PARITY),
        .STOP_BITS(STOP_BITS)
    ) u_uart_rx (
        .sys_clk_50mhz(pll_sys_clk_50mhz),
        .uart_clk(uart_clk),
        .sys_rst_n(uart_domain_rst_n),
        .sys_uart_rx(sys_uart_rx),
        .uart_data_rx(uart_data_rx),
        .uart_data_valid_rx(uart_data_valid_rx)
    );

    // 单字节回环缓冲区。tx_pending保持有效，直到发送器真正输出起始位，
    // 从而避免接收到的字节在启动发送之前丢失。
    always @(posedge uart_clk or negedge uart_domain_rst_n) begin
        if (!uart_domain_rst_n) begin
            tx_data_buffer <= 8'd0;
            tx_pending <= 1'b0;
        end
        else begin
            if (uart_data_valid_rx) begin
                tx_data_buffer <= uart_data_rx;
                tx_pending <= 1'b1;
            end
            else if (tx_start) begin
                tx_pending <= 1'b0;
            end
        end
    end

    uart_tx #(
        .SYS_CLK_FREQ(SYS_CLK_FREQ),
        .UART_CLK_FREQ(UART_CLK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .DATA_BITS(DATA_BITS),
        .PARITY(PARITY),
        .STOP_BITS(STOP_BITS)
    ) u_uart_tx (
        .sys_clk_50mhz(pll_sys_clk_50mhz),
        .uart_clk(uart_clk),
        .sys_rst_n(uart_domain_rst_n),
        .sys_uart_tx(sys_uart_tx),
        .uart_data_tx(tx_data_buffer),
        .uart_data_valid_tx(tx_pending)
    );

    assign tx_start = tx_pending & ~sys_uart_tx;

    // 将短暂的收发有效脉冲转换为翻转信号，再跨入50 MHz的LED时钟域。
    // 即使原始脉冲很窄，两级同步器也能够检测到翻转事件。
    always @(posedge uart_clk or negedge uart_domain_rst_n) begin
        if (!uart_domain_rst_n) begin
            rx_activity_toggle <= 1'b0;
            tx_activity_toggle <= 1'b0;
        end
        else begin
            if (uart_data_valid_rx) rx_activity_toggle <= ~rx_activity_toggle;
            if (tx_start) tx_activity_toggle <= ~tx_activity_toggle;
        end
    end

    always @(posedge pll_sys_clk_50mhz or negedge sys_domain_rst_n) begin
        if (!sys_domain_rst_n) begin
            rx_toggle_meta <= 1'b0;
            rx_toggle_sync <= 1'b0;
            rx_toggle_delay <= 1'b0;
            tx_toggle_meta <= 1'b0;
            tx_toggle_sync <= 1'b0;
            tx_toggle_delay <= 1'b0;
            rx_led_count <= 0;
            tx_led_count <= 0;
        end
        else begin
            rx_toggle_meta <= rx_activity_toggle;
            rx_toggle_sync <= rx_toggle_meta;
            rx_toggle_delay <= rx_toggle_sync;
            tx_toggle_meta <= tx_activity_toggle;
            tx_toggle_sync <= tx_toggle_meta;
            tx_toggle_delay <= tx_toggle_sync;

            if (rx_toggle_sync != rx_toggle_delay) rx_led_count <= LED_ON_CYCLES;
            else if (rx_led_count > 0) rx_led_count <= rx_led_count - 1;

            if (tx_toggle_sync != tx_toggle_delay) tx_led_count <= LED_ON_CYCLES;
            else if (tx_led_count > 0) tx_led_count <= tx_led_count - 1;
        end
    end

    always @(*) begin
        led_cmd = 8'd0;
        led_cmd[7] = (rx_led_count > 0);
        led_cmd[6] = (tx_led_count > 0);
    end

    led #(
        .LED_NUMBER(8)
    ) u_led (
        .sys_clk_50mhz(pll_sys_clk_50mhz),
        .sys_rst_n(sys_domain_rst_n),
        .led_cmd(led_cmd),
        .sys_led(sys_led)
    );

endmodule

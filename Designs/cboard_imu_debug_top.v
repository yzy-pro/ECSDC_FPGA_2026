// IMU receive/verify/forward debug top. LED7: accepted frame, LED6: forwarded frame.
module cboard_imu_debug_top #(
    parameter SYS_CLK_FREQ = 50_000_000,
    parameter UART_CLK_FREQ = 14_743_589,
    parameter BAUD_RATE = 921600,
    parameter DATA_BITS = 8,
    parameter PARITY = "NONE",
    parameter STOP_BITS = 1,
    parameter LED_ON_MS = 100
) (
    input wire sys_clk_50mhz,
    input wire sys_rst_n,
    input wire sys_cboardimu_rx,
    output wire sys_uart_tx,
    output wire [7:0] sys_led
);
    localparam integer LED_ON_CYCLES = (SYS_CLK_FREQ / 1000) * LED_ON_MS;
    wire pll_lock, pll_sys_clk_50mhz, uart_clk, pll_reset_n, sys_domain_rst_n, uart_domain_rst_n;
    reg [1:0] sys_reset_sync, uart_reset_sync;
    wire [47:0] attitude_data;
    wire attitude_empty, attitude_rd_en, rx_activity_toggle, tx_activity_toggle;
    reg
        rx_toggle_meta,
        rx_toggle_sync,
        rx_toggle_delay,
        tx_toggle_meta,
        tx_toggle_sync,
        tx_toggle_delay;
    integer rx_led_count, tx_led_count;
    reg [7:0] led_cmd;
    pll_50mhz u_pll_50mhz (
        .clkin1(sys_clk_50mhz),
        .pll_lock(pll_lock),
        .clkout0(pll_sys_clk_50mhz),
        .clkout1(uart_clk)
    );
    assign pll_reset_n = sys_rst_n & pll_lock;
    always @(posedge pll_sys_clk_50mhz or negedge pll_reset_n) begin
        if (!pll_reset_n) sys_reset_sync <= 0;
        else sys_reset_sync <= {sys_reset_sync[0], 1'b1};
    end
    always @(posedge uart_clk or negedge pll_reset_n) begin
        if (!pll_reset_n) uart_reset_sync <= 0;
        else uart_reset_sync <= {uart_reset_sync[0], 1'b1};
    end
    assign sys_domain_rst_n = sys_reset_sync[1];
    assign uart_domain_rst_n = uart_reset_sync[1];
    cboard_imu #(
        .SYS_CLK_FREQ(SYS_CLK_FREQ),
        .UART_CLK_FREQ(UART_CLK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .DATA_BITS(DATA_BITS),
        .PARITY(PARITY),
        .STOP_BITS(STOP_BITS)
    ) u_cboard_imu (
        .sys_clk_50mhz(pll_sys_clk_50mhz),
        .uart_clk(uart_clk),
        .sys_rst_n(sys_domain_rst_n),
        .uart_rst_n(uart_domain_rst_n),
        .sys_cboardimu_rx(sys_cboardimu_rx),
        .attitude_rd_en(attitude_rd_en),
        .attitude_rd_data(attitude_data),
        .attitude_empty(attitude_empty),
        .rx_activity_toggle(rx_activity_toggle)
    );
    cp2102 #(
        .SYS_CLK_FREQ(SYS_CLK_FREQ),
        .UART_CLK_FREQ(UART_CLK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .DATA_BITS(DATA_BITS),
        .PARITY(PARITY),
        .STOP_BITS(STOP_BITS)
    ) u_cp2102 (
        .sys_clk_50mhz(pll_sys_clk_50mhz),
        .uart_clk(uart_clk),
        .sys_rst_n(sys_domain_rst_n),
        .uart_rst_n(uart_domain_rst_n),
        .attitude_data(attitude_data),
        .attitude_empty(attitude_empty),
        .attitude_rd_en(attitude_rd_en),
        .sys_uart_tx(sys_uart_tx),
        .tx_activity_toggle(tx_activity_toggle)
    );
    always @(posedge pll_sys_clk_50mhz or negedge sys_domain_rst_n) begin
        if (!sys_domain_rst_n) begin
            rx_toggle_meta <= 0;
            rx_toggle_sync <= 0;
            rx_toggle_delay <= 0;
            tx_toggle_meta <= 0;
            tx_toggle_sync <= 0;
            tx_toggle_delay <= 0;
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
        led_cmd = 0;
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

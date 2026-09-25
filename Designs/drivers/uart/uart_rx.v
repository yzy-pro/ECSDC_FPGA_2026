// UART接收驱动模块，采用16倍波特率时钟在数据位中点采样。

module uart_rx #(
    parameter SYS_CLK_FREQ  = 50_000_000,
    parameter UART_CLK_FREQ = 14_745_600,
    parameter BAUD_RATE     = 921600,
    parameter DATA_BITS     = 8,
    parameter PARITY        = "NONE",  // 校验模式："NONE"、"EVEN"或"ODD"
    parameter STOP_BITS     = 1
) (
    input  wire       sys_clk_50mhz,
    input  wire       uart_clk,
    input  wire       sys_rst_n,

    input  wire       sys_uart_rx,

    output reg  [7:0] uart_data_rx,
    output reg        uart_data_valid_rx
);

    // 采用四舍五入计算每个串口数据位对应的时钟周期数。
    // PLL输出约为14.74359 MHz，如果直接截断除法结果，会错误地得到15；
    // 四舍五入后得到正确的16个uart_clk周期。
    localparam integer CLKS_PER_BIT =
        (UART_CLK_FREQ + (BAUD_RATE / 2)) / BAUD_RATE;
    localparam integer HALF_BIT     = CLKS_PER_BIT / 2;
    localparam         PARITY_EN    = (PARITY != "NONE");

    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_START  = 3'd1;
    localparam [2:0] ST_DATA   = 3'd2;
    localparam [2:0] ST_PARITY = 3'd3;
    localparam [2:0] ST_STOP   = 3'd4;

    reg [2:0] current_state;
    reg [2:0] next_state;

    reg       rx_meta;
    reg       rx_sync;
    reg [7:0] rx_data_latch;
    reg       parity_error;
    reg       frame_error;
    integer   clk_count;
    integer   bit_index;
    integer   stop_index;

    wire start_sample = (clk_count == HALF_BIT - 1);
    wire bit_sample   = (clk_count == CLKS_PER_BIT - 1);

    // 为保持模块接口兼容而保留sys_clk_50mhz。
    // 接收驱动内部逻辑全部工作在uart_clk时钟域。
    wire unused_sys_clk = sys_clk_50mhz;

    // 使用两级寄存器同步异步串口输入，再进行电平检测和数据采样。
    always @(posedge uart_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= sys_uart_rx;
            rx_sync <= rx_meta;
        end
    end

    // 第一段：时序逻辑，保存当前状态。
    always @(posedge uart_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            current_state <= ST_IDLE;
        else
            current_state <= next_state;
    end

    // 第二段：组合逻辑，根据当前状态和输入条件计算下一状态。
    always @(*) begin
        next_state = current_state;

        case (current_state)
            ST_IDLE: begin
                if (!rx_sync)
                    next_state = ST_START;
            end

            ST_START: begin
                if (start_sample) begin
                    if (!rx_sync)
                        next_state = ST_DATA;
                    else
                        next_state = ST_IDLE;  // 起始位无效，返回空闲状态。
                end
            end

            ST_DATA: begin
                if (bit_sample && (bit_index == DATA_BITS - 1)) begin
                    if (PARITY_EN)
                        next_state = ST_PARITY;
                    else
                        next_state = ST_STOP;
                end
            end

            ST_PARITY: begin
                if (bit_sample)
                    next_state = ST_STOP;
            end

            ST_STOP: begin
                if (bit_sample && (stop_index == STOP_BITS - 1))
                    next_state = ST_IDLE;
            end

            default: next_state = ST_IDLE;
        endcase
    end

    // 第三段：时序逻辑，更新接收数据、计数器及有效脉冲。
    always @(posedge uart_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rx_data_latch      <= 8'd0;
            uart_data_rx       <= 8'd0;
            uart_data_valid_rx <= 1'b0;
            parity_error       <= 1'b0;
            frame_error        <= 1'b0;
            clk_count          <= 0;
            bit_index          <= 0;
            stop_index         <= 0;
        end else begin
            uart_data_valid_rx <= 1'b0;

            case (current_state)
                ST_IDLE: begin
                    clk_count     <= 0;
                    bit_index     <= 0;
                    stop_index    <= 0;
                    parity_error  <= 1'b0;
                    frame_error   <= 1'b0;
                end

                ST_START: begin
                    if (start_sample)
                        clk_count <= 0;
                    else
                        clk_count <= clk_count + 1;
                end

                ST_DATA: begin
                    if (bit_sample) begin
                        clk_count <= 0;
                        rx_data_latch[bit_index] <= rx_sync;

                        if (bit_index < DATA_BITS - 1)
                            bit_index <= bit_index + 1;
                    end else begin
                        clk_count <= clk_count + 1;
                    end
                end

                ST_PARITY: begin
                    if (bit_sample) begin
                        clk_count <= 0;

                        if (PARITY == "ODD")
                            parity_error <= (rx_sync != ~(^rx_data_latch[DATA_BITS-1:0]));
                        else
                            parity_error <= (rx_sync !=  ^rx_data_latch[DATA_BITS-1:0]);
                    end else begin
                        clk_count <= clk_count + 1;
                    end
                end

                ST_STOP: begin
                    if (bit_sample) begin
                        clk_count <= 0;

                        if (!rx_sync)
                            frame_error <= 1'b1;

                        if (stop_index < STOP_BITS - 1) begin
                            stop_index <= stop_index + 1;
                        end else if (!parity_error && !frame_error && rx_sync) begin
                            uart_data_rx       <= rx_data_latch;
                            uart_data_valid_rx <= 1'b1;
                        end
                    end else begin
                        clk_count <= clk_count + 1;
                    end
                end

                default: begin
                    clk_count  <= 0;
                    bit_index  <= 0;
                    stop_index <= 0;
                end
            endcase
        end
    end

endmodule

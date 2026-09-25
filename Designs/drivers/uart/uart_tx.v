// UART发送驱动模块。
// uart_clk应当为波特率的整数倍；使用默认参数时，
// uart_clk为常用的16倍波特率时钟。

module uart_tx #(
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

    output wire       sys_uart_tx,

    input  wire [7:0] uart_data_tx,
    input  wire       uart_data_valid_tx,
    output wire       uart_busy
);

    // 采用四舍五入计算每个串口数据位对应的时钟周期数。
    // PLL输出约为14.74359 MHz，如果直接截断除法结果，会错误地得到15；
    // 四舍五入后得到正确的16个uart_clk周期。
    localparam integer CLKS_PER_BIT =
        (UART_CLK_FREQ + (BAUD_RATE / 2)) / BAUD_RATE;
    localparam         PARITY_EN    = (PARITY != "NONE");

    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_START  = 3'd1;
    localparam [2:0] ST_DATA   = 3'd2;
    localparam [2:0] ST_PARITY = 3'd3;
    localparam [2:0] ST_STOP   = 3'd4;

    reg [2:0] current_state;
    reg [2:0] next_state;

    reg [7:0] tx_data_latch;
    reg       parity_bit;
    integer   clk_count;
    integer   bit_index;
    integer   stop_index;

    wire bit_done = (clk_count == CLKS_PER_BIT - 1);

    // 为保持模块接口兼容而保留sys_clk_50mhz。
    // 发送驱动内部逻辑全部工作在uart_clk时钟域。
    wire unused_sys_clk = sys_clk_50mhz;

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
                if (uart_data_valid_tx)
                    next_state = ST_START;
            end

            ST_START: begin
                if (bit_done)
                    next_state = ST_DATA;
            end

            ST_DATA: begin
                if (bit_done && (bit_index == DATA_BITS - 1)) begin
                    if (PARITY_EN)
                        next_state = ST_PARITY;
                    else
                        next_state = ST_STOP;
                end
            end

            ST_PARITY: begin
                if (bit_done)
                    next_state = ST_STOP;
            end

            ST_STOP: begin
                if (bit_done && (stop_index == STOP_BITS - 1))
                    next_state = ST_IDLE;
            end

            default: next_state = ST_IDLE;
        endcase
    end

    // 第三段：时序逻辑，更新数据寄存器和各计数器。
    always @(posedge uart_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tx_data_latch <= 8'd0;
            parity_bit    <= 1'b0;
            clk_count     <= 0;
            bit_index     <= 0;
            stop_index    <= 0;
        end else begin
            case (current_state)
                ST_IDLE: begin
                    clk_count  <= 0;
                    bit_index  <= 0;
                    stop_index <= 0;

                    if (uart_data_valid_tx) begin
                        tx_data_latch <= uart_data_tx;

                        if (PARITY == "ODD")
                            parity_bit <= ~(^uart_data_tx[DATA_BITS-1:0]);
                        else
                            parity_bit <=  ^uart_data_tx[DATA_BITS-1:0];
                    end
                end

                ST_START: begin
                    if (bit_done)
                        clk_count <= 0;
                    else
                        clk_count <= clk_count + 1;
                end

                ST_DATA: begin
                    if (bit_done) begin
                        clk_count <= 0;
                        if (bit_index < DATA_BITS - 1)
                            bit_index <= bit_index + 1;
                    end else begin
                        clk_count <= clk_count + 1;
                    end
                end

                ST_PARITY: begin
                    if (bit_done)
                        clk_count <= 0;
                    else
                        clk_count <= clk_count + 1;
                end

                ST_STOP: begin
                    if (bit_done) begin
                        clk_count <= 0;
                        if (stop_index < STOP_BITS - 1)
                            stop_index <= stop_index + 1;
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

    // Moore型输出译码：串口空闲为高电平，数据从最低位开始发送。
    assign sys_uart_tx = (current_state == ST_START)  ? 1'b0 :
                         (current_state == ST_DATA)   ? tx_data_latch[bit_index] :
                         (current_state == ST_PARITY) ? parity_bit :
                                                        1'b1;

    assign uart_busy = (current_state != ST_IDLE);

endmodule

// IMU frame receiver and attitude FIFO.
// Frame format: 55 AA YL YH PL PH RL RH SUM 0D.
module cboard_imu #(
    parameter SYS_CLK_FREQ = 50_000_000,
    parameter UART_CLK_FREQ = 14_743_589,
    parameter BAUD_RATE = 921600,
    parameter DATA_BITS = 8,
    parameter PARITY = "NONE",
    parameter STOP_BITS = 1
) (
    input wire sys_clk_50mhz,
    input wire uart_clk,
    input wire sys_rst_n,
    input wire uart_rst_n,
    input wire sys_cboardimu_rx,
    input wire attitude_rd_en,
    output wire [47:0] attitude_rd_data,
    output wire attitude_empty,
    output reg rx_activity_toggle
);
    localparam [2:0] ST_HEADER_1 = 3'd0,
        ST_HEADER_2 = 3'd1, ST_PAYLOAD = 3'd2, ST_CHECKSUM = 3'd3, ST_TAIL = 3'd4;
    reg [2:0] current_state, next_state;
    reg [2:0] payload_index;
    reg [7:0] payload_0, payload_1, payload_2, payload_3, payload_4, payload_5;
    reg [7:0] checksum_accumulator;
    reg checksum_ok;
    wire [7:0] uart_data_rx;
    wire uart_data_valid_rx;
    reg [47:0] fifo_wr_data;
    reg fifo_wr_en;
    wire fifo_wr_full;
    wire fifo_almost_full, fifo_almost_empty;

    uart_rx #(
        .SYS_CLK_FREQ(SYS_CLK_FREQ),
        .UART_CLK_FREQ(UART_CLK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .DATA_BITS(DATA_BITS),
        .PARITY(PARITY),
        .STOP_BITS(STOP_BITS)
    ) u_uart_rx (
        .sys_clk_50mhz(sys_clk_50mhz),
        .uart_clk(uart_clk),
        .sys_rst_n(uart_rst_n),
        .sys_uart_rx(sys_cboardimu_rx),
        .uart_data_rx(uart_data_rx),
        .uart_data_valid_rx(uart_data_valid_rx)
    );
    cboard_imu_rx_fifo u_cboard_imu_rx_fifo (
        .wr_clk(uart_clk),
        .wr_rst(~uart_rst_n),
        .wr_en(fifo_wr_en),
        .wr_data(fifo_wr_data),
        .wr_full(fifo_wr_full),
        .rd_clk(sys_clk_50mhz),
        .rd_rst(~sys_rst_n),
        .rd_en(attitude_rd_en),
        .rd_data(attitude_rd_data),
        .almost_full(fifo_almost_full),
        .rd_empty(attitude_empty),
        .almost_empty(fifo_almost_empty)
    );

    // Three-stage FSM: state register.
    always @(posedge uart_clk or negedge uart_rst_n) begin
        if (!uart_rst_n) current_state <= ST_HEADER_1;
        else current_state <= next_state;
    end
    // Three-stage FSM: next-state logic and byte-stream resynchronization.
    always @(*) begin
        next_state = current_state;
        if (uart_data_valid_rx)
            case (current_state)
                ST_HEADER_1: if (uart_data_rx == 8'h55) next_state = ST_HEADER_2;
                ST_HEADER_2:
                if (uart_data_rx == 8'hAA) next_state = ST_PAYLOAD;
                else if (uart_data_rx == 8'h55) next_state = ST_HEADER_2;
                else next_state = ST_HEADER_1;
                ST_PAYLOAD: if (payload_index == 3'd5) next_state = ST_CHECKSUM;
                ST_CHECKSUM: next_state = ST_TAIL;
                ST_TAIL:
                if (uart_data_rx == 8'h55) next_state = ST_HEADER_2;
                else next_state = ST_HEADER_1;
                default: next_state = ST_HEADER_1;
            endcase
    end
    // Three-stage FSM: payload registers, checksum and FIFO write.
    always @(posedge uart_clk or negedge uart_rst_n) begin
        if (!uart_rst_n) begin
            payload_index <= 0;
            payload_0 <= 0;
            payload_1 <= 0;
            payload_2 <= 0;
            payload_3 <= 0;
            payload_4 <= 0;
            payload_5 <= 0;
            checksum_accumulator <= 0;
            checksum_ok <= 0;
            fifo_wr_data <= 0;
            fifo_wr_en <= 0;
            rx_activity_toggle <= 0;
        end
        else begin
            fifo_wr_en <= 0;
            if (uart_data_valid_rx)
                case (current_state)
                    ST_HEADER_2:
                    if (uart_data_rx == 8'hAA) begin
                        payload_index <= 0;
                        checksum_accumulator <= 0;
                        checksum_ok <= 0;
                    end
                    ST_PAYLOAD: begin
                        case (payload_index)
                            0: payload_0 <= uart_data_rx;
                            1: payload_1 <= uart_data_rx;
                            2: payload_2 <= uart_data_rx;
                            3: payload_3 <= uart_data_rx;
                            4: payload_4 <= uart_data_rx;
                            5: payload_5 <= uart_data_rx;
                            default: payload_0 <= payload_0;
                        endcase
                        checksum_accumulator <= checksum_accumulator + uart_data_rx;
                        if (payload_index < 5) payload_index <= payload_index + 1'b1;
                    end
                    ST_CHECKSUM: checksum_ok <= (uart_data_rx == checksum_accumulator);
                    ST_TAIL:
                    if ((uart_data_rx == 8'h0D) && checksum_ok && !fifo_wr_full) begin
                        fifo_wr_data <= {
                            payload_5, payload_4, payload_3, payload_2, payload_1, payload_0
                        };
                        fifo_wr_en <= 1;
                        rx_activity_toggle <= ~rx_activity_toggle;
                    end
                    default: payload_index <= payload_index;
                endcase
        end
    end
    wire unused_fifo_flags = fifo_almost_full | fifo_almost_empty;
endmodule

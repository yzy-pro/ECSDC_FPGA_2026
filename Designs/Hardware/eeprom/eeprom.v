// EEPROM 读写控制器。
//
// 写请求通过 RX FIFO 缓存，FIFO 数据格式为：
//   wr_data[20:8] = 13 位 EEPROM 地址
//   wr_data[7:0]  = 待写入的一个字节
//
// 读请求使用 read_req/read_addr 接口，I2C 驱动读回的数据进入 TX FIFO，
// 主控通过 read_data_rd_en 从 TX FIFO 取出数据。读请求要求 read_ready 为高时发出。
module eeprom #(
    parameter integer DEVICE_ADDR          = 7'b1010_000,
    parameter integer I2C_CLK_FREQ         = 1_000_000,
    parameter integer I2C_SCL_FREQ         = 250_000,
    parameter integer WRITE_CYCLE_TIME_US  = 5_000
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        write_req,
    input  wire [12:0] write_addr,
    input  wire [7:0]  write_data,
    output wire        write_full,

    input  wire        read_req,
    input  wire [12:0] read_addr,
    output wire        read_ready,
    output reg         read_accept,

    input  wire        read_data_rd_en,
    output wire [7:0]  read_data,
    output wire        read_data_empty,
    output wire        read_data_full,

    output wire        busy,
    output wire        scl,
    inout  wire        sda
);

    localparam integer WRITE_CYCLE_COUNT =
        (I2C_CLK_FREQ / 1_000_000) * WRITE_CYCLE_TIME_US;
    localparam integer WAIT_WIDTH =
        (WRITE_CYCLE_COUNT < 1) ? 1 : $clog2(WRITE_CYCLE_COUNT + 1);

    localparam [2:0] CTRL_IDLE  = 3'd0;
    localparam [2:0] CTRL_POP   = 3'd1;
    localparam [2:0] CTRL_LOAD  = 3'd2;
    localparam [2:0] CTRL_START = 3'd3;
    localparam [2:0] CTRL_WAIT  = 3'd4;

    reg [2:0] ctrl_state;
    reg [2:0] ctrl_state_next;
    reg [WAIT_WIDTH-1:0] write_wait_cnt;

    reg        operation_read;
    reg [15:0] operation_addr;
    reg [7:0]  operation_wr_data;

    wire [20:0] rx_fifo_wr_data;
    wire [20:0] rx_fifo_rd_data;
    wire        rx_fifo_wr_en;
    wire        rx_fifo_rd_en;
    wire        rx_fifo_full;
    wire        rx_fifo_empty;
    wire        rx_fifo_almost_full;
    wire        rx_fifo_almost_empty;

    wire [7:0]  tx_fifo_wr_data;
    wire [7:0]  tx_fifo_rd_data;
    wire        tx_fifo_wr_en;
    wire        tx_fifo_full;
    wire        tx_fifo_empty;
    wire        tx_fifo_almost_full;
    wire        tx_fifo_almost_empty;

    wire [7:0]  i2c_rd_data;
    wire        i2c_done;
    wire        i2c_error;
    wire        i2c_start;
    wire        i2c_wr_en;
    wire        i2c_rd_en;

    assign rx_fifo_wr_data = {write_addr, write_data};
    assign rx_fifo_wr_en   = write_req && !rx_fifo_full;
    assign write_full     = rx_fifo_full;

    // 读请求只在控制器空闲、写周期等待结束且 TX FIFO 未满时接受。
    assign read_ready = (ctrl_state == CTRL_IDLE) &&
                        (write_wait_cnt == 0) && !tx_fifo_full;
    assign busy = (ctrl_state != CTRL_IDLE) || (write_wait_cnt != 0);

    assign i2c_start = (ctrl_state == CTRL_START);
    assign i2c_wr_en = i2c_start && !operation_read;
    assign i2c_rd_en = i2c_start && operation_read;

    // POP 与 LOAD 分开，给同步 FIFO 留出一个完整时钟使读数据稳定。
    assign rx_fifo_rd_en = (ctrl_state == CTRL_POP);

    assign tx_fifo_wr_data = i2c_rd_data;
    assign tx_fifo_wr_en   = (ctrl_state == CTRL_WAIT) && i2c_done &&
                             operation_read && !i2c_error && !tx_fifo_full;

    assign read_data       = tx_fifo_rd_data;
    assign read_data_empty = tx_fifo_empty;
    assign read_data_full  = tx_fifo_full;

    // 控制器次态：读请求优先于已经排队的写请求，写请求按 FIFO 顺序执行。
    always @(*) begin
        ctrl_state_next = ctrl_state;

        case (ctrl_state)
            CTRL_IDLE: begin
                if (write_wait_cnt != 0) begin
                    ctrl_state_next = CTRL_IDLE;
                end
                else if (read_req && read_ready) begin
                    ctrl_state_next = CTRL_START;
                end
                else if (!rx_fifo_empty) begin
                    ctrl_state_next = CTRL_POP;
                end
            end

            CTRL_POP:  ctrl_state_next = CTRL_LOAD;
            CTRL_LOAD: ctrl_state_next = CTRL_START;
            CTRL_START: ctrl_state_next = CTRL_WAIT;

            CTRL_WAIT: begin
                if (i2c_done)
                    ctrl_state_next = CTRL_IDLE;
            end

            default: ctrl_state_next = CTRL_IDLE;
        endcase
    end

    // 控制器寄存器、FIFO 数据装载和 EEPROM 写周期等待计数。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_state        <= CTRL_IDLE;
            write_wait_cnt    <= {WAIT_WIDTH{1'b0}};
            operation_read    <= 1'b0;
            operation_addr   <= 16'd0;
            operation_wr_data <= 8'd0;
            read_accept       <= 1'b0;
        end
        else begin
            ctrl_state  <= ctrl_state_next;
            read_accept <= 1'b0;

            if (write_wait_cnt != 0)
                write_wait_cnt <= write_wait_cnt - 1'b1;

            // 读请求在进入 I2C START 状态前锁存。
            if ((ctrl_state == CTRL_IDLE) && read_req && read_ready) begin
                operation_read     <= 1'b1;
                operation_addr    <= {3'b000, read_addr};
                operation_wr_data <= 8'd0;
                read_accept        <= 1'b1;
            end

            // RX FIFO 的数据格式为 {13 位地址，8 位写数据}。
            if (ctrl_state == CTRL_LOAD) begin
                operation_read     <= 1'b0;
                operation_addr    <= {3'b000, rx_fifo_rd_data[20:8]};
                operation_wr_data <= rx_fifo_rd_data[7:0];
            end

            // 写事务完成后等待 EEPROM 内部写周期；读事务则把结果压入 TX FIFO。
            if ((ctrl_state == CTRL_WAIT) && i2c_done && !operation_read)
                write_wait_cnt <= WRITE_CYCLE_COUNT;
        end
    end

    eeprom_rx_fifo rx_fifo_inst (
        .clk          (clk),
        .rst          (!rst_n),
        .wr_en        (rx_fifo_wr_en),
        .wr_data      (rx_fifo_wr_data),
        .wr_full      (rx_fifo_full),
        .almost_full  (rx_fifo_almost_full),
        .rd_en        (rx_fifo_rd_en),
        .rd_data      (rx_fifo_rd_data),
        .rd_empty     (rx_fifo_empty),
        .almost_empty (rx_fifo_almost_empty)
    );

    eeprom_tx_fifo tx_fifo_inst (
        .clk          (clk),
        .rst          (!rst_n),
        .wr_en        (tx_fifo_wr_en),
        .wr_data      (tx_fifo_wr_data),
        .wr_full      (tx_fifo_full),
        .almost_full  (tx_fifo_almost_full),
        .rd_en        (read_data_rd_en && !tx_fifo_empty),
        .rd_data      (tx_fifo_rd_data),
        .rd_empty     (tx_fifo_empty),
        .almost_empty (tx_fifo_almost_empty)
    );

    i2c_driver #(
        .DEVICE_ADDR  (DEVICE_ADDR),
        .I2C_CLK_FREQ (I2C_CLK_FREQ),
        .I2C_SCL_FREQ (I2C_SCL_FREQ)
    ) i2c_driver_inst (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr_en        (i2c_wr_en),
        .rd_en        (i2c_rd_en),
        .addr_length  (1'b1),
        .addr         (operation_addr),
        .wr_data      (operation_wr_data),
        .rd_data      (i2c_rd_data),
        .i2c_start    (i2c_start),
        .i2c_done     (i2c_done),
        .i2c_error    (i2c_error),
        .scl          (scl),
        .sda          (sda)
    );

endmodule

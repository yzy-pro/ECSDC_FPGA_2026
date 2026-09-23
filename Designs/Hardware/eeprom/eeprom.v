// EEPROM 读写控制器。
//
// 写请求通过 RX FIFO 缓存，FIFO 数据格式为：
//   wr_data[20:8] = 13 位 EEPROM 地址
//   wr_data[7:0]  = 待写入的一个字节
//
// 读请求使用 read_req/read_addr 接口，I2C 驱动读回的数据进入 TX FIFO，
// 主控通过 read_data_rd_en 从 TX FIFO 取出数据。读请求要求 read_ready 为高时发出。
module eeprom #(
    // EEPROM 的 7 位 I2C 从设备地址。
    parameter integer DEVICE_ADDR = 7'b1010_000,
    // 主控时钟和 I2C SCL 目标频率，传递给底层 i2c_driver。
    parameter integer I2C_CLK_FREQ = 1_000_000,
    parameter integer I2C_SCL_FREQ = 250_000,
    // EEPROM 内部写周期的最大时间，单位为 us。
    parameter integer WRITE_CYCLE_TIME_US = 5_000
) (
    // 系统时钟和低有效异步复位。
    input wire clk,
    input wire rst_n,

    // 写请求接口：写入 13 位存储地址和一个字节数据。
    input wire write_req,
    input wire [12:0] write_addr,
    input wire [7:0] write_data,
    output wire write_full,

    // 读请求接口；read_accept 用一个 clk 周期确认请求已被接收。
    input wire read_req,
    input wire [12:0] read_addr,
    output reg read_ready,
    output reg read_accept,

    // 读数据 FIFO 的用户侧读取接口。
    input wire read_data_rd_en,
    output wire [7:0] read_data,
    output wire read_data_empty,
    output wire read_data_full,

    // busy 表示控制器或 EEPROM 内部写周期正在占用；scl/sda 连接 I2C 总线。
    output reg busy,
    output wire scl,
    inout wire sda
);

    // 将 EEPROM 写周期从 us 换算为 clk 个数，写事务完成后据此屏蔽新的访问。
    localparam integer WRITE_CYCLE_COUNT = (I2C_CLK_FREQ / 1_000_000) * WRITE_CYCLE_TIME_US;
    // 写等待计数器位宽；加 1 保证可以表示 WRITE_CYCLE_COUNT 本身。
    localparam integer WAIT_WIDTH = (WRITE_CYCLE_COUNT < 1) ? 1 : $clog2(WRITE_CYCLE_COUNT + 1);

    // 控制器状态：空闲、弹出写 FIFO、装载事务、启动 I2C、等待完成。
    localparam [2:0] CTRL_IDLE  = 3'd0;
    localparam [2:0] CTRL_POP   = 3'd1;
    localparam [2:0] CTRL_LOAD  = 3'd2;
    localparam [2:0] CTRL_START = 3'd3;
    localparam [2:0] CTRL_WAIT  = 3'd4;

    // 三段式状态机的当前状态和次态。
    reg [2:0] ctrl_state;
    reg [2:0] ctrl_state_next;
    // 写周期倒计时，非零时禁止新的读写事务。
    reg [WAIT_WIDTH-1:0] write_wait_cnt;

    // 当前送给 i2c_driver 的事务参数；由读请求或 RX FIFO 装载。
    reg operation_read;
    reg [15:0] operation_addr;
    reg [7:0] operation_wr_data;

    // 写请求 RX FIFO：缓存 {13 位 EEPROM 地址, 8 位写数据}。
    wire [20:0] rx_fifo_wr_data;
    wire [20:0] rx_fifo_rd_data;
    wire rx_fifo_wr_en;
    reg rx_fifo_rd_en;
    wire rx_fifo_full;
    wire rx_fifo_empty;
    wire rx_fifo_almost_full;
    wire rx_fifo_almost_empty;

    // 读结果 TX FIFO：缓存 i2c_driver 返回的 8 位数据。
    wire [7:0] tx_fifo_wr_data;
    wire [7:0] tx_fifo_rd_data;
    reg tx_fifo_wr_en;
    wire tx_fifo_full;
    wire tx_fifo_empty;
    wire tx_fifo_almost_full;
    wire tx_fifo_almost_empty;

    // i2c_driver 的事务状态和读数据接口。
    wire [7:0] i2c_rd_data;
    wire i2c_done;
    wire i2c_error;
    reg i2c_start;
    reg i2c_wr_en;
    reg i2c_rd_en;

    // 上层写请求直接打包进入 RX FIFO；FIFO 满时不接受该请求。
    assign rx_fifo_wr_data = {write_addr, write_data};
    assign rx_fifo_wr_en = write_req && !rx_fifo_full;
    assign write_full = rx_fifo_full;

    assign tx_fifo_wr_data = i2c_rd_data;

    // 对外透明连接 TX FIFO 的数据、空标志和满标志。
    assign read_data = tx_fifo_rd_data;
    assign read_data_empty = tx_fifo_empty;
    assign read_data_full = tx_fifo_full;


    // 第一段：状态寄存器、事务参数寄存器和 EEPROM 写周期等待计数器。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 复位后控制器空闲，清除未完成事务和读请求确认脉冲。
            ctrl_state <= CTRL_IDLE;
            write_wait_cnt <= {WAIT_WIDTH{1'b0}};
            operation_read <= 1'b0;
            operation_addr <= 16'd0;
            operation_wr_data <= 8'd0;
            read_accept <= 1'b0;
        end
        else begin
            // 每个 clk 更新一次状态；read_accept 默认拉低，只在接收读请求时脉冲。
            ctrl_state <= ctrl_state_next;
            read_accept <= 1'b0;

            // EEPROM 写周期期间倒计时，计数为 0 才允许下一笔访问。
            if (write_wait_cnt != 0) write_wait_cnt <= write_wait_cnt - 1'b1;

            // 读请求在进入 I2C START 状态前锁存。
            // 读请求在进入 I2C START 前锁存，避免执行期间上层输入变化。
            if ((ctrl_state == CTRL_IDLE) && read_req && read_ready) begin
                operation_read <= 1'b1;
                operation_addr <= {3'b000, read_addr};
                operation_wr_data <= 8'd0;
                read_accept <= 1'b1;
            end

            // RX FIFO 的数据格式为 {13 位地址，8 位写数据}。
            // CTRL_LOAD 读取同步 RX FIFO 的输出，并将其转换为 i2c_driver 参数。
            if (ctrl_state == CTRL_LOAD) begin
                operation_read <= 1'b0;
                operation_addr <= {3'b000, rx_fifo_rd_data[20:8]};
                operation_wr_data <= rx_fifo_rd_data[7:0];
            end

            // 写事务完成后等待 EEPROM 内部写周期；读事务则把结果压入 TX FIFO。
            // 写事务完成后等待 EEPROM 内部写周期；读事务不需要此等待。
            if ((ctrl_state == CTRL_WAIT) && i2c_done && !operation_read)
                write_wait_cnt <= WRITE_CYCLE_COUNT;
        end
    end

    // 第二段：次态组合逻辑。读请求优先于已经排队的写请求，写请求按 FIFO 顺序执行。
    always @(*) begin
        ctrl_state_next = ctrl_state;

        case (ctrl_state)
            CTRL_IDLE: begin
                // 读请求具有优先级；没有读请求时再按 RX FIFO 先入先出顺序处理写请求。
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

            // 先弹出 RX FIFO，再在 LOAD 状态锁存其输出，最后启动底层 I2C。
            CTRL_POP: ctrl_state_next = CTRL_LOAD;
            CTRL_LOAD: ctrl_state_next = CTRL_START;
            CTRL_START: ctrl_state_next = CTRL_WAIT;

            CTRL_WAIT: begin
                // I2C 完成后回到空闲；读结果写 TX FIFO 与状态退出在同一周期完成。
                if (i2c_done) ctrl_state_next = CTRL_IDLE;
            end

            default: ctrl_state_next = CTRL_IDLE;
        endcase
    end


    // 第三段：状态输出组合逻辑。
    // 将当前状态译码为 FIFO 和 i2c_driver 的控制脉冲，默认值保证无状态时不产生操作。
    always @(*) begin
        read_ready = (ctrl_state == CTRL_IDLE) && (write_wait_cnt == 0) && !tx_fifo_full;
        busy = (ctrl_state != CTRL_IDLE) || (write_wait_cnt != 0);

        i2c_start = (ctrl_state == CTRL_START);
        i2c_wr_en = i2c_start && !operation_read;
        i2c_rd_en = i2c_start && operation_read;

        // POP 只在 CTRL_POP 有效；下一状态 CTRL_LOAD 负责锁存同步 FIFO 输出。
        rx_fifo_rd_en = (ctrl_state == CTRL_POP);

        // 读事务在 I2C 完成且没有错误时写入 TX FIFO。
        tx_fifo_wr_en = (ctrl_state == CTRL_WAIT) && i2c_done && operation_read && !i2c_error &&
            !tx_fifo_full;
    end

    // RX FIFO：缓存上层连续写请求，避免控制器忙时丢失写数据。
    eeprom_rx_fifo rx_fifo_inst (
        .clk(clk),
        .rst(!rst_n),
        .wr_en(rx_fifo_wr_en),
        .wr_data(rx_fifo_wr_data),
        .wr_full(rx_fifo_full),
        .almost_full(rx_fifo_almost_full),
        .rd_en(rx_fifo_rd_en),
        .rd_data(rx_fifo_rd_data),
        .rd_empty(rx_fifo_empty),
        .almost_empty(rx_fifo_almost_empty)
    );

    // TX FIFO：缓存 I2C 读回数据，供上层稍后通过 read_data_rd_en 取走。
    eeprom_tx_fifo tx_fifo_inst (
        .clk(clk),
        .rst(!rst_n),
        .wr_en(tx_fifo_wr_en),
        .wr_data(tx_fifo_wr_data),
        .wr_full(tx_fifo_full),
        .almost_full(tx_fifo_almost_full),
        .rd_en(read_data_rd_en && !tx_fifo_empty),
        .rd_data(tx_fifo_rd_data),
        .rd_empty(tx_fifo_empty),
        .almost_empty(tx_fifo_almost_empty)
    );

    // 通用 I2C 主机：本控制器固定使用 16 位 EEPROM 地址模式。
    // 写事务格式为 START + 器件写地址 + 地址 + 数据 + STOP；
    // 读事务由驱动自动完成写地址、RESTART、读地址和单字节 NACK。
    i2c_driver #(
        .DEVICE_ADDR(DEVICE_ADDR),
        .I2C_CLK_FREQ(I2C_CLK_FREQ),
        .I2C_SCL_FREQ(I2C_SCL_FREQ)
    ) i2c_driver_inst (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(i2c_wr_en),
        .rd_en(i2c_rd_en),
        .addr_length(1'b1),
        .addr(operation_addr),
        .wr_data(operation_wr_data),
        .rd_data(i2c_rd_data),
        .i2c_start(i2c_start),
        .i2c_done(i2c_done),
        .i2c_error(i2c_error),
        .scl(scl),
        .sda(sda)
    );

endmodule

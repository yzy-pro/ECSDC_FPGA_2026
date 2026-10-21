// =============================================================================
// 模块名称：iic_dir
// 功能：FPGA 作为 I2C 主机，访问带“内部寄存器地址”的 I2C 从机。
//
// I2C 入门：
// 1. SCL 是时钟线，SDA 是双向数据线；空闲时二者都由外部上拉电阻拉高。
// 2. SCL 为高时，SDA 从高变低是 START，从低变高是 STOP。
// 3. 每个字节都先传最高位（bit7），传完 8 位后还有第 9 个 ACK/NACK 时钟。
// 4. SDA 是开漏线：FPGA 只能“拉低”或“释放”，不能主动输出高电平。
//
// 本模块的事务顺序：
// 写：START -> 从机地址+W -> 寄存器地址 -> 数据 -> STOP
// 读：START -> 从机地址+W -> 寄存器地址 -> RESTART -> 从机地址+R
//     -> 从机数据 -> 主机 ACK/NACK -> STOP
//
// 接口约定：
// - device_id[7:1] 是 7 位从机地址，device_id[0] 会被本模块的读写位替换。
// - w_r=1 表示写，w_r=0 表示读。
// - sda_out 固定为 0；sda_out_en=1 表示拉低 SDA，=0 表示释放 SDA。
//   顶层通常写成：assign i2c_sda = sda_out_en ? sda_out : 1'bz;
// - 多字节写时，上层可在 byte_over 脉冲后更新 data_in。
// - 多字节读时，data_out 和 byte_over 在同一拍更新。
// =============================================================================

module iic_dir #(
    parameter integer MAIN_CLOCK      = 50_000_000, // FPGA 系统时钟频率，单位 Hz
    parameter integer IIC_CLOCK       = 400_000,    // 目标 I2C SCL 频率，单位 Hz
    parameter integer TIME_WAIT_WIRTE = 5,          // 写后等待时间，单位 ms；保留原拼写以兼容上层
    parameter integer ADDR_BYTE       = 1,          // 内部寄存器地址字节数：支持 1 或 2
    parameter integer ADDR_LSB_FIRST  = 0,          // 1：16 位寄存器地址低字节先发；兼容 MS7200/MS7210 原驱动
    parameter integer LEN_WIDTH       = 4,          // byte_len 的位宽
    parameter integer DATA_WIDTH      = 8           // 保留兼容；I2C 每次仍传输 8 位
)(
    input                         clk,
    input                         rstn,
    input                         pluse,      // 启动脉冲；保留原拼写以兼容上层
    input       [7:0]             device_id,
    input                         w_r,        // 1：写，0：读
    input       [LEN_WIDTH-1:0]   byte_len,
    input       [ADDR_BYTE*8-1:0] addr,
    input       [7:0]             data_in,

    output reg                    busy,
    output reg                    byte_over,
    output reg  [7:0]             data_out,

    output                        scl,
    input                         sda_in,
    output reg                    sda_out,
    output reg                    sda_out_en
);

    // -------------------------------------------------------------------------
    // 功能块 1：SCL 分频和一个位周期中的关键时间点
    // 默认 50 MHz / 400 kHz = 125 个系统时钟构成一个 SCL 周期。
    // sample_tick 位于 SCL 高电平中间，full_tick 是一个位周期的结尾。
    // -------------------------------------------------------------------------
    localparam integer CLK_DIV = MAIN_CLOCK / IIC_CLOCK;
    localparam integer QUARTER_COUNT = CLK_DIV / 4;
    localparam integer HALF_COUNT = CLK_DIV / 2;
    localparam integer THREE_QUARTER_COUNT = (CLK_DIV * 3) / 4;
    localparam integer WRITE_DELAY_CYCLES =
        (TIME_WAIT_WIRTE * MAIN_CLOCK) / 1000;
    localparam integer COUNT_WIDTH = LEN_WIDTH + 2;
    localparam integer HEADER_BYTES = ADDR_BYTE + 1;

    reg [31:0] clk_div_cnt;
    wire sample_tick = (clk_div_cnt == THREE_QUARTER_COUNT - 1);
    wire full_tick = (clk_div_cnt == CLK_DIV - 1);

    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            clk_div_cnt <= 32'd0; 
        else if (full_tick)
            clk_div_cnt <= 32'd0;
        else
            clk_div_cnt <= clk_div_cnt + 1'b1;
    end

    // -------------------------------------------------------------------------
    // 功能块 2：检测 pluse 上升沿
    // 两级同步后再检测边沿；忙碌期间的新请求会被忽略。
    // -------------------------------------------------------------------------
    reg pluse_meta;
    reg pluse_sync;
    reg pluse_sync_d;
    wire request_rise = pluse_sync & ~pluse_sync_d;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            pluse_meta   <= 1'b0;
            pluse_sync   <= 1'b0;
            pluse_sync_d <= 1'b0;
        end else begin
            pluse_meta   <= pluse;
            pluse_sync   <= pluse_meta;
            pluse_sync_d <= pluse_sync;
        end
    end

    // -------------------------------------------------------------------------
    // 功能块 3：状态和事务寄存器
    // IDLE 空闲；S_START 开始；SEND 发送；S_ACK 从机应答；
    // RECEIV 接收；R_ACK 主机应答；STOP 停止。
    // -------------------------------------------------------------------------
    localparam [2:0] IDLE    = 3'd0;
    localparam [2:0] S_START = 3'd1;
    localparam [2:0] SEND    = 3'd2;
    localparam [2:0] S_ACK   = 3'd3;
    localparam [2:0] RECEIV  = 3'd4;
    localparam [2:0] R_ACK   = 3'd5;
    localparam [2:0] STOP    = 3'd6;

    reg [2:0] state;
    reg       start_pending;
    reg       repeated_start;
    reg                       direction_write;
    reg [6:0]                 device_addr;
    reg [ADDR_BYTE*8-1:0]     addr_latched;
    reg [LEN_WIDTH-1:0]       byte_len_latched;
    reg [2:0]                 bit_count;
    reg [COUNT_WIDTH-1:0]     bytes_done;
    reg [COUNT_WIDTH-1:0]     total_bytes;
    reg [7:0]                 send_data;
    reg [7:0]                 receive_data;
    reg                       slave_ack;
    reg                       transaction_ok;
    reg                       write_wait_en;
    reg [31:0]                write_wait_cnt;

    // -------------------------------------------------------------------------
    // 功能块 4：产生 SCL
    // 数据/ACK 状态前半周期低、后半周期高。START 与 STOP 使用专门波形。
    // 该接口没有 scl_in/scl_en，因此不支持从机 clock stretching。
    // -------------------------------------------------------------------------
    wire bit_state = (state == SEND)   || (state == S_ACK) ||
                     (state == RECEIV) || (state == R_ACK);

    // 重复 START 前必须先给出 SCL 低电平阶段，再升高 SCL 并拉低 SDA；
    // 否则从 ACK 直接进入普通 START 时，可能先产生一个意外的 STOP。
    assign scl = (state == S_START) ?
                     (repeated_start ?
                         ((clk_div_cnt >= QUARTER_COUNT) &&
                          (clk_div_cnt < THREE_QUARTER_COUNT)) :
                         (clk_div_cnt < HALF_COUNT)) :
                 (state == STOP)    ? (clk_div_cnt >= HALF_COUNT) :
                 bit_state          ? (clk_div_cnt >= HALF_COUNT) :
                                      1'b1;

    // -------------------------------------------------------------------------
    // 功能块 5：SDA 开漏方向控制
    // sda_out 永远为 0。发送 0 时使能输出；发送 1、接收或等从机 ACK 时释放。
    // -------------------------------------------------------------------------
    always @(*) begin
        sda_out    = 1'b0;
        sda_out_en = 1'b0;

        case (state)
            S_START: begin
                if (repeated_start)
                    sda_out_en = (clk_div_cnt >= HALF_COUNT);
                else
                    sda_out_en = (clk_div_cnt >= QUARTER_COUNT);
            end

            SEND: begin
                sda_out_en = ~send_data[7-bit_count];
            end

            S_ACK,
            RECEIV: begin
                sda_out_en = 1'b0;
            end

            R_ACK: begin
                // 还有数据则拉低发 ACK；最后一字节后释放发 NACK。
                sda_out_en = (bytes_done < total_bytes);
            end

            STOP: begin
                // SCL 升高后释放 SDA，形成 STOP 上升沿。
                sda_out_en = (clk_div_cnt < THREE_QUARTER_COUNT);
            end

            default: begin
                sda_out_en = 1'b0;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // 功能块 6：主状态机、移位收发和字节计数
    // 状态只在 full_tick 前进；SDA 数据和 ACK 在 SCL 高电平中间采样。
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state            <= IDLE;
            start_pending    <= 1'b0;
            repeated_start   <= 1'b0;
            direction_write  <= 1'b0;
            device_addr      <= 7'd0;
            addr_latched     <= {ADDR_BYTE*8{1'b0}};
            byte_len_latched <= {LEN_WIDTH{1'b0}};
            bit_count        <= 3'd0;
            bytes_done       <= {COUNT_WIDTH{1'b0}};
            total_bytes      <= {COUNT_WIDTH{1'b0}};
            send_data        <= 8'd0;
            receive_data     <= 8'd0;
            slave_ack        <= 1'b0;
            transaction_ok   <= 1'b0;
            busy             <= 1'b0;
            byte_over        <= 1'b0;
            data_out         <= 8'd0;
            write_wait_en    <= 1'b0;
            write_wait_cnt   <= 32'd0;
        end else begin
            byte_over <= 1'b0;

            // 写后等待只用于写事务；时间换算已经按毫秒修正。
            if (write_wait_en) begin
                if ((WRITE_DELAY_CYCLES <= 1) ||
                    (write_wait_cnt >= WRITE_DELAY_CYCLES - 1)) begin
                    write_wait_en  <= 1'b0;
                    write_wait_cnt <= 32'd0;
                    busy           <= 1'b0;
                end else begin
                    write_wait_cnt <= write_wait_cnt + 1'b1;
                end
            end

            case (state)
                IDLE: begin
                    bit_count    <= 3'd0;
                    receive_data <= 8'd0;

                    // 锁存整笔事务的参数，防止 busy 期间输入变化破坏传输。
                    if (request_rise && !busy) begin
                        direction_write  <= w_r;
                        device_addr      <= device_id[7:1];
                        addr_latched     <= addr;
                        byte_len_latched <= byte_len;
                        send_data        <= {device_id[7:1], 1'b0};
                        bytes_done       <= {COUNT_WIDTH{1'b0}};
                        start_pending    <= 1'b1;
                        repeated_start   <= 1'b0;
                        transaction_ok   <= 1'b1;
                        busy             <= 1'b1;

                        if (w_r)
                            total_bytes <= HEADER_BYTES + byte_len;
                        else
                            total_bytes <= HEADER_BYTES + 1 + byte_len;
                    end

                    if (start_pending && full_tick) begin
                        start_pending <= 1'b0;
                        state         <= S_START;
                    end
                end

                S_START: begin
                    if (full_tick) begin
                        bit_count <= 3'd0;
                        repeated_start <= 1'b0;
                        state     <= SEND;
                    end
                end

                SEND: begin
                    // 数据区字节结束前通知上层准备下一个 data_in。
                    if (sample_tick && (bit_count == 3'd7) &&
                        direction_write && (bytes_done >= HEADER_BYTES))
                        byte_over <= 1'b1;

                    if (full_tick) begin
                        if (bit_count == 3'd7) begin
                            bit_count  <= 3'd0;
                            bytes_done <= bytes_done + 1'b1;
                            slave_ack  <= 1'b0;
                            state      <= S_ACK;
                        end else begin
                            bit_count <= bit_count + 1'b1;
                        end
                    end
                end

                S_ACK: begin
                    if (sample_tick)
                        slave_ack <= ~sda_in; // SDA=0 是 ACK

                    if (full_tick) begin
                        if (!slave_ack) begin
                            // NACK 或设备不存在时停止，不再继续发送。
                            transaction_ok <= 1'b0;
                            state <= STOP;
                        end else if (bytes_done < HEADER_BYTES) begin
                            // 原 06_hdmi_loop 的 MS72xx 驱动采用低字节优先：
                            // 16'h1234 在总线上依次发送 8'h34、8'h12。
                            // 其他器件通常采用高字节优先，因此通过参数选择，
                            // 而不是把某一种顺序硬编码到通用 I2C 主机中。
                            if (ADDR_BYTE == 1)
                                send_data <= addr_latched[7:0];
                            else if (ADDR_LSB_FIRST) begin
                                if (bytes_done == 1)
                                    send_data <= addr_latched[7:0];
                                else
                                    send_data <= addr_latched[15:8];
                            end else begin
                                if (bytes_done == 1)
                                    send_data <= addr_latched[15:8];
                                else
                                    send_data <= addr_latched[7:0];
                            end
                            state <= SEND;
                        end else if (direction_write) begin
                            if (bytes_done < total_bytes) begin
                                send_data <= data_in;
                                state     <= SEND;
                            end else begin
                                state <= STOP;
                            end
                        end else begin
                            // 读：寄存器地址后重复 START，设备读地址 ACK 后开始收数据。
                            if (bytes_done == HEADER_BYTES) begin
                                if (byte_len_latched == 0) begin
                                    state <= STOP;
                                end else begin
                                    send_data <= {device_addr, 1'b1};
                                    repeated_start <= 1'b1;
                                    state     <= S_START;
                                end
                            end else begin
                                receive_data <= 8'd0;
                                bit_count    <= 3'd0;
                                state        <= RECEIV;
                            end
                        end
                    end
                end

                RECEIV: begin
                    // 第 8 位采样时直接组成完整字节，避免 data_out 少最后一位。
                    if (sample_tick) begin
                        receive_data <= {receive_data[6:0], sda_in};
                        if (bit_count == 3'd7) begin
                            data_out  <= {receive_data[6:0], sda_in};
                            byte_over <= 1'b1;
                        end
                    end

                    if (full_tick) begin
                        if (bit_count == 3'd7) begin
                            bit_count    <= 3'd0;
                            bytes_done   <= bytes_done + 1'b1;
                            receive_data <= 8'd0;
                            state        <= R_ACK;
                        end else begin
                            bit_count <= bit_count + 1'b1;
                        end
                    end
                end

                R_ACK: begin
                    if (full_tick) begin
                        if (bytes_done < total_bytes)
                            state <= RECEIV;
                        else
                            state <= STOP;
                    end
                end

                STOP: begin
                    if (full_tick) begin
                        state <= IDLE;
                        if (direction_write && transaction_ok &&
                            (WRITE_DELAY_CYCLES > 0)) begin
                            write_wait_en  <= 1'b1;
                            write_wait_cnt <= 32'd0;
                        end else begin
                            busy <= 1'b0;
                        end
                    end
                end

                default: begin
                    state         <= IDLE;
                    start_pending <= 1'b0;
                    busy          <= 1'b0;
                end
            endcase
        end
    end

endmodule

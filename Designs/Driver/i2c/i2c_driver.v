// 通用 I2C 主机驱动。
//
// 一次事务支持：
//   写：START + 设备地址(W) + 存储地址 + 写数据 + STOP
//   读：START + 设备地址(W) + 存储地址 + RESTART + 设备地址(R)
//       + 读一个字节 + NACK + STOP
//
// clk 为驱动输入时钟。SCL 使用四相节拍：低电平准备数据、高电平采样，
// 因而 I2C_SCL_FREQ 应不高于 I2C_CLK_FREQ / 4。
module i2c_driver #(
    // I2C 从设备地址的 7 位部分，默认 1010xxx 为 EEPROM 地址段。
    parameter integer DEVICE_ADDR = 7'b1010_000,
    // 驱动模块输入时钟频率，单位 Hz。
    parameter integer I2C_CLK_FREQ = 1_000_000,
    // 目标 SCL 时钟频率，单位 Hz；内部按四相节拍生成 SCL。
    parameter integer I2C_SCL_FREQ = 250_000
) (
    // 系统时钟与低有效异步复位。
    input wire clk,
    input wire rst_n,

    // 一次事务的操作请求：wr_en 表示写，rd_en 表示读。
    input wire wr_en,
    input wire rd_en,
    // 存储器地址宽度选择：0 为 8 位地址，1 为 16 位地址。
    input wire addr_length,  // 0：8 位存储地址，1：16 位存储地址
    // EEPROM 存储器地址及待写入的一个字节。
    input wire [15:0] addr,
    input wire [7:0] wr_data,
    // 事务完成后输出从 EEPROM 读回的一个字节。
    output reg [7:0] rd_data,

    // 拉高一个请求周期后启动事务；空闲时才会被接受。
    input wire i2c_start,
    // STOP 时序结束时拉高一个 clk 周期。
    output reg i2c_done,
    // 任意从设备 ACK 阶段收到 NACK 后置位，下一次事务启动时清零。
    output reg i2c_error,

    // SCL 为推挽输出；sda 为开漏双向总线，外部需要上拉电阻。
    output reg scl,
    inout wire sda
);

    // 每个 SCL 周期拆成四个相位：低电平准备、低电平保持、高电平采样、高电平保持。
    // RAW_DIV 是理想分频值，TICK_DIV 保证分频计数至少为 1。
    localparam integer RAW_DIV   = I2C_CLK_FREQ / (I2C_SCL_FREQ * 4);
    // 分频值小于 1 时强制取 1，避免比较表达式产生无效的负值或零分频。
    localparam integer TICK_DIV  = (RAW_DIV < 1) ? 1 : RAW_DIV;
    // 根据分频上限计算计数器位宽，TICK_DIV=1 时至少保留 1 位。
    localparam integer DIV_WIDTH = (TICK_DIV <= 1) ? 1 : $clog2(TICK_DIV);

    // 状态机编码。发送一个字节、等待 ACK、产生 START/STOP 都分别占用独立状态。
    localparam [4:0] ST_IDLE       = 5'd0;
    localparam [4:0] ST_START      = 5'd1;
    localparam [4:0] ST_DEV_W      = 5'd2;
    localparam [4:0] ST_ACK_DEV_W  = 5'd3;
    localparam [4:0] ST_ADDR_H     = 5'd4;
    localparam [4:0] ST_ACK_ADDR_H = 5'd5;
    localparam [4:0] ST_ADDR_L     = 5'd6;
    localparam [4:0] ST_ACK_ADDR_L = 5'd7;
    localparam [4:0] ST_WR_DATA    = 5'd8;
    localparam [4:0] ST_ACK_WR     = 5'd9;
    localparam [4:0] ST_RESTART    = 5'd10;
    localparam [4:0] ST_DEV_R      = 5'd11;
    localparam [4:0] ST_ACK_DEV_R  = 5'd12;
    localparam [4:0] ST_RD_DATA    = 5'd13;
    localparam [4:0] ST_NACK       = 5'd14;
    localparam [4:0] ST_STOP       = 5'd15;

    // 当前状态和组合逻辑计算出的下一状态。
    reg [4:0] state;
    reg [4:0] state_next;
    // 系统时钟分频计数器和四相节拍计数器。
    reg [DIV_WIDTH-1:0] div_cnt;
    reg [1:0] phase;
    // 当前字节已处理的位编号，0 到 7；发送和接收均为 MSB 优先。
    reg [2:0] bit_cnt;

    // 当前事务方向：1 表示纯读事务，0 表示写事务或读地址阶段。
    reg op_read;
    // 锁存后的地址宽度、存储地址和待写数据，在事务执行期间保持不变。
    reg addr_length_reg;
    reg [15:0] addr_reg;
    reg [7:0] wr_data_reg;
    // 接收移位寄存器；读事务完成时复制到 rd_data。
    reg [7:0] rd_data_reg;
    // ACK 阶段采样结果：1 表示没有检测到有效 ACK，即 NACK。
    reg ack_seen;
    // SDA 开漏控制，1 表示主动拉低，0 表示释放总线。
    reg sda_drive_low;

    // tick 表示分频计数到期；active 用于空闲时停止分频计数。
    wire tick = (div_cnt == TICK_DIV - 1);
    wire active = (state != ST_IDLE);
    // ACK 状态需要在 SCL 高电平期间释放 SDA 并采样从设备响应。
    wire ack_state = (state == ST_ACK_DEV_W) || (state == ST_ACK_ADDR_H) ||
        (state == ST_ACK_ADDR_L) || (state == ST_ACK_WR) || (state == ST_ACK_DEV_R);
    wire send_state = (state == ST_DEV_W) || (state == ST_ADDR_H) || (state == ST_ADDR_L) ||
        (state == ST_WR_DATA) || (state == ST_DEV_R);

    // 输出译码使用的当前发送字节：设备地址、存储器地址或写数据。
    reg [7:0] send_byte;

    // 第一段：时序寄存器、节拍计数器和事务数据寄存器。
    // 这里完成复位、输入锁存、四相推进、ACK/读数据采样以及完成脉冲产生。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 异步复位时回到空闲，释放总线并清空事务结果。
            state <= ST_IDLE;
            div_cnt <= {DIV_WIDTH{1'b0}};
            phase <= 2'd0;
            bit_cnt <= 3'd0;
            op_read <= 1'b0;
            addr_length_reg <= 1'b0;
            addr_reg <= 16'd0;
            wr_data_reg <= 8'd0;
            rd_data_reg <= 8'd0;
            rd_data <= 8'd0;
            ack_seen <= 1'b1;
            i2c_done <= 1'b0;
            i2c_error <= 1'b0;
        end
        else begin
            // 状态寄存器只在 clk 上升沿更新，state_next 由第二段组合逻辑产生。
            state <= state_next;
            i2c_done <= 1'b0;

            if (state == ST_IDLE) begin
                // 空闲时不运行分频器；新事务到来时锁存所有输入，避免执行期间变化。
                div_cnt <= {DIV_WIDTH{1'b0}};
                phase <= 2'd0;
                bit_cnt <= 3'd0;

                // 只在空闲状态接受启动请求，并锁存整笔事务的输入。
                if (i2c_start && (wr_en || rd_en)) begin
                    op_read <= rd_en && !wr_en;
                    addr_length_reg <= addr_length;
                    addr_reg <= addr;
                    wr_data_reg <= wr_data;
                    rd_data_reg <= 8'd0;
                    i2c_error <= 1'b0;
                end
            end
            else if (tick) begin
                // 每次 tick 推进一个四相节拍。相位 3 结束后才允许位计数和状态前进。
                div_cnt <= {DIV_WIDTH{1'b0}};
                if (phase == 2'd3) phase <= 2'd0;
                else phase <= phase + 1'b1;

                // 每个发送/接收字节在相位 3 结束时推进一位。
                if (phase == 2'd3) begin
                    if (send_state || (state == ST_RD_DATA)) begin
                        if (bit_cnt == 3'd7) bit_cnt <= 3'd0;
                        else bit_cnt <= bit_cnt + 1'b1;
                    end
                    else begin
                        bit_cnt <= 3'd0;
                    end
                end

                // ACK 在 SCL 高电平的第二个采样点读取，0 表示应答。
                // SCL 高电平的相位 2 采样 ACK：SDA 为 0 是 ACK，其他值均按 NACK 处理。
                if (ack_state && (phase == 2'd2)) begin
                    ack_seen <= (sda !== 1'b0);
                    if (sda !== 1'b0) i2c_error <= 1'b1;
                end

                // EEPROM 在 SCL 高电平期间输出读数据。
                // 读数据同样在 SCL 高电平相位 2 采样，按 MSB 优先写入移位寄存器。
                if ((state == ST_RD_DATA) && (phase == 2'd2)) rd_data_reg[7-bit_cnt] <= sda;

                if ((state == ST_RD_DATA) && (phase == 2'd3) && (bit_cnt == 3'd7))
                    rd_data <= rd_data_reg;

                // STOP 的最后一个相位结束后给出单周期完成脉冲，并保持最终读数据。
                if ((state == ST_STOP) && (phase == 2'd3)) begin
                    i2c_done <= 1'b1;
                    rd_data <= rd_data_reg;
                end
            end
            else if (active) begin
                div_cnt <= div_cnt + 1'b1;
            end
        end
    end

    // 第二段：次态组合逻辑。所有状态只在 tick 且 phase=3 时完成跳转，
    // 因此每个状态都对应一个完整的四相节拍周期。
    always @(*) begin
        state_next = state;

        case (state)
            ST_IDLE: begin
                // 接收到有效启动请求后先产生 START 条件。
                if (i2c_start && (wr_en || rd_en)) state_next = ST_START;
            end

            ST_START: begin
                // START 完成后发送器件地址和写方向位，先定位 EEPROM 存储地址。
                if (tick && (phase == 2'd3)) state_next = ST_DEV_W;
            end

            ST_DEV_W: begin
                // 设备写地址的 8 位发送完毕后进入 ACK 等待。
                if (tick && (phase == 2'd3) && (bit_cnt == 3'd7)) state_next = ST_ACK_DEV_W;
            end

            ST_ACK_DEV_W: begin
                // 器件未应答则直接 STOP；应答后按地址宽度选择高字节或低字节。
                if (tick && (phase == 2'd3)) begin
                    if (ack_seen) state_next = ST_STOP;
                    else if (addr_length_reg) state_next = ST_ADDR_H;
                    else state_next = ST_ADDR_L;
                end
            end

            ST_ADDR_H: begin
                // 16 位存储地址的高 8 位，发送后等待 ACK。
                if (tick && (phase == 2'd3) && (bit_cnt == 3'd7)) state_next = ST_ACK_ADDR_H;
            end

            ST_ACK_ADDR_H: begin
                // 高地址字节未应答则结束，否则继续发送低地址字节。
                if (tick && (phase == 2'd3)) begin
                    if (ack_seen) state_next = ST_STOP;
                    else state_next = ST_ADDR_L;
                end
            end

            ST_ADDR_L: begin
                // 8 位地址模式下该字节就是完整地址；16 位模式下是低地址字节。
                if (tick && (phase == 2'd3) && (bit_cnt == 3'd7)) state_next = ST_ACK_ADDR_L;
            end

            ST_ACK_ADDR_L: begin
                // 地址 ACK 后，写事务发送数据；读事务先发 RESTART 再切换到读地址。
                if (tick && (phase == 2'd3)) begin
                    if (ack_seen) state_next = ST_STOP;
                    else if (op_read) state_next = ST_RESTART;
                    else state_next = ST_WR_DATA;
                end
            end

            ST_WR_DATA: begin
                // 写数据字节发送完成后等待 EEPROM 的数据 ACK。
                if (tick && (phase == 2'd3) && (bit_cnt == 3'd7)) state_next = ST_ACK_WR;
            end

            ST_ACK_WR: begin
                // 写数据 ACK 阶段结束后产生 STOP，事务完成。
                if (tick && (phase == 2'd3)) state_next = ST_STOP;
            end

            ST_RESTART: begin
                // RESTART：SCL 全程保持高电平，先释放 SDA 再重新拉低 SDA。
                // 重复 START 完成后发送同一器件地址，但方向改为读。
                if (tick && (phase == 2'd3)) state_next = ST_DEV_R;
            end

            ST_DEV_R: begin
                // 设备读地址发送完毕后等待从设备 ACK。
                if (tick && (phase == 2'd3) && (bit_cnt == 3'd7)) state_next = ST_ACK_DEV_R;
            end

            ST_ACK_DEV_R: begin
                // 读地址未应答则 STOP，应答后进入 8 位数据接收。
                if (tick && (phase == 2'd3)) begin
                    if (ack_seen) state_next = ST_STOP;
                    else state_next = ST_RD_DATA;
                end
            end

            ST_RD_DATA: begin
                // 接收 8 位数据；全部采样后由主机发送 NACK 表示不再继续读。
                if (tick && (phase == 2'd3) && (bit_cnt == 3'd7)) state_next = ST_NACK;
            end

            ST_NACK: begin
                // NACK 字节结束后释放总线并进入 STOP。
                if (tick && (phase == 2'd3)) state_next = ST_STOP;
            end

            ST_STOP: begin
                // STOP：SCL 已为高电平时释放 SDA，使 SDA 产生低到高的跳变。
                // STOP 条件完成后回到空闲，等待下一笔事务。
                if (tick && (phase == 2'd3)) state_next = ST_IDLE;
            end

            default: state_next = ST_IDLE;
        endcase
    end

    // 第三段：SCL/SDA 输出译码。
    // I2C 的 SDA 采用开漏方式：发送 0 时拉低，发送 1 或接收时释放总线。
    always @(*) begin
        scl = 1'b1;
        sda_drive_low = 1'b0;
        send_byte = 8'hff;

        case (state)
            ST_START: begin
                // START 条件：SCL 保持高电平时 SDA 从高变低。
                scl = 1'b1;
                sda_drive_low = (phase != 2'd0);
            end

            ST_DEV_W: begin
                // 发送器件地址加写方向位（最低位为 0），MSB 先发送。
                send_byte = {DEVICE_ADDR, 1'b0};
                scl = (phase == 2'd1) || (phase == 2'd2);
                if (send_byte[7-bit_cnt] == 1'b0) sda_drive_low = 1'b1;
            end

            ST_ACK_DEV_W, ST_ACK_ADDR_H, ST_ACK_ADDR_L, ST_ACK_WR, ST_DEV_R, ST_ACK_DEV_R,
                ST_RD_DATA, ST_NACK: begin
                // ACK、读数据和 NACK 阶段均释放 SDA，交由从设备或主机产生响应位。
                scl = (phase == 2'd1) || (phase == 2'd2);

                if (state == ST_DEV_R) begin
                    // 重复 START 后发送器件地址加读方向位（最低位为 1）。
                    send_byte = {DEVICE_ADDR, 1'b1};
                    if (send_byte[7-bit_cnt] == 1'b0) sda_drive_low = 1'b1;
                end
                // ACK、读数据和 NACK 阶段均释放 SDA。
            end

            ST_ADDR_H: begin
                // 发送 16 位存储地址的高字节。
                send_byte = addr_reg[15:8];
                scl = (phase == 2'd1) || (phase == 2'd2);
                if (send_byte[7-bit_cnt] == 1'b0) sda_drive_low = 1'b1;
            end

            ST_ADDR_L: begin
                // 发送存储地址低字节；8 位地址模式也使用该分支。
                send_byte = addr_reg[7:0];
                scl = (phase == 2'd1) || (phase == 2'd2);
                if (send_byte[7-bit_cnt] == 1'b0) sda_drive_low = 1'b1;
            end

            ST_WR_DATA: begin
                // 发送待写入 EEPROM 的数据字节。
                send_byte = wr_data_reg;
                scl = (phase == 2'd1) || (phase == 2'd2);
                if (send_byte[7-bit_cnt] == 1'b0) sda_drive_low = 1'b1;
            end

            ST_RESTART: begin
                // 重启条件：SCL 全程保持高，先释放 SDA，再拉低 SDA。
                scl = 1'b1;
                sda_drive_low = (phase >= 2'd2);
            end

            ST_STOP: begin
                // STOP：SCL 保持高电平时释放 SDA。
                scl = (phase != 2'd0);
                sda_drive_low = (phase == 2'd0) || (phase == 2'd1);
            end

            default: begin
                scl = 1'b1;
                sda_drive_low = 1'b0;
            end
        endcase
    end
    // 未拉低时输出高阻态，由外部上拉电阻将 SDA 拉高并允许从设备应答。
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

endmodule

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
    parameter integer DEVICE_ADDR = 7'b1010_000,
    parameter integer I2C_CLK_FREQ = 1_000_000,
    parameter integer I2C_SCL_FREQ = 250_000
) (
    input wire clk,
    input wire rst_n,

    input wire wr_en,
    input wire rd_en,
    input wire addr_length,  // 0：8 位存储地址，1：16 位存储地址
    input wire [15:0] addr,
    input wire [7:0] wr_data,
    output reg [7:0] rd_data,

    input wire i2c_start,
    output reg i2c_done,
    output reg i2c_error,

    output reg scl,
    inout wire sda
);

    localparam integer RAW_DIV   = I2C_CLK_FREQ / (I2C_SCL_FREQ * 4);
    localparam integer TICK_DIV  = (RAW_DIV < 1) ? 1 : RAW_DIV;
    localparam integer DIV_WIDTH = (TICK_DIV <= 1) ? 1 : $clog2(TICK_DIV);

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

    reg [4:0] state;
    reg [4:0] state_next;
    reg [DIV_WIDTH-1:0] div_cnt;
    reg [1:0] phase;
    reg [2:0] bit_cnt;

    reg op_read;
    reg addr_length_reg;
    reg [15:0] addr_reg;
    reg [7:0] wr_data_reg;
    reg [7:0] rd_data_reg;
    reg ack_seen;
    reg sda_drive_low;

    wire tick = (div_cnt == TICK_DIV - 1);
    wire active = (state != ST_IDLE);
    wire ack_state = (state == ST_ACK_DEV_W) || (state == ST_ACK_ADDR_H) ||
        (state == ST_ACK_ADDR_L) || (state == ST_ACK_WR) || (state == ST_ACK_DEV_R);
    wire send_state = (state == ST_DEV_W) || (state == ST_ADDR_H) || (state == ST_ADDR_L) ||
        (state == ST_WR_DATA) || (state == ST_DEV_R);

    reg [7:0] send_byte;

    // 第一段：状态寄存器、节拍计数器及事务数据寄存器。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
            state <= state_next;
            i2c_done <= 1'b0;

            if (state == ST_IDLE) begin
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
                if (ack_state && (phase == 2'd2)) begin
                    ack_seen <= (sda !== 1'b0);
                    if (sda !== 1'b0) i2c_error <= 1'b1;
                end

                // EEPROM 在 SCL 高电平期间输出读数据。
                if ((state == ST_RD_DATA) && (phase == 2'd2)) rd_data_reg[7-bit_cnt] <= sda;

                if ((state == ST_RD_DATA) && (phase == 2'd3) && (bit_cnt == 3'd7))
                    rd_data <= rd_data_reg;

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

    // 第二段：次态组合逻辑。所有状态只在一个完整四相周期结束时跳转。
    always @(*) begin
        state_next = state;

        case (state)
            ST_IDLE: begin
                if (i2c_start && (wr_en || rd_en)) state_next = ST_START;
            end

            ST_START: begin
                if (tick && (phase == 2'd3)) state_next = ST_DEV_W;
            end

            ST_DEV_W: begin
                if (tick && (phase == 2'd3) && (bit_cnt == 3'd7)) state_next = ST_ACK_DEV_W;
            end

            ST_ACK_DEV_W: begin
                if (tick && (phase == 2'd3)) begin
                    if (ack_seen) state_next = ST_STOP;
                    else if (addr_length_reg) state_next = ST_ADDR_H;
                    else state_next = ST_ADDR_L;
                end
            end

            ST_ADDR_H: begin
                if (tick && (phase == 2'd3) && (bit_cnt == 3'd7)) state_next = ST_ACK_ADDR_H;
            end

            ST_ACK_ADDR_H: begin
                if (tick && (phase == 2'd3)) begin
                    if (ack_seen) state_next = ST_STOP;
                    else state_next = ST_ADDR_L;
                end
            end

            ST_ADDR_L: begin
                if (tick && (phase == 2'd3) && (bit_cnt == 3'd7)) state_next = ST_ACK_ADDR_L;
            end

            ST_ACK_ADDR_L: begin
                if (tick && (phase == 2'd3)) begin
                    if (ack_seen) state_next = ST_STOP;
                    else if (op_read) state_next = ST_RESTART;
                    else state_next = ST_WR_DATA;
                end
            end

            ST_WR_DATA: begin
                if (tick && (phase == 2'd3) && (bit_cnt == 3'd7)) state_next = ST_ACK_WR;
            end

            ST_ACK_WR: begin
                if (tick && (phase == 2'd3)) state_next = ST_STOP;
            end

            ST_RESTART: begin
                if (tick && (phase == 2'd3)) state_next = ST_DEV_R;
            end

            ST_DEV_R: begin
                if (tick && (phase == 2'd3) && (bit_cnt == 3'd7)) state_next = ST_ACK_DEV_R;
            end

            ST_ACK_DEV_R: begin
                if (tick && (phase == 2'd3)) begin
                    if (ack_seen) state_next = ST_STOP;
                    else state_next = ST_RD_DATA;
                end
            end

            ST_RD_DATA: begin
                if (tick && (phase == 2'd3) && (bit_cnt == 3'd7)) state_next = ST_NACK;
            end

            ST_NACK: begin
                if (tick && (phase == 2'd3)) state_next = ST_STOP;
            end

            ST_STOP: begin
                if (tick && (phase == 2'd3)) state_next = ST_IDLE;
            end

            default: state_next = ST_IDLE;
        endcase
    end

    // 第三段：SCL 和 SDA 输出译码。SDA 只主动拉低，逻辑 1 时释放总线。
    always @(*) begin
        scl = 1'b1;
        sda_drive_low = 1'b0;
        send_byte = 8'hff;

        case (state)
            ST_DEV_W: begin
                send_byte = {DEVICE_ADDR, 1'b0};
                scl = (phase == 2'd1) || (phase == 2'd2);
                if (send_byte[7-bit_cnt] == 1'b0) sda_drive_low = 1'b1;
            end

            ST_START: begin
                scl = 1'b1;
                sda_drive_low = (phase != 2'd0);
            end

            ST_ACK_DEV_W, ST_ACK_ADDR_H, ST_ACK_ADDR_L, ST_ACK_WR, ST_DEV_R, ST_ACK_DEV_R,
                ST_RD_DATA, ST_NACK: begin
                scl = (phase == 2'd1) || (phase == 2'd2);

                if (state == ST_DEV_R) begin
                    send_byte = {DEVICE_ADDR, 1'b1};
                    if (send_byte[7-bit_cnt] == 1'b0) sda_drive_low = 1'b1;
                end
                // ACK、读数据和 NACK 阶段均释放 SDA。
            end

            ST_ADDR_H: begin
                send_byte = addr_reg[15:8];
                scl = (phase == 2'd1) || (phase == 2'd2);
                if (send_byte[7-bit_cnt] == 1'b0) sda_drive_low = 1'b1;
            end

            ST_ADDR_L: begin
                send_byte = addr_reg[7:0];
                scl = (phase == 2'd1) || (phase == 2'd2);
                if (send_byte[7-bit_cnt] == 1'b0) sda_drive_low = 1'b1;
            end

            ST_WR_DATA: begin
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

    assign sda = sda_drive_low ? 1'b0 : 1'bz;

endmodule

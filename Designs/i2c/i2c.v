module i2c #(
    parameter integer DEVICE_ADDR = 7'b1010_000,
    parameter integer I2C_CLK_FREQ = 20'd1_000_000,
    parameter integer I2C_SCL_FREQ = 18'd250_000
) (
    input wire clk,
    input wire rst_n,

    input wire wr_en,
    input wire rd_en,

    input wire addr_length,
    input wire [15:0] addr,
    input wire [7:0] wr_data,
    output reg [7:0] rd_data,

    input wire i2c_start,
    output reg i2c_done,

    output reg scl,
    inout wire sda
);

    reg [3:0] state;
    parameter integer StateIdle = 4'd0;

    parameter integer StateWrAddrStart = StateIdle + 4'd1;
    parameter integer StateWrDeviceAddr = StateWrAddrStart + 4'd1;
    parameter integer StateAckDeviceAddr = StateWrDeviceAddr + 4'd1;
    parameter integer StateWrStroageAddrH = StateAckDeviceAddr + 4'd1;
    parameter integer StateAckStroageAddrH = StateWrStroageAddrH + 4'd1;
    parameter integer StateWrStroageAddrL = StateAckStroageAddrH + 4'd1;
    parameter integer StateAckStroageAddrL = StateWrStroageAddrL + 4'd1;

    parameter integer StateWrData = StateAckStroageAddrL + 4'd1;
    parameter integer StateAckWrData = StateWrData + 4'd1;

    parameter integer StateRdDataStart = StateAckWrData + 4'd1;
    parameter integer StateWrRdAddr = StateRdDataStart + 4'd1;
    parameter integer StateAckWrRdAddr = StateWrRdAddr + 4'd1;
    parameter integer StateRdData = StateAckWrRdAddr + 4'd1;
    parameter integer StateNAck = StateRdData + 4'd1;

    parameter integer StateStop = StateNAck + 4'd1;

    reg i2c_enable;  // i2c使能信号，锁存i2c_start信号，直到i2c传输完成
    reg [1:0] scl_cnt;  // 将i2c_clk4分频
    reg [2:0] bit_cnt;  // 计数器，计数每个字节的8位数据传输

    reg ack;  // 设备应答信号

    wire sda_in_en;  // sda输入使能信号
    reg sda_reg;  // sda输入寄存器

    reg [7:0] rd_data_reg;  // 读数据寄存器

    assign sda_in_en = ((state == StateRdData) || (state == StateAckDeviceAddr) ||
                     (state == StateAckStroageAddrH) || (state == StateAckStroageAddrL) ||
                     (state == StateAckWrData) || (state == StateAckWrRdAddr)) ? 1'b0 : 1'b1;
    assign sda = sda_in_en ? sda_reg : 1'bz;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i2c_enable <= 1'b0;
        end
        else if (i2c_start) begin
            i2c_enable <= 1'b1;
        end
        else if ((state == StateStop) && (scl_cnt == 3'd3)) begin
            i2c_enable <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_cnt <= 2'd0;
        end
        else if (i2c_enable) begin
            if (scl_cnt == 2'd3) begin
                scl_cnt <= 2'd0;
            end
            else begin
                scl_cnt <= scl_cnt + 2'd1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt <= 3'd0;
        end
        else if ((state == StateIdle) || (state == StateWrAddrStart) || (state == StateRdDataStart)
                 || (state == StateAckDeviceAddr) || (state == StateAckStroageAddrH) ||
                 (state == StateAckStroageAddrL) || (state == StateAckWrData) ||
                 (state == StateAckWrRdAddr) || (state == StateNAck)) begin
            bit_cnt <= 3'd0;
        end
        else if ((scl_cnt == 2'd3)) begin
            if (bit_cnt == 3'd7) begin
                bit_cnt <= 3'd0;
            end
            else begin
                bit_cnt <= bit_cnt + 3'd1;
            end
        end
    end

    // FSM状态切换描述
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= StateIdle;
        end
        else begin
            case (state)
                StateIdle: begin
                    if (i2c_start) begin
                        state <= StateWrAddrStart;
                    end
                end

                StateWrAddrStart: begin
                    if (scl_cnt == 2'd3) begin
                        state <= StateWrDeviceAddr;
                    end
                end

                StateWrDeviceAddr: begin
                    if ((scl_cnt == 2'd3) && (bit_cnt == 3'd7)) begin
                        state <= StateAckDeviceAddr;
                    end
                end

                StateAckDeviceAddr: begin
                    if ((scl_cnt == 2'd3) && (ack == 1'b0)) begin
                        if (addr_length) begin
                            state <= StateWrStroageAddrH;
                        end
                        else begin
                            state <= StateWrStroageAddrL;
                        end
                    end
                end

                StateWrStroageAddrH: begin
                    if ((scl_cnt == 2'd3) && (bit_cnt == 3'd7)) begin
                        state <= StateAckStroageAddrH;
                    end
                end

                StateAckStroageAddrH: begin
                    if ((scl_cnt == 2'd3) && (ack == 1'b0)) begin
                        state <= StateWrStroageAddrL;
                    end
                end

                StateWrStroageAddrL: begin
                    if ((scl_cnt == 2'd3) && (bit_cnt == 3'd7)) begin
                        state <= StateAckStroageAddrL;
                    end
                end

                StateAckStroageAddrL: begin
                    if ((scl_cnt == 2'd3) && (ack == 1'b0)) begin
                        if (wr_en) begin
                            state <= StateWrData;
                        end
                        else if (rd_en) begin
                            state <= StateRdDataStart;
                        end
                    end
                end

                StateWrData: begin
                    if ((scl_cnt == 2'd3) && (bit_cnt == 3'd7)) begin
                        state <= StateAckWrData;
                    end
                end

                StateAckWrData: begin
                    if ((scl_cnt == 2'd3) && (ack == 1'b0)) begin
                        state <= StateStop;
                    end
                end

                StateRdDataStart: begin
                    if ((scl_cnt == 2'd3)) begin
                        state <= StateWrRdAddr;
                    end
                end

                StateWrRdAddr: begin
                    if ((scl_cnt == 2'd3) && (bit_cnt == 3'd7)) begin
                        state <= StateAckWrRdAddr;
                    end
                end

                StateAckWrRdAddr: begin
                    if ((scl_cnt == 2'd3) && (ack == 1'b0)) begin
                        state <= StateRdData;
                    end
                end

                StateRdData: begin
                    if ((scl_cnt == 2'd3) && (bit_cnt == 3'd7)) begin
                        state <= StateNAck;
                    end
                end

                StateNAck: begin
                    if ((scl_cnt == 2'd3)) begin
                        state <= StateStop;
                    end
                end

                StateStop: begin
                    if ((scl_cnt == 2'd3)) begin
                        state <= StateIdle;
                    end
                end

                default: begin
                    state <= StateIdle;
                end
            endcase
        end
    end


    //状态机输出描述
    //ack信号描述
    always @(*) begin
        if ((state == StateAckDeviceAddr) || (state == StateAckStroageAddrH) ||
            (state == StateAckStroageAddrL) || (state == StateAckWrData) ||
            (state == StateAckWrRdAddr)) begin
            if (scl_cnt == 2'd0) begin
                ack <= sda;
            end
        end
        else if ((state == StateIdle) || (state == StateWrAddrStart) || (state == StateRdDataStart)
                 || (state == StateWrDeviceAddr) || (state == StateWrStroageAddrH) ||
                 (state == StateWrStroageAddrL) || (state == StateWrData) ||
                 (state == StateWrRdAddr) || (state == StateRdData) || (state == StateNAck)) begin
            ack <= 1'b1;
        end
        else begin
            ack <= 1'b1;
        end
    end

    //scl信号描述
    always @(*) begin
        if ((state == StateIdle)) begin
            scl <= 1'b1;
        end
        else if ((state == StateWrAddrStart)) begin
            if (scl_cnt == 2'd3) begin
                scl <= 1'b0;
            end
            else begin
                scl <= 1'b1;
            end
        end
        else if ((state == StateWrDeviceAddr) || (state == StateAckDeviceAddr) ||
                 (state == StateWrStroageAddrH) || (state == StateAckStroageAddrH) ||
                 (state == StateWrStroageAddrL) || (state == StateAckStroageAddrL) || (
                 state == StateWrData) || (state == StateAckWrData) || (state == StateWrRdAddr) || (
                 state == StateAckWrRdAddr) || (state == StateRdData) || (state == StateNAck) || (state == StateRdDataStart)) begin
            if ((scl_cnt == 2'd1) || (scl_cnt == 2'd2)) begin
                scl <= 1'b1;
            end
            else begin
                scl <= 1'b0;
            end
        end
        else if ((state == StateStop)) begin
            if ((scl_cnt == 2'd0) && (bit_cnt == 3'd0)) begin
                scl <= 1'b0;
            end
            else begin
                scl <= 1'b1;
            end
        end
        else begin
            scl <= 1'b1;
        end
    end

    //rd_data_reg寄存器描述
    always @(*)begin
        case(state)
            StateIdle:begin
                sda_reg <= 1'b1;
                rd_data_reg <= 8'd0;
            end

            StateWrAddrStart:begin
                if(scl_cnt == 2'd0)begin
                    sda_reg <= 1'b1;
                end
                else begin
                    sda_reg <= 1'b0;
                end
            end

            StateWrDeviceAddr:begin
                if(bit_cnt<=3'd6)begin
                    sda_reg <= DEVICE_ADDR[6-bit_cnt];
                end
                else begin
                    sda_reg <= 1'b0;
                end
            end

            StateWrStroageAddrH:begin
                sda_reg <= addr[15-bit_cnt];
            end

            StateWrStroageAddrL:begin
                sda_reg <= addr[7-bit_cnt];
            end

            StateWrData:begin
                sda_reg <= wr_data[7-bit_cnt];
            end

            StateWrRdAddr:begin
                if(bit_cnt <= 3'd6)begin
                    sda_reg <= DEVICE_ADDR[6-bit_cnt];
                end
                else begin
                    sda_reg <= 1'b1;
                end
            end

            StateRdData:begin
                if(scl_cnt == 2'd2)begin
                    rd_data_reg[7-bit_cnt] <= sda;
                end
            end

            StateStop:begin
                if((scl_cnt <2'd3) && (bit_cnt == 3'd0))begin
                    sda_reg <= 1'b0;
                end
                else begin
                    sda_reg <= 1'b1;
                end
            end

StateAckDeviceAddr,StateAckStroageAddrH,StateAckStroageAddrL,StateAckWrData,StateAckWrRdAddr,StateNAck:begin
                sda_reg <= 1'b1;
            end

            default:begin
                sda_reg <= 1'b1;
            end
        endcase


    end

    //rd_data寄存器描述
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data <= 8'd0;
        end
        else if ((state == StateRdData) && (scl_cnt == 2'd3) && (bit_cnt == 3'd7)) begin
            rd_data <= rd_data_reg;
        end
    end

    //i2c_done寄存器描述
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i2c_done <= 1'b0;
        end
        else if ((state == StateStop) && (scl_cnt == 2'd3)) begin
            i2c_done <= 1'b1;
        end
        else begin
            i2c_done <= 1'b0;
        end
    end

endmodule

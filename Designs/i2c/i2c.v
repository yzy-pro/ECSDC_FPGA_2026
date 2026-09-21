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
    output reg rd_data,

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


    // FSM状态切换描述，待完善
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
                    else begin
                        state <= state;
                    end
                end

                StateWrAddrStart: begin
                    state <= StateWrDeviceAddr;
                end

                default: begin
                    state <= StateIdle;
                end
            endcase
        end
    end

endmodule

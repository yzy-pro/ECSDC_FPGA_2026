`timescale 1ns/1ps
// Streaming parser for the IMU Q2048 attitude protocol.
module imu_protocol_50m (
    input  wire       clk,
    input  wire       rstn,
    input  wire       uart_rx,
    output reg [15:0] yaw,
    output reg [15:0] pitch,
    output reg [15:0] roll,
    output reg        attitude_valid,
    output reg        attitude_toggle
);
    localparam ST_H1=3'd0, ST_H2=3'd1, ST_PAYLOAD=3'd2,
               ST_SUM=3'd3, ST_TAIL=3'd4;
    reg [2:0] state;
    reg [2:0] index;
    reg [7:0] payload [0:5];
    reg [7:0] checksum;
    wire [7:0] rx_data;
    wire rx_valid;
    integer i;

    imu_uart_rx_50m u_rx (.clk(clk), .rstn(rstn), .rx(uart_rx),
                          .data(rx_data), .data_valid(rx_valid));

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= ST_H1; index <= 0; checksum <= 0;
            yaw <= 0; pitch <= 0; roll <= 0;
            attitude_valid <= 1'b0; attitude_toggle <= 1'b0;
            for (i=0; i<6; i=i+1) payload[i] <= 0;
        end else begin
            attitude_valid <= 1'b0;
            if (rx_valid) begin
                case (state)
                    ST_H1: begin
                        if (rx_data == 8'h55) state <= ST_H2;
                    end
                    ST_H2: begin
                        if (rx_data == 8'hAA) begin
                            state <= ST_PAYLOAD; index <= 0; checksum <= 0;
                        end else if (rx_data == 8'h55) state <= ST_H2;
                        else state <= ST_H1;
                    end
                    ST_PAYLOAD: begin
                        payload[index] <= rx_data;
                        checksum <= checksum + rx_data;
                        if (index == 5) state <= ST_SUM;
                        else index <= index + 1'b1;
                    end
                    ST_SUM: begin
                        if (rx_data == checksum) state <= ST_TAIL;
                        else if (rx_data == 8'h55) state <= ST_H2;
                        else state <= ST_H1;
                    end
                    ST_TAIL: begin
                        if (rx_data == 8'h0D) begin
                            yaw <= {payload[1],payload[0]};
                            pitch <= {payload[3],payload[2]};
                            roll <= {payload[5],payload[4]};
                            attitude_valid <= 1'b1;
                            attitude_toggle <= ~attitude_toggle;
                        end
                        if (rx_data == 8'h55) state <= ST_H2;
                        else state <= ST_H1;
                    end
                    default: state <= ST_H1;
                endcase
            end
        end
    end
endmodule

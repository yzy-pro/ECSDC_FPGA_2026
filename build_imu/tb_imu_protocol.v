`timescale 1ns/1ps
module tb_imu_protocol;
reg clk=0; reg rstn=0; reg uart_rx=1;
wire [15:0] yaw,pitch,roll; wire attitude_valid,attitude_toggle;
always #10 clk=~clk;
imu_protocol_50m dut(.clk(clk),.rstn(rstn),.uart_rx(uart_rx),.yaw(yaw),.pitch(pitch),.roll(roll),.attitude_valid(attitude_valid),.attitude_toggle(attitude_toggle));
localparam time BIT_TIME=1085;
task automatic send_byte; input [7:0] value; integer i; begin uart_rx=0; #(BIT_TIME); for(i=0;i<8;i=i+1) begin uart_rx=value[i]; #(BIT_TIME); end uart_rx=1; #(BIT_TIME); end endtask
task automatic send_frame; input [15:0] y; input [15:0] p; input [15:0] r; input bad_checksum; reg [7:0] sum; begin sum=y[7:0]+y[15:8]+p[7:0]+p[15:8]+r[7:0]+r[15:8]; send_byte(8'h55);send_byte(8'hAA);send_byte(y[7:0]);send_byte(y[15:8]);send_byte(p[7:0]);send_byte(p[15:8]);send_byte(r[7:0]);send_byte(r[15:8]);send_byte(bad_checksum?sum+8'h01:sum);send_byte(8'h0D); end endtask
initial begin
 repeat(10) @(posedge clk); rstn=1; repeat(10) @(posedge clk);
 send_frame(16'hFC00,16'h0200,16'hFF00,0); repeat(4) @(posedge clk);
 if(yaw!==16'hFC00 || pitch!==16'h0200 || roll!==16'hFF00 || attitude_toggle!==1'b1) $fatal(1,"valid mismatch y=%h p=%h r=%h t=%b",yaw,pitch,roll,attitude_toggle);
 $display("VALID_FRAME_OK y=%h p=%h r=%h",yaw,pitch,roll);
 send_frame(16'h0100,16'h0200,16'h0300,1); repeat(4) @(posedge clk);
 if(attitude_toggle!==1'b1 || yaw!==16'hFC00 || pitch!==16'h0200 || roll!==16'hFF00) $fatal(1,"bad checksum changed");
 $display("BAD_CHECKSUM_REJECT_OK");
 send_byte(8'h33); send_byte(8'h55);
 send_frame(16'h0100,16'hFE00,16'h0080,0); repeat(4) @(posedge clk);
 if(attitude_toggle!==1'b0 || yaw!==16'h0100 || pitch!==16'hFE00 || roll!==16'h0080) $fatal(1,"resync mismatch y=%h p=%h r=%h t=%b",yaw,pitch,roll,attitude_toggle);
 $display("RESYNC_NEGATIVE_FRAME_OK y=%h p=%h r=%h",yaw,pitch,roll);
 $display("TB_IMU_PROTOCOL_PASS"); $finish;
end
endmodule

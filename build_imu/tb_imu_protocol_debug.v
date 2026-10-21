`timescale 1ns/1ps
module tb_imu_protocol;
reg clk=0; reg rstn=0; reg uart_rx=1;
wire [15:0] yaw,pitch,roll; wire attitude_valid,attitude_toggle;
always #10 clk=~clk;
imu_protocol_50m dut(.clk(clk),.rstn(rstn),.uart_rx(uart_rx),.yaw(yaw),.pitch(pitch),.roll(roll),.attitude_valid(attitude_valid),.attitude_toggle(attitude_toggle));
localparam time BIT_TIME=1085;
task automatic send_byte; input [7:0] value; integer i; begin uart_rx=0; #(BIT_TIME); for(i=0;i<8;i=i+1) begin uart_rx=value[i]; #(BIT_TIME); end uart_rx=1; #(BIT_TIME); end endtask
task automatic send_frame; input [15:0] y; input [15:0] p; input [15:0] r; input bad_checksum; reg [7:0] sum; begin sum=y[7:0]+y[15:8]+p[7:0]+p[15:8]+r[7:0]+r[15:8]; send_byte(8'h55);send_byte(8'hAA);send_byte(y[7:0]);send_byte(y[15:8]);send_byte(p[7:0]);send_byte(p[15:8]);send_byte(r[7:0]);send_byte(r[15:8]);send_byte(bad_checksum?sum+8'h01:sum);send_byte(8'h0D); end endtask
always @(posedge dut.u_rx.data_valid) $display("RX_BYTE %h at %0t state=%0d idx=%0d",dut.u_rx.data,$time,dut.state,dut.index);
always @(posedge attitude_valid) $display("ATT_VALID y=%h p=%h r=%h t=%0t",yaw,pitch,roll,$time);
always @(attitude_toggle) $display("TOGGLE=%b t=%0t",attitude_toggle,$time);
initial begin
 repeat(10) @(posedge clk); rstn=1; repeat(10) @(posedge clk);
 send_frame(16'hFC00,16'h0200,16'hFF00,0);
 $display("AFTER_FRAME t=%0t toggle=%b valid=%b",$time,attitude_toggle,attitude_valid);
 repeat(10) @(posedge clk);
 $finish;
end
endmodule

`timescale 1ns/1ps
module tb_attitude_cdc;
reg src_clk=0, dst_clk=0, src_rstn=0, dst_rstn=0;
reg [15:0] src_yaw=0,src_pitch=0,src_roll=0; reg src_toggle=0;
wire [15:0] dst_yaw,dst_pitch,dst_roll; wire dst_valid;
always #10 src_clk=~src_clk;
always #3.367 dst_clk=~dst_clk;
attitude_cdc dut(.src_clk(src_clk),.src_rstn(src_rstn),.src_yaw(src_yaw),.src_pitch(src_pitch),.src_roll(src_roll),.src_toggle(src_toggle),.dst_clk(dst_clk),.dst_rstn(dst_rstn),.dst_yaw(dst_yaw),.dst_pitch(dst_pitch),.dst_roll(dst_roll),.dst_valid(dst_valid));
initial begin
 #25; src_rstn=1; dst_rstn=1;
 repeat(5) @(posedge src_clk);
 src_yaw=16'hFC00; src_pitch=16'h0200; src_roll=16'hFF00; src_toggle=1;
 @(posedge dst_valid); #1;
 if(dst_yaw!==16'hFC00 || dst_pitch!==16'h0200 || dst_roll!==16'hFF00) $fatal(1,"CDC first snapshot mismatch");
 $display("CDC_FIRST_OK y=%h p=%h r=%h",dst_yaw,dst_pitch,dst_roll);
 repeat(20) @(posedge dst_clk);
 src_yaw=16'h0100; src_pitch=16'hFE00; src_roll=16'h0080; src_toggle=0;
 @(posedge dst_valid); #1;
 if(dst_yaw!==16'h0100 || dst_pitch!==16'hFE00 || dst_roll!==16'h0080) $fatal(1,"CDC second snapshot mismatch");
 $display("CDC_SECOND_OK y=%h p=%h r=%h",dst_yaw,dst_pitch,dst_roll);
 $display("TB_ATTITUDE_CDC_PASS"); $finish;
end
endmodule

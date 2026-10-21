`timescale 1ns/1ps
module tb_imu_protocol;
    reg clk=0,rstn=0,uart_rx=1;
    always #10 clk=~clk;
    wire [15:0] yaw,pitch,roll;
    wire valid,toggle;
    imu_protocol_50m dut(clk,rstn,uart_rx,yaw,pitch,roll,valid,toggle);
    localparam time BIT_TIME=1085;
    task automatic byte_send(input [7:0] value);
        integer i;
        begin
            uart_rx=0;#(BIT_TIME);
            for(i=0;i<8;i=i+1) begin uart_rx=value[i];#(BIT_TIME);end
            uart_rx=1;#(BIT_TIME);
        end
    endtask
    task automatic frame_send(input [15:0] y,p,r,input bit bad);
        reg [7:0] sum;
        begin
            sum=y[7:0]+y[15:8]+p[7:0]+p[15:8]+r[7:0]+r[15:8];
            byte_send(8'h55);byte_send(8'haa);
            byte_send(y[7:0]);byte_send(y[15:8]);
            byte_send(p[7:0]);byte_send(p[15:8]);
            byte_send(r[7:0]);byte_send(r[15:8]);
            byte_send(bad?sum+8'd1:sum);byte_send(8'h0d);
        end
    endtask
    integer packets=0;
    always @(posedge clk) if(valid) packets=packets+1;
    initial begin
        repeat(10) @(negedge clk);rstn=1;repeat(10) @(negedge clk);
        frame_send(16'hfc00,16'h0200,16'hff00,0);repeat(4) @(negedge clk);
        if(yaw!==16'hfc00 || pitch!==16'h0200 || roll!==16'hff00 || toggle!==1 || packets!=1)
            $fatal(1,"valid packet mismatch");
        frame_send(16'h0100,16'h0200,16'h0300,1);repeat(4) @(negedge clk);
        if(toggle!==1 || yaw!==16'hfc00 || packets!=1)$fatal(1,"bad checksum accepted");
        byte_send(8'h33);byte_send(8'h55);
        frame_send(16'h0100,16'hfe00,16'h0080,0);repeat(4) @(negedge clk);
        if(yaw!==16'h0100 || pitch!==16'hfe00 || roll!==16'h0080 || toggle!==0 || packets!=2)
            $fatal(1,"resynchronization mismatch");
        $display("PASS IMU UART: 921600 baud, signed little endian, checksum rejection, repeated header resynchronization");
        $finish;
    end
    initial begin #1000000;$fatal(1,"UART timeout");end
endmodule

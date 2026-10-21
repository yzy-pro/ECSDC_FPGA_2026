`timescale 1ns/1ps
module tb_attitude_cdc;
    reg src_clk=0,dst_clk=0,src_rstn=0,dst_rstn=0;
    always #10 src_clk=~src_clk;
    always #3.367 dst_clk=~dst_clk;
    reg [15:0] sy=0,sp=0,sr=0;
    reg toggle=0;
    wire [15:0] dy,dp,dr;
    wire valid;
    attitude_cdc dut(src_clk,src_rstn,sy,sp,sr,toggle,dst_clk,dst_rstn,dy,dp,dr,valid);
    integer i,received=0;
    always @(posedge dst_clk) if(valid) begin
        if(dy!==sy || dp!==sp || dr!==sr)$fatal(1,"mixed CDC snapshot");
        received=received+1;
    end
    initial begin
        #25;src_rstn=1;dst_rstn=1;
        for(i=0;i<100;i=i+1) begin
            repeat(7+i%17) @(negedge src_clk);
            sy=i*657+13;sp=~sy;sr=i*119-18000;toggle=~toggle;
            @(posedge valid);#1;
            if(dy!==sy || dp!==sp || dr!==sr)$fatal(1,"snapshot missing");
        end
        repeat(10) @(negedge dst_clk);
        if(received!=100)$fatal(1,"duplicate or lost CDC update");
        dst_rstn=0;#1;
        if(valid!==0 || dy!==0 || dp!==0 || dr!==0)$fatal(1,"destination reset failed");
        $display("PASS attitude CDC: 100 asynchronous snapshots, no duplicate/mixed packets, reset");
        $finish;
    end
    initial begin #100000;$fatal(1,"CDC timeout");end
endmodule

`timescale 1ns/1ps
module tb_imu_affine;
    reg clk=0;always #5 clk=~clk;
    reg signed [31:0] x=0,y=0;
    reg signed [15:0] yaw=0,pitch=0,roll=0;
    wire signed [31:0] u,v;
    imu_affine_q14 dut(clk,x,y,yaw,pitch,roll,u,v);
    integer a,b,c,ix,iy,tx,ty,rx,ry,coeff,checks=0;
    reg signed [63:0] product;
    initial begin
        for(a=-3;a<=3;a=a+1) for(b=-3;b<=3;b=b+1) for(c=-3;c<=3;c=c+1)
        for(ix=0;ix<1920;ix=ix+239) for(iy=0;iy<1080;iy=iy+179) begin
            @(negedge clk);yaw=a*200;pitch=b*200;roll=c;
            x=ix*16384+7919;y=iy*16384+3701;
            tx=a*200*128;ty=b*200*128;
            if(tx>32768)tx=32768;if(tx< -32768)tx= -32768;
            if(ty>32768)ty=32768;if(ty< -32768)ty= -32768;
            coeff=c;if(coeff>2)coeff=2;if(coeff< -2)coeff= -2;
            product=(x-15481296);product=product*coeff;rx=product>>>11;
            product=(y-8558941);product=product*coeff;ry=product>>>11;
            repeat(3) @(posedge clk);#1;
            if(u!==x+tx-ry || v!==y+ty+rx)$fatal(1,"affine arithmetic/sign mismatch");
            if(u-x>65536 || u-x< -65536 || v-y>65536 || v-y< -65536)
                $fatal(1,"dynamic cache envelope exceeded");
            checks=checks+1;
        end
        @(negedge clk);yaw=0;pitch=0;roll=0;repeat(3) @(posedge clk);#1;
        if(u!==x || v!==y)$fatal(1,"zero attitude changed baseline");
        $display("PASS IMU affine: %0d signed samples, rotation, translation, saturation, cache envelope, zero identity",checks);
        $finish;
    end
endmodule

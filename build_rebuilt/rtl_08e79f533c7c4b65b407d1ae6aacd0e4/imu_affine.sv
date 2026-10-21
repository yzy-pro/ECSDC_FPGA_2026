`timescale 1ns/1ps
module tb_imu_affine;
    reg clk=0;always #5 clk=~clk;
    reg signed [31:0] x=0,y=0;
    reg signed [15:0] yaw=0,pitch=0,roll=0;
    wire signed [31:0] u,v;
    imu_affine_q14 dut(clk,x,y,yaw,pitch,roll,u,v);
    integer a,b,c,ix,iy,tx,ty,checks=0;
    function signed [15:0] angle_value(input integer index);
        case(index)
            0:angle_value=-32768;1:angle_value=-257;2:angle_value=-256;
            3:angle_value=-255;4:angle_value=-1;5:angle_value=0;
            6:angle_value=1;7:angle_value=255;8:angle_value=256;
            9:angle_value=257;default:angle_value=32767;
        endcase
    endfunction
    initial begin
        for(a=0;a<=10;a=a+1) for(b=0;b<=10;b=b+1) for(c=0;c<=4;c=c+1)
        for(ix=0;ix<1920;ix=ix+239) for(iy=0;iy<1080;iy=iy+179) begin
            @(negedge clk);yaw=angle_value(a);pitch=angle_value(b);
            case(c)
                0:roll=-32768;1:roll=-2048;2:roll=0;3:roll=2048;4:roll=32767;
            endcase
            x=ix*16384+7919;y=iy*16384+3701;
            tx=$signed(yaw)*128;ty=$signed(pitch)*128;
            if(tx>32768)tx=32768;if(tx< -32768)tx= -32768;
            if(ty>32768)ty=32768;if(ty< -32768)ty= -32768;
            repeat(3) @(posedge clk);#1;
            if(u!==x+tx || v!==y-ty)$fatal(1,"yaw/pitch sampling sign or roll rejection mismatch");
            if(u-x>32768 || u-x< -32768 || v-y>32768 || v-y< -32768)
                $fatal(1,"dynamic cache envelope exceeded");
            checks=checks+1;
        end
        @(negedge clk);yaw=0;pitch=0;roll=-32768;repeat(3) @(posedge clk);#1;
        if(u!==x || v!==y)$fatal(1,"zero attitude changed baseline");
        $display("PASS IMU yaw/pitch: %0d signed samples, yaw up-positive, pitch down-positive, ignored roll, saturation, cache envelope, identity",checks);
        $finish;
    end
endmodule

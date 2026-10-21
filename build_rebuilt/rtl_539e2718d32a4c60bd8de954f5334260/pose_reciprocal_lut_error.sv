`timescale 1ns/1ps
module tb_pose_reciprocal_lut;
    reg signed [23:0] x=0,y=0;
    reg [23:0] z=0;
    reg valid=0,candidate=0;
    wire out_valid,out_candidate;
    wire signed [23:0] u,v;
    integer i,ex,ey,du,dv,max_error=0;
    reg signed [63:0] ex64,ey64;
    reg [31:0] rng=32'h91c3a57d;
    pose_reciprocal_lut dut(x,y,z,valid,candidate,out_valid,out_candidate,u,v);
    initial begin
        for(i=0;i<20000;i=i+1) begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            z=24'd1024+(rng%523264);
            x=$signed(rng[23:0]);
            y=$signed({rng[22:0],rng[31]});
            // Restrict to the valid projection cone, |component| < 2*z.
            if(x>($signed(z)<<<1)) x=($signed(z)<<<1)-1;
            if(x<(-($signed(z)<<<1))) x=-($signed(z)<<<1)+1;
            if(y>($signed(z)<<<1)) y=($signed(z)<<<1)-1;
            if(y<(-($signed(z)<<<1))) y=-($signed(z)<<<1)+1;
            valid=1; candidate=1; #1;
            ex64=$signed(x)*64'sd262144;
            ey64=$signed(y)*64'sd262144;
            ex=ex64/$signed(z);
            ey=ey64/$signed(z);
            du=$signed(u)-ex; if(du<0) du=-du;
            dv=$signed(v)-ey; if(dv<0) dv=-dv;
            if(du>max_error) max_error=du;
            if(dv>max_error) max_error=dv;
            if(!out_valid || !out_candidate || du>32 || dv>32)
                $fatal(1,"reciprocal mismatch i=%0d xyz=(%0d,%0d,%0d) got=(%0d,%0d) expected=(%0d,%0d) err=(%0d,%0d)",i,x,y,z,u,v,ex,ey,du,dv);
        end
        z=24'd1023; #1;
        if(dut.out_candidate!==1'b0) $fatal(1,"depth below epsilon was accepted");
        $display("PASS reciprocal LUT: 20000 randomized rays, max quotient error %0d Q18 LSB",max_error);
        $finish;
    end
endmodule

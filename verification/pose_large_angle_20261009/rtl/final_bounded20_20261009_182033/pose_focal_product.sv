`timescale 1ns/1ps
// The focal multiply was split for timing. Compare its registered result to
// a full signed 64-bit multiply, including values outside the normal camera
// range, to detect carry/sign/truncation errors independently of projection.
module tb_pose_focal_product;
    reg clk=0,rstn=0;
    always #5 clk=~clk;
    reg signed [31:0] drive_x=0,drive_y=0;
    reg signed [31:0] drive_radius=0;
    reg signed [63:0] expected_radius;
    reg signed [23:0] drive_norm_x=0,drive_norm_y=0;
    reg signed [63:0] expected_norm_x2,expected_norm_y2,expected_norm_xy;
    reg signed [63:0] expected_x[0:2],expected_y[0:2];
    integer count=0,checked=0,j;
    reg [31:0] random_state=32'h94a5287b;
    pose_inverse_project_q14 dut (
        .clk(clk),.rstn(rstn),.pose_load(1'b0),
        .pose_yaw_q2048(16'sd0),.pose_pitch_q2048(16'sd0),
        .pose_clamped(),.pose_ready(),.in_valid(1'b0),.dst_x(11'd0),.dst_y(11'd0),
        .out_valid(),.map_valid(),.src_x_q14(),.src_y_q14()
    );
    function automatic signed [63:0] wide_product(input signed [31:0] a,b);
        reg signed [63:0] wide_a;
        begin wide_a=a; wide_product=wide_a*b; end
    endfunction
    always @(posedge clk) if(rstn) begin
        expected_x[2]=expected_x[1]; expected_x[1]=expected_x[0];
        expected_y[2]=expected_y[1]; expected_y[1]=expected_y[0];
        expected_x[0]=wide_product(drive_x,32'sd12262554);
        expected_y[0]=wide_product(drive_y,32'sd12256498);
        expected_radius=wide_product(drive_radius,drive_radius)>>>18;
        expected_norm_x2=wide_product(drive_norm_x,drive_norm_x);
        expected_norm_y2=wide_product(drive_norm_y,drive_norm_y);
        expected_norm_xy=wide_product(drive_norm_x,drive_norm_y);
        count=count+1;
        #1;
        if(dut.l3_r4_q18!==expected_radius[39:0])
            $fatal(1,"bounded20-bit radius square changed a publishable ray");
        if(dut.l1_x2_q36!==expected_norm_x2[47:0] ||
           dut.l1_y2_q36!==expected_norm_y2[47:0] || dut.l1_xy_q36!==expected_norm_xy[47:0])
            $fatal(1,"signed20-bit normalized ray product changed a reachable ray");
        if(count>=3) begin
            if(dut.mapped_x_product!==expected_x[2] || dut.mapped_y_product!==expected_y[2])
                $fatal(1,"focal split multiply changed signed64-bit result");
            checked=checked+1;
        end
    end
    initial begin
        force dut.l5_xdist_q18=drive_x;
        force dut.l5_ydist_q18=drive_y;
        force dut.l2_r2_q18=drive_radius;
        force dut.l0_x_q18=drive_norm_x;
        force dut.l0_y_q18=drive_norm_y;
        repeat(3) @(negedge clk); rstn=1;
        for(j=0;j<2056;j=j+1) begin
            @(negedge clk);
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            drive_radius=(j==0) ? 600000 : ((j==1) ? 599999 : (random_state%600001));
            drive_norm_x=(j==0) ? 524287 : ((j==1) ? -524287 : $signed(random_state[19:0]));
            drive_norm_y=(j==0) ? -524287 : ((j==1) ? 524287 : -$signed(random_state[19:0]));
            case(j)
                0: begin drive_x=32'sh7fffffff; drive_y=32'sh80000000; end
                1: begin drive_x=-1; drive_y=1; end
                2: begin drive_x=32'sh0000ffff; drive_y=32'shffff0000; end
                3: begin drive_x=32'sh00010000; drive_y=32'shffff0001; end
                default: begin drive_x=random_state; drive_y=~random_state; end
            endcase
        end
        repeat(4) @(negedge clk);
        $display("PASS focal product: %0d exact signed64-bit multiplies peraxis, extreme sign/carry and randomized operands; valid-domain20-bit radius square and signed20-bit normalized products exact",checked);
        $finish;
    end
endmodule

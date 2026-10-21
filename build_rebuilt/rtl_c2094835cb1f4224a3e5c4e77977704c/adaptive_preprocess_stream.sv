`timescale 1ns/1ps
module tb_adaptive_preprocess_stream;
    reg clk=0, rstn=0, frame_start=0, in_de=0, enable=0, lut_we=0;
    reg [1:0] mode=0;
    reg [9:0] gain_q8=256;
    reg signed [8:0] offset=0;
    reg [7:0] lut_addr=0, lut_r_data=0, lut_g_data=0, lut_b_data=0;
    reg [7:0] in_r=0,in_g=0,in_b=0;
    wire [7:0] out_r,out_g,out_b; wire out_de;
    wire [31:0] luma_sum,pixel_count; wire stats_valid;
    adaptive_preprocess_stream dut(.*);
    always #5 clk=~clk;
    initial begin
        #12 rstn=1;
        #3 in_de=1; in_r=8'd10; in_g=8'd20; in_b=8'd30;
        #1 if(out_r!==10 || out_g!==20 || out_b!==30 || !out_de) $fatal(1,"bypass failed");
        enable=1; mode=1; gain_q8=10'd512; offset=-9'sd5; #1;
        if(out_r!==15 || out_g!==35 || out_b!==55) $fatal(1,"gain/offset failed");
        @(negedge clk); lut_addr=8'd10; lut_r_data=8'd99; lut_g_data=8'd88; lut_b_data=8'd77; lut_we=1;
        @(negedge clk); lut_we=0; mode=2; #1;
        if(out_r!==99 || out_g!==20 || out_b!==30) $fatal(1,"LUT mode failed");
        // The LUT is channel indexed; write all three entries for this sample.
        lut_addr=8'd20; lut_r_data=8'd91; lut_g_data=8'd81; lut_b_data=8'd71; lut_we=1;
        @(negedge clk); lut_we=0; in_r=20; in_g=20; in_b=20; #1;
        if(out_r!==91 || out_g!==81 || out_b!==71) $fatal(1,"three-channel LUT failed");
        @(negedge clk); frame_start=1; in_de=0;
        @(negedge clk); frame_start=0; in_de=1;
        repeat(3) @(posedge clk);
        if(pixel_count==0 || luma_sum==0) $fatal(1,"statistics did not accumulate");
        $display("PASS adaptive preprocess: bypass, gain/offset, LUT, frame statistics");
        $finish;
    end
endmodule

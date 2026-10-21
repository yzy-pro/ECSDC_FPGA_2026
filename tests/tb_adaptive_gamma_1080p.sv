`timescale 1ns/1ps
// Full-frame worst accumulator value and uninterrupted148.5MHz input.
module tb_adaptive_gamma_1080p;
    localparam PIXELS=1920*1080;
    reg clk=0;always #3.367 clk=~clk;
    reg rstn=0,in_vs=0,in_de=0;
    reg [7:0] in_r=255,in_g=255,in_b=255;
    wire out_vs,out_de,stats_valid;
    wire [7:0] out_r,out_g,out_b;
    wire [2:0] active_curve,target_curve;
    wire [31:0] luma_sum,pixel_count,dark_count,highlight_count;
    adaptive_gamma_stream dut(.clk(clk),.rstn(rstn),.in_vs(in_vs),.in_de(in_de),
        .in_r(in_r),.in_g(in_g),.in_b(in_b),.enable(1'b1),
        .out_vs(out_vs),.out_de(out_de),.out_r(out_r),.out_g(out_g),.out_b(out_b),
        .active_curve(active_curve),.target_curve(target_curve),.stats_valid(stats_valid),
        .luma_sum(luma_sum),.pixel_count(pixel_count),.dark_count(dark_count),.highlight_count(highlight_count));
    reg [1:0] expected_de=0,expected_vs=0;
    integer output_pixels=0,stats=0,x,y;
    always @(posedge clk) if(rstn) begin
        expected_de={expected_de[0],in_de};expected_vs={expected_vs[0],in_vs};
        #1;
        if(out_de!==expected_de[1] || out_vs!==expected_vs[1]) $fatal(1,"1080p cadence lost");
        if(out_de)begin
            if({out_r,out_g,out_b}!==24'hffffff) $fatal(1,"white endpoint altered");
            output_pixels=output_pixels+1;
        end
        if(stats_valid)begin
            if(pixel_count!=PIXELS || luma_sum!=528768000 || highlight_count!=PIXELS || dark_count!=0)
                $fatal(1,"1080p sum/count overflow or missing pixels sum=%0d count=%0d",luma_sum,pixel_count);
            stats=stats+1;
        end
    end
    initial begin
        repeat(4)@(negedge clk);rstn=1;
        // Full2200x1125 frame; VS3cycles overlapsfirstDE deliberately.
        for(y=0;y<1080;y=y+1) begin
            for(x=0;x<1920;x=x+1)begin
                in_vs=y==0&&x<3;in_de=1;@(negedge clk);
            end
            in_de=0;repeat(280)@(negedge clk);
        end
        repeat(45*2200)@(negedge clk);
        in_vs=1;repeat(3)@(negedge clk);in_vs=0;
        repeat(8)@(negedge clk);
        if(output_pixels!=PIXELS || stats!=1) $fatal(1,"1080p incomplete output");
        $display("PASS adaptive gamma1080p: 2073600pixels at148.5MHz, 60Hz raster, no inserted cycles, maximum luma528768000 exact");
        $finish;
    end
    initial begin #20000000;$fatal(1,"timeout");end
endmodule

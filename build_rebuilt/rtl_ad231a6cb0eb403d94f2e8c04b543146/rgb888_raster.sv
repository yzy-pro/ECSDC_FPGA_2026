`timescale 1ns/1ps
module tb_rgb888_raster;
    reg clk=0,rstn=0,de=0;
    reg [15:0] rgb=0;
    wire [7:0] r,g,b;
    wire converted_de,d19,d2;
    always #5 clk=~clk;
    rgb565_to_rgb888 converter(.rgb565_in(rgb),.de_in(de),.r_out(r),.g_out(g),.b_out(b),.de_out(converted_de));
    video_raster_delay a(.clk(clk),.rstn(rstn),.timing_de(de),.display_de(d19));
    video_raster_delay #(.PIPE_DELAY(2)) z(.clk(clk),.rstn(rstn),.timing_de(de),.display_de(d2));
    reg [22:0] history=0;
    integer i;
    always @(posedge clk) begin
        if(!rstn) history=0; else history={history[21:0],de};
        #1;
        if(d19!==history[22] || d2!==history[1]) $fatal(1,"raster latency/reset");
    end
    initial begin
        repeat(2) @(negedge clk); rstn=1;
        for(i=0;i<65536;i=i+1) begin
            rgb=i; de=(i%2200<1920); rstn=(i%7919!=0);
            #1;
            if({r,g,b}!=={rgb[15:11],rgb[15:13],rgb[10:5],rgb[10:9],rgb[4:0],rgb[4:2]} || converted_de!==de)
                $fatal(1,"RGB565 expansion mismatch %h",rgb);
            @(negedge clk);
        end
        $display("PASS RGB888: all 65536 colors, exact DE forwarding, 23/2-cycle raster/reset");
        $finish;
    end
endmodule

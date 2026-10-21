`timescale 1ns/1ps
// Exercise the real input converter and writer across frame boundaries.
module tb_input_frame_alignment;
    reg clk=0, ddr_clk=0;
    always #5 clk=~clk;
    always #7 ddr_clk=~ddr_clk;
    reg rstn=0, vs=1, de=0;
    reg [23:0] rgb=0;
    wire vs_q, active, en;
    wire [15:0] data;
    rgb888_to_rgb565 input_stage(
        .clk(clk), .rstn(rstn), .vs_in(vs), .vs_out(vs_q), .de_in(de),
        .r_in(rgb[23:16]), .g_in(rgb[15:8]), .b_in(rgb[7:0]),
        .active_out(active), .wr_en(en), .wr_data(data));
    wr_buf #(.PIX_WIDTH(16), .H_NUM(1920), .V_NUM(2)) writer(
        .ddr_clk(ddr_clk), .ddr_rstn(rstn), .wr_clk(clk),
        .wr_fsync(~vs_q), .wr_active(active), .wr_en(en), .wr_data(data),
        .display_frame_bank(2'd2), .rd_bac(1'b0), .ddr_wrdy(1'b0),
        .ddr_wdone(1'b0), .ddr_wdata_req(1'b0));
    integer frame=0, words=0, row, x, f;
    function [23:0] pixel(input integer index, frame_id);
        pixel=(index*24'h13579+frame_id*24'h278391) & 24'hffffff;
    endfunction
    function [15:0] packed_pixel(input integer index, frame_id);
        reg [23:0] p;
        begin p=pixel(index,frame_id); packed_pixel={p[23:19],p[15:10],p[7:3]}; end
    endfunction
    always @(posedge clk) begin
        #2;
        if(rstn && vs_q !== vs) $fatal(1,"VS did not align with input data");
        if(rstn && writer.write_en && writer.wr_enable) begin
            if(writer.write_data !== {packed_pixel(2*words+1,frame),packed_pixel(2*words,frame)})
                $fatal(1,"pixel pairing mismatch frame=%0d word=%0d",frame,words);
            words=words+1;
        end
    end
    task blank(input integer cycles);
        begin repeat(cycles) @(negedge clk); end
    endtask
    initial begin
        blank(8); rstn=1; blank(8);
        for(f=0;f<3;f=f+1) begin
            frame=f; words=0; vs=1; de=0; blank(8);
            vs=0; blank(8);
            for(row=0;row<2;row=row+1) begin
                for(x=0;x<1920;x=x+1) begin
                    de=1; rgb=pixel(row*1920+x,frame); @(negedge clk);
                end
                de=0; blank(12);
            end
            if(words!=1920) $fatal(1,"missing/extra packed pixels: %0d",words);
            if(writer.y_cnt!=2) $fatal(1,"incorrect line count: %0d",writer.y_cnt);
            vs=1; blank(8);
        end
        $display("PASS input frame alignment: 3 frames, 1920 pixels/line, RGB565 pairing and VS/DE boundaries");
        $finish;
    end
endmodule

// The input-side test checks packed words before storage. DDR RAM read data
// is unused because DDR requests are deliberately held not-ready.
module wr_fram_buf(input [31:0] wr_data, input [11:0] wr_addr,
    input wr_en,wr_clk,wr_rst, input [8:0] rd_addr,
    output [255:0] rd_data, input rd_clk,rd_rst);
    assign rd_data=0;
endmodule

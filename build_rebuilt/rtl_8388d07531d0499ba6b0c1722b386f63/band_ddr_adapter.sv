`timescale 1ns/1ps
// Real cache -> command adapter -> rd_ctrl, with an AXI-like DDR responder.
module tb_band_ddr_adapter;
    reg clk=0; always #5 clk=~clk;
    reg rstn=0,fsync=0,init_done=0;
    wire request,ready,done,issue,issued,rvalid;
    wire [27:0] address,read_address,araddr;
    wire [31:0] length;
    wire [3:0] read_len,arlen;
    wire [255:0] data;
    wire pref;
    reg arready=0,valid=0;
    reg [255:0] response=0;
    wire arvalid;
    undistort_band_cache cache(.ddr_clk(clk),.ddr_rstn(rstn),.vout_clk(clk),
        .rd_fsync(fsync),.rd_active(1'b0),.init_done(init_done),.completed_frame_bank(2'd1),
        .ddr_rreq(request),.ddr_raddr(address),.ddr_rd_len(length),.ddr_rrdy(ready),
        .ddr_rdone(done),.ddr_rdata(data),.ddr_rdata_en(rvalid),.cache_prefill_ready(pref),
        .src_x(11'd0),.src_y(11'd0));
    wr_cmd_trans #(.MEM_DQ_WIDTH(32)) adapter(.clk(clk),.rstn(rstn),.wr_cmd_en(1'b0),
        .wr_cmd_addr(28'd0),.wr_cmd_len(32'd0),.wr_bac(1'b0),.wr_ctrl_data(256'd0),
        .wr_ready(1'b0),.wr_done(1'b0),.rd_cmd_en(request),.rd_cmd_addr(address),
        .rd_cmd_len(length),.rd_cmd_ready(ready),.rd_cmd_done(done),.read_en(rvalid),
        .rd_en(issue),.rd_addr(read_address),.rd_len(read_len),.rd_done_p(issued));
    rd_ctrl #(.MEM_DQ_WIDTH(32)) channel(.clk(clk),.rst_n(rstn),
        .read_addr(read_address),.read_id(4'd0),.read_len(read_len),.read_en(issue),
        .read_done_p(issued),.read_ready(1'b1),.read_rdata(data),.read_rdata_en(rvalid),
        .axi_araddr(araddr),.axi_arlen(arlen),.axi_arvalid(arvalid),.axi_arready(arready),
        .axi_rdata(response),.axi_rvalid(valid),.axi_rlast(1'b0),.axi_rid(4'd0),.axi_rresp(2'd0));
    function [15:0] tag(input integer row,x); tag=(row*157+x*31+17749)&65535; endfunction
    integer request_count=0,bursts=0,words=0,beat,lane,row,first_word;
    reg pending=0;
    always @(posedge clk) if(rstn && request) begin
        if(pending) $fatal(1,"overlapping segment requests");
        pending=1;request_count=request_count+1;
    end
    always @(posedge clk) if(rstn && done) pending=0;
    initial forever begin
        wait(arvalid);
        // Exercise AR backpressure and both fast/late R returns relative to
        // the adapter's command-issued pulse.
        repeat(1+bursts%7) @(negedge clk);
        arready=1;
        @(posedge clk);
        if(arlen!=15) $fatal(1,"expected one 16-beat AXI burst");
        bursts=bursts+1;row=(araddr&28'h03fffff)/960;
        first_word=((araddr&28'h03fffff)%960)/8;
        if(araddr[23:22]!=1 || first_word>104) $fatal(1,"unsafe DDR address");
        @(negedge clk);arready=0;
        repeat((bursts%2)?0:35) @(negedge clk);
        for(beat=0;beat<16;beat=beat+1) begin
            if(beat==15) begin valid=0;repeat(9) @(negedge clk);end
            for(lane=0;lane<16;lane=lane+1) response[lane*16+:16]=tag(row,(first_word+beat)*16+lane);
            valid=1;@(negedge clk);
        end
        valid=0;
    end
    integer b,y,w,l,addr,x;
    integer capacity[0:7];
    reg [271:0] expected,actual;
    initial begin
        capacity[0]=58;capacity[1]=56;capacity[2]=26;capacity[3]=18;
        capacity[4]=18;capacity[5]=28;capacity[6]=68;capacity[7]=58;
        repeat(4) @(negedge clk);rstn=1;init_done=1;fsync=1;
        repeat(8) @(negedge clk);fsync=0;
        wait(pref);@(negedge clk);
        for(b=0;b<8;b=b+1) begin
            for(y=cache.first_rows[b*11+:11];y<=cache.future_max[b*11+:11];y=y+1) begin
                for(w=0;w<15;w=w+1) begin
                    addr=cache.band_base(b)+((y/2)%(capacity[b]/2))*15+w;
                    if(addr<2048) actual=(y%2)?cache.cache_odd_main[addr]:cache.cache_even_main[addr];
                    else actual=(y%2)?cache.cache_odd_tail[addr-2048]:cache.cache_even_tail[addr-2048];
                    for(l=0;l<17;l=l+1) begin
                        x=b*240+w*16+l;
                        expected[l*16+:16]=tag(y,(x>1919)?1919:x);
                    end
                    if(actual!==expected) $fatal(1,"AXI cache data mismatch");
                    words=words+1;
                end
            end
        end
        if(bursts!=request_count) $fatal(1,"lost/duplicated AXI burst");
        $display("PASS real DDR adapter + rd_ctrl: %0d segments, %0d words, AR/R stalls",bursts,words);
        $finish;
    end
    initial begin #2000000;$fatal(1,"DDR adapter timeout");end
endmodule

`timescale 1ns/1ps
module tb_cache_return;
    reg clk=0; always #5 clk=~clk;
    reg rstn=0,fsync=0,init_done=0,valid=0;
    reg [1:0] completed=2;
    reg [255:0] data=0;
    wire request,done;
    wire [27:0] address;
    wire [31:0] length;
    wire [1:0] display_bank;
    undistort_rd_buf reader(.ddr_clk(clk),.ddr_rstn(rstn),.vout_clk(clk),
        .rd_fsync(fsync),.rd_active(1'b0),.rd_en(1'b0),.init_done(init_done),
        .completed_frame_bank(completed),.display_frame_bank(display_bank),
        .ddr_rreq(request),.ddr_raddr(address),.ddr_rd_len(length),
        .ddr_rrdy(1'b1),.ddr_rdone(done),.ddr_rdata(data),.ddr_rdata_en(valid));
    wr_cmd_trans #(.MEM_DQ_WIDTH(32)) counter(.clk(clk),.rstn(rstn),.wr_cmd_en(1'b0),
        .wr_cmd_addr(28'd0),.wr_cmd_len(32'd0),.wr_bac(1'b0),.wr_ctrl_data(256'd0),
        .wr_ready(1'b0),.wr_done(1'b0),.rd_cmd_en(request),.rd_cmd_addr(address),
        .rd_cmd_len(length),.rd_cmd_done(done),.read_en(valid),.rd_done_p(1'b0));
    function [15:0] tag(input integer bank,row,x);
        tag=(bank*17749+row*157+x*31)&65535;
    endfunction
    integer beat,row,bank,first_word,lane;
    initial forever begin
        @(posedge clk);
        if(rstn && request) begin
            bank=address[23:22];row=(address&28'h03fffff)/960;
            first_word=((address&28'h03fffff)%960)/8;
            if(length!=16 || first_word>104) $fatal(1,"request is not a safe row-local 16-beat burst");
            for(beat=0;beat<16;beat=beat+1) begin
                if(beat==15) begin @(negedge clk);valid=0;repeat(7) @(negedge clk);end
                @(negedge clk);valid=1;
                for(lane=0;lane<16;lane=lane+1) data[lane*16+:16]=tag(bank,row,(first_word+beat)*16+lane);
            end
            @(negedge clk);valid=0;
        end
    end
    integer band,line,localrow,word,addr,x,checked=0;
    integer capacity[0:7];
    reg [271:0] actual,expected;
    initial begin
        capacity[0]=58;capacity[1]=56;capacity[2]=26;capacity[3]=18;
        capacity[4]=18;capacity[5]=28;capacity[6]=68;capacity[7]=58;
        repeat(4) @(negedge clk);rstn=1;fsync=1;
        repeat(8) @(negedge clk);fsync=0;init_done=1;
        wait(reader.u_band_cache.beat_count==15 && !valid);
        @(negedge clk);completed=1;fsync=1;
        repeat(5) @(negedge clk);
        if(reader.frame_sel!==2'd2 || !reader.u_band_cache.frame_restart_pending)
            $fatal(1,"frame switched before tail drain");
        fsync=0;
        wait(reader.cache_prefill_ready);#2;
        if(reader.frame_sel!==2'd1) $fatal(1,"bad bank after restart");
        for(band=0;band<8;band=band+1) begin
            for(line=reader.u_band_cache.first_rows[band*11+:11];
                line<=reader.u_band_cache.future_max[band*11+:11];line=line+1) begin
                localrow=(line/2)%(capacity[band]/2);
                for(word=0;word<15;word=word+1) begin
                    addr=reader.u_band_cache.band_base(band)+localrow*15+word;
                    actual=line%2?reader.u_band_cache.cache_odd[addr]:reader.u_band_cache.cache_even[addr];
                    for(lane=0;lane<17;lane=lane+1) begin
                        x=band*240+word*16+lane;
                        expected[lane*16+:16]=tag(1,line,(x>1919)?1919:x);
                    end
                    if(actual!==expected) $fatal(1,"stale/halo word band=%0d row=%0d word=%0d",band,line,word);
                    checked=checked+1;
                end
            end
        end
        $display("PASS eight-band cache: stalled tail, restart drain, %0d words including halos",checked);
        $finish;
    end
    initial begin #2000000;$fatal(1,"prefill timeout");end
endmodule

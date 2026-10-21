`timescale 1ns/1ps
module tb_pose_ddr_arbiter;
    reg clk=0, rstn=0;
    always #5 clk=~clk;
    reg cap_w_valid=0,render_w_valid=0,display_r_valid=0,render_r_valid=0;
    wire cap_w_ready,render_w_ready,display_r_ready,render_r_ready;
    reg [27:0] cap_w_addr=0,render_w_addr=0,display_r_addr=0,render_r_addr=0;
    reg [4095:0] cap_w_data=0;
    reg [255:0] render_w_data=0;
    wire [4095:0] render_w_burst={3840'd0,render_w_data};
    wire [4:0] render_w_len=5'd1;
    reg [4:0] cap_w_len=1;
    reg [4:0] display_r_len=1,render_r_len=1;
    wire cap_w_done,render_w_done,display_r_done,render_r_done;
    wire [255:0] display_r_data,render_r_data;
    wire display_r_data_valid,render_r_data_valid;
    wire [27:0] axi_awaddr,axi_araddr;
    wire [3:0] axi_awid,axi_arid,axi_awlen,axi_arlen;
    wire axi_awvalid,axi_arvalid;
    reg axi_awready=0,axi_arready=0,axi_wready=0,axi_wlast=0;
    wire [255:0] axi_wdata;
    wire [31:0] axi_wstrb;
    reg [255:0] axi_rdata=0;
    reg axi_rvalid=0,axi_rlast=0;
    reg [3:0] axi_rid=0;
    wire protocol_error;
    pose_ddr_arbiter dut(.*);

    function automatic [255:0] payload(input [27:0] address);
        integer lane;
        begin
            for(lane=0;lane<8;lane=lane+1)
                payload[lane*32 +: 32] = {4'ha,address} ^ (32'h1020304*lane);
        end
    endfunction

    bit model_enable=1, strict_check=1;
    bit write_pending=0, read_pending=0;
    integer write_delay=0, read_delay=0, return_beat=0, return_len=0;
    integer write_beat=0,write_len=0;
    reg [27:0] return_addr=0;
    reg [3:0] return_id=0;
    reg [31:0] random_state=32'h67a14ce5;
    reg [27:0] expected_w_addr=0,expected_r_addr=0;
    reg [4095:0] expected_w_data=0;
    integer expected_w_len=0;
    bit expected_w_owner=0,expected_r_owner=0;
    integer expected_r_len=0,expected_r_beat=0;
    integer writes_done=0,reads_done=0,read_beats=0,write_beats=0;
    integer write_accepts=0,read_accepts=0;
    bit aw_stalled=0,ar_stalled=0;
    reg [27:0] held_awaddr,held_araddr;
    reg [3:0] held_awid,held_awlen,held_arid,held_arlen;
    reg [255:0] held_wdata;
    bit expected_cap_done,expected_render_done,expected_display_valid;
    bit expected_render_valid,expected_read_done;
    reg [255:0] expected_return_data;

    // The memory deliberately stalls address and payload independently.
    // Delays up to 31 cycles exceed the legacy timer-based completion window.
    always @(negedge clk) if(model_enable) begin
        random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
        axi_awready=rstn && random_state[0];
        axi_arready=rstn && random_state[3];
        axi_wready=rstn && write_pending && write_delay==0;
        axi_wlast=axi_wready && write_beat==write_len-1;
        axi_rvalid=rstn && read_pending && read_delay==0;
        axi_rlast=axi_rvalid && return_beat==return_len-1;
        axi_rid=return_id;
        axi_rdata=payload(return_addr+return_beat*8);
    end

    always @(posedge clk) begin
        if(!rstn) begin
            write_pending=0;read_pending=0;aw_stalled=0;ar_stalled=0;
        end else if(model_enable && strict_check) begin
            if(aw_stalled && (!axi_awvalid || axi_awaddr!==held_awaddr ||
                axi_awid!==held_awid || axi_awlen!==held_awlen || axi_wdata!==held_wdata))
                $fatal(1,"write request changed while AW stalled");
            if(ar_stalled && (!axi_arvalid || axi_araddr!==held_araddr ||
                axi_arid!==held_arid || axi_arlen!==held_arlen))
                $fatal(1,"read request changed while AR stalled");
            aw_stalled=axi_awvalid && !axi_awready;
            ar_stalled=axi_arvalid && !axi_arready;
            held_awaddr=axi_awaddr;held_awid=axi_awid;held_awlen=axi_awlen;held_wdata=axi_wdata;
            held_araddr=axi_araddr;held_arid=axi_arid;held_arlen=axi_arlen;
            if(cap_w_valid && render_w_valid && cap_w_ready && render_w_ready)
                $fatal(1,"capture priority/one write owner violated");
            if(display_r_valid && render_r_valid && display_r_ready && render_r_ready)
                $fatal(1,"display priority/one read owner violated");
            if(cap_w_valid && cap_w_ready || render_w_valid && render_w_ready) begin
                expected_w_owner=!(cap_w_valid && cap_w_ready);
                expected_w_addr=expected_w_owner ? render_w_addr : cap_w_addr;
                expected_w_data=expected_w_owner ? render_w_data : cap_w_data;
                expected_w_len=expected_w_owner ? 1 : cap_w_len;
                write_accepts++;
            end
            if(display_r_valid && display_r_ready || render_r_valid && render_r_ready) begin
                expected_r_owner=!(display_r_valid && display_r_ready);
                expected_r_addr=expected_r_owner ? render_r_addr : display_r_addr;
                expected_r_len=expected_r_owner ? 1 : display_r_len;
                expected_r_beat=0;
                read_accepts++;
            end
            if(write_pending && write_delay>0) write_delay--;
            if(read_pending && read_delay>0) read_delay--;
            if(axi_awvalid && axi_awready) begin
                if(write_pending) $fatal(1,"multiple writes outstanding");
                if(axi_awaddr!==expected_w_addr || axi_awid!=={3'd0,expected_w_owner} ||
                    axi_awlen!==expected_w_len-1 || axi_wstrb!==32'hffffffff)
                    $fatal(1,"AW request mismatch");
                write_pending=1;write_delay=random_state[12:8];write_beat=0;write_len=axi_awlen+1;
            end
            if(axi_arvalid && axi_arready) begin
                if(read_pending) $fatal(1,"multiple reads outstanding");
                if(axi_araddr!==expected_r_addr || axi_arid!=={3'd0,expected_r_owner} ||
                    axi_arlen!==expected_r_len-1)
                    $fatal(1,"AR request mismatch");
                read_pending=1;return_addr=axi_araddr;return_id=axi_arid;
                return_len=axi_arlen+1;return_beat=0;read_delay=random_state[20:16];
            end
            expected_cap_done=0;expected_render_done=0;
            if(axi_wready) begin
                write_beats++;
                if(!write_pending || axi_wdata!==expected_w_data[write_beat*256 +: 256] ||
                    axi_wlast!==(write_beat==write_len-1))
                    $fatal(1,"write payload was lost or modified");
                if(axi_wlast) begin
                    expected_cap_done=!expected_w_owner;expected_render_done=expected_w_owner;
                    write_pending=0;writes_done++;
                end else begin write_beat++;write_delay=random_state[16:13];end
            end
            expected_display_valid=0;expected_render_valid=0;expected_read_done=0;
            if(axi_rvalid) begin
                if(!read_pending) $fatal(1,"read response without request");
                expected_return_data=payload(expected_r_addr+expected_r_beat*8);
                expected_display_valid=!expected_r_owner;expected_render_valid=expected_r_owner;
                expected_read_done=expected_r_beat==expected_r_len-1;
                if(axi_rdata!==expected_return_data || axi_rlast!==expected_read_done)
                    $fatal(1,"memory model data mismatch");
                expected_r_beat++;read_beats++;
                if(axi_rlast) begin read_pending=0;reads_done++;end
                else begin return_beat++;read_delay=random_state[27:24];end
            end
            #1;
            if(protocol_error) $fatal(1,"unexpected protocol error");
            if(cap_w_done!==expected_cap_done || render_w_done!==expected_render_done)
                $fatal(1,"write done was early or routed to wrong owner");
            if(display_r_data_valid!==expected_display_valid ||
                render_r_data_valid!==expected_render_valid)
                $fatal(1,"read payload was early or routed to wrong owner");
            if(display_r_done!==(expected_display_valid && expected_read_done) ||
                render_r_done!==(expected_render_valid && expected_read_done))
                $fatal(1,"read done was not the actual final beat");
            if(expected_display_valid && display_r_data!==expected_return_data)
                $fatal(1,"display payload mismatch");
            if(expected_render_valid && render_r_data!==expected_return_data)
                $fatal(1,"renderer payload mismatch");
        end
    end

    task automatic send_write(input bit owner,input integer number);
        integer beat;
        begin
            @(negedge clk);
            if(owner) begin render_w_valid=1;render_w_addr=28'h800000+number*8;render_w_data=payload(render_w_addr);end
            else begin
                cap_w_valid=1;cap_w_addr=number*128;cap_w_len=number%16+1;
                for(beat=0;beat<16;beat++) cap_w_data[beat*256 +: 256]=payload(cap_w_addr+beat*8);
            end
            @(posedge clk);
            while(owner ? !render_w_ready : !cap_w_ready) @(posedge clk);
            @(negedge clk);
            if(owner) begin render_w_valid=0;render_w_addr='1;render_w_data='1;end
            else begin cap_w_valid=0;cap_w_addr='1;cap_w_data='1;end
            repeat(number%5) @(negedge clk);
        end
    endtask
    task automatic send_read(input bit owner,input integer number);
        begin
            @(negedge clk);
            if(owner) begin render_r_valid=1;render_r_addr=28'h400000+number*8;end
            else begin display_r_valid=1;display_r_addr=28'h800000+number*128;display_r_len=number%16+1;end
            @(posedge clk);
            while(owner ? !render_r_ready : !display_r_ready) @(posedge clk);
            @(negedge clk);
            if(owner) begin render_r_valid=0;render_r_addr='1;end
            else begin display_r_valid=0;display_r_addr='1;display_r_len=0;end
            repeat(number%3) @(negedge clk);
        end
    endtask
    task automatic reset_manual;
        begin
            @(negedge clk);rstn=0;
            cap_w_valid=0;cap_w_len=1;render_w_valid=0;display_r_valid=0;render_r_valid=0;
            axi_awready=0;axi_wready=0;axi_wlast=0;axi_arready=0;
            axi_rvalid=0;axi_rlast=0;axi_rid=0;
            repeat(3) @(negedge clk);
            rstn=1;
        end
    endtask
    task automatic accept_manual_read(input integer length);
        begin
            @(negedge clk);display_r_valid=1;display_r_len=length;display_r_addr=28'h800000;
            @(negedge clk);display_r_valid=0;axi_arready=1;
            @(negedge clk);axi_arready=0;
        end
    endtask

    integer cw,rw,dr,rr;
    initial begin
        repeat(3) @(negedge clk);rstn=1;
        fork
            for(cw=0;cw<80;cw++) send_write(0,cw);
            for(rw=0;rw<80;rw++) send_write(1,rw);
            for(dr=0;dr<48;dr++) send_read(0,dr);
            for(rr=0;rr<80;rr++) send_read(1,rr);
        join
        wait(writes_done==160 && reads_done==128);
        repeat(3) @(negedge clk);
        if(write_accepts!=160 || read_accepts!=128 || read_beats!=488 || write_beats!=760)
            $fatal(1,"transaction count mismatch");
        model_enable=0;strict_check=0;

        // Missing LAST on a single beat must stop ownership reuse and never
        // publish that malformed payload as a completed display transaction.
        reset_manual();accept_manual_read(1);
        axi_rvalid=1;axi_rlast=0;axi_rid=0;
        @(negedge clk);axi_rvalid=0;
        if(!protocol_error || display_r_done || display_r_data_valid || display_r_ready || render_r_ready)
            $fatal(1,"missing RLAST did not hold faulty channel");

        // Early LAST and wrong owner ID are independently rejected.
        reset_manual();accept_manual_read(16);
        axi_rvalid=1;axi_rlast=1;axi_rid=0;
        @(negedge clk);axi_rvalid=0;
        if(!protocol_error || display_r_done || display_r_data_valid)
            $fatal(1,"early RLAST was accepted");
        reset_manual();accept_manual_read(1);
        axi_rvalid=1;axi_rlast=1;axi_rid=1;
        @(negedge clk);axi_rvalid=0;
        if(!protocol_error || display_r_data_valid || render_r_data_valid)
            $fatal(1,"wrong RID was accepted");

        // A zero-latency response at the AR handshake is still owned.
        reset_manual();
        @(negedge clk);render_r_valid=1;render_r_addr=28'h1234560;
        @(negedge clk);render_r_valid=0;axi_arready=1;
        axi_rvalid=1;axi_rlast=1;axi_rid=1;axi_rdata=payload(28'h1234560);
        @(negedge clk);
        if(protocol_error || !render_r_done || !render_r_data_valid || render_r_data!==axi_rdata)
            $fatal(1,"same-edge AR/return was lost");

        // The payload cannot complete on WLAST alone; WREADY is required.
        reset_manual();
        @(negedge clk);cap_w_valid=1;cap_w_addr=28'h1234560;cap_w_data=payload(28'h1234560);
        @(negedge clk);cap_w_valid=0;axi_awready=1;
        @(negedge clk);axi_awready=0;axi_wlast=1;
        repeat(25) begin
            @(negedge clk);
            if(cap_w_done || cap_w_ready) $fatal(1,"write completed without WREADY");
        end
        axi_wready=1;
        @(negedge clk);
        if(!cap_w_done || protocol_error) $fatal(1,"valid final write not completed");

        reset_manual();
        @(negedge clk);render_w_valid=1;render_w_addr=28'h3456780;render_w_data=payload(28'h3456780);
        @(negedge clk);render_w_valid=0;axi_awready=1;
        @(negedge clk);axi_awready=0;axi_wready=1;axi_wlast=0;
        @(negedge clk);axi_wready=0;
        if(!protocol_error || render_w_done || cap_w_ready || render_w_ready)
            $fatal(1,"missing WLAST did not hold faulty write channel");
        reset_manual();
        @(negedge clk);cap_w_valid=1;cap_w_len=16;cap_w_data=0;
        @(negedge clk);cap_w_valid=0;axi_awready=1;
        @(negedge clk);axi_awready=0;axi_wready=1;axi_wlast=1;
        @(negedge clk);axi_wready=0;
        if(!protocol_error || cap_w_done || cap_w_ready)
            $fatal(1,"early WLAST completed an incomplete capture burst");
        $display("PASS pose_ddr_arbiter: 160 writes/760 beats, 128 reads/488 beats, randomized stalls, priority, ownership, LAST/ID faults");
        $finish;
    end
    initial begin #2000000;$fatal(1,"arbiter test timeout");end
endmodule

`timescale 1ns/1ps

// Reduced complete-frame integration: actual FIFO, projector, renderer and
// arbiter, backed by a variable-latency behavioral DDR controller.
module tb_fram_buf_pose;
    localparam H=32, V=33, PIXELS=H*V, WORDS=PIXELS/16;
    reg ddr_clk=0, vin_clk=0, vout_clk=0, ddr_rstn=0;
    always #5 ddr_clk=~ddr_clk;
    always #7 vin_clk=~vin_clk;
    initial begin #2; forever #11 vout_clk=~vout_clk; end
    reg wr_fsync=0,wr_en=0,rd_fsync=0,rd_en=0;
    reg [15:0] wr_data=0;
    reg signed [15:0] imu_yaw=0,imu_pitch=0;
    wire vout_de,init_done,display_underrun,pose_clamped,protocol_error;
    wire [15:0] vout_data;
    wire [27:0] axi_awaddr,axi_araddr;
    wire [3:0] axi_awid,axi_awlen,axi_arid,axi_arlen;
    wire axi_awvalid,axi_arvalid;
    wire [255:0] axi_wdata;
    wire [31:0] axi_wstrb;
    reg axi_awready=0,axi_wready=0,axi_wlast=0,axi_arready=0;
    reg [255:0] axi_rdata=0;
    reg axi_rvalid=0,axi_rlast=0;
    reg [3:0] axi_rid=0;
    wire [31:0] captured_frames,rendered_frames,displayed_frames,rejected_captures;
    fram_buf_pose #(.H_NUM(H),.V_NUM(V),.FIFO_BITS(5),
        .FX_Q14(16*16384),.FY_Q14(16*16384),.CX_Q14(16*16384),.CY_Q14(8*16384),
        .K1_Q14(0),.K2_Q14(0)) dut (.*);

    reg [255:0] memory [0:2][0:WORDS-1];
    integer cycle=0;
    reg [31:0] rng=32'h19b57e21;
    reg write_pending=0,read_pending=0;
    reg [27:0] write_address,read_address;
    reg [3:0] read_id;
    integer read_beats=0,write_beats=0,write_delay=0,read_delay=0;
    integer capture_writes=0,render_writes=0,display_reads=0;
    integer capture_full_bursts=0,capture_tail_bursts=0;
    integer held_final_cycles=0,source_generation=1,render_generation=1;
    integer expected_render_yaw=0,expected_render_pitch=0;
    integer active_render_yaw=0,active_render_pitch=0;
    integer bank,index,lane;
    reg hold_final_write=1;
    reg pause_display_returns=0;
    reg pause_capture_writes=0;
    reg [255:0] stalled_write_data;
    reg [27:0] stalled_awaddr,stalled_araddr;
    reg aw_stalled=0,ar_stalled=0;

    function automatic [15:0] source_pixel(input integer generation,x,y);
        integer r,g,b;
        begin
            r=(3*x+y+generation*7)&31;
            g=(x+5*y+generation*11)&63;
            b=(x^y^(generation*3))&31;
            source_pixel={r[4:0],g[5:0],b[4:0]};
        end
    endfunction

    // Independent floating camera oracle; no distortion in this fixture.
    // Production arithmetic/coefficients are covered by projector regressions.
    function automatic [15:0] expected_pixel(input integer generation,x,y,yaw,pitch);
        real ya,pi,nx,ny,rx,yz,ry,rz,sx,sy,u,v;
        integer ix,iy;
        begin
            ya=yaw/2048.0; pi=pitch/2048.0;
            nx=(x+1.0-16.0)/16.0; ny=(y+1.0-8.0)/16.0;
            rx=$cos(ya)*nx+$sin(ya); yz=$cos(ya)-$sin(ya)*nx;
            ry=$cos(pi)*ny-$sin(pi)*yz; rz=$sin(pi)*ny+$cos(pi)*yz;
            sx=rx/rz; sy=ry/rz; u=sx*16+15; v=sy*16+7;
            ix=$rtoi(u+0.5); iy=$rtoi(v+0.5);
            if (rz<=0.00390625 || sx>=2 || sx<=-2 || sy>=2 || sy<=-2 ||
                sx*sx+sy*sy>600000.0/262144.0 || u<0 || u>=H-1 || v<0 || v>=V-1)
                expected_pixel=0;
            else expected_pixel=source_pixel(generation,ix,iy);
        end
    endfunction

    always @(negedge ddr_clk) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        axi_awready=ddr_rstn && !write_pending && rng[1:0]!=0;
        axi_arready=ddr_rstn && !read_pending && rng[3:2]!=0;
        axi_wready=0; axi_wlast=0; axi_rvalid=0; axi_rlast=0;
        if (write_pending && !(pause_capture_writes && write_address[23:22]==0)) begin
            if (hold_final_write && write_address[23:22]==1 && write_address[21:3]==WORDS-1) begin
                held_final_cycles=held_final_cycles+1;
                if (rendered_frames!=0 || init_done || dut.pending_valid)
                    $fatal(1,"render published before final DDR write transfer");
                if (held_final_cycles>=120) hold_final_write=0;
            end else if (write_delay!=0) write_delay=write_delay-1;
            else if (rng[5:4]!=0) begin axi_wready=1; axi_wlast=write_beats==1; end
        end
        if (read_pending && !(pause_display_returns && read_id==0)) begin
            if (read_delay!=0) read_delay=read_delay-1;
            else if (rng[7:6]!=0) begin
                axi_rvalid=1; axi_rlast=read_beats==1; axi_rid=read_id;
                axi_rdata=memory[read_address[23:22]][read_address[21:3]];
            end
        end
    end

    always @(posedge ddr_clk) if (ddr_rstn) begin
        cycle=cycle+1;
        if (protocol_error) $fatal(1,"wrapper reported protocol_error");
        if (aw_stalled && (!axi_awvalid || axi_awaddr!==stalled_awaddr || axi_wdata!==stalled_write_data))
            $fatal(1,"write address/payload changed under address backpressure");
        if (ar_stalled && (!axi_arvalid || axi_araddr!==stalled_araddr))
            $fatal(1,"read address changed under backpressure");
        aw_stalled=axi_awvalid && !axi_awready;
        ar_stalled=axi_arvalid && !axi_arready;
        stalled_awaddr=axi_awaddr; stalled_araddr=axi_araddr; stalled_write_data=axi_wdata;

        if (dut.renderer_start) begin
            active_render_yaw=expected_render_yaw;
            active_render_pitch=expected_render_pitch;
        end
        if (dut.renderer_busy && (dut.g_serial.u_renderer.yaw_q!==active_render_yaw ||
                                 dut.g_serial.u_renderer.pitch_q!==active_render_pitch))
            $fatal(1,"renderer pose changed during frame");

        if (axi_awvalid && axi_awready) begin
            if (write_pending || (axi_awaddr[23:22]!=0 && axi_awlen!=0) ||
                axi_awaddr[2:0]!=0 || axi_awaddr[23:22]>2 ||
                axi_awaddr[21:3]+axi_awlen>=WORDS || axi_wstrb!==32'hffffffff)
                $fatal(1,"bad write command");
            write_pending=1; write_address=axi_awaddr; write_beats=axi_awlen+1;
            write_delay=2+rng[11:8];
            if (axi_awaddr[23:22]==0) begin
                if (axi_awlen==15) capture_full_bursts=capture_full_bursts+1;
                else capture_tail_bursts=capture_tail_bursts+1;
            end
            if (axi_awaddr[23:22]==0 && dut.renderer_busy)
                $fatal(1,"capture overwrote renderer-owned source frame");
            if (axi_awaddr[23:22]!=0 && init_done && axi_awaddr[23:22]==dut.display_bank)
                $fatal(1,"renderer overwrote displayed frame");
        end
        if (axi_wready) begin
            if (!write_pending || axi_wlast!=(write_beats==1)) $fatal(1,"unexpected write transfer");
            bank=write_address[23:22]; index=write_address[21:3];
            for (lane=0;lane<16;lane=lane+1) begin
                if (bank==0) begin
                    if (axi_wdata[lane*16+:16]!==source_pixel(source_generation,(index*16+lane)%H,(index*16+lane)/H))
                        $fatal(1,"capture pixel packing/ordering mismatch at word %0d lane %0d",index,lane);
                end else if (axi_wdata[lane*16+:16]!==expected_pixel(render_generation,
                    (index*16+lane)%H,(index*16+lane)/H,active_render_yaw,active_render_pitch))
                    $fatal(1,"render pixel mismatch bank=%0d word=%0d lane=%0d got=%h expected=%h",
                        bank,index,lane,axi_wdata[lane*16+:16],expected_pixel(render_generation,
                        (index*16+lane)%H,(index*16+lane)/H,active_render_yaw,active_render_pitch));
            end
            memory[bank][index]=axi_wdata;
            if (bank==0) capture_writes=capture_writes+1; else render_writes=render_writes+1;
            write_address=write_address+8; write_beats=write_beats-1;
            if (write_beats==0) write_pending=0;
        end
        if (axi_arvalid && axi_arready) begin
            if (read_pending || axi_araddr[2:0]!=0 || axi_araddr[23:22]>2 ||
                axi_araddr[21:3]+axi_arlen>=WORDS)
                $fatal(1,"bad read command");
            read_pending=1; read_address=axi_araddr; read_beats=axi_arlen+1;
            read_id=axi_arid; read_delay=2+rng[15:12];
            if (axi_arid==0) display_reads=display_reads+1;
        end
        if (axi_rvalid) begin
            if (!read_pending) $fatal(1,"unexpected read transfer");
            read_address=read_address+8; read_beats=read_beats-1;
            if (read_beats==0) read_pending=0;
            else read_delay=rng[17:16];
        end
    end

    integer output_generation=0,output_yaw=0,output_pitch=0,output_count=0;
    integer output_frames=0;
    reg checking_output=0;
    always @(posedge vout_clk) begin
        #0.1;
        if (ddr_rstn && vout_de) begin
            if (!checking_output || output_count>=PIXELS) $fatal(1,"unexpected DE/pixel count");
            if (vout_data!==expected_pixel(output_generation,output_count%H,output_count/H,output_yaw,output_pitch))
                $fatal(1,"display pixel order/data mismatch frame=%0d pixel=%0d got=%h expected=%h",
                    output_frames,output_count,vout_data,expected_pixel(output_generation,
                    output_count%H,output_count/H,output_yaw,output_pitch));
            output_count=output_count+1;
        end
    end

    task send_source(input integer generation);
        integer p;
        begin
            @(negedge vin_clk); wr_fsync=1; wr_en=0;
            repeat (3) @(negedge vin_clk);
            wr_fsync=0;
            repeat (10) @(negedge vin_clk);
            for (p=0;p<PIXELS;p=p+1) begin
                wr_en=1; wr_data=source_pixel(generation,p%H,p/H);
                if (p==PIXELS/2) begin imu_yaw=-512; imu_pitch=512; end
                @(negedge vin_clk);
                if (p%H==H-1) begin wr_en=0; repeat (4) @(negedge vin_clk); end
            end
            wr_en=0;
        end
    endtask

    task show_frame(input integer generation,yaw,pitch);
        integer p;
        begin
            output_generation=generation; output_yaw=yaw; output_pitch=pitch;
            output_count=0; checking_output=1;
            @(negedge vout_clk); rd_fsync=1; rd_en=0;
            repeat (3) @(negedge vout_clk);
            rd_fsync=0;
            // Model vertical blanking long enough to refill the reduced frame.
            repeat (220) @(negedge vout_clk);
            for (p=0;p<PIXELS;p=p+1) begin
                rd_en=1;
                @(negedge vout_clk);
                if (p%H==H-1) begin rd_en=0; repeat (8) @(negedge vout_clk); end
            end
            rd_en=0;
            repeat (5) @(negedge vout_clk);
            if (output_count!=PIXELS) $fatal(1,"display DE count mismatch");
            if (display_underrun) $fatal(1,"display unexpectedly starved");
            output_frames=output_frames+1; checking_output=0;
        end
    endtask

    task pulse_display_vs;
        begin
            @(negedge vout_clk); rd_fsync=1;
            repeat (3) @(negedge vout_clk);
            rd_fsync=0;
            repeat (4) @(negedge vout_clk);
        end
    endtask

    task send_short_source(input integer generation);
        integer p;
        begin
            @(negedge vin_clk); wr_fsync=1; wr_en=0;
            repeat (3) @(negedge vin_clk);
            wr_fsync=0;
            repeat (10) @(negedge vin_clk);
            for (p=0;p<39;p=p+1) begin
                wr_en=1; wr_data=source_pixel(generation,p%H,p/H);
                @(negedge vin_clk);
            end
            wr_en=0;
            repeat (4) @(negedge vin_clk);
            wr_fsync=1;
            repeat (3) @(negedge vin_clk);
            wr_fsync=0;
        end
    endtask

    reg outstanding_epoch;
    integer rapid_vs;
    initial begin
        repeat (6) @(negedge ddr_clk);
        ddr_rstn=1;
        repeat (20) @(negedge vin_clk);
        send_source(1);
        wait (dut.renderer_busy);
        fork
            send_source(99); // Must be skipped while slot zero is owned.
            begin
                repeat (50) @(negedge ddr_clk);
                imu_yaw=900; imu_pitch=-400;
            end
        join
        wait (rendered_frames==1);
        if (captured_frames!=1 || capture_writes!=WORDS || render_writes!=WORDS || held_final_cycles<120)
            $fatal(1,"first source/render completion accounting incorrect");
        show_frame(1,0,0);
        if (!init_done || displayed_frames!=1 || dut.display_bank!=1)
            $fatal(1,"first frame did not publish at VS");
        show_frame(1,0,0); // Repeats a completed output while waiting for input.
        if (displayed_frames!=1) $fatal(1,"repeated frame counted as new publication");

        source_generation=2; render_generation=2;
        expected_render_yaw=512; expected_render_pitch=0;
        imu_yaw=512; imu_pitch=0;
        send_source(2);
        wait (dut.renderer_busy);
        repeat (50) @(negedge ddr_clk);
        imu_yaw=-700; imu_pitch=500;
        show_frame(1,0,0); // Read slot one while renderer writes slot two.
        wait (rendered_frames==2);
        show_frame(2,512,0);
        if (displayed_frames!=2 || dut.display_bank!=2 || captured_frames!=2 ||
            capture_writes!=2*WORDS || render_writes!=2*WORDS || rejected_captures!=0)
            $fatal(1,"second frame ownership/completion accounting incorrect");
        show_frame(2,512,0);
        // Hold an old display burst across multiple VS edges. No new request
        // may alias it, and a later complete frame must restart at pixel zero.
        pause_display_returns=1;
        pulse_display_vs;
        wait (read_pending && read_id==0);
        pulse_display_vs;
        outstanding_epoch=dut.display_request;
        for (rapid_vs=0;rapid_vs<4;rapid_vs=rapid_vs+1) begin
            pulse_display_vs;
            if (dut.display_request!==outstanding_epoch || !dut.display_flush)
                $fatal(1,"rapid VS aliased an unacknowledged display request");
        end
        pause_display_returns=0;
        wait (!dut.display_flush);
        repeat (30) @(negedge vout_clk);
        show_frame(2,512,0);
        if (protocol_error || display_reads<8 || output_frames!=6)
            $fatal(1,"integration exercise incomplete");

        // Reject a truncated source and then a complete source whose FIFO
        // overflowed while DDR writes were blocked. Neither may be published.
        source_generation=3;
        send_short_source(3);
        wait (rejected_captures==1);
        if (captured_frames!=2 || rendered_frames!=2 || displayed_frames!=2 || dut.renderer_busy)
            $fatal(1,"short capture poisoned frame publication");
        repeat (30) @(negedge vin_clk);
        source_generation=4;
        pause_capture_writes=1;
        send_source(4);
        if (!dut.capture_failed) $fatal(1,"capture overflow injection did not fill FIFO");
        pause_capture_writes=0;
        wait (rejected_captures==2);
        if (captured_frames!=2 || rendered_frames!=2 || displayed_frames!=2 || dut.renderer_busy)
            $fatal(1,"overflowed capture poisoned frame publication");
        show_frame(2,512,0);
        repeat (30) @(negedge vin_clk);
        source_generation=5; render_generation=5;
        expected_render_yaw=0; expected_render_pitch=0;
        imu_yaw=0; imu_pitch=0;
        send_source(5);
        wait (rendered_frames==3);
        show_frame(5,0,0);
        if (captured_frames!=3 || displayed_frames!=3 || rejected_captures!=2 ||
            dut.display_bank!=1 || protocol_error || output_frames!=8 ||
            capture_full_bursts<12 || capture_tail_bursts<3)
            $fatal(1,"capture did not recover cleanly after short/overflow rejection");
        $display("PASS complete pose wrapper: async capture/display, real projection, DDR stalls/gaps, source ownership, final-write publication, VS bank swap, delayed old burst/rapid VS flush, pose snapshot, short/overflow capture rejection/recovery, %0d checked displayed pixels",output_frames*PIXELS);
        $finish;
    end
    initial begin
        #3000000;
        $fatal(1,"complete pose wrapper timeout: captured=%0d rendered=%0d displayed=%0d state=%0d renderer=%0d",
               captured_frames,rendered_frames,displayed_frames,dut.control_state,dut.g_serial.u_renderer.state);
    end
endmodule

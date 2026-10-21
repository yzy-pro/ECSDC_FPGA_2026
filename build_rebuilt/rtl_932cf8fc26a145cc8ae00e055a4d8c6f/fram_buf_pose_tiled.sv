`timescale 1ns/1ps
// Concurrent capture/render/display with the production FIFOs and arbiter.
// DDR model has independent 24-cycle command latency and payload stalls.
// FULL uses 1080p60 raster timing and measures sustained distinct publications.
module tb_fram_buf_pose_tiled;
    parameter FULL=0,H=320,V=180,FRAMES=12,DDR_LATENCY=24;
    localparam PIXELS=H*V,WORDS=PIXELS/16;
    localparam HT=FULL ? 2200 : H+64,VT=FULL ? 1125 : V+20;
    localparam FX=FULL ? 12262554 : 125*16384;
    localparam FY=FULL ? 12256498 : 125*16384;
    localparam CX=FULL ? 15481296 : 160*16384;
    localparam CY=FULL ? 8558941 : 90*16384;
    reg ddr_clk=0,vin_clk=0,vout_clk=0,ddr_rstn=0;
    always #5 ddr_clk=~ddr_clk;
    always #3.367 vin_clk=~vin_clk;
    initial begin #1;forever #3.367 vout_clk=~vout_clk;end
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
    fram_buf_pose #(.H_NUM(H),.V_NUM(V),.TILED_ENABLE(1),
        .FX_Q14(FX),.FY_Q14(FY),.CX_Q14(CX),.CY_Q14(CY)) dut(.*);
    reg [255:0] memory[0:3][0:WORDS-1];
    reg [15:0] expected[0:PIXELS-1];
    reg seen[0:PIXELS-1];
    integer generation[0:3];
    integer input_generation=0,render_generation=0,pending_generation=0,last_display_generation=0;
    integer cycle=0,write_wait=0,read_wait=0,write_left=0,read_left=0;
    integer capture_beats=0,render_beats=0,checked_pixels=0,display_checked=0;
    reg wp=0,rp=0;
    reg [27:0] wa,ra;
    reg [3:0] rid;
    reg [31:0] rng=32'h563a214e;
    integer bank,index,lane,i,pindex;
    integer first_publication=0,last_publication=0,publications=0;
    integer prev_rendered=0,prev_displayed=0,render_start_cycle=0,max_render_cycles=0;
    integer overlap_cycles=0,capture_fifo_peak=0;
    reg [4:0] rendered_pose_mask=0;
    function automatic [15:0] pixel(input integer gen,x,y);
        pixel={5'((x+3*y+gen*7)&31),6'((5*x+y+gen*11)&63),5'((x^y^(gen*3))&31)};
    endfunction
    // This integration oracle checks frame identity/DDR sampling. Exact
    // geometry and traversal are independently covered by the renderer bench.
    always @(posedge ddr_clk) if(ddr_rstn) begin
        cycle=cycle+1;
        if(dut.cap_rd_count>capture_fifo_peak) capture_fifo_peak=dut.cap_rd_count;
        if(dut.renderer_busy && dut.capture_active) overlap_cycles=overlap_cycles+1;
        if(protocol_error || rejected_captures!=0) $fatal(1,"frame protocol/capture fault");
        if(dut.renderer_start) begin
            render_generation=generation[dut.renderer_source_bank];render_start_cycle=cycle;checked_pixels=0;
            for(i=0;i<PIXELS;i=i+1) begin seen[i]=0;expected[i]='x;end
        end
        if(dut.g_tiled.u_renderer.pv &&
           (dut.g_tiled.u_renderer.ps==4 || dut.g_tiled.u_renderer.ps==5)) begin
            pindex=(dut.g_tiled.u_renderer.oy[dut.g_tiled.u_renderer.pb]+dut.g_tiled.u_renderer.result_y)*H+
                   dut.g_tiled.u_renderer.ox[dut.g_tiled.u_renderer.pb]+dut.g_tiled.u_renderer.result_x;
            expected[pindex]=dut.g_tiled.u_renderer.pm ? pixel(render_generation,
                dut.g_tiled.u_renderer.tap_x,dut.g_tiled.u_renderer.tap_y) : 0;
        end
        if(axi_awvalid&&axi_awready) begin
            if(wp || axi_awaddr[2:0]!=0 || axi_awaddr[21:3]+axi_awlen>=WORDS) $fatal(1,"bad write command");
            bank=axi_awaddr[23:22];
            if(axi_awid==0 && dut.renderer_busy && bank==dut.renderer_source_bank) $fatal(1,"overwrote active source");
            if(axi_awid==1 && dut.display_valid && bank==dut.display_bank) $fatal(1,"overwrote displayed output");
            if((axi_awid==0 && bank!=0 && bank!=3) || (axi_awid==1 && bank!=1 && bank!=2)) $fatal(1,"wrong bank class");
            wa=axi_awaddr;write_left=axi_awlen+1;write_wait=DDR_LATENCY;wp=1;
        end
        if(axi_wready) begin
            if(!wp || axi_wlast!=(write_left==1)) $fatal(1,"bad write LAST");
            bank=wa[23:22];index=wa[21:3];
            for(lane=0;lane<16;lane=lane+1) begin
                pindex=index*16+lane;
                if(bank==0 || bank==3) begin
                    if(axi_wdata[lane*16+:16]!==pixel(generation[bank],pindex%H,pindex/H)) $fatal(1,"capture mixing");
                end else begin
                    if(seen[pindex] || axi_wdata[lane*16+:16]!==expected[pindex])
                        $fatal(1,"render identity/sample mismatch index=%0d gen=%0d got=%h expected=%h",pindex,render_generation,axi_wdata[lane*16+:16],expected[pindex]);
                    seen[pindex]=1;checked_pixels=checked_pixels+1;
                end
            end
            memory[bank][index]=axi_wdata;
            if(bank==0 || bank==3) capture_beats=capture_beats+1;else render_beats=render_beats+1;
            wa=wa+8;write_left=write_left-1;if(write_left==0) wp=0;
        end
        if(axi_arvalid&&axi_arready) begin
            if(rp || axi_araddr[2:0]!=0 || axi_araddr[21:3]+axi_arlen>=WORDS) $fatal(1,"bad read command");
            if(axi_arid==1 && axi_araddr[23:22]!=dut.renderer_source_bank) $fatal(1,"read wrong source");
            if(axi_arid==0 && dut.renderer_busy && axi_araddr[23:22]==dut.render_bank) $fatal(1,"displayed uncommitted output");
            ra=axi_araddr;rid=axi_arid;read_left=axi_arlen+1;read_wait=DDR_LATENCY;rp=1;
        end
        if(axi_rvalid) begin ra=ra+8;read_left=read_left-1;if(read_left==0) rp=0;end
        if(rendered_frames!=prev_rendered) begin
            if(checked_pixels!=PIXELS) $fatal(1,"publication omitted pixels: checked=%0d required=%0d",checked_pixels,PIXELS);
            if(dut.renderer_yaw==0 && dut.renderer_pitch==0) rendered_pose_mask[0]=1;
            if(dut.renderer_yaw==536 && dut.renderer_pitch==536) rendered_pose_mask[1]=1;
            if(dut.renderer_yaw==536 && dut.renderer_pitch==-536) rendered_pose_mask[2]=1;
            if(dut.renderer_yaw==-536 && dut.renderer_pitch==536) rendered_pose_mask[3]=1;
            if(dut.renderer_yaw==-536 && dut.renderer_pitch==-536) rendered_pose_mask[4]=1;
            pending_generation=render_generation;
            if(cycle-render_start_cycle>max_render_cycles) max_render_cycles=cycle-render_start_cycle;
            $display("RENDER frame=%0d gen=%0d clocks=%0d",rendered_frames,render_generation,cycle-render_start_cycle);
            if(FULL && cycle-render_start_cycle>3333333) $fatal(1,"contended render exceeded 30fps");
            prev_rendered=rendered_frames;
        end
        if(displayed_frames!=prev_displayed) begin
            if(pending_generation<=last_display_generation) $fatal(1,"duplicate/stale publication");
            last_display_generation=pending_generation;
            if(publications==0) first_publication=cycle;
            last_publication=cycle;publications=publications+1;prev_displayed=displayed_frames;
            $display("PUBLISH frame=%0d gen=%0d clock=%0d",displayed_frames,pending_generation,cycle);
        end
    end
    always @(negedge ddr_clk) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        axi_awready=ddr_rstn&&!wp&&rng[1:0]!=0;
        axi_arready=ddr_rstn&&!rp&&rng[3:2]!=0;
        axi_wready=0;axi_wlast=0;axi_rvalid=0;axi_rlast=0;
        if(wp) begin
            if(write_wait!=0) write_wait=write_wait-1;
            else if(rng[5:4]!=0) begin axi_wready=1;axi_wlast=write_left==1;end
        end
        if(rp) begin
            if(read_wait!=0) read_wait=read_wait-1;
            else if(rng[7:6]!=0) begin
                axi_rvalid=1;axi_rlast=read_left==1;axi_rid=rid;
                axi_rdata=memory[ra[23:22]][ra[21:3]];
            end
        end
    end
    always @(posedge vin_clk) if(ddr_rstn && dut.capture_active && wr_en && dut.capture_pixels==0)
        generation[dut.capture_bank]=input_generation;
    integer f,y,x;
    initial begin
        generation[0]=0;generation[1]=0;generation[2]=0;generation[3]=0;
        repeat(10) @(negedge vin_clk);ddr_rstn=1;
        for(f=1;f<=FRAMES;f=f+1) begin
            input_generation=f;
            // Full runs alternate zero and all four +/-15 degree combinations.
            case(f%5)
                0:begin imu_yaw=0;imu_pitch=0;end
                1:begin imu_yaw=536;imu_pitch=536;end
                2:begin imu_yaw=536;imu_pitch=-536;end
                3:begin imu_yaw=-536;imu_pitch=536;end
                4:begin imu_yaw=-536;imu_pitch=-536;end
            endcase
            wr_fsync=1;@(negedge vin_clk);wr_fsync=0;
            repeat((VT-V)*HT-1) @(negedge vin_clk);
            for(y=0;y<V;y=y+1) begin
                for(x=0;x<H;x=x+1) begin wr_en=1;wr_data=pixel(f,x,y);@(negedge vin_clk);end
                wr_en=0;repeat(HT-H) @(negedge vin_clk);
            end
        end
        wr_en=0;
        wait(publications>=(FRAMES/2-1));
        if(overlap_cycles==0 || publications<3 || display_checked==0) $fatal(1,"no concurrent/sustained progress");
        if(FULL && rendered_pose_mask!=5'b11111) $fatal(1,"incomplete five-pose coverage");
        if(FULL && (publications-1)*100000000.0/(last_publication-first_publication)<29.99)
            $fatal(1,"sustained publication below 30fps");
        $display("PASS concurrent tiled frame path: publications=%0d fps=%0f max_render_clocks=%0d capture_fifo_peak=%0d overlap_clocks=%0d displayed_pixels_checked=%0d",publications,
            (publications-1)*100000000.0/(last_publication-first_publication),max_render_cycles,capture_fifo_peak,overlap_cycles,display_checked);
        $finish;
    end
    // Input/output streams are phase offset and use independent clock domains.
    integer df,dy,dx;
    reg [15:0] expected0=0,expected1=0;
    reg [1:0] de_expected=0;
    reg checking=0;
    integer output_index=0,output_bank;
    initial begin
        wait(ddr_rstn);repeat(140) @(negedge vout_clk);
        forever begin
            rd_fsync=1;@(negedge vout_clk);rd_fsync=0;
            repeat((VT-V)*HT-1) @(negedge vout_clk);
            checking=init_done;output_index=0;output_bank=dut.display_bank;
            if(checking && dut.display_bad) $fatal(1,"display failed epoch before active raster");
            for(dy=0;dy<V;dy=dy+1) begin
                rd_en=1;repeat(H) @(negedge vout_clk);
                rd_en=0;repeat(HT-H) @(negedge vout_clk);
            end
            checking=0;
        end
    end
    always @(posedge vout_clk) begin
        de_expected<={de_expected[0],rd_en&&checking};
        expected1<=expected0;
        if(rd_en&&checking) begin
            expected0<=memory[output_bank][output_index/16][(output_index%16)*16+:16];
            output_index=output_index+1;
            if(dut.display_bad || dut.display_flush) $fatal(1,"display underrun/epoch during active raster");
        end
        #1;
        if(de_expected[1]) begin
            if(!vout_de || vout_data!==expected1) $fatal(1,"display FIFO pixel mismatch got=%h expected=%h",vout_data,expected1);
            display_checked=display_checked+1;
        end
    end
    initial begin #500000000;$fatal(1,"integration timeout");end
endmodule

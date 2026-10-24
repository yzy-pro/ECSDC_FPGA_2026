`timescale 1ns/1ps
// Concurrent capture/render/display with the production FIFOs and arbiter.
// DDR model has configurable command latency and 25% payload stalls.
// Optional shared payload/periodic refresh models the finite DDR data bus.
// FULL uses 1080p60 raster timing and measures sustained distinct publications.
module tb_fram_buf_pose_tiled;
    parameter FULL=0,H=320,V=180,FRAMES=12,DDR_LATENCY=32;
    parameter SHARED_PAYLOAD=0,REFRESH_CYCLES=0,REFRESH_INTERVAL=780;
    parameter PREPROCESS=0;
    parameter RUNTIME=0;
    reg [2:0] control_mask=7;
    reg lens_enable=1;
    localparam PIXELS=H*V,WORDS=PIXELS/16,POSE_COUNT=11;
    localparam HT=FULL ? 2200 : H+64,VT=FULL ? 1125 : V+20;
    localparam FX=FULL ? 12262554 : 125*16384;
    localparam FY=FULL ? 12256498 : 125*16384;
    localparam CX=FULL ? 15481296 : 160*16384;
    localparam CY=FULL ? 8558941 : 90*16384;
    reg ddr_clk=0,vin_clk=0,vout_clk=0,ddr_rstn=0;
    always #5 ddr_clk=~ddr_clk;
    always #3.367 vin_clk=~vin_clk;
    initial begin #1;forever #3.367 vout_clk=~vout_clk;end
    reg raw_fsync=0,raw_en=0,rd_fsync=0,rd_en=0;
    reg [15:0] raw_data=0;
    wire wr_fsync,wr_en;
    wire [15:0] wr_data;
    wire [2:0] gamma_curve;
    generate if(PREPROCESS) begin:g_preprocess
        wire gamma_vs,gamma_de,converted_vs;
        wire [7:0] gamma_r,gamma_g,gamma_b;
        reg input_vs=0,input_de=0;
        reg [7:0] input_r=0,input_g=0,input_b=0;
        // Same external-pad register as the production top: gamma follows
        // the input IOL registers and is followed by the RGB565 register.
        always @(posedge vin_clk or negedge ddr_rstn) begin
            if(!ddr_rstn) begin
                input_vs<=0;input_de<=0;input_r<=0;input_g<=0;input_b<=0;
            end else begin
                input_vs<=raw_fsync;input_de<=raw_en;
                input_r<={raw_data[15:11],raw_data[15:13]};
                input_g<={raw_data[10:5],raw_data[10:9]};
                input_b<={raw_data[4:0],raw_data[4:2]};
            end
        end
        adaptive_gamma_stream u_gamma (
            .clk(vin_clk),.rstn(ddr_rstn),.in_vs(input_vs),.in_de(input_de),
            .in_r(input_r),.in_g(input_g),.in_b(input_b),.enable(!RUNTIME || control_mask[2]),
            .out_vs(gamma_vs),.out_de(gamma_de),.out_r(gamma_r),.out_g(gamma_g),.out_b(gamma_b),
            .active_curve(gamma_curve),.target_curve(),.stats_valid(),.luma_sum(),
            .pixel_count(),.dark_count(),.highlight_count());
        // Production converter preserves the full VS/RGB/DE alignment while
        // adding one register; physical HDMI VS polarity is active low.
        rgb888_to_rgb565 u_convert (.clk(vin_clk),.rstn(ddr_rstn),.vs_in(!gamma_vs),
            .de_in(gamma_de),.r_in(gamma_r),.g_in(gamma_g),.b_in(gamma_b),
            .vs_out(converted_vs),.active_out(),.wr_en(wr_en),.wr_data(wr_data));
        assign wr_fsync=!converted_vs;
    end else begin:g_direct
        assign wr_fsync=raw_fsync;
        assign wr_en=raw_en;
        assign wr_data=raw_data;
        assign gamma_curve=3;
    end endgenerate
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
    fram_buf_pose #(.H_NUM(H),.V_NUM(V),.TILED_ENABLE(1),.RUNTIME_CONTROL(RUNTIME),
        .FX_Q14(FX),.FY_Q14(FY),.CX_Q14(CX),.CY_Q14(CY)) dut(.*);
    reg [255:0] memory[0:3][0:WORDS-1];
    reg [15:0] expected[0:PIXELS-1];
    reg seen[0:PIXELS-1];
    integer generation[0:3],generation_pose[0:3];
    integer generation_curve[0:FRAMES+1];
    reg [2:0] generation_mask[0:FRAMES+1];
    reg [7:0] rendered_control_mask=0;
    reg [7:0] gamma_oracle[0:6][0:255];
    reg [6:0] captured_curve_mask=0;
    integer input_generation=0,render_generation=0,pending_generation=0,last_display_generation=0;
    integer accepted_sources=0,input_pose_index=0,render_pose_index=0;
    integer cycle=0,write_wait=0,read_wait=0,write_left=0,read_left=0;
    integer capture_beats=0,render_beats=0,checked_pixels=0,display_checked=0;
    reg wp=0,rp=0;
    reg [27:0] wa,ra;
    reg [3:0] rid;
    reg [31:0] rng=32'h563a214e;
    integer bank,index,lane,i,pindex;
    integer first_publication=0,last_publication=0,publications=0;
    integer max_publication_clocks=0;
    integer prev_rendered=0,prev_displayed=0,render_start_cycle=0,max_render_cycles=0;
    integer overlap_cycles=0,capture_fifo_peak=0;
    integer shared_contentions=0,refresh_stall_clocks=0;
    reg shared_last_write=0,refresh_active=0;
    reg [POSE_COUNT-1:0] rendered_pose_mask=0;
    reg [POSE_COUNT-1:0] pending_pose=0,published_pose_mask=0;
    integer completed_display_generation=0;
    function automatic [15:0] raw_pixel(input integer gen,x,y);
        integer r,g,b,scene;
        begin
            r=(x+3*y+gen*7)&31;g=(5*x+y+gen*11)&63;b=(x^y^(gen*3))&31;
            // Eight dark, eight bright, eight normal/mixed input frames
            // exercise automatic curve transitions despite skipped captures.
            scene=((gen-1)/8)%3;
            if(PREPROCESS && scene==0) begin r=r>>2;g=g>>2;b=b>>2;end
            if(PREPROCESS && scene==1) begin r=24+(r>>2);g=48+(g>>2);b=24+(b>>2);end
            raw_pixel={5'(r),6'(g),5'(b)};
        end
    endfunction
    function automatic [15:0] pixel(input integer gen,x,y);
        reg [15:0] p;
        reg [7:0] r,g,b;
        begin
            p=raw_pixel(gen,x,y);
            if(PREPROCESS && (!RUNTIME || generation_mask[gen][2])) begin
                r=gamma_oracle[generation_curve[gen]][{p[15:11],p[15:13]}];
                g=gamma_oracle[generation_curve[gen]][{p[10:5],p[10:9]}];
                b=gamma_oracle[generation_curve[gen]][{p[4:0],p[4:2]}];
                pixel={r[7:3],g[7:2],b[7:3]};
            end else pixel=p;
        end
    endfunction
    function automatic signed [15:0] pose_yaw(input integer pose_index);
        case(pose_index)
            1,2,5:pose_yaw=536;
            3,4,6:pose_yaw=-536;
            9:pose_yaw=-179;
            10:pose_yaw=179;
            default:pose_yaw=0;
        endcase
    endfunction
    function automatic signed [15:0] pose_pitch(input integer pose_index);
        case(pose_index)
            1,3,7:pose_pitch=536;
            2,4,8:pose_pitch=-536;
            default:pose_pitch=0;
        endcase
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
            render_pose_index=generation_pose[dut.renderer_source_bank];
            if(dut.renderer_yaw!==((!RUNTIME || generation_mask[render_generation][1]) ? pose_yaw(render_pose_index) : 16'sd0) ||
               dut.renderer_pitch!==((!RUNTIME || generation_mask[render_generation][1]) ? pose_pitch(render_pose_index) : 16'sd0))
                $fatal(1,"source pose/frame mismatch gen=%0d pose=%0d yaw=%0d pitch=%0d",
                    render_generation,render_pose_index,dut.renderer_yaw,dut.renderer_pitch);
            if(RUNTIME && dut.renderer_lens_enable!==generation_mask[render_generation][0])
                $fatal(1,"lens setting mixed between source frames");
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
            rendered_control_mask[generation_mask[render_generation]]=1;
            if(checked_pixels!=PIXELS) $fatal(1,"publication omitted pixels: checked=%0d required=%0d",checked_pixels,PIXELS);
            rendered_pose_mask[render_pose_index]=1;
            pending_pose=0;pending_pose[render_pose_index]=1;
            pending_generation=render_generation;
            if(cycle-render_start_cycle>max_render_cycles) max_render_cycles=cycle-render_start_cycle;
            $display("RENDER frame=%0d gen=%0d pose=%0d yaw=%0d pitch=%0d curve=%0d clocks=%0d",
                rendered_frames,render_generation,render_pose_index,dut.renderer_yaw,dut.renderer_pitch,generation_curve[render_generation],cycle-render_start_cycle);
            if(FULL && cycle-render_start_cycle>3333333) $fatal(1,"contended render exceeded 30fps");
            prev_rendered=rendered_frames;
        end
        if(displayed_frames!=prev_displayed) begin
            if(pending_generation<=last_display_generation) $fatal(1,"duplicate/stale publication");
            last_display_generation=pending_generation;
            published_pose_mask=published_pose_mask|pending_pose;
            if(publications==0) first_publication=cycle;
            else begin
                if(cycle-last_publication>max_publication_clocks) max_publication_clocks=cycle-last_publication;
                if(FULL && cycle-last_publication>3333334)
                    $fatal(1,"distinct publication interval exceeded 30fps: clocks=%0d",cycle-last_publication);
            end
            last_publication=cycle;publications=publications+1;prev_displayed=displayed_frames;
            $display("PUBLISH frame=%0d gen=%0d clock=%0d",displayed_frames,pending_generation,cycle);
        end
    end
    always @(negedge ddr_clk) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        refresh_active=ddr_rstn && REFRESH_CYCLES>0 && cycle%REFRESH_INTERVAL<REFRESH_CYCLES;
        if(refresh_active) refresh_stall_clocks=refresh_stall_clocks+1;
        axi_awready=ddr_rstn&&!refresh_active&&!wp&&rng[1:0]!=0;
        axi_arready=ddr_rstn&&!refresh_active&&!rp&&rng[3:2]!=0;
        axi_wready=0;axi_wlast=0;axi_rvalid=0;axi_rlast=0;
        if(wp && !refresh_active) begin
            if(write_wait!=0) write_wait=write_wait-1;
            else if(rng[5:4]!=0) begin axi_wready=1;axi_wlast=write_left==1;end
        end
        if(rp && !refresh_active) begin
            if(read_wait!=0) read_wait=read_wait-1;
            else if(rng[7:6]!=0) begin
                axi_rvalid=1;axi_rlast=read_left==1;axi_rid=rid;
                axi_rdata=memory[ra[23:22]][ra[21:3]];
            end
        end
        // A 32-bit DDR800 interface has the same peak payload bandwidth as
        // one 256-bit beat at 100 MHz, shared between reads and writes.
        // Fair arbitration here adds no explicit bus-turnaround latency.
        if(SHARED_PAYLOAD && axi_wready && axi_rvalid) begin
            shared_contentions=shared_contentions+1;
            if(shared_last_write) begin axi_wready=0;axi_wlast=0;end
            else begin axi_rvalid=0;axi_rlast=0;end
        end
        if(axi_wready) shared_last_write=1;
        if(axi_rvalid) shared_last_write=0;
    end
    always @(posedge vin_clk) if(ddr_rstn && dut.capture_active && wr_en && dut.capture_pixels==0) begin
        generation[dut.capture_bank]=input_generation;
        generation_pose[dut.capture_bank]=input_pose_index;
        generation_curve[input_generation]=gamma_curve;
        captured_curve_mask[gamma_curve]=1;
    end
    always @(posedge vin_clk) if(ddr_rstn && PREPROCESS && dut.capture_active && wr_en && dut.capture_pixels!=0)
        if(gamma_curve!=generation_curve[input_generation]) $fatal(1,"gamma curve changed during captured frame");
    integer f,y,x,curve,value;
    real exponent;
    initial begin
        if(REFRESH_INTERVAL<1 || REFRESH_CYCLES<0 || REFRESH_CYCLES>=REFRESH_INTERVAL)
            $fatal(1,"invalid refresh model parameters");
        $display("MODEL latency=%0d shared_payload=%0d refresh_cycles=%0d refresh_interval=%0d payload_bubble_percent=25 preprocess=%0d",
            DDR_LATENCY,SHARED_PAYLOAD,REFRESH_CYCLES,REFRESH_INTERVAL,PREPROCESS);
        for(curve=0;curve<7;curve=curve+1) begin
            case(curve)
                0:exponent=0.50;1:exponent=0.65;2:exponent=0.80;3:exponent=1.0;
                4:exponent=1.25;5:exponent=1.55;6:exponent=1.90;
            endcase
            for(value=0;value<256;value=value+1)
                gamma_oracle[curve][value]=$rtoi(255.0*((value/255.0)**exponent)+0.5);
        end
        for(f=0;f<=FRAMES+1;f=f+1) generation_curve[f]=3;
        generation[0]=0;generation[1]=0;generation[2]=0;generation[3]=0;
        repeat(10) @(negedge vin_clk);ddr_rstn=1;
        for(f=1;f<=FRAMES;f=f+1) begin
            input_generation=f;
            control_mask=RUNTIME ? accepted_sources%8 : 7;
            generation_mask[f]=control_mask;lens_enable=control_mask[0];
            // Advance only after accepted SOF: the renderer may deliberately
            // skip input frames while its source/output banks are owned.
            input_pose_index=accepted_sources%POSE_COUNT;
            imu_yaw=(!RUNTIME || control_mask[1]) ? pose_yaw(input_pose_index) : 0;
            imu_pitch=(!RUNTIME || control_mask[1]) ? pose_pitch(input_pose_index) : 0;
            raw_fsync=1;@(negedge vin_clk);raw_fsync=0;
            repeat((VT-V)*HT-1) @(negedge vin_clk);
            if(dut.capture_active) accepted_sources=accepted_sources+1;
            // Stress the source-SOF snapshot independently of normal controls.
            if(RUNTIME) lens_enable=~lens_enable;
            for(y=0;y<V;y=y+1) begin
                for(x=0;x<H;x=x+1) begin raw_en=1;raw_data=raw_pixel(f,x,y);@(negedge vin_clk);end
                raw_en=0;repeat(HT-H) @(negedge vin_clk);
            end
        end
        raw_en=0;
        wait(publications>=(FRAMES/2-1) && (!FULL || &published_pose_mask));
        wait(completed_display_generation>=last_display_generation);
        if(overlap_cycles==0 || publications<3 || display_checked==0) $fatal(1,"no concurrent/sustained progress");
        if(FULL && !(&rendered_pose_mask)) $fatal(1,"incomplete eleven-pose coverage");
        if(RUNTIME && !(&rendered_control_mask)) $fatal(1,"incomplete runtime switch coverage %b",rendered_control_mask);
        if(PREPROCESS && (captured_curve_mask & 7'b1110111)==0) $fatal(1,"adaptive gamma never exercised nonidentity curve");
        if(FULL && (publications-1)*100000000.0/(last_publication-first_publication)<29.99)
            $fatal(1,"sustained publication below 30fps");
        $display("PASS concurrent tiled frame path: publications=%0d fps=%0f max_render_clocks=%0d max_publication_clocks=%0d capture_fifo_peak=%0d overlap_clocks=%0d displayed_pixels_checked=%0d pose_mask=%b shared_contentions=%0d refresh_stall_clocks=%0d gamma_curve_mask=%b",publications,
            (publications-1)*100000000.0/(last_publication-first_publication),max_render_cycles,max_publication_clocks,capture_fifo_peak,overlap_cycles,display_checked,published_pose_mask,shared_contentions,refresh_stall_clocks,captured_curve_mask);
        $finish;
    end
    // Input/output streams are phase offset and use independent clock domains.
    integer df,dy,dx;
    reg [15:0] expected0=0,expected1=0;
    reg [1:0] de_expected=0;
    reg checking=0;
    integer output_index=0,output_bank,output_generation;
    initial begin
        wait(ddr_rstn);repeat(140) @(negedge vout_clk);
        forever begin
            rd_fsync=1;@(negedge vout_clk);rd_fsync=0;
            repeat((VT-V)*HT-1) @(negedge vout_clk);
            checking=init_done;output_index=0;output_bank=dut.display_bank;
            output_generation=last_display_generation;
            if(checking && dut.display_bad) $fatal(1,"display failed epoch before active raster");
            for(dy=0;dy<V;dy=dy+1) begin
                rd_en=1;repeat(H) @(negedge vout_clk);
                rd_en=0;repeat(HT-H) @(negedge vout_clk);
            end
            if(checking) completed_display_generation=output_generation;
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
    initial begin
        #((FRAMES+8)*HT*VT*6.734);
        $fatal(1,"integration timeout: accepted=%0d rendered=%0d publications=%0d pose_mask=%b",
            accepted_sources,rendered_frames,publications,published_pose_mask);
    end
endmodule

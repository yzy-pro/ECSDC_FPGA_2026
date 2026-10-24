`timescale 1ns/1ps
// All output pixels checked against the separately verified exact projector.
// Independent tile traversal/address coverage catches omissions and aliases.
module tb_pose_renderer_tiled;
    parameter H=320,V=180,WIDTH=H,HEIGHT=V,FULL=0;
    parameter READ_LATENCY=24,WRITE_LATENCY=24;
    parameter TILE_W=128,TILE_H=32;
    parameter RUNTIME=0,CONTROL_MODE=3;
    reg lens_enable=1;
    reg identity_expected=0;
    localparam PIXELS=WIDTH*HEIGHT;
    localparam FX=FULL ? 12262554 : 125*16384;
    localparam FY=FULL ? 12256498 : 125*16384;
    localparam CX=FULL ? 15481296 : 160*16384;
    localparam CY=FULL ? 8558941 : 90*16384;
    reg clk=0; always #5 clk=~clk;
    reg rstn=0,start=0;
    reg [1:0] source_bank=0,render_bank=2;
    reg signed [15:0] yaw=0,pitch=0;
    wire busy,done,error,pose_clamped;
    wire [1:0] completed_bank;
    wire rd_cmd_valid,wr_cmd_valid;
    wire [27:0] rd_cmd_addr,wr_cmd_addr;
    wire [4:0] rd_cmd_len,wr_cmd_len;
    wire [4095:0] wr_data;
    reg rd_cmd_ready=0,wr_cmd_ready=0,rd_data_valid=0,rd_data_last=0,wr_done=0;
    reg [255:0] rd_data=0;
    pose_renderer_tiled #(.H_NUM(H),.V_NUM(V),.OUTPUT_H_NUM(WIDTH),.OUTPUT_V_NUM(HEIGHT),
        .TILE_W(TILE_W),.TILE_H(TILE_H),.RUNTIME_CONTROL(RUNTIME),
        .FX_Q14(FX),.FY_Q14(FY),.CX_Q14(CX),.CY_Q14(CY)) dut (
        .clk(clk),.rstn(rstn),.start(start),.source_bank(source_bank),.render_bank(render_bank),
        .lens_enable(lens_enable),
        .yaw_q2048(yaw),.pitch_q2048(pitch),.busy(busy),.done(done),.error(error),
        .pose_clamped(pose_clamped),.completed_bank(completed_bank),
        .rd_cmd_valid(rd_cmd_valid),.rd_cmd_ready(rd_cmd_ready),.rd_cmd_addr(rd_cmd_addr),.rd_cmd_len(rd_cmd_len),
        .rd_data_valid(rd_data_valid),.rd_data(rd_data),.rd_data_last(rd_data_last),
        .wr_cmd_valid(wr_cmd_valid),.wr_cmd_ready(wr_cmd_ready),.wr_cmd_addr(wr_cmd_addr),.wr_cmd_len(wr_cmd_len),
        .wr_data(wr_data),.wr_done(wr_done));
    reg reference_load=0;
    reg bad_last=0;
    reg signed [15:0] eyaw=0,epitch=0;
    integer tx=0,ty=0,lx=0,ly=0,inputs=0,results=0;
    wire [10:0] ref_x=tx+lx,ref_y=ty+ly;
    wire ref_valid,ref_map;
    wire signed [31:0] ref_u,ref_v;
    pose_inverse_project_q14 #(.H_NUM(H),.V_NUM(V),.POSE_LIMIT_Q2048(536),
        .K1_Q14((RUNTIME && !(CONTROL_MODE&1)) ? 0 : 162),
        .K2_Q14((RUNTIME && !(CONTROL_MODE&1)) ? 0 : -711),
        .FX_Q14(FX),.FY_Q14(FY),.CX_Q14(CX),.CY_Q14(CY)) oracle (
        .clk(clk),.rstn(rstn),.pose_load(reference_load),.pose_yaw_q2048(eyaw),.pose_pitch_q2048(epitch),
        .pose_clamped(),.pose_ready(),.in_valid(dut.project_en),.dst_x(ref_x),.dst_y(ref_y),
        .out_valid(ref_valid),.map_valid(ref_map),.src_x_q14(ref_u),.src_y_q14(ref_v));
    integer positions[0:PIXELS-1];
    reg [15:0] expected[0:PIXELS-1];
    reg seen[0:PIXELS-1];
    function automatic [15:0] pixel(input integer bank,x,y);
        pixel={5'((x+3*y+bank)&31),6'((5*x+y+bank)&63),5'((x^y^(bank*7))&31)};
    endfunction
    integer esource=0,erender=2,black=0,color=0;
    always @(posedge clk) if(rstn) begin
        if(dut.project_en && !bad_last) begin
            if(dut.u_projector.dst_x!==ref_x || dut.u_projector.dst_y!==ref_y)
                $fatal(1,"tile traversal mismatch");
            positions[inputs]=(ty+ly)*WIDTH+tx+lx;inputs=inputs+1;
            if(lx==((WIDTH-tx<TILE_W)?WIDTH-tx:TILE_W)-1) begin
                lx=0;ly=ly+1;
                if(ly==((HEIGHT-ty<TILE_H)?HEIGHT-ty:TILE_H)) begin
                    ly=0;tx=tx+TILE_W;
                    if(tx>=WIDTH) begin tx=0;ty=ty+TILE_H; end
                end
            end else lx=lx+1;
        end
        if(ref_valid && !bad_last) begin
            expected[positions[results]]=identity_expected ?
                pixel(esource,positions[results]%WIDTH,positions[results]/WIDTH) :
                ref_map ? pixel(esource,(ref_u+8192)>>14,(ref_v+8192)>>14) : 0;
            results=results+1;
            if(ref_map) color=color+1; else black=black+1;
        end
    end
    integer cycle=0,read_wait=0,write_wait=0,read_left=0;
    integer reads=0,readbeats=0,writes=0,writebeats=0,commits=0;
    reg rp=0,wp=0;
    reg [27:0] read_addr;
    integer address,row,col,lane,beat,index,i,start_cycle;
    reg rs=0,ws=0;
    reg [27:0] held_ra,held_wa;
    reg [4:0] held_rl,held_wl;
    reg [4095:0] held_payload;
    always @(negedge clk) begin
        cycle=cycle+1;
        rd_cmd_ready=!rp && cycle%4!=0;
        wr_cmd_ready=!wp && cycle%5!=0;
        rd_data_valid=0;rd_data_last=0;wr_done=0;
        if(rp) begin
            if(read_wait!=0) read_wait=read_wait-1;
            else begin
                address=read_addr-(esource<<22);row=address/(H/2);col=(address%(H/2))/8*16;
                for(lane=0;lane<16;lane=lane+1) rd_data[lane*16+:16]=pixel(esource,col+lane,row);
                rd_data_valid=1;rd_data_last=read_left==1 && !bad_last;
                read_addr=read_addr+8;read_left=read_left-1;
                if(read_left==0) rp=0;
            end
        end
        if(wp) begin
            if(write_wait!=0) write_wait=write_wait-1;
            else begin wp=0;wr_done=1;commits=commits+1; end
        end
    end
    always @(posedge clk) if(rstn) begin
        if(rs && (!rd_cmd_valid || rd_cmd_addr!==held_ra || rd_cmd_len!==held_rl)) $fatal(1,"unstable read");
        if(ws && (!wr_cmd_valid || wr_cmd_addr!==held_wa || wr_cmd_len!==held_wl || wr_data!==held_payload)) $fatal(1,"unstable write");
        rs=rd_cmd_valid&&!rd_cmd_ready;ws=wr_cmd_valid&&!wr_cmd_ready;
        held_ra=rd_cmd_addr;held_rl=rd_cmd_len;held_wa=wr_cmd_addr;held_wl=wr_cmd_len;held_payload=wr_data;
        if(rd_cmd_valid&&rd_cmd_ready) begin
            if(rp || rd_cmd_len<1 || rd_cmd_len>16 || rd_cmd_addr[23:22]!=esource || rd_cmd_addr[2:0]!=0)
                $fatal(1,"invalid source burst");
            read_addr=rd_cmd_addr;read_left=rd_cmd_len;read_wait=READ_LATENCY+(cycle%7);
            rp=1;reads=reads+1;readbeats=readbeats+rd_cmd_len;
        end
        if(wr_cmd_valid&&wr_cmd_ready) begin
            if(wp || wr_cmd_len<1 || wr_cmd_len>16 || wr_cmd_addr[23:22]!=erender || wr_cmd_addr[2:0]!=0)
                $fatal(1,"invalid output burst");
            address=wr_cmd_addr-(erender<<22);row=address/(H/2);col=(address%(H/2))/8*16;
            for(beat=0;beat<wr_cmd_len;beat=beat+1)
                for(lane=0;lane<16;lane=lane+1) begin
                    index=row*WIDTH+col+beat*16+lane;
                    if(row>=HEIGHT || col+beat*16+lane>=WIDTH || seen[index]) $fatal(1,"duplicate/outside output");
                    if(wr_data[beat*256+lane*16+:16]!==expected[index])
                        $fatal(1,"pixel %0d at %0d,%0d got=%h expected=%h",index,col+beat*16+lane,row,wr_data[beat*256+lane*16+:16],expected[index]);
                    seen[index]=1;
                end
            wp=1;write_wait=WRITE_LATENCY+wr_cmd_len+(cycle%7);
            writes=writes+1;writebeats=writebeats+wr_cmd_len;
        end
        if(done && (wp || writes!=commits || completed_bank!=erender || writebeats!=PIXELS/16))
            $fatal(1,"premature publication");
        if(error && !bad_last) $fatal(1,"renderer fault ps=%0d bbox=%0d",dut.ps,dut.bbox_size);
    end
    task automatic render(input integer ya,pi,bank);
        begin
            @(negedge clk);
            if(RUNTIME && !(CONTROL_MODE&2)) begin ya=0;pi=0;end
            lens_enable=!RUNTIME || (CONTROL_MODE&1)!=0;
            identity_expected=RUNTIME && !lens_enable && ya==0 && pi==0;
            tx=0;ty=0;lx=0;ly=0;inputs=0;results=0;reads=0;readbeats=0;writes=0;writebeats=0;commits=0;black=0;color=0;
            for(i=0;i<PIXELS;i=i+1) begin seen[i]=0;expected[i]='x; end
            esource=bank;erender=bank+2;eyaw=ya;epitch=pi;
            source_bank=bank;render_bank=bank+2;yaw=ya;pitch=pi;reference_load=1;
            repeat(2) @(negedge clk);reference_load=0;start=1;start_cycle=cycle;
            @(negedge clk);start=0;
            repeat(8) @(negedge clk);source_bank=bank^1;render_bank=(bank^1)+2;yaw=-ya;pitch=-pi;
            lens_enable=~lens_enable;
            wait(done);@(negedge clk);
            if(inputs!=PIXELS || results!=PIXELS || error) $fatal(1,"incomplete frame");
            for(i=0;i<PIXELS;i=i+1) if(!seen[i]) $fatal(1,"missing output pixel");
            $display("MEASURE tiled yaw=%0d pitch=%0d pixels=%0d clocks=%0d source_commands=%0d source_beats=%0d write_commands=%0d ms=%0f fps=%0f valid=%0d black=%0d",ya,pi,PIXELS,cycle-start_cycle,reads,readbeats,writes,(cycle-start_cycle)/100000.0,100000000.0/(cycle-start_cycle),color,black);
            if(FULL && cycle-start_cycle>3333333) $fatal(1,"1080p30 render budget exceeded");
            repeat(8) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rstn=1;
        render(0,0,0);render(536,536,1);render(536,-536,0);render(-536,536,1);render(-536,-536,0);
        if(!FULL) begin
            @(negedge clk);bad_last=1;source_bank=0;render_bank=2;yaw=0;pitch=0;start=1;
            @(negedge clk);start=0;wait(error);repeat(15) @(negedge clk);
            if(!busy || done) $fatal(1,"fault released ownership");
        end
        $display("PASS tiled renderer: exact pixels, all tile edges, pose snapshot, DDR bursts/backpressure, final commit%s",FULL?"":" and bad LAST hold");$finish;
    end
    initial begin #2000000000;$fatal(1,"timeout"); end
endmodule

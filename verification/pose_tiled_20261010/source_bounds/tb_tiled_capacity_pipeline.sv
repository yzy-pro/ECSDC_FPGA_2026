`timescale 1ns/1ps
// Actual projector geometry yields32x8 nearest taps:2words x8rows=16beats.
// Tests cache-size equality, real overflow, and empty-tile bypass after a
// completed frame. No mocked projection result replaces the real arithmetic.
module tb_tiled_capacity_pipeline;
    reg clk=0;always #5 clk=~clk;
    reg rstn=0,start_ok=0,start_small=0;
    reg signed [15:0] yaw=0;
    wire busy_ok,done_ok,error_ok,rdv_ok,wv_ok;
    wire [27:0] raddr_ok,waddr_ok;
    wire [4:0] rlen_ok,wlen_ok;
    wire [4095:0] wdata_ok;
    reg rv_ok=0,rlast_ok=0,wdone_ok=0;
    reg [255:0] rdata_ok={16{16'habcd}};
    wire busy_small,done_small,error_small,rdv_small,wv_small;
    wire [27:0] raddr_small,waddr_small;
    wire [4:0] rlen_small,wlen_small;
    wire [4095:0] wdata_small;
    pose_renderer_tiled #(.H_NUM(64),.V_NUM(16),.OUTPUT_H_NUM(32),.OUTPUT_V_NUM(8),
        .TILE_W(32),.TILE_H(8),.SOURCE_BITS(4),.FX_Q14(256*16384),.FY_Q14(256*16384),
        .CX_Q14(0),.CY_Q14(0),.K1_Q14(0),.K2_Q14(0)) equal_cache (
        .clk(clk),.rstn(rstn),.start(start_ok),.source_bank(2'd0),.render_bank(2'd2),
        .yaw_q2048(yaw),.pitch_q2048(16'sd0),.busy(busy_ok),.done(done_ok),.error(error_ok),
        .pose_clamped(),.completed_bank(),
        .rd_cmd_valid(rdv_ok),.rd_cmd_ready(1'b1),.rd_cmd_addr(raddr_ok),.rd_cmd_len(rlen_ok),
        .rd_data_valid(rv_ok),.rd_data(rdata_ok),.rd_data_last(rlast_ok),
        .wr_cmd_valid(wv_ok),.wr_cmd_ready(1'b1),.wr_cmd_addr(waddr_ok),.wr_cmd_len(wlen_ok),
        .wr_data(wdata_ok),.wr_done(wdone_ok));
    pose_renderer_tiled #(.H_NUM(64),.V_NUM(16),.OUTPUT_H_NUM(32),.OUTPUT_V_NUM(8),
        .TILE_W(32),.TILE_H(8),.SOURCE_BITS(3),.FX_Q14(256*16384),.FY_Q14(256*16384),
        .CX_Q14(0),.CY_Q14(0),.K1_Q14(0),.K2_Q14(0)) small_cache (
        .clk(clk),.rstn(rstn),.start(start_small),.source_bank(2'd0),.render_bank(2'd2),
        .yaw_q2048(16'sd0),.pitch_q2048(16'sd0),.busy(busy_small),.done(done_small),.error(error_small),
        .pose_clamped(),.completed_bank(),
        .rd_cmd_valid(rdv_small),.rd_cmd_ready(1'b1),.rd_cmd_addr(raddr_small),.rd_cmd_len(rlen_small),
        .rd_data_valid(1'b0),.rd_data(256'd0),.rd_data_last(1'b0),
        .wr_cmd_valid(wv_small),.wr_cmd_ready(1'b1),.wr_cmd_addr(waddr_small),.wr_cmd_len(wlen_small),
        .wr_data(wdata_small),.wr_done(1'b0));
    integer read_left=0,read_beats=0,writes=0,write_beats=0,i;
    integer capacity_checks=0,black_capacity_checks=0,black_bounds=0;
    integer projected_valid=0,projected_total=0,black=0;
    reg write_pending=0;
    always @(negedge clk) begin
        rv_ok=0;rlast_ok=0;wdone_ok=0;
        if(read_left!=0)begin
            rv_ok=1;rlast_ok=read_left==1;read_left=read_left-1;
        end
        if(write_pending)begin wdone_ok=1;write_pending=0;end
    end
    always @(posedge clk) if(rstn)begin
        if(error_ok) $fatal(1,"equal-capacity/black renderer failed");
        if(rdv_small || wv_small || done_small) $fatal(1,"overflow released commands/ownership");
        if(equal_cache.pv&&(equal_cache.ps==4||equal_cache.ps==5))begin
            projected_total=projected_total+1;
            if(equal_cache.pm)projected_valid=projected_valid+1;
        end
        if(equal_cache.ps==12)begin
            if(black)black_capacity_checks=black_capacity_checks+1;
            else begin
                if(equal_cache.bbox_size!==20'd16) $fatal(1,"test geometry not exact capacity");
                capacity_checks=capacity_checks+1;
            end
        end
        if(black && equal_cache.ps==6)begin
            if(equal_cache.any_valid) $fatal(1,"black pose had valid tap");
            black_bounds=black_bounds+1;
        end
        if(rdv_ok)begin
            if(black || read_left!=0 || rlen_ok!=2 || raddr_ok!=read_beats/2*32)
                $fatal(1,"unexpected source request");
            read_left=rlen_ok;read_beats=read_beats+rlen_ok;
        end
        if(wv_ok)begin
            if(wlen_ok!=2 || waddr_ok!=(2<<22)+(writes%8)*32) $fatal(1,"bad row write");
            for(i=0;i<32;i=i+1) if(wdata_ok[i*16+:16] !== (black?16'd0:16'habcd))
                $fatal(1,"wrong equality/black output tap");
            writes=writes+1;write_beats=write_beats+wlen_ok;write_pending=1;
        end
    end
    initial begin
        repeat(4)@(negedge clk);rstn=1;start_ok=1;start_small=1;
        @(negedge clk);start_ok=0;start_small=0;
        wait(done_ok);@(negedge clk);
        if(!error_small || !busy_small || small_cache.bbox_size!=16 || capacity_checks!=1 ||
           read_beats!=16 || write_beats!=16 || projected_total!=256 || projected_valid!=256)
            $fatal(1,"capacity equality/overflow precondition failed");
        $display("PASS bbox area16==SW16:256real projected pixels/16readbeats/full committed output; area16>SW8:fault,zero requests,ownershipheld");
        // Positive15degree yaw places every output ray beyond the64-wide
        // source. Poison unused stale product to stress empty-tile bypass;
        // this does not override any projection/map-valid signal.
        black=1;yaw=536;projected_total=0;projected_valid=0;
        force equal_cache.bbox_size=20'd17;
        start_ok=1;@(negedge clk);start_ok=0;
        wait(done_ok);@(negedge clk);
        if(error_ok || black_capacity_checks!=0 || black_bounds!=1 ||
           read_beats!=16 || write_beats!=32 || projected_total!=256 || projected_valid!=0 ||
           !error_small || !busy_small || done_small)
            $fatal(1,"empty tile failed bypass/black fill/fault isolation");
        release equal_cache.bbox_size;
        $display("PASS empty tile:256black pixels,zero new reads,stale area17>SW16 ignored,no capacity stage");
        $display("PASS pipelined tile capacity boundary regression");$finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule

`timescale 1ns/1ps
// Full physical raster, asynchronous clocks, tagged DDR pixels and stalls.
// This is a bounded DDR service model, NOT a simulation of the vendor PHY.
module tb_direct1920_raster #(parameter FRAME_COUNT=3, parameter INTERPOLATION_MODE=1, parameter DYNAMIC_IMU=0);
    reg pixel_clk=0, ddr_clk=0, rstn=0;
    always #3.367 pixel_clk=~pixel_clk;
    always #5 ddr_clk=~ddr_clk;
    wire vs, hs, de, display_de, out_de;
    wire [15:0] out_data;
    reg [1:0] completed=1;
    sync_vg #(.V_TOTAL(1125),.V_FP(4),.V_BP(36),.V_SYNC(5),.V_ACT(1080),
        .H_TOTAL(2200),.H_FP(88),.H_BP(148),.H_SYNC(44),.H_ACT(1920)) timing(
        .clk(pixel_clk),.rstn(rstn),.vs_out(vs),.hs_out(hs),.de_out(de));
    video_raster_delay raster(.clk(pixel_clk),.rstn(rstn),.timing_de(de),.display_de(display_de));
    wire req, done;
    wire [27:0] address;
    wire [31:0] length;
    reg valid=0;
    reg [255:0] data=0;
    reg signed [15:0] imu_yaw=0,imu_pitch=0,imu_roll=0;
    reg imu_valid=0;
    undistort_rd_buf #(.INTERPOLATION_MODE(INTERPOLATION_MODE)) reader(.ddr_clk(ddr_clk),.ddr_rstn(rstn),.vout_clk(pixel_clk),
        .rd_fsync(vs),.rd_active(de),.rd_en(de),.init_done(rstn),
        .imu_yaw(imu_yaw),.imu_pitch(imu_pitch),.imu_roll(imu_roll),.imu_valid(imu_valid),
        .completed_frame_bank(completed),.ddr_rreq(req),.ddr_raddr(address),
        .ddr_rd_len(length),.ddr_rrdy(1'b1),.ddr_rdone(done),
        .ddr_rdata(data),.ddr_rdata_en(valid),.vout_de(out_de),.vout_data(out_data));
    wr_cmd_trans #(.MEM_DQ_WIDTH(32)) counter(.clk(ddr_clk),.rstn(rstn),.wr_cmd_en(1'b0),
        .wr_cmd_addr(28'd0),.wr_cmd_len(32'd0),.wr_bac(1'b0),.wr_ctrl_data(256'd0),
        .wr_ready(1'b0),.wr_done(1'b0),.rd_cmd_en(req),.rd_cmd_addr(address),
        .rd_cmd_len(length),.rd_cmd_done(done),.read_en(valid),.rd_done_p(1'b0));
    function [15:0] tag(input integer bank,row,x);
        tag=(bank*17749 + row*157 + x*31) & 65535;
    endfunction
    integer beat, lane, row, bank, commands=0, stall, first_word;
    initial forever begin
        @(posedge ddr_clk);
        if(rstn && req) begin
            commands=commands+1;
            bank=address[23:22]; row=(address & 28'h03fffff)/960;
            first_word=((address & 28'h03fffff)%960)/8;
            if(length!=16 || row>=1080 || (first_word!=104 && (first_word>90 || first_word%15!=0)))
                $fatal(1,"bad 1920 DDR line address/length");
            // Include bounded arbitration stalls representing competing writes.
            repeat(16+commands%37+((commands%4==0)?120:0)) @(negedge ddr_clk);
            for(beat=0;beat<16;beat=beat+1) begin
                if(beat%5==4 || beat==15) begin
                    @(negedge ddr_clk); valid=0;
                    repeat(3) @(negedge ddr_clk);
                end
                @(negedge ddr_clk); valid=1;
                for(lane=0;lane<16;lane=lane+1)
                    data[16*lane+:16]=tag(bank,row,first_word*16+beat*16+lane);
            end
            @(negedge ddr_clk); valid=0;
        end
    end
    integer frames=0, pixels=0, taps=0, x, y, j;
    integer line_pixels=0, lines=0;
    reg prior_de=0;
    reg signed [15:0] expected_yaw=0,expected_pitch=0;
    // A packet deliberately arrives mid-frame. It must affect only the next
    // VS; alternate extrema exercise both directions and strip crossings.
    initial if(DYNAMIC_IMU) forever begin
        @(negedge vs);
        wait(de); repeat(500) @(negedge pixel_clk);
        imu_yaw=(imu_yaw<=0)?16'sd32767:-16'sd32768;
        imu_pitch=imu_yaw; imu_roll=(imu_yaw>0)?16'sd32767:-16'sd32768;
        imu_valid=1; @(negedge pixel_clk); imu_valid=0;
        @(posedge vs);
        expected_yaw=imu_yaw;expected_pitch=imu_pitch;
    end
    reg [15:0] q00[0:5], q01[0:5], q10[0:5], q11[0:5];
    reg [15:0] nearest[0:9], expected;
    reg [15:0] e00,e01,e10,e11;
    function [15:0] interpolate(input integer b,r,c,fx,fy);
        reg [15:0] a,d,e,f;
        integer rr0,gg0,bb0,rr1,gg1,bb1,rr,gg,bb;
        begin
            a=tag(b,r,c);d=tag(b,r,c+1);e=tag(b,r+1,c);f=tag(b,r+1,c+1);
            rr0=(a[15:11]*(32-fx)+d[15:11]*fx)>>5;
            gg0=(a[10:5]*(32-fx)+d[10:5]*fx)>>5;
            bb0=(a[4:0]*(32-fx)+d[4:0]*fx)>>5;
            rr1=(e[15:11]*(32-fx)+f[15:11]*fx)>>5;
            gg1=(e[10:5]*(32-fx)+f[10:5]*fx)>>5;
            bb1=(e[4:0]*(32-fx)+f[4:0]*fx)>>5;
            rr=(rr0*(32-fy)+rr1*fy)>>5;gg=(gg0*(32-fy)+gg1*fy)>>5;bb=(bb0*(32-fy)+bb1*fy)>>5;
            interpolate={rr[4:0],gg[5:0],bb[4:0]};
        end
    endfunction
    always @(posedge vs) if(rstn) begin
        frames=frames+1;
        $display("full raster: reached VS %0d, checked %0d pixels",frames,pixels);
        $fflush();
        if(frames>1 && (lines!=1080 || pixels!=(frames-1)*1920*1080))
            $fatal(1,"frame size: lines=%0d total pixels=%0d",lines,pixels);
        lines=0;
        if(frames==FRAME_COUNT+1) begin
            $display("PASS direct1920 raster: %0d frames, %0d pixels, %0d four-tap checks, DDR stalls and bank rotation",FRAME_COUNT,pixels,taps);
            $finish;
        end
    end
    // Change the next completed bank during blanking, before the next VS.
    always @(negedge vs) if(rstn) completed=(completed==2)?0:completed+1;
    always @(posedge pixel_clk) begin
        e00=q00[5]; e01=q01[5]; e10=q10[5]; e11=q11[5]; expected=nearest[9];
        if(rstn && de && !reader.pix_rd_active_d && reader.y_count==0 && !reader.cache_ready_sync[1])
            $fatal(1,"first active line began before prefill completed");
        #2;
        if(rstn) begin
            if(DYNAMIC_IMU && de && (reader.yaw_hold!==expected_yaw || reader.pitch_hold!==expected_pitch))
                $fatal(1,"attitude changed within active frame or failed to latch at VS");
            if(reader.cache_underrun) $fatal(1,"band prefetch deadline missed");
            if(display_de !== out_de) $fatal(1,"raster/reader DE phase mismatch");
            if(reader.v10) begin
                if(reader.p00!==e00 || reader.p01!==e01 || reader.p10!==e10 || reader.p11!==e11)
                    $fatal(1,"stale/misaligned cache taps frame=%0d outputY=%0d pixel=%0d: p00=%h expected=%h",frames,reader.y_count,pixels,reader.p00,e00);
                taps=taps+1;
            end
            if(out_de) begin
                if(out_data!==expected) $fatal(1,"RGB pixel/frame mismatch at %0d: got %h expected %h",pixels,out_data,expected);
                pixels=pixels+1; line_pixels=line_pixels+1;
            end
            if(prior_de && !display_de) begin
                if(line_pixels!=1920) $fatal(1,"line has %0d pixels",line_pixels);
                lines=lines+1; line_pixels=0;
            end
            prior_de=display_de;
            for(j=5;j>0;j=j-1) begin q00[j]=q00[j-1];q01[j]=q01[j-1];q10[j]=q10[j-1];q11[j]=q11[j-1];end
            for(j=9;j>0;j=j-1) nearest[j]=nearest[j-1];
            x=reader.src_x0; y=reader.src_y0;
            q00[0]=tag(reader.frame_sel,y,x); q01[0]=tag(reader.frame_sel,y,x+1);
            q10[0]=tag(reader.frame_sel,y+1,x); q11[0]=tag(reader.frame_sel,y+1,x+1);
            if(INTERPOLATION_MODE==0)
                nearest[0]=interpolate(reader.frame_sel,y,x,reader.frac_x0,reader.frac_y0);
            else nearest[0]=tag(reader.frame_sel,y+(reader.frac_y0>=16),x+(reader.frac_x0>=16));
        end
    end
    initial begin repeat(10) @(negedge pixel_clk); rstn=1; end
    initial begin #60000000; $fatal(1,"full-raster timeout"); end
endmodule

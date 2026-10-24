`timescale 1ns/1ps
// Exercise the top-level ordering: pad register -> frame control + gamma ->
// RGB565 -> geometry SOF. Toggle every mask while a prior frame is active.
module tb_pc_control_frame_alignment;
    parameter GAMMA=1;
    reg sys_clk=0,clk=0,rstn=0;
    always #10 sys_clk=~sys_clk;
    always #3.367 clk=~clk;
    reg pad_vs=1,pad_de=0;
    reg [7:0] pad_pixel=0;
    reg input_vs_q=1,input_de=0;
    reg [7:0] input_pixel=0;
    always @(posedge clk) begin
        if(!rstn) begin input_vs_q<=1;input_de<=0;input_pixel<=0;end
        else begin input_vs_q<=pad_vs;input_de<=pad_de;input_pixel<=pad_pixel;end
    end
    wire control_vs=!input_vs_q;
    reg control_vs_d=0;
    always @(posedge clk or negedge rstn)
        if(!rstn) control_vs_d<=0;else control_vs_d<=control_vs;
    reg command_valid=0;
    reg [2:0] command_mask=0;
    wire busy;
    wire [2:0] requested_mask,applied_mask_sys,source_mask,next_source_mask;
    video_control_cdc controls (
        .sys_clk(sys_clk),.vin_clk(clk),.rstn(rstn),
        .frame_start(control_vs && !control_vs_d),.command_valid(command_valid),
        .command_mask(command_mask),.busy(busy),.requested_mask(requested_mask),
        .applied_mask_sys(applied_mask_sys),.applied_mask_vin(source_mask),
        .next_mask_vin(next_source_mask));
    wire out_vs,out_de,stats_valid,stats_enabled;
    wire [7:0] out_r,out_g,out_b;
    wire [2:0] active_curve,target_curve,stats_curve,stats_target;
    wire [31:0] luma_sum,pixel_count,dark_count,highlight_count;
    generate if(GAMMA) begin:g_gamma
        adaptive_gamma_stream gamma (
            .clk(clk),.rstn(rstn),.in_vs(control_vs),.in_de(input_de),
            .in_r(input_pixel),.in_g(input_pixel),.in_b(input_pixel),
            .enable(next_source_mask[2]),.out_vs(out_vs),.out_de(out_de),
            .out_r(out_r),.out_g(out_g),.out_b(out_b),.active_curve(active_curve),
            .target_curve(target_curve),.stats_valid(stats_valid),.luma_sum(luma_sum),
            .pixel_count(pixel_count),.dark_count(dark_count),.highlight_count(highlight_count),
            .stats_curve(stats_curve),.stats_target(stats_target),.stats_enabled(stats_enabled));
    end else begin:g_manual
        assign out_vs=!pad_vs;
        assign out_de=pad_de;
        assign out_r=pad_pixel;assign out_g=pad_pixel;assign out_b=pad_pixel;
        assign stats_valid=0;assign stats_enabled=0;
        assign active_curve=3;assign target_curve=3;assign stats_curve=3;assign stats_target=3;
        assign luma_sum=0;assign pixel_count=0;assign dark_count=0;assign highlight_count=0;
    end endgenerate
    wire converted_vs,converted_de;
    wire [15:0] converted_pixel;
    rgb888_to_rgb565 convert (
        .clk(clk),.rstn(rstn),.vs_in(!out_vs),.de_in(out_de),
        .r_in(out_r),.g_in(out_g),.b_in(out_b),.vs_out(converted_vs),
        .active_out(),.wr_en(converted_de),.wr_data(converted_pixel));
    wire [2:0] geometry_mask=GAMMA ? source_mask : next_source_mask;
    wire sample_valid;
    wire [223:0] sample_data;
    gamma_telemetry telemetry (
        .clk(clk),.rstn(rstn),.stats_valid(stats_valid),.out_vs(out_vs),.out_de(out_de),
        .out_r(out_r),.out_g(out_g),.out_b(out_b),.luma_sum(luma_sum),.pixel_count(pixel_count),
        .dark_count(dark_count),.highlight_count(highlight_count),.stats_curve(stats_curve),
        .stats_target(stats_target),.frame_mask(source_mask),.stats_enabled(stats_enabled),
        .sample_valid(sample_valid),.sample_data(sample_data));
    integer expected_mask[0:31],raw_total[0:31],corrected_total[0:31];
    integer frame=-1,geometry_frame=-1,telemetry_checked=0,checked_pixels=0;
    integer frame_curve,frame_pixels=0,expected_pixel,index;
    reg out_vs_d=0,converted_vs_d=1;
    real exponent;
    always @(posedge clk) if(rstn) begin
        out_vs_d<=out_vs;converted_vs_d<=converted_vs;
        if(out_vs && !out_vs_d) begin
            frame=frame+1;frame_pixels=0;frame_curve=active_curve;
            corrected_total[frame]=0;
            if(GAMMA && source_mask!==3'(expected_mask[frame]))
                $fatal(1,"control and registered gamma SOF mismatch frame=%0d",frame);
        end
        if(out_de) begin
            case(frame_curve)
                0:exponent=0.50;1:exponent=0.65;2:exponent=0.80;3:exponent=1.00;
                4:exponent=1.25;5:exponent=1.55;default:exponent=1.90;
            endcase
            expected_pixel=(GAMMA && (expected_mask[frame]&4)) ?
                $rtoi(255.0*$pow((raw_total[frame]/16)/255.0,exponent)+0.5) : raw_total[frame]/16;
            if(out_r!==8'(expected_pixel) || out_g!==out_r || out_b!==out_r)
                $fatal(1,"frame gamma enable/pixel mismatch frame=%0d got=%0d expected=%0d",frame,out_r,expected_pixel);
            corrected_total[frame]=corrected_total[frame]+out_r;
            checked_pixels=checked_pixels+1;frame_pixels=frame_pixels+1;
        end
        if(!converted_vs && converted_vs_d) begin
            geometry_frame=geometry_frame+1;
            if(geometry_mask!==3'(expected_mask[geometry_frame]))
                $fatal(1,"geometry and gamma configuration differ frame=%0d got=%0d expected=%0d",
                    geometry_frame,geometry_mask,expected_mask[geometry_frame]);
        end
        if(sample_valid) begin
            index=sample_data[31:0];
            if(sample_data[63:32]!=raw_total[index] || sample_data[95:64]!=16 ||
               sample_data[191:160]!=corrected_total[index] ||
               sample_data[223:216]!=expected_mask[index] ||
               sample_data[215:208]!=((expected_mask[index]>>2)&1))
                $fatal(1,"telemetry and input configuration differ frame=%0d",index);
            telemetry_checked=telemetry_checked+1;
        end
    end
    task queue_mask(input [2:0] mask);
        begin
            wait(!busy);@(negedge sys_clk);command_mask=mask;command_valid=1;
            @(negedge sys_clk);command_valid=0;
            repeat(8) @(negedge clk);
        end
    endtask
    integer f;
    initial begin
        repeat(8) @(negedge clk);rstn=1;
        for(f=0;f<25;f=f+1) begin
            expected_mask[f]=(f==0) ? 7 : (f-1)%8;
            @(negedge clk);pad_pixel=(f<10) ? 32 : 224;
            raw_total[f]=16*pad_pixel;pad_vs=0;pad_de=1;
            @(negedge clk);pad_vs=1;
            repeat(15) @(negedge clk);pad_de=0;
            // No new SOF: pending commands must leave the current frame alone.
            queue_mask(3'(f%8));
            if(source_mask!==3'(expected_mask[f])) $fatal(1,"configuration changed mid-frame");
            repeat(20) @(negedge clk);
        end
        repeat(30) @(negedge clk);
        if(frame!=24 || geometry_frame!=24 || checked_pixels!=400 ||
           (GAMMA && telemetry_checked!=24)) $fatal(1,"frame/pixel/snapshot coverage");
        $display("PASS registered SOF control alignment: GAMMA=%0d, 25 frames, all 8 masks, first DE at SOF, pending commands, gamma oracle and geometry/telemetry identity",GAMMA);
        $finish;
    end
    initial begin #1000000;$fatal(1,"control alignment timeout");end
endmodule

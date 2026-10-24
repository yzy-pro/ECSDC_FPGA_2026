`timescale 1ns/1ps
module tb_gamma_telemetry;
    parameter COLOR=0;
    reg clk=0,rstn=0,in_vs=0,in_de=0,enable=1;
    always #3.367 clk=~clk;
    reg [7:0] in_r=0,in_g=0,in_b=0;
    reg [2:0] frame_mask=7;
    wire out_vs,out_de,stats_valid,stats_enabled;
    wire [7:0] out_r,out_g,out_b;
    wire [2:0] active_curve,target_curve,stats_curve,stats_target;
    wire [31:0] luma_sum,pixel_count,dark_count,highlight_count;
    wire sample_valid;
    wire [223:0] sample_data;
    adaptive_gamma_stream gamma(.*);
    gamma_telemetry telemetry(.*);
    wire mailbox_valid,mailbox_busy;
    wire [223:0] mailbox_data;
    reg sys_clk=0;
    always #10 sys_clk=~sys_clk;
    cdc_snapshot #(.WIDTH(224)) mailbox(
        .src_clk(clk),.dst_clk(sys_clk),.rstn(rstn),.src_valid(sample_valid),
        .src_data(sample_data),.src_busy(mailbox_busy),.dst_valid(mailbox_valid),.dst_data(mailbox_data));
    integer frames=0,checked=0,pixels=0,raw_total=0,out_total=0;
    integer raw_sums[0:31],out_sums[0:31],counts[0:31],masks[0:31],curves[0:31],enabled[0:31];
    reg vin_vs_d=0,vout_vs_d=0;
    integer out_frame=-1;
    function automatic integer gamma_pixel(input integer value,curve,input bit enabled);
        real exponent;
        begin
            case(curve)
                0:exponent=0.50;1:exponent=0.65;2:exponent=0.80;3:exponent=1.00;
                4:exponent=1.25;5:exponent=1.55;default:exponent=1.90;
            endcase
            gamma_pixel=enabled ? $rtoi(255.0*$pow(value/255.0,exponent)+0.5) : value;
        end
    endfunction
    integer expected_r,expected_g,expected_b;
    always @(posedge clk) if(rstn) begin
        vin_vs_d<=in_vs;vout_vs_d<=out_vs;
        if(in_vs && !vin_vs_d) begin
            if(frames>0) begin raw_sums[frames-1]=raw_total;counts[frames-1]=pixels;end
            frames=frames+1;raw_total=0;pixels=0;
        end
        if(in_de) begin
            raw_total=raw_total+((int'(in_r)+2*int'(in_g)+int'(in_b))>>2);pixels=pixels+1;
        end
        if(out_vs && !vout_vs_d) begin
            if(out_frame>=0) out_sums[out_frame]=out_total;
            out_frame=out_frame+1;out_total=0;
            masks[out_frame]=frame_mask;curves[out_frame]=active_curve;
            enabled[out_frame]=gamma.enable1;
        end
        if(out_de) begin
            expected_r=gamma_pixel(gamma.bypass_r,curves[out_frame],enabled[out_frame]);
            expected_g=gamma_pixel(gamma.bypass_g,curves[out_frame],enabled[out_frame]);
            expected_b=gamma_pixel(gamma.bypass_b,curves[out_frame],enabled[out_frame]);
            if(out_r!==8'(expected_r) || out_g!==8'(expected_g) || out_b!==8'(expected_b))
                $fatal(1,"Gamma pixel oracle");
            out_total=out_total+((expected_r+2*expected_g+expected_b)>>2);
        end
    end
    integer idx;
    always @(posedge sys_clk) if(rstn && mailbox_valid) begin
        idx=mailbox_data[31:0];
        if(mailbox_data[63:32]!==raw_sums[idx] || mailbox_data[95:64]!==counts[idx] ||
           mailbox_data[191:160]!==out_sums[idx])
            $fatal(1,"stats frame mismatch frame=%0d raw=%0d/%0d out=%0d/%0d pixels=%0d/%0d",idx,
                mailbox_data[63:32],raw_sums[idx],mailbox_data[191:160],out_sums[idx],mailbox_data[95:64],counts[idx]);
        if(mailbox_data[199:192]!=curves[idx] || mailbox_data[215:208]!=enabled[idx] ||
           mailbox_data[223:216]!=masks[idx]) $fatal(1,"frame metadata mismatch frame=%0d",idx);
        checked=checked+1;
    end
    integer f,p;
    initial begin
        repeat(5) @(negedge clk);rstn=1;
        for(f=0;f<17;f=f+1) begin
            frame_mask=f<12 ? 7 : 3;enable=f<12;
            in_r=f<6 ? 32 : f<12 ? 224 : 96;
            in_g=COLOR ? 8'(in_r+70) : in_r;in_b=COLOR ? 8'(255-in_r) : in_r;
            in_vs=1;in_de=1;
            @(negedge clk);in_vs=0;
            for(p=1;p<16;p=p+1) @(negedge clk);
            in_de=0;enable=~enable; // Mid-frame changes must not affect the frame.
            repeat(30) @(negedge clk);
        end
        repeat(30) @(negedge sys_clk);
        if(checked!=16) $fatal(1,"snapshot count %0d",checked);
        $display("PASS gamma telemetry: COLOR=%0d, independent RGB Gamma oracle, raw/output luma sums, prior-frame metadata, coherent CDC",COLOR);
        $finish;
    end
    initial begin #1000000;$fatal(1,"gamma telemetry timeout");end
endmodule

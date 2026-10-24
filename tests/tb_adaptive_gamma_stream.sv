`timescale 1ns/1ps
module tb_adaptive_gamma_stream;
    reg clk=0;always #3.367 clk=~clk;
    reg rstn=0,in_vs=0,in_de=0,enable=1;
    reg [7:0] in_r=0,in_g=0,in_b=0;
    wire out_vs,out_de,stats_valid;
    wire [7:0] out_r,out_g,out_b;
    wire [2:0] active_curve,target_curve;
    wire [31:0] luma_sum,pixel_count,dark_count,highlight_count;
    adaptive_gamma_stream dut(.stats_curve(),.stats_target(),.stats_enabled(),.*);
    reg lut_clk=0;
    reg [2:0] curve=0;
    reg [7:0] value=0;
    wire [7:0] result;
    adaptive_gamma_lut lut(.clk(lut_clk),.curve(curve),.value(value),.result(result));
    function automatic integer gamma(input integer c,v);
        real exponent;
        begin
            case(c)
                0:exponent=0.50;1:exponent=0.65;2:exponent=0.80;
                4:exponent=1.25;5:exponent=1.55;6:exponent=1.90;
                default:exponent=1.0;
            endcase
            gamma=$rtoi(255.0*((v/255.0)**exponent)+0.5);
        end
    endfunction
    reg evs=0,ede=0,eenable=0;
    reg [7:0] er=0,eg=0,eb=0;
    reg svs,sde,senable;
    reg [7:0] sr,sg,sb;
    reg old_vs=0,frame_enable=0,seen_frame=0;
    integer expected_sum=0,expected_count=0,expected_dark=0,expected_high=0;
    integer checked=0,stats_checked=0,old_curve=3,luma,expected_curve,frames=0;
    always @(posedge clk) begin
        if(!rstn) begin
            evs=0;ede=0;eenable=0;er=0;eg=0;eb=0;old_vs=0;seen_frame=0;
            expected_sum=0;expected_count=0;expected_dark=0;expected_high=0;old_curve=3;frame_enable=0;
        end else begin
            // Independent two-register RGB/DE/VS delay scoreboard.
            svs=evs;sde=ede;senable=eenable;sr=er;sg=eg;sb=eb;
            evs=in_vs;ede=in_de;eenable=enable;er=in_r;eg=in_g;eb=in_b;
            #1;
            if(out_vs!==svs || out_de!==sde) $fatal(1,"RGB/DE/VS cadence changed");
            if(svs&&!old_vs) begin
                frames=frames+1;frame_enable=senable;
                if(active_curve>old_curve+1 || old_curve>active_curve+1) $fatal(1,"gamma slew exceeded one step/frame");
                if(seen_frame && expected_count!=0) begin
                    if(!stats_valid || luma_sum!=expected_sum || pixel_count!=expected_count ||
                       dark_count!=expected_dark || highlight_count!=expected_high)
                        $fatal(1,"frame statistics mismatch sum=%0d expected=%0d count=%0d expected=%0d",luma_sum,expected_sum,pixel_count,expected_count);
                    stats_checked=stats_checked+1;
                end else if(stats_valid) $fatal(1,"empty/startup frame declared valid");
                seen_frame=1;expected_sum=0;expected_count=0;expected_dark=0;expected_high=0;
            end else begin
                if(active_curve!=old_curve) $fatal(1,"curve changed inside frame");
                if(stats_valid) $fatal(1,"statistics outside frame boundary");
            end
            old_curve=active_curve;old_vs=svs;
            if(sde) begin
                expected_curve=frame_enable ? active_curve : 3;
                if(out_r!==8'(gamma(expected_curve,sr)) || out_g!==8'(gamma(expected_curve,sg)) ||
                   out_b!==8'(gamma(expected_curve,sb)))
                    $fatal(1,"gamma/bypass pixel mismatch curve=%0d RGB=%0d/%0d/%0d output=%0d/%0d/%0d",expected_curve,sr,sg,sb,out_r,out_g,out_b);
                checked=checked+1;
                if(seen_frame) begin
                    luma=(sr+2*sg+sb)/4;expected_sum=expected_sum+luma;expected_count=expected_count+1;
                    if(luma<48)expected_dark=expected_dark+1;
                    if(luma>=208)expected_high=expected_high+1;
                end
            end
        end
    end
    task automatic frame(input integer scene,frame_enable_in,blank_cycles);
        integer p,v;
        begin
            for(p=0;p<256;p=p+1) begin
                @(negedge clk);
                in_vs=p<3;in_de=1;enable=frame_enable_in;
                case(scene)
                    0:v=16;      // night, gamma .5
                    1:v=224;     // strong light, gamma 1.9
                    2:v=p%2 ? 224 : 32; // mixed shadows+highlights
                    3:v=128;     // neutral
                    4:v=p;       // complete range
                    5:v=111;     // below threshold, alternating scene test
                    6:v=112;     // above threshold
                    default:v=0;
                endcase
                in_r=v;in_g=v;in_b=v;
                // Preserve current frame's captured enable despite changes.
                if(scene==4 && p>=128)enable=!frame_enable_in;
                if(scene==4) begin in_g=255-p;in_b=(p*13)%256;end
            end
            @(negedge clk);in_vs=0;in_de=0;enable=frame_enable_in;
            repeat(blank_cycles) @(negedge clk);
        end
    endtask
    task automatic settle(input integer scene,expected_target);
        integer k;
        begin
            for(k=0;k<9;k=k+1)frame(scene,1,k%3);
            repeat(4)@(negedge clk);
            if(active_curve!=expected_target || target_curve!=expected_target)
                $fatal(1,"scene %0d failed adaptation curve=%0d target=%0d expected=%0d",scene,active_curve,target_curve,expected_target);
            $display("SCENE scene=%0d active=%0d target=%0d",scene,active_curve,target_curve);
        end
    endtask
    integer c,v,previous,k;
    initial begin
        // Exhaustively check every ROM entry against the mathematical power,
        // monotonicity, endpoints and safe identity curve7.
        for(c=0;c<8;c=c+1) begin
            previous=-1;
            for(v=0;v<256;v=v+1)begin
                curve=c;value=v;#1;lut_clk=1;#1;
                if(result!=gamma(c,v) || int'(result)<previous) $fatal(1,"gamma ROM mismatch curve=%0d value=%0d got=%0d expected=%0d",c,v,result,gamma(c,v));
                if((v==0&&result!=0)||(v==255&&result!=255)) $fatal(1,"gamma endpoint clipped");
                previous=result;lut_clk=0;
            end
        end
        repeat(3)@(negedge clk);rstn=1;
        // Active pixels before the first VS must not contaminate frame stats.
        in_de=1;in_r=255;in_g=255;in_b=255;repeat(5)@(negedge clk);in_de=0;
        settle(0,0);settle(1,6);settle(2,2);settle(3,3);
        // Alternating classifications never pass two-frame hysteresis.
        for(k=0;k<12;k=k+1) frame(k%2 ? 6 : 5,1,2);
        repeat(4)@(negedge clk);
        if(target_curve!=3 || active_curve!=3) $fatal(1,"threshold flicker defeated hysteresis");
        // All curves exercise independent RGB channels, endpoint preservation,
        // enable changes inside a frame and bypass with identical cadence.
        settle(0,0);frame(4,1,0);frame(4,0,0);frame(4,1,0);
        // Zero-pixel VS epochs publish no valid statistics or false decision.
        @(negedge clk);in_vs=1;in_de=0;repeat(3)@(negedge clk);in_vs=0;
        repeat(8)@(negedge clk);in_vs=1;repeat(3)@(negedge clk);in_vs=0;
        repeat(8)@(negedge clk);
        if(checked<10000 || stats_checked<40) $fatal(1,"insufficient coverage");
        $display("PASS adaptive gamma: all2048 LUT entries, night/strong/mixedlight adaptation, neutral, hysteresis, atomic enable/curve, DE/VS two-stage cadence, exact frame stats; pixels=%0d stats=%0d",checked,stats_checked);
        $finish;
    end
    initial begin #2000000;$fatal(1,"timeout");end
endmodule

`timescale 1ns/1ps
module tb_pose_renderer_dma;
    parameter integer INTERPOLATION_MODE=0;
    parameter integer CACHE_INDEX_BITS=10;
    parameter integer RECIPROCAL_LUT_ENABLE=0;
    parameter integer WIDTH=64, HEIGHT=4, FULL_FRAME_RUN=0;
    localparam integer PIXELS=WIDTH*HEIGHT;
    reg clk=0;
    always #5 clk=~clk;
    reg rstn=0,start=0;
    reg [1:0] source_bank=0,render_bank=2;
    reg signed [15:0] yaw=0,pitch=0;
    wire busy,done,error,pose_clamped;
    wire [1:0] completed_bank;
    wire rd_cmd_valid,wr_cmd_valid,wr_data_valid;
    wire [27:0] rd_cmd_addr,wr_cmd_addr;
    wire [255:0] wr_data;
    reg rd_cmd_ready=0,wr_ready=0,rd_data_valid=0,rd_data_last=0,wr_done=0;
    reg [255:0] rd_data=0;
    pose_renderer_dma #(.OUTPUT_H_NUM(WIDTH),.OUTPUT_V_NUM(HEIGHT),
        .INTERPOLATION_MODE(INTERPOLATION_MODE),.CACHE_INDEX_BITS(CACHE_INDEX_BITS),
        .RECIPROCAL_LUT_ENABLE(RECIPROCAL_LUT_ENABLE)) dut (
        .clk(clk),.rstn(rstn),.start(start),.source_bank(source_bank),
        .render_bank(render_bank),.yaw_q2048(yaw),.pitch_q2048(pitch),
        .busy(busy),.done(done),.error(error),.pose_clamped(pose_clamped),
        .completed_bank(completed_bank),.rd_cmd_valid(rd_cmd_valid),
        .rd_cmd_ready(rd_cmd_ready),.rd_cmd_addr(rd_cmd_addr),
        .rd_data_valid(rd_data_valid),.rd_data(rd_data),.rd_data_last(rd_data_last),
        .wr_cmd_valid(wr_cmd_valid),.wr_cmd_ready(wr_ready),.wr_cmd_addr(wr_cmd_addr),
        .wr_data_valid(wr_data_valid),.wr_data_ready(wr_ready),.wr_data(wr_data),.wr_done(wr_done)
    );

    // A second actual projector receives an independently counted raster
    // and immutable expected pose. This catches lost/reordered coordinates
    // and live-pose use while the standalone projector test checks geometry.
    reg reference_pose_load=0;
    reg signed [15:0] expected_yaw=0,expected_pitch=0;
    integer input_count=0,result_count=0;
    wire [10:0] reference_x=input_count%WIDTH;
    wire [10:0] reference_y=input_count/WIDTH;
    wire reference_valid,reference_map;
    wire signed [31:0] reference_u,reference_v;
    pose_inverse_project_q14 reference_projector (
        .clk(clk),.rstn(rstn),.pose_load(reference_pose_load),
        .pose_yaw_q2048(expected_yaw),.pose_pitch_q2048(expected_pitch),.pose_clamped(),.pose_ready(),
        .in_valid(dut.u_projector.in_valid),.dst_x(reference_x),.dst_y(reference_y),
        .out_valid(reference_valid),.map_valid(reference_map),
        .src_x_q14(reference_u),.src_y_q14(reference_v)
    );
    reg [15:0] expected_pixels [0:PIXELS-1];
    reg [1:0] expected_source,expected_render;
    integer expected_black=0,expected_color=0;
    function automatic [15:0] source_pixel(input integer bank,x,y);
        integer r,g,b;
        begin
            r=(x+3*y+bank)&31;
            g=(5*x+y+bank)&63;
            b=(x^y^(bank*7))&31;
            source_pixel={r[4:0],g[5:0],b[4:0]};
        end
    endfunction
    function automatic [15:0] reference_sample(input integer bank,u,v);
        integer x,y,fx,fy,wx,wy,r,g,b;
        reg [15:0] a,bp,c,d;
        begin
            if (INTERPOLATION_MODE==1) reference_sample=source_pixel(bank,(u+8192)>>14,(v+8192)>>14);
            else begin
                x=u>>14; y=v>>14; fx=(u&16383)>>9; fy=(v&16383)>>9;
                wx=32-fx; wy=32-fy;
                a=source_pixel(bank,x,y); bp=source_pixel(bank,x+1,y);
                c=source_pixel(bank,x,y+1); d=source_pixel(bank,x+1,y+1);
                r=(a[15:11]*wx*wy+bp[15:11]*fx*wy+c[15:11]*wx*fy+d[15:11]*fx*fy+512)/1024;
                g=(a[10:5]*wx*wy+bp[10:5]*fx*wy+c[10:5]*wx*fy+d[10:5]*fx*fy+512)/1024;
                b=(a[4:0]*wx*wy+bp[4:0]*fx*wy+c[4:0]*wx*fy+d[4:0]*fx*fy+512)/1024;
                reference_sample={r[4:0],g[5:0],b[4:0]};
            end
        end
    endfunction
    always @(posedge clk) if (rstn) begin
        if (dut.u_projector.in_valid) begin
            if (dut.u_projector.dst_x!==reference_x || dut.u_projector.dst_y!==reference_y)
                $fatal(1,"projection raster skipped/repeated coordinate");
            input_count<=input_count+1;
        end
        if (reference_valid) begin
            if (result_count>=PIXELS) $fatal(1,"extra projector result");
            expected_pixels[result_count]=reference_map ?
                reference_sample(expected_source,reference_u,reference_v) : 16'd0;
            result_count=result_count+1;
            if (reference_map) expected_color=expected_color+1;
            else expected_black=expected_black+1;
        end
    end

    integer cycle=0,read_delay=0,write_delay=0;
    integer read_requests=0,write_requests=0,write_completions=0;
    integer row,word_index,lane,pixel_index,local_address;
    reg read_pending=0,write_pending=0,inject_bad_last=0;
    reg [27:0] pending_read_addr;
    reg rd_stalled=0,wr_stalled=0;
    reg [27:0] stalled_read_addr,stalled_write_addr;
    reg [255:0] stalled_write_data;
    // Change memory response signals away from the accepting edge.
    always @(negedge clk) begin
        cycle=cycle+1;
        rd_cmd_ready=(!read_pending && (cycle%4!=0));
        wr_ready=(!write_pending && (cycle%5==0));
        rd_data_valid=0; rd_data_last=0; wr_done=0;
        if (read_pending) begin
            if (read_delay==0) begin
                local_address=pending_read_addr-(expected_source<<22);
                row=local_address/960; word_index=(local_address%960)/8;
                for(lane=0;lane<16;lane=lane+1)
                    rd_data[lane*16 +:16]=source_pixel(expected_source,word_index*16+lane,row);
                rd_data_valid=1; rd_data_last=!inject_bad_last; read_pending=0;
            end else read_delay=read_delay-1;
        end
        if (write_pending) begin
            if (write_delay==0) begin
                wr_done=1; write_pending=0; write_completions=write_completions+1;
            end else write_delay=write_delay-1;
        end
    end
    always @(posedge clk) if (rstn) begin
        if (rd_stalled && (!rd_cmd_valid || rd_cmd_addr!==stalled_read_addr))
            $fatal(1,"read command changed under backpressure");
        if (wr_stalled && (!wr_cmd_valid || !wr_data_valid || wr_cmd_addr!==stalled_write_addr || wr_data!==stalled_write_data))
            $fatal(1,"write command/data changed under backpressure");
        rd_stalled=rd_cmd_valid&&!rd_cmd_ready;
        wr_stalled=wr_cmd_valid&&!wr_ready;
        stalled_read_addr=rd_cmd_addr; stalled_write_addr=wr_cmd_addr; stalled_write_data=wr_data;
        if (rd_cmd_valid&&rd_cmd_ready) begin
            if (read_pending) $fatal(1,"multiple outstanding source reads");
            if (rd_cmd_addr[23:22]!==expected_source || rd_cmd_addr[2:0]!==0)
                $fatal(1,"source bank or source-word alignment changed");
            pending_read_addr=rd_cmd_addr; read_delay=3+(cycle%6);
            read_pending=1; read_requests=read_requests+1;
        end
        if (wr_cmd_valid&&wr_ready) begin
            if (!wr_data_valid || write_pending) $fatal(1,"non-atomic write request");
            row=write_requests/(WIDTH/16); word_index=write_requests%(WIDTH/16);
            if (wr_cmd_addr!==((expected_render<<22)+row*960+word_index*8))
                $fatal(1,"destination word address mismatch");
            for(lane=0;lane<16;lane=lane+1) begin
                pixel_index=write_requests*16+lane;
                if(pixel_index>=result_count || wr_data[lane*16 +:16]!==expected_pixels[pixel_index])
                    $fatal(1,"pixel %0d mismatch got=%h expected=%h",pixel_index,wr_data[lane*16 +:16],expected_pixels[pixel_index]);
            end
            write_requests=write_requests+1; write_delay=4+(cycle%7); write_pending=1;
            if (FULL_FRAME_RUN && (write_requests%(WIDTH/16*108)==0))
                $display("PROGRESS full frame: completed_rows=%0d clocks=%0d",write_requests/(WIDTH/16),cycle-frame_start_cycle);
        end
        if (done && (write_completions!=PIXELS/16 || completed_bank!==expected_render))
            $fatal(1,"frame published before final DDR write completion");
    end

    integer total_black=0,total_color=0;
    integer frame_start_cycle;
    task automatic render_case(input integer yy,pp,bank);
        begin
            @(negedge clk);
            input_count=0; result_count=0; expected_black=0; expected_color=0;
            write_requests=0; write_completions=0; read_requests=0;
            expected_yaw=yy; expected_pitch=pp; expected_source=bank; expected_render=bank+2;
            source_bank=bank; render_bank=bank+2; yaw=yy; pitch=pp; reference_pose_load=1;
            repeat(2) @(negedge clk);
            reference_pose_load=0; start=1; frame_start_cycle=cycle;
            @(negedge clk); start=0;
            repeat(5) @(negedge clk);
            // Input changes mid-frame must never alter pose or either bank.
            yaw=-yy+333; pitch=-pp+555; source_bank=bank^1; render_bank=(bank^1)+2;
            wait(done); @(negedge clk);
            if(error || input_count!=PIXELS || result_count!=PIXELS || write_requests!=PIXELS/16)
                $fatal(1,"incomplete rendered frame");
            if(expected_color>32 && read_requests>=expected_color)
                $fatal(1,"word cache did not reuse adjacent samples");
            total_black=total_black+expected_black; total_color=total_color+expected_color;
            $display("case yaw=%0d pitch=%0d mode=%0d valid=%0d black=%0d source reads=%0d",yy,pp,INTERPOLATION_MODE,expected_color,expected_black,read_requests);
            if (FULL_FRAME_RUN)
                $display("MEASURE full frame: clocks=%0d source_reads=%0d destination_writes=%0d at_model_100MHz_ms=%0f",cycle-frame_start_cycle,read_requests,write_requests,(cycle-frame_start_cycle)/100000.0);
            repeat(3) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rstn=1;
        if (FULL_FRAME_RUN) begin
            render_case(1072,-715,0);
            if(total_black==0 || total_color==0) $fatal(1,"full frame did not exercise both mapping outcomes");
            $display("PASS full1080p renderer DMA: %0d pixels checked, pose +30/-20 degrees, source sampling, black borders, command stalls and completed DDR writes",PIXELS);
            $finish;
        end
        render_case(0,0,0);
        render_case(1072,-1072,1);
        render_case(-1072,1072,0);
        render_case(1072,1072,1);
        if(total_black==0 || total_color==0) $fatal(1,"test did not exercise both mapping outcomes");
        // A malformed single-beat return must hold ownership and prevent
        // publication rather than turn an incomplete frame into display data.
        input_count=0; result_count=0; write_requests=0; write_completions=0;
        expected_source=0; expected_render=2; expected_yaw=0; expected_pitch=0;
        source_bank=0; render_bank=2; yaw=0; pitch=0; reference_pose_load=1;
        repeat(2) @(negedge clk); reference_pose_load=0; inject_bad_last=1; start=1;
        @(negedge clk); start=0;
        wait(error); repeat(20) @(negedge clk);
        if (!busy || done || write_requests!=0) $fatal(1,"malformed read published a frame or released ownership");
        $display("PASS pose renderer DMA mode=%0d: real +/-30 degree projection, pose/bank snapshot, source cache, RGB565 packing, black borders, stalled commands, delayed final write and malformed-return hold",INTERPOLATION_MODE);
        $finish;
    end
    initial begin
        if (FULL_FRAME_RUN) #2000000000;
        else #20000000;
        $fatal(1,"renderer timeout");
    end
endmodule

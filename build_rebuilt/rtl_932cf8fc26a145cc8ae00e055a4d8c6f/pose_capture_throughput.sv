`timescale 1ns/1ps

// Capture-rate regression: 148.5 MHz pixels, 1920 active + 280 blank clocks
// per line, 100 MHz DDR, and 18 controller clocks before each write burst.
// Thirty-two full-width lines cover repeated burst service/queue occupancy.
// This verifies capture bandwidth; it makes no renderer frame-rate claim.
module tb_pose_capture_throughput;
    localparam H=1920,V=32,PIXELS=H*V,WORDS=PIXELS/16;
    reg ddr_clk=0,vin_clk=0,vout_clk=0,ddr_rstn=0;
    always #5 ddr_clk=~ddr_clk;
    always #3.367 vin_clk=~vin_clk;
    initial begin #1; forever #3.367 vout_clk=~vout_clk; end
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
    fram_buf_pose #(.H_NUM(H),.V_NUM(V)) dut (.*);

    reg write_pending=0;
    integer delay_cycles=0,remaining=0,received_words=0,burst_count=0;
    integer peak_fifo_words=0,lane;
    always @(negedge ddr_clk) begin
        // This fixture measures capture only; hold subsequent renderer writes.
        axi_awready=ddr_rstn && !write_pending && axi_awid==0;
        axi_wready=0; axi_wlast=0;
        if (write_pending) begin
            if (delay_cycles>0) delay_cycles=delay_cycles-1;
            else begin axi_wready=1; axi_wlast=remaining==1; end
        end
    end
    always @(posedge ddr_clk) if (ddr_rstn) begin
        if (dut.cap_rd_count>peak_fifo_words) peak_fifo_words=dut.cap_rd_count;
        if (protocol_error || rejected_captures!=0)
            $fatal(1,"full-rate capture rejected/faulted");
        if (axi_awvalid && axi_awready) begin
            if (write_pending || axi_awlen!=15 || axi_awaddr!=received_words*8 || axi_awid!=0)
                $fatal(1,"capture did not issue correctly ordered 16-beat bursts");
            write_pending=1; remaining=16; delay_cycles=18;
            burst_count=burst_count+1;
        end
        if (axi_wready) begin
            if (!write_pending || axi_wlast!=(remaining==1))
                $fatal(1,"capture burst final-beat mismatch");
            for (lane=0;lane<16;lane=lane+1)
                if (axi_wdata[lane*16+:16]!==((received_words*16+lane)^16'h5a39))
                    $fatal(1,"full-rate capture pixel lost/reordered word=%0d lane=%0d",received_words,lane);
            received_words=received_words+1; remaining=remaining-1;
            if (remaining==0) write_pending=0;
        end
    end
    always @(posedge vin_clk) if (ddr_rstn && dut.capture_fifo_valid && !dut.capture_fifo_ready)
        $fatal(1,"capture FIFO overflowed at 148.5 MHz pixel input");

    integer x,y;
    initial begin
        repeat (5) @(negedge ddr_clk);
        ddr_rstn=1;
        repeat (25) @(negedge vin_clk);
        wr_fsync=1;
        repeat (4) @(negedge vin_clk);
        wr_fsync=0;
        repeat (20) @(negedge vin_clk);
        for (y=0;y<V;y=y+1) begin
            for (x=0;x<H;x=x+1) begin
                wr_en=1; wr_data=(y*H+x)^16'h5a39;
                @(negedge vin_clk);
            end
            wr_en=0;
            repeat (280) @(negedge vin_clk);
        end
        wait (captured_frames==1);
        if (received_words!=WORDS || burst_count!=WORDS/16 || rejected_captures!=0 ||
            dut.capture_failed || peak_fifo_words>=512)
            $fatal(1,"capture completion/rate accounting incorrect");
        $display("PASS capture throughput: 148.5 MHz input, 1920x32 active, 100 MHz DDR, 18-cycle overhead + 16-beat bursts, %0d ordered pixels, peak FIFO %0d/512 words",PIXELS,peak_fifo_words);
        $finish;
    end
    initial begin #2000000; $fatal(1,"capture throughput timeout"); end
endmodule

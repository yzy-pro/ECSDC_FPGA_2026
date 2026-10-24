`timescale 1ns/1ps
// Complete-frame pose path. Tiled mode alternates source slots 0/3, while
// output slots 1/2 alternate display/render ownership. Capture of the next
// source overlaps rendering; a ready source waits without overwriting either
// owned frame. Legacy mode retains the serial single-source renderer.
// DDR addresses use 32-bit units (8 per 256-bit beat), as the board IP expects.
module fram_buf_pose #(
    parameter ADDR_WIDTH=28, H_NUM=1920, V_NUM=1080,
    parameter FIFO_BITS=9, CACHE_INDEX_BITS=10, CACHE_LINE_WORDS=1, INTERPOLATION_MODE=1,
    parameter RECIPROCAL_LUT_ENABLE=0,
    parameter TILED_ENABLE=0,
    parameter RUNTIME_CONTROL=0,
    parameter signed [31:0] FX_Q14=32'sd12262554,
    parameter signed [31:0] FY_Q14=32'sd12256498,
    parameter signed [31:0] CX_Q14=32'sd15481296,
    parameter signed [31:0] CY_Q14=32'sd8558941,
    parameter signed [17:0] K1_Q14=18'sd162,
    parameter signed [17:0] K2_Q14=-18'sd711,
    parameter signed [17:0] P1_Q14=18'sd0, P2_Q14=18'sd0
) (
    input ddr_clk, ddr_rstn, vin_clk, wr_fsync, wr_en,
    input [15:0] wr_data,
    input vout_clk, rd_fsync, rd_en,
    // Coherent attitude mailbox already synchronized into vin_clk.
    input signed [15:0] imu_yaw, imu_pitch,
    // Held from input SOF through source-frame completion and dispatch.
    input lens_enable,
    output vout_de, output reg [15:0] vout_data,
    output reg init_done,
    output [ADDR_WIDTH-1:0] axi_awaddr,
    output [3:0] axi_awid, axi_awlen,
    output axi_awvalid, input axi_awready,
    output [255:0] axi_wdata, output [31:0] axi_wstrb,
    input axi_wready, axi_wlast,
    output [ADDR_WIDTH-1:0] axi_araddr,
    output [3:0] axi_arid, axi_arlen,
    output axi_arvalid, input axi_arready,
    input [255:0] axi_rdata, input axi_rvalid, axi_rlast,
    input [3:0] axi_rid,
    output reg [31:0] captured_frames, rendered_frames, displayed_frames,
    output reg [31:0] rejected_captures,
    output reg display_underrun,
    output pose_clamped, protocol_error
);
    localparam WORDS=H_NUM*V_NUM/16;
    localparam PIXELS=H_NUM*V_NUM;
    localparam FAST=TILED_ENABLE && INTERPOLATION_MODE==1;
    localparam C_REQUEST=0,C_CAPTURE=1,C_RENDER=2,C_PUBLISH=3;
    reg [1:0] control_state;
    reg capture_request;
    reg [1:0] capture_bank,renderer_source_bank;
    reg signed [15:0] renderer_yaw,renderer_pitch;
    reg capture_lens_enable,renderer_lens_enable;
    reg [1:0] vin_reset, out_reset;
    always @(posedge vin_clk or negedge ddr_rstn)
        if(!ddr_rstn) vin_reset<=0; else vin_reset<={vin_reset[0],1'b1};
    always @(posedge vout_clk or negedge ddr_rstn)
        if(!ddr_rstn) out_reset<=0; else out_reset<={out_reset[0],1'b1};

    // A toggle requests exactly one source frame. Completion is sent only
    // after the last pixel; its status remains stable until the next request.
    reg [1:0] capture_req_sync;
    reg capture_req_seen, capture_active, capture_complete, capture_failed;
    reg capture_finish_pending;
    reg signed [15:0] capture_yaw, capture_pitch;
    reg wr_fs_d;
    reg [21:0] capture_pixels;
    reg [255:0] capture_pack, capture_fifo_data;
    reg capture_fifo_valid;
    wire capture_fifo_ready;
    always @(posedge vin_clk or negedge ddr_rstn) begin
        if(!ddr_rstn) begin
            capture_req_sync<=0; capture_req_seen<=0; capture_active<=0;
            capture_complete<=0; capture_failed<=0; wr_fs_d<=0;
            capture_finish_pending<=0;
            capture_yaw<=0; capture_pitch<=0;
            capture_lens_enable<=1;
            capture_pixels<=0; capture_pack<=0; capture_fifo_data<=0;
            capture_fifo_valid<=0;
        end else if(vin_reset[1]) begin
            capture_req_sync<={capture_req_sync[0],capture_request};
            wr_fs_d<=wr_fsync;
            capture_fifo_valid<=0;
            if(capture_fifo_valid && !capture_fifo_ready) capture_failed<=1;
            if(capture_finish_pending) begin
                // Publish only on/after the last FIFO acceptance attempt.
                capture_complete<=capture_req_seen; capture_finish_pending<=0;
            end
            if(wr_fsync && !wr_fs_d) begin
                if(capture_active) begin
                    // Malformed/short input frame: drain, discard and retry.
                    capture_active<=0; capture_failed<=1;
                    capture_complete<=capture_req_seen;
                end else if(capture_req_sync[1]!=capture_req_seen) begin
                    capture_req_seen<=capture_req_sync[1]; capture_active<=1;
                    capture_pixels<=0; capture_failed<=0; capture_pack<=0;
                    capture_yaw<=imu_yaw; capture_pitch<=imu_pitch;
                    capture_lens_enable<=!RUNTIME_CONTROL || lens_enable;
                end
            end
            if(capture_active && wr_en && !(wr_fsync && !wr_fs_d)) begin
                capture_pack[capture_pixels[3:0]*16 +: 16]<=wr_data;
                if(capture_pixels[3:0]==15) begin
                    capture_fifo_data<={wr_data,capture_pack[239:0]};
                    capture_fifo_valid<=1;
                end
                if(capture_pixels==PIXELS-1) begin
                    capture_active<=0; capture_finish_pending<=1;
                end else capture_pixels<=capture_pixels+1'b1;
            end
        end
    end
    wire cap_fifo_valid, cap_fifo_ready;
    wire [255:0] cap_fifo_data;
    wire [FIFO_BITS:0] cap_rd_count;
    pose_async_fifo #(.WIDTH(256),.ADDR_BITS(FIFO_BITS)) u_capture_fifo (
        .rstn(ddr_rstn),.wr_clk(vin_clk),.wr_valid(capture_fifo_valid),
        .wr_ready(capture_fifo_ready),.wr_data(capture_fifo_data),.wr_free(),
        .rd_clk(ddr_clk),.rd_valid(cap_fifo_valid),.rd_ready(cap_fifo_ready),
        .rd_data(cap_fifo_data),.rd_count(cap_rd_count)
    );
    reg [2:0] cap_done_sync, cap_bad_sync;
    reg [31:0] cap_words;
    reg cap_inflight;
    reg [3:0] cap_settle;
    wire [4095:0] capture_burst;
    wire [255:0] capture_beat,render_write_beat;
    wire [3:0] write_beat_index;
    reg [4:0] capture_burst_count, capture_sent_len;
    wire cap_w_ready,cap_w_done;
    wire capture_tail=cap_done_sync[2]==capture_request && cap_settle==8 &&
                      !cap_fifo_valid && cap_rd_count==0;
    wire cap_w_valid=control_state==C_CAPTURE && !cap_inflight &&
        (capture_burst_count==16 || (capture_tail && capture_burst_count!=0));
    assign cap_fifo_ready=control_state==C_CAPTURE && capture_burst_count<16 &&
        (!FAST || !cap_inflight);
    generate if(FAST) begin : g_capture_write_ram
        reg [255:0] burst_mem[0:15] /* synthesis syn_ramstyle="lut_ram" */;
        always @(posedge ddr_clk)
            if(ddr_rstn && cap_fifo_valid && cap_fifo_ready)
                burst_mem[capture_burst_count[3:0]]<=cap_fifo_data;
        assign capture_beat=burst_mem[write_beat_index];
        assign capture_burst=4096'd0;
    end else begin : g_capture_write_registers
        reg [4095:0] burst_q;
        always @(posedge ddr_clk or negedge ddr_rstn)
            if(!ddr_rstn) burst_q<=0;
            else if(cap_fifo_valid && cap_fifo_ready)
                burst_q[capture_burst_count*256 +:256]<=cap_fifo_data;
        assign capture_burst=burst_q;
        assign capture_beat=256'd0;
    end endgenerate
    wire [ADDR_WIDTH-1:0] capture_base={{(ADDR_WIDTH-24){1'b0}},capture_bank,22'd0};
    wire [ADDR_WIDTH-1:0] cap_addr=capture_base+cap_words*8;

    // Display requests an epoch at VS. The pixel side drains every old word;
    // DDR acknowledges only after both outstanding reads and the FIFO empty.
    // New reads start after acknowledgment, so no old frame can alias a VS.
    reg display_request, rd_fs_d;
    reg [1:0] display_ack_sync;
    reg display_flush;
    reg display_accept_epoch;
    reg [1:0] display_accept_sync;
    reg [1:0] display_req_sync;
    reg display_epoch;
    reg [1:0] display_bank, render_bank;
    reg display_valid, pending_valid;
    reg [31:0] display_words;
    reg display_inflight;
    wire display_r_ready,display_r_done,display_data_valid;
    wire [255:0] display_data;
    wire [FIFO_BITS:0] display_free;
    wire display_fifo_ready;
    wire [4:0] display_len=(WORDS-display_words>=16) ? 5'd16 : WORDS-display_words;
    wire display_boundary=display_req_sync[1]!=display_epoch;
    wire display_r_valid=display_valid && !display_boundary && !display_inflight &&
                         display_accept_sync[1]==display_epoch &&
                         display_words<WORDS && display_free>=display_len;
    wire [ADDR_WIDTH-1:0] display_base={{(ADDR_WIDTH-24){1'b0}},display_bank,22'd0};
    wire [ADDR_WIDTH-1:0] display_addr=display_base+display_words*8;
    wire out_fifo_valid,out_fifo_ready;
    wire [255:0] out_fifo_data;
    pose_async_fifo #(.WIDTH(256),.ADDR_BITS(FIFO_BITS)) u_display_fifo (
        .rstn(ddr_rstn),.wr_clk(ddr_clk),.wr_valid(display_data_valid),
        .wr_ready(display_fifo_ready),.wr_data(display_data),
        .wr_free(display_free),.rd_clk(vout_clk),.rd_valid(out_fifo_valid),
        .rd_ready(out_fifo_ready),.rd_data(out_fifo_data),.rd_count()
    );
    reg [3:0] display_lane;
    reg display_bad;
    reg [15:0] pixel_d;
    reg [1:0] de_pipe;
    assign out_fifo_ready=out_fifo_valid &&
        (display_flush || display_bad || (rd_en && display_lane==15));
    assign vout_de=de_pipe[1];
    always @(posedge vout_clk or negedge ddr_rstn) begin
        if(!ddr_rstn) begin
            display_request<=0; rd_fs_d<=0; display_lane<=0;
            display_ack_sync<=0; display_flush<=0; display_accept_epoch<=0;
            display_bad<=0; display_underrun<=0; pixel_d<=0; vout_data<=0; de_pipe<=0;
        end else if(out_reset[1]) begin
            rd_fs_d<=rd_fsync;
            display_ack_sync<={display_ack_sync[0],display_epoch};
            if(display_flush && display_ack_sync[1]==display_request) begin
                display_flush<=0; display_accept_epoch<=display_request;
            end
            de_pipe<={de_pipe[0],rd_en};
            pixel_d<=0; vout_data<=pixel_d;
            if(rd_fsync && !rd_fs_d) begin
                if(display_ack_sync[1]==display_request && !display_flush) begin
                    display_request<=~display_request; display_flush<=1;
                    display_bad<=0;
                end else display_bad<=1;
                display_lane<=0;
            end else if(rd_en) begin
                if(!display_bad && !display_flush && out_fifo_valid) begin
                    pixel_d<=out_fifo_data[display_lane*16 +: 16];
                    display_lane<=display_lane+1'b1;
                end else begin
                    // Never shift late pixels horizontally after starvation.
                    display_bad<=1; display_underrun<=1;
                end
            end
        end
    end

    wire renderer_busy, renderer_done, renderer_error;
    reg renderer_start;
    wire render_rd_valid,render_rd_ready,render_data_valid,render_rd_done;
    wire [4:0] render_rd_len;
    wire [ADDR_WIDTH-1:0] render_rd_addr,render_wr_addr;
    wire [255:0] render_read_data,render_write_data;
    wire [4095:0] render_write_burst;
    wire [4:0] render_write_len;
    wire render_wr_valid,render_wr_ready,render_wr_done;
    generate if(FAST) begin : g_tiled
    pose_renderer_tiled #(
        .ADDR_WIDTH(ADDR_WIDTH),.H_NUM(H_NUM),.V_NUM(V_NUM),
        .SHARED_WRITE_PAYLOAD(1),
        .RUNTIME_CONTROL(RUNTIME_CONTROL),
        .RECIPROCAL_LUT_ENABLE(RECIPROCAL_LUT_ENABLE),
        .FX_Q14(FX_Q14),.FY_Q14(FY_Q14),.CX_Q14(CX_Q14),.CY_Q14(CY_Q14),
        .K1_Q14(K1_Q14),.K2_Q14(K2_Q14),.P1_Q14(P1_Q14),.P2_Q14(P2_Q14)
    ) u_renderer (
        .clk(ddr_clk),.rstn(ddr_rstn),.start(renderer_start),
        .lens_enable(renderer_lens_enable),
        .source_bank(renderer_source_bank),.render_bank(render_bank),
        .yaw_q2048(renderer_yaw),.pitch_q2048(renderer_pitch),
        .busy(renderer_busy),.done(renderer_done),.error(renderer_error),
        .pose_clamped(pose_clamped),.completed_bank(),
        .rd_cmd_valid(render_rd_valid),.rd_cmd_ready(render_rd_ready),
        .rd_cmd_addr(render_rd_addr),.rd_cmd_len(render_rd_len),
        .rd_data_valid(render_data_valid),.rd_data(render_read_data),.rd_data_last(render_rd_done),
        .wr_cmd_valid(render_wr_valid),.wr_cmd_ready(render_wr_ready),
        .wr_cmd_addr(render_wr_addr),.wr_cmd_len(render_write_len),
        .wr_data(render_write_burst),.wr_done(render_wr_done),
        .wr_beat_index(write_beat_index),.wr_beat(render_write_beat)
    );
    assign render_write_data=render_write_burst[255:0];
    end else begin : g_serial
    pose_renderer_dma #(
        .ADDR_WIDTH(ADDR_WIDTH),.H_NUM(H_NUM),.V_NUM(V_NUM),.INTERPOLATION_MODE(INTERPOLATION_MODE),
        .CACHE_INDEX_BITS(CACHE_INDEX_BITS),
        .CACHE_LINE_WORDS(CACHE_LINE_WORDS),
        .RECIPROCAL_LUT_ENABLE(RECIPROCAL_LUT_ENABLE),
        .FX_Q14(FX_Q14),.FY_Q14(FY_Q14),.CX_Q14(CX_Q14),.CY_Q14(CY_Q14),
        .K1_Q14(K1_Q14),.K2_Q14(K2_Q14),.P1_Q14(P1_Q14),.P2_Q14(P2_Q14)
    ) u_renderer (
        .clk(ddr_clk),.rstn(ddr_rstn),.start(renderer_start),
        .source_bank(2'd0),.render_bank(render_bank),
        // Source attitude is held from source SOF through render completion.
        // The completion toggle crosses only after the source frame commits.
        .yaw_q2048(capture_yaw),.pitch_q2048(capture_pitch),
        .busy(renderer_busy),.done(renderer_done),.error(renderer_error),
        .pose_clamped(pose_clamped),.completed_bank(),
        .rd_cmd_valid(render_rd_valid),.rd_cmd_ready(render_rd_ready),
        .rd_cmd_addr(render_rd_addr),.rd_cmd_len(render_rd_len),.rd_data_valid(render_data_valid),
        .rd_data(render_read_data),.rd_data_last(render_rd_done),
        .wr_cmd_valid(render_wr_valid),.wr_cmd_ready(render_wr_ready),
        .wr_cmd_addr(render_wr_addr),.wr_data(render_write_data),.wr_done(render_wr_done),
        .wr_data_valid(),.wr_data_ready(render_wr_ready)
    );
    assign render_write_burst={3840'd0,render_write_data};
    assign render_write_len=5'd1;
    assign render_write_beat=256'd0;
    end endgenerate
    wire arbiter_error;
    reg fifo_error;
    assign protocol_error=arbiter_error || renderer_error || fifo_error;
    pose_ddr_arbiter #(.ADDR_WIDTH(ADDR_WIDTH),
        .RENDER_BURST_ENABLE(FAST || CACHE_LINE_WORDS > 1),
        .RENDER_WRITE_BURST_ENABLE(FAST),.SHARED_WRITE_PAYLOAD(FAST)) u_arbiter (
        .clk(ddr_clk),.rstn(ddr_rstn),
        .cap_w_valid(cap_w_valid),.cap_w_ready(cap_w_ready),
        .cap_w_addr(cap_addr),.cap_w_data(capture_burst),.cap_w_len(capture_burst_count),.cap_w_done(cap_w_done),
        .render_w_valid(render_wr_valid),.render_w_ready(render_wr_ready),
        .render_w_addr(render_wr_addr),.render_w_data(render_write_data),.render_w_done(render_wr_done),
        .render_w_burst(render_write_burst),.render_w_len(render_write_len),
        .cap_w_beat(capture_beat),.render_w_beat(render_write_beat),
        .write_beat_index(write_beat_index),
        .display_r_valid(display_r_valid),.display_r_ready(display_r_ready),
        .display_r_addr(display_addr),.display_r_len(display_len),
        .display_r_data(display_data),.display_r_data_valid(display_data_valid),.display_r_done(display_r_done),
        .render_r_valid(render_rd_valid),.render_r_ready(render_rd_ready),.render_r_addr(render_rd_addr),
        .render_r_len(render_rd_len),
        .render_r_data(render_read_data),.render_r_data_valid(render_data_valid),.render_r_done(render_rd_done),
        .axi_awaddr(axi_awaddr),.axi_awid(axi_awid),.axi_awlen(axi_awlen),
        .axi_awvalid(axi_awvalid),.axi_awready(axi_awready),
        .axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),.axi_wready(axi_wready),.axi_wlast(axi_wlast),
        .axi_araddr(axi_araddr),.axi_arid(axi_arid),.axi_arlen(axi_arlen),
        .axi_arvalid(axi_arvalid),.axi_arready(axi_arready),
        .axi_rdata(axi_rdata),.axi_rvalid(axi_rvalid),.axi_rlast(axi_rlast),.axi_rid(axi_rid),
        .protocol_error(arbiter_error)
    );
    always @(posedge ddr_clk or negedge ddr_rstn) begin
        if(!ddr_rstn) begin
            control_state<=C_REQUEST; capture_request<=0;
            capture_bank<=0;renderer_source_bank<=0;renderer_yaw<=0;renderer_pitch<=0;
            renderer_lens_enable<=1;
            cap_done_sync<=0; cap_bad_sync<=0; cap_words<=0; cap_inflight<=0;
            cap_settle<=0;
            capture_burst_count<=0; capture_sent_len<=0;
            display_req_sync<=0; display_epoch<=0; display_bank<=2; render_bank<=1;
            display_accept_sync<=0;
            display_valid<=0; pending_valid<=0; display_words<=0; display_inflight<=0;
            renderer_start<=0; init_done<=0; fifo_error<=0;
            captured_frames<=0; rendered_frames<=0; displayed_frames<=0; rejected_captures<=0;
        end else begin
            cap_done_sync<={cap_done_sync[1:0],capture_complete};
            cap_bad_sync<={cap_bad_sync[1:0],capture_failed};
            display_req_sync<={display_req_sync[0],display_request};
            display_accept_sync<={display_accept_sync[0],display_accept_epoch};
            renderer_start<=0;
            // Completion/status can cross before the final FIFO write pointer.
            // Wait eight DDR clocks after the completion mailbox is stable.
            if(control_state==C_CAPTURE && cap_done_sync[2]==capture_request) begin
                if(cap_settle<8) cap_settle<=cap_settle+1'b1;
            end else cap_settle<=0;
            if(cap_fifo_valid && cap_fifo_ready) begin
                capture_burst_count<=capture_burst_count+1'b1;
            end
            if(cap_w_valid && cap_w_ready) begin
                cap_inflight<=1; capture_sent_len<=capture_burst_count;
                capture_burst_count<=0;
            end
            if(cap_w_done) begin cap_inflight<=0; cap_words<=cap_words+capture_sent_len; end
            if(display_r_valid && display_r_ready) begin
                display_inflight<=1; display_words<=display_words+display_len;
            end
            if(display_r_done) display_inflight<=0;
            if(display_data_valid && !display_fifo_ready) fifo_error<=1;
            // Last returned beat is already stored before bank/epoch changes.
            if(display_boundary && !display_inflight && display_free==(1<<FIFO_BITS)) begin
                display_epoch<=display_req_sync[1]; display_words<=0;
                if(pending_valid) begin
                    display_bank<=render_bank; display_valid<=1;
                    pending_valid<=0; init_done<=1;
                    displayed_frames<=displayed_frames+1'b1;
                end
            end
            if(FAST) begin
                if(renderer_done && !renderer_error) begin
                    pending_valid<=1;rendered_frames<=rendered_frames+1'b1;
                end
                case(control_state)
                    C_REQUEST: begin
                        capture_request<=~capture_request;cap_words<=0;control_state<=C_CAPTURE;
                    end
                    C_CAPTURE: if(cap_done_sync[2]==capture_request && cap_settle==8 &&
                        !cap_fifo_valid && cap_rd_count==0 && !cap_inflight && capture_burst_count==0) begin
                        if(cap_bad_sync[2] || cap_words!=WORDS) begin
                            rejected_captures<=rejected_captures+1'b1;control_state<=C_REQUEST;
                        end else begin
                            captured_frames<=captured_frames+1'b1;control_state<=C_RENDER;
                        end
                    end
                    // C_RENDER denotes a committed source waiting to dispatch.
                    // A pending output must be published before its bank is reused.
                    C_RENDER: if(!renderer_busy && !renderer_start && !renderer_done && !pending_valid && !renderer_error) begin
                        renderer_source_bank<=capture_bank;
                        renderer_yaw<=capture_yaw;renderer_pitch<=capture_pitch;
                        renderer_lens_enable<=capture_lens_enable;
                        render_bank<=(display_bank==1) ? 2 : 1;
                        renderer_start<=1;
                        capture_bank<=(capture_bank==0) ? 3 : 0;
                        control_state<=C_REQUEST;
                    end
                endcase
            end else case(control_state)
                C_REQUEST: begin
                    capture_request<=~capture_request; cap_words<=0;
                    control_state<=C_CAPTURE;
                end
                C_CAPTURE: if(cap_done_sync[2]==capture_request && cap_settle==8 &&
                    !cap_fifo_valid && cap_rd_count==0 && !cap_inflight && capture_burst_count==0) begin
                    if(cap_bad_sync[2] || cap_words!=WORDS) begin
                        rejected_captures<=rejected_captures+1'b1;
                        control_state<=C_REQUEST;
                    end else begin
                        captured_frames<=captured_frames+1'b1;
                        render_bank<=(display_bank==1) ? 2 : 1;
                        renderer_start<=1; control_state<=C_RENDER;
                    end
                end
                C_RENDER: if(renderer_done && !renderer_error) begin
                    pending_valid<=1; rendered_frames<=rendered_frames+1'b1;
                    control_state<=C_PUBLISH;
                end
                C_PUBLISH: if(!pending_valid) control_state<=C_REQUEST;
            endcase
        end
    end
endmodule

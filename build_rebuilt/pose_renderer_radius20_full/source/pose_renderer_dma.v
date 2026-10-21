`timescale 1ns/1ps

// Correctness-first complete-frame inverse projection renderer. All ports are
// in clk (DDR) domain. A frame snapshots its pose and bank ownership at start.
// RGB565 pixel zero occupies payload[15:0], matching wr_buf/rd_buf.
// H_NUM/OUTPUT_H_NUM must be multiples of 16. Commands are one 256-bit beat.
// The owner must lock source_bank until done and keep render_bank off display.
// The cache and 16-pixel projection batches reduce traffic, but this baseline
// does not claim 1080p60 rendering throughput. HDMI repeats completed frames.
module pose_renderer_dma #(
    parameter integer ADDR_WIDTH = 28,
    parameter integer H_NUM = 1920,
    parameter integer V_NUM = 1080,
    // Smaller output extents can render an origin-aligned crop for bring-up;
    // projection/source bounds continue to use the full H_NUM/V_NUM sensor.
    parameter integer OUTPUT_H_NUM = H_NUM,
    parameter integer OUTPUT_V_NUM = V_NUM,
    parameter integer ROW_ADDR_STRIDE = H_NUM/2,
    parameter integer CACHE_INDEX_BITS = 8,
    parameter integer INTERPOLATION_MODE = 1,
    parameter signed [31:0] FX_Q14 = 32'sd12262554,
    parameter signed [31:0] FY_Q14 = 32'sd12256498,
    parameter signed [31:0] CX_Q14 = 32'sd15481296,
    parameter signed [31:0] CY_Q14 = 32'sd8558941,
    parameter signed [17:0] K1_Q14 = 18'sd162,
    parameter signed [17:0] K2_Q14 = -18'sd711,
    parameter signed [17:0] P1_Q14 = 18'sd0,
    parameter signed [17:0] P2_Q14 = 18'sd0
) (
    input clk, input rstn,
    input start,
    input [1:0] source_bank, input [1:0] render_bank,
    input signed [15:0] yaw_q2048, input signed [15:0] pitch_q2048,
    output reg busy, output reg done, output reg error,
    output pose_clamped,
    output [1:0] completed_bank,
    output rd_cmd_valid, input rd_cmd_ready,
    output [ADDR_WIDTH-1:0] rd_cmd_addr,
    input rd_data_valid, input [255:0] rd_data, input rd_data_last,
    output wr_cmd_valid, input wr_cmd_ready,
    output [ADDR_WIDTH-1:0] wr_cmd_addr,
    output wr_data_valid, input wr_data_ready,
    output [255:0] wr_data,
    input wr_done
);
    localparam S_IDLE=4'd0, S_POSE=4'd1, S_PROJECT=4'd2,
        S_PROJECT_WAIT=4'd3, S_LOOKUP=4'd4, S_CACHE=4'd5,
        S_READ_CMD=4'd6, S_READ_DATA=4'd7, S_PACK=4'd8,
        S_WRITE_CMD=4'd9, S_WRITE_DONE=4'd10, S_FAULT=4'd11, S_POSE_WAIT=4'd12;
    localparam integer CACHE_ENTRIES = 1 << CACHE_INDEX_BITS;
    reg [3:0] state;
    reg [1:0] source_q, render_q;
    reg signed [15:0] yaw_q, pitch_q;
    reg [10:0] dst_word_x, dst_y;
    reg [4:0] launch_count, result_count;
    reg [3:0] sample_index;
    reg [10:0] sample_x [0:15];
    reg [10:0] sample_y [0:15];
    reg [4:0] sample_fx [0:15];
    reg [4:0] sample_fy [0:15];
    reg [15:0] sample_valid;
    wire projected_valid, projected_map_valid, projected_pose_ready;
    wire signed [31:0] projected_x, projected_y;
    wire [10:0] rounded_x = projected_x[24:14] + projected_x[13];
    wire [10:0] rounded_y = projected_y[24:14] + projected_y[13];
    wire [10:0] project_dst_x = dst_word_x + launch_count;

    pose_inverse_project_q14 #(
        .H_NUM(H_NUM), .V_NUM(V_NUM), .FX_Q14(FX_Q14), .FY_Q14(FY_Q14),
        .CX_Q14(CX_Q14), .CY_Q14(CY_Q14), .K1_Q14(K1_Q14), .K2_Q14(K2_Q14),
        .P1_Q14(P1_Q14), .P2_Q14(P2_Q14)
    ) u_projector (
        .clk(clk), .rstn(rstn), .pose_load(state==S_POSE),
        .pose_yaw_q2048(yaw_q), .pose_pitch_q2048(pitch_q),
        .pose_clamped(pose_clamped), .pose_ready(projected_pose_ready), .in_valid(state==S_PROJECT),
        .dst_x(project_dst_x), .dst_y(dst_y),
        .out_valid(projected_valid), .map_valid(projected_map_valid),
        .src_x_q14(projected_x), .src_y_q14(projected_y)
    );

    reg [255:0] cache_data [0:CACHE_ENTRIES-1];
    reg [ADDR_WIDTH-1:0] cache_tag [0:CACHE_ENTRIES-1];
    reg [CACHE_ENTRIES-1:0] cache_valid;
    reg [255:0] cache_data_q;
    reg [ADDR_WIDTH-1:0] cache_tag_q;
    reg cache_valid_q;
    reg [ADDR_WIDTH-1:0] fetch_addr;
    reg [CACHE_INDEX_BITS-1:0] fetch_index;
    reg [3:0] fetch_lane;
    reg [15:0] pixel_q;
    reg [1:0] tap_index;
    reg [15:0] tap00, tap01, tap10;
    reg [255:0] packed_pixels;
    wire [ADDR_WIDTH-1:0] source_base = {{(ADDR_WIDTH-24){1'b0}},source_q,22'd0};
    wire [ADDR_WIDTH-1:0] render_base = {{(ADDR_WIDTH-24){1'b0}},render_q,22'd0};
    wire [10:0] lookup_x = sample_x[sample_index] +
        ((INTERPOLATION_MODE==0) ? tap_index[0] : 1'b0);
    wire [10:0] lookup_y = sample_y[sample_index] +
        ((INTERPOLATION_MODE==0) ? tap_index[1] : 1'b0);
    wire [ADDR_WIDTH-1:0] lookup_addr = source_base +
        lookup_y*ROW_ADDR_STRIDE + (lookup_x >> 4)*8;
    wire [CACHE_INDEX_BITS-1:0] lookup_index = lookup_addr[CACHE_INDEX_BITS+2:3];

    function automatic [15:0] bilinear565;
        input [15:0] a,b,c,d;
        input [4:0] fx,fy;
        integer ix,iy,wx,wy,red,green,blue;
        begin
            wx=fx; wy=fy; ix=32-wx; iy=32-wy;
            red=(a[15:11]*ix*iy+b[15:11]*wx*iy+c[15:11]*ix*wy+d[15:11]*wx*wy+512)>>10;
            green=(a[10:5]*ix*iy+b[10:5]*wx*iy+c[10:5]*ix*wy+d[10:5]*wx*wy+512)>>10;
            blue=(a[4:0]*ix*iy+b[4:0]*wx*iy+c[4:0]*ix*wy+d[4:0]*wx*wy+512)>>10;
            bilinear565={red[4:0],green[5:0],blue[4:0]};
        end
    endfunction

    assign completed_bank = render_q;
    assign rd_cmd_valid = state==S_READ_CMD;
    assign rd_cmd_addr = fetch_addr;
    assign wr_cmd_valid = state==S_WRITE_CMD;
    assign wr_cmd_addr = render_base + dst_y*ROW_ADDR_STRIDE + (dst_word_x >> 4)*8;
    // Command and payload form one atomic request. Both ready inputs must
    // assert together; the owner snapshots addr/data on this handshake.
    assign wr_data_valid = state==S_WRITE_CMD;
    assign wr_data = packed_pixels;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state<=S_IDLE; busy<=0; done<=0; error<=0;
            source_q<=0; render_q<=0; yaw_q<=0; pitch_q<=0;
            dst_word_x<=0; dst_y<=0; launch_count<=0; result_count<=0;
            sample_index<=0; sample_valid<=0; cache_valid<=0;
            cache_data_q<=0; cache_tag_q<=0; cache_valid_q<=0;
            fetch_addr<=0; fetch_index<=0; fetch_lane<=0;
            pixel_q<=0; packed_pixels<=0; tap_index<=0; tap00<=0; tap01<=0; tap10<=0;
        end else begin
            done<=0;
            // The pipeline output is independent of cache/DDR stalls. Each
            // batch has exactly 16 inputs and is drained before sampling.
            if (projected_valid && busy && result_count < 16) begin
                sample_x[result_count[3:0]] <= (INTERPOLATION_MODE==0) ? projected_x[24:14] : rounded_x;
                sample_y[result_count[3:0]] <= (INTERPOLATION_MODE==0) ? projected_y[24:14] : rounded_y;
                sample_fx[result_count[3:0]] <= projected_x[13:9];
                sample_fy[result_count[3:0]] <= projected_y[13:9];
                sample_valid[result_count[3:0]] <= projected_map_valid &&
                    rounded_x < H_NUM && rounded_y < V_NUM;
                result_count <= result_count + 1'b1;
            end
            case (state)
                S_IDLE: if (start) begin
                    if (source_bank==render_bank) error<=1;
                    else begin
                        source_q<=source_bank; render_q<=render_bank;
                        yaw_q<=yaw_q2048; pitch_q<=pitch_q2048;
                        dst_word_x<=0; dst_y<=0; launch_count<=0; result_count<=0;
                        sample_index<=0; cache_valid<=0; packed_pixels<=0; tap_index<=0;
                        busy<=1; error<=0; state<=S_POSE;
                    end
                end
                S_POSE: state<=S_POSE_WAIT;
                S_POSE_WAIT: if (projected_pose_ready) state<=S_PROJECT;
                S_PROJECT: begin
                    if (launch_count==15) state<=S_PROJECT_WAIT;
                    else launch_count<=launch_count+1'b1;
                end
                S_PROJECT_WAIT: if (result_count==16) begin
                    sample_index<=0; state<=S_LOOKUP;
                end
                S_LOOKUP: begin
                    if (!sample_valid[sample_index]) begin
                        pixel_q<=0; state<=S_PACK;
                    end else begin
                        fetch_addr<=lookup_addr; fetch_index<=lookup_index;
                        fetch_lane<=lookup_x[3:0];
                        cache_data_q<=cache_data[lookup_index];
                        cache_tag_q<=cache_tag[lookup_index];
                        cache_valid_q<=cache_valid[lookup_index];
                        state<=S_CACHE;
                    end
                end
                S_CACHE: begin
                    if (cache_valid_q && cache_tag_q==fetch_addr) begin
                        pixel_q<=cache_data_q[fetch_lane*16 +: 16];
                        state<=S_PACK;
                    end else state<=S_READ_CMD;
                end
                S_READ_CMD: if (rd_cmd_ready) state<=S_READ_DATA;
                S_READ_DATA: if (rd_data_valid) begin
                    // Commands have one beat. A missing LAST is a protocol
                    // fault; keep waiting for reset rather than publish a
                    // potentially misrouted or incomplete rendered frame.
                    if (!rd_data_last) begin error<=1; state<=S_FAULT; end
                    else begin
                        cache_data[fetch_index]<=rd_data;
                        cache_tag[fetch_index]<=fetch_addr;
                        cache_valid[fetch_index]<=1;
                        pixel_q<=rd_data[fetch_lane*16 +: 16]; state<=S_PACK;
                    end
                end
                S_PACK: begin
                    if (INTERPOLATION_MODE==0 && sample_valid[sample_index] && tap_index!=3) begin
                        case (tap_index)
                            0: tap00<=pixel_q;
                            1: tap01<=pixel_q;
                            2: tap10<=pixel_q;
                        endcase
                        tap_index<=tap_index+1'b1; state<=S_LOOKUP;
                    end else begin
                        packed_pixels[sample_index*16 +: 16]<=
                            (INTERPOLATION_MODE==0 && sample_valid[sample_index]) ?
                            bilinear565(tap00,tap01,tap10,pixel_q,sample_fx[sample_index],sample_fy[sample_index]) : pixel_q;
                        tap_index<=0;
                        if (sample_index==15) state<=S_WRITE_CMD;
                        else begin sample_index<=sample_index+1'b1; state<=S_LOOKUP; end
                    end
                end
                S_WRITE_CMD: if (wr_cmd_ready && wr_data_ready) state<=S_WRITE_DONE;
                S_WRITE_DONE: if (wr_done) begin
                    if (dst_word_x==OUTPUT_H_NUM-16 && dst_y==OUTPUT_V_NUM-1) begin
                        busy<=0; done<=1; state<=S_IDLE;
                    end else begin
                        if (dst_word_x==OUTPUT_H_NUM-16) begin dst_word_x<=0; dst_y<=dst_y+1'b1; end
                        else dst_word_x<=dst_word_x+16;
                        launch_count<=0; result_count<=0; state<=S_PROJECT;
                    end
                end
                S_FAULT: begin busy<=1; error<=1; end
                default: begin state<=S_FAULT; busy<=1; error<=1; end
            endcase
        end
    end
endmodule

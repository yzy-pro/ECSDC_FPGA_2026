`timescale 1ns/1ps
// Exact inverse projection, two complete tile slots. Projection/source loading
// of tile n+1 overlaps sampling/burst writes of tile n. No geometric mesh
// approximation is used. Source bounds include EVERY valid nearest tap.
// DDR addresses are 32-bit words; a command carries 1..16 packed 256-bit beats.
// Source/output banks and pose are immutable until the final write completes.
module pose_renderer_tiled #(
    parameter ADDR_WIDTH=28, H_NUM=1920, V_NUM=1080,
    parameter OUTPUT_H_NUM=H_NUM, OUTPUT_V_NUM=V_NUM,
    parameter TILE_W=128, TILE_H=64, SOURCE_BITS=11,
    parameter signed [15:0] POSE_LIMIT_Q2048=16'sd536,
    parameter RECIPROCAL_LUT_ENABLE=0,
    parameter signed [31:0] FX_Q14=32'sd12262554, FY_Q14=32'sd12256498,
    parameter signed [31:0] CX_Q14=32'sd15481296, CY_Q14=32'sd8558941,
    parameter signed [17:0] K1_Q14=18'sd162, K2_Q14=-18'sd711,
    parameter signed [17:0] P1_Q14=18'sd0, P2_Q14=18'sd0
) (
    input clk, rstn, start,
    input [1:0] source_bank, render_bank,
    input signed [15:0] yaw_q2048, pitch_q2048,
    output reg busy, done, error, output pose_clamped,
    output [1:0] completed_bank,
    output rd_cmd_valid, input rd_cmd_ready,
    output [ADDR_WIDTH-1:0] rd_cmd_addr, output [4:0] rd_cmd_len,
    input rd_data_valid, input [255:0] rd_data, input rd_data_last,
    output wr_cmd_valid, input wr_cmd_ready,
    output [ADDR_WIDTH-1:0] wr_cmd_addr, output [4:0] wr_cmd_len,
    output [4095:0] wr_data, input wr_done
);
    localparam TP=TILE_W*TILE_H, CB=$clog2(TP), OW=TP/16,
               OB=$clog2(OW), SW=1<<SOURCE_BITS;
    localparam P_IDLE=0,P_POSE=1,P_POSE_WAIT=2,P_SLOT=3,P_PROJECT=4,
               P_DRAIN=5,P_BOUNDS=6,P_READ_CMD=7,P_READ_DATA=8,P_READY=9,P_END=10,
               P_AREA=11,P_CAPACITY=12;
    localparam S_WAIT=0,S_RUN=1,S_DRAIN=2;
    localparam W_WAIT=0,W_LOAD=1,W_CMD=2,W_DONE=3;
    reg [3:0] ps;
    reg [1:0] ss,ws;
    reg pb,sb;
    reg [1:0] occupied,ready_tiles;
    reg [1:0] source_q,render_q;
    reg signed [15:0] yaw_q,pitch_q;
    reg [10:0] next_x,next_y;
    reg [10:0] ox[0:1],oy[0:1],sy0[0:1];
    reg [7:0] width[0:1],height[0:1],sxword[0:1],srcwords[0:1];
    reg last_tile[0:1];
    reg [7:0] rows_ready[0:1];
    reg [7:0] launch_x,launch_y,result_x,result_y;
    reg [10:0] xmin,xmax,ymin,ymax;
    reg any_valid;
    reg [10:0] read_y;
    reg [7:0] read_x;
    reg [SOURCE_BITS:0] fill_count;
    reg [4:0] read_left;
    wire pv,pm,pose_ready;
    wire signed [31:0] pu,pvcoord;
    wire [10:0] tap_x=pu[24:14]+pu[13];
    wire [10:0] tap_y=pvcoord[24:14]+pvcoord[13];
    wire project_en=busy && !error && ps==P_PROJECT;
    pose_inverse_project_q14 #(.H_NUM(H_NUM),.V_NUM(V_NUM),
        .POSE_LIMIT_Q2048(POSE_LIMIT_Q2048),.RECIPROCAL_LUT_ENABLE(RECIPROCAL_LUT_ENABLE),
        .FX_Q14(FX_Q14),.FY_Q14(FY_Q14),.CX_Q14(CX_Q14),.CY_Q14(CY_Q14),
        .K1_Q14(K1_Q14),.K2_Q14(K2_Q14),.P1_Q14(P1_Q14),.P2_Q14(P2_Q14)) u_projector (
        .clk(clk),.rstn(rstn),.pose_load(busy && ps==P_POSE),
        .pose_yaw_q2048(yaw_q),.pose_pitch_q2048(pitch_q),
        .pose_clamped(pose_clamped),.pose_ready(pose_ready),
        .in_valid(project_en),.dst_x(ox[pb]+launch_x),.dst_y(oy[pb]+launch_y),
        .out_valid(pv),.map_valid(pm),.src_x_q14(pu),.src_y_q14(pvcoord));
    // Separate synchronous RAM ports. Contents need no reset: slot ownership,
    // valid coordinates and rows_ready prevent reading stale/unwritten words.
    reg [22:0] coordinates[0:2*TP-1];
    reg [255:0] source_mem[0:2*SW-1];
    reg [255:0] output_mem[0:2*OW-1];
    wire [CB-1:0] result_pos=result_y*TILE_W+result_x;
    wire [7:0] bbox_words=(xmax>>4)-(xmin>>4)+1;
    wire [11:0] bbox_rows={1'b0,ymax}-{1'b0,ymin}+1;
    // Separate subtraction, multiplication and capacity comparison. Keeping
    // them in one cycle put the bounding box -> state/error path over 10 ns.
    reg [7:0] bbox_words_q;
    reg [11:0] bbox_rows_q;
    reg [19:0] bbox_size;
    wire [ADDR_WIDTH-1:0] source_base={{(ADDR_WIDTH-24){1'b0}},source_q,22'd0};
    wire [ADDR_WIDTH-1:0] render_base={{(ADDR_WIDTH-24){1'b0}},render_q,22'd0};
    assign completed_bank=render_q;
    assign rd_cmd_valid=busy && !error && ps==P_READ_CMD;
    assign rd_cmd_addr=source_base+read_y*(H_NUM/2)+(sxword[pb]+read_x)*8;
    assign rd_cmd_len=(srcwords[pb]-read_x>16) ? 5'd16 : srcwords[pb]-read_x;
    // Sampling pipeline: coordinate RAM -> relative address -> source RAM ->
    // lane selection -> RGB565 packing. Initiation interval is one pixel.
    reg [7:0] sample_x,sample_y;
    reg [3:0] sample_valid;
    reg [22:0] coord_q;
    reg [SOURCE_BITS-1:0] source_addr_q;
    reg [255:0] source_data_q;
    reg [15:0] pixel_q;
    reg [CB-1:0] pos0,pos1,pos2,pos3;
    reg map1,map2;
    reg [3:0] lane1,lane2;
    reg [255:0] pack;
    wire sample_en=busy && !error && ss==S_RUN;
    wire [CB-1:0] sample_pos=sample_y*TILE_W+sample_x;
    wire [18:0] relative_addr=(coord_q[21:11]-sy0[sb])*srcwords[sb]+
                              (coord_q[10:4]-sxword[sb]);
    // Output RAM lets DDR writes run concurrently with pixel sampling. Each
    // completed row is loaded atomically into the arbiter's burst buffer.
    reg [7:0] write_y;
    reg [4:0] load_word;
    reg load_phase;
    reg [255:0] output_q;
    reg [4095:0] write_burst;
    wire [OB-1:0] out_read_pos=write_y*(TILE_W/16)+load_word;
    assign wr_cmd_valid=busy && !error && ws==W_CMD;
    assign wr_cmd_addr=render_base+(oy[sb]+write_y)*(H_NUM/2)+(ox[sb]/16)*8;
    assign wr_cmd_len=width[sb]/16;
    assign wr_data=write_burst;
    wire tile_committed=busy && !error && ws==W_DONE && wr_done && write_y==height[sb]-1;
    always @(posedge clk) begin
        if(busy && !error && pv && (ps==P_PROJECT || ps==P_DRAIN))
            coordinates[{pb,result_pos}]<={pm,tap_y,tap_x};
        if(busy && !error && ps==P_READ_DATA && rd_data_valid &&
           fill_count<SW && rd_data_last==(read_left==1))
            source_mem[{pb,fill_count[SOURCE_BITS-1:0]}]<=rd_data;
        if(sample_en) coord_q<=coordinates[{sb,sample_pos}];
        source_data_q<=source_mem[{sb,source_addr_q}];
        if(sample_valid[3] && !error && pos3[3:0]==15)
            output_mem[{sb,pos3[CB-1:4]}]<={pixel_q,pack[239:0]};
        if(ws==W_LOAD && !load_phase) output_q<=output_mem[{sb,out_read_pos}];
    end
    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            busy<=0;done<=0;error<=0;ps<=P_IDLE;ss<=S_WAIT;ws<=W_WAIT;
            pb<=0;sb<=0;occupied<=0;ready_tiles<=0;source_q<=0;render_q<=0;
            yaw_q<=0;pitch_q<=0;next_x<=0;next_y<=0;
            launch_x<=0;launch_y<=0;result_x<=0;result_y<=0;
            xmin<=0;xmax<=0;ymin<=0;ymax<=0;any_valid<=0;
            read_x<=0;read_y<=0;fill_count<=0;read_left<=0;
            bbox_words_q<=0;bbox_rows_q<=0;bbox_size<=0;
            rows_ready[0]<=0;rows_ready[1]<=0;
            sample_x<=0;sample_y<=0;sample_valid<=0;
            source_addr_q<=0;pixel_q<=0;pos0<=0;pos1<=0;pos2<=0;pos3<=0;
            map1<=0;map2<=0;lane1<=0;lane2<=0;pack<=0;
            write_y<=0;load_word<=0;load_phase<=0;write_burst<=0;
        end else begin
            done<=0;
            sample_valid<={sample_valid[2:0],sample_en};
            if(sample_en) pos0<=sample_pos;
            pos1<=pos0;pos2<=pos1;pos3<=pos2;
            source_addr_q<=relative_addr[SOURCE_BITS-1:0];
            map1<=coord_q[22];map2<=map1;lane1<=coord_q[3:0];lane2<=lane1;
            pixel_q<=map2 ? source_data_q[lane2*16 +:16] : 16'd0;
            if(sample_valid[3] && !error) begin
                pack[pos3[3:0]*16 +:16]<=pixel_q;
                if((pos3%TILE_W)==width[sb]-1)
                    rows_ready[sb]<=pos3/TILE_W+1'b1;
            end
            if(start && !busy) begin
                busy<=1;error<=0;source_q<=source_bank;render_q<=render_bank;
                yaw_q<=yaw_q2048;pitch_q<=pitch_q2048;
                ps<=P_POSE;ss<=S_WAIT;ws<=W_WAIT;pb<=0;sb<=0;
                occupied<=0;ready_tiles<=0;next_x<=0;next_y<=0;
                rows_ready[0]<=0;rows_ready[1]<=0;sample_valid<=0;write_y<=0;
            end else if(busy && !error) begin
                if(pv && (ps==P_PROJECT || ps==P_DRAIN)) begin
                    if(pm) begin
                        any_valid<=1;
                        if(!any_valid || tap_x<xmin) xmin<=tap_x;
                        if(!any_valid || tap_x>xmax) xmax<=tap_x;
                        if(!any_valid || tap_y<ymin) ymin<=tap_y;
                        if(!any_valid || tap_y>ymax) ymax<=tap_y;
                    end
                    if(result_x==width[pb]-1) begin
                        result_x<=0;result_y<=result_y+1'b1;
                        if(result_y==height[pb]-1) ps<=P_BOUNDS;
                    end else result_x<=result_x+1'b1;
                end
                case(ps)
                    P_POSE: ps<=P_POSE_WAIT;
                    P_POSE_WAIT: if(pose_ready) ps<=P_SLOT;
                    P_SLOT: if(!occupied[pb]) begin
                        occupied[pb]<=1;rows_ready[pb]<=0;
                        ox[pb]<=next_x;oy[pb]<=next_y;
                        width[pb]<=(OUTPUT_H_NUM-next_x<TILE_W) ? OUTPUT_H_NUM-next_x : TILE_W;
                        height[pb]<=(OUTPUT_V_NUM-next_y<TILE_H) ? OUTPUT_V_NUM-next_y : TILE_H;
                        last_tile[pb]<=next_x+TILE_W>=OUTPUT_H_NUM && next_y+TILE_H>=OUTPUT_V_NUM;
                        launch_x<=0;launch_y<=0;result_x<=0;result_y<=0;
                        any_valid<=0;ps<=P_PROJECT;
                    end
                    P_PROJECT: begin
                        if(launch_x==width[pb]-1) begin
                            launch_x<=0;launch_y<=launch_y+1'b1;
                            if(launch_y==height[pb]-1) ps<=P_DRAIN;
                        end else launch_x<=launch_x+1'b1;
                    end
                    P_BOUNDS: begin
                        sxword[pb]<=xmin>>4;sy0[pb]<=ymin;srcwords[pb]<=bbox_words;
                        read_x<=0;read_y<=ymin;fill_count<=0;
                        bbox_words_q<=bbox_words;bbox_rows_q<=bbox_rows;
                        if(!any_valid) ps<=P_READY;
                        else ps<=P_AREA;
                    end
                    P_AREA: begin
                        bbox_size<=bbox_words_q*bbox_rows_q;
                        ps<=P_CAPACITY;
                    end
                    P_CAPACITY: begin
                        if(bbox_size>SW) error<=1;
                        else ps<=P_READ_CMD;
                    end
                    P_READ_CMD: if(rd_cmd_ready) begin read_left<=rd_cmd_len;ps<=P_READ_DATA; end
                    P_READ_DATA: if(rd_data_valid) begin
                        if(rd_data_last!=(read_left==1) || fill_count>=SW) error<=1;
                        else begin
                            fill_count<=fill_count+1'b1;read_left<=read_left-1'b1;
                            if(read_left==1) begin
                                if(read_x+((srcwords[pb]-read_x>16)?16:srcwords[pb]-read_x)==srcwords[pb]) begin
                                    read_x<=0;read_y<=read_y+1'b1;
                                    ps<=(read_y==ymax) ? P_READY : P_READ_CMD;
                                end else begin read_x<=read_x+16;ps<=P_READ_CMD; end
                            end
                        end
                    end
                    P_READY: begin
                        ready_tiles[pb]<=1;pb<=~pb;
                        if(last_tile[pb]) ps<=P_END;
                        else begin
                            if(next_x+TILE_W>=OUTPUT_H_NUM) begin next_x<=0;next_y<=next_y+TILE_H; end
                            else next_x<=next_x+TILE_W;
                            ps<=P_SLOT;
                        end
                    end
                endcase
                case(ss)
                    S_WAIT: if(ready_tiles[sb]) begin sample_x<=0;sample_y<=0;ss<=S_RUN; end
                    S_RUN: begin
                        if(sample_x==width[sb]-1) begin
                            sample_x<=0;sample_y<=sample_y+1'b1;
                            if(sample_y==height[sb]-1) ss<=S_DRAIN;
                        end else sample_x<=sample_x+1'b1;
                    end
                endcase
                case(ws)
                    W_WAIT: if(ready_tiles[sb] && rows_ready[sb]>write_y) begin
                        load_word<=0;load_phase<=0;ws<=W_LOAD;
                    end
                    W_LOAD: begin
                        load_phase<=~load_phase;
                        if(load_phase) begin
                            write_burst[load_word*256 +:256]<=output_q;
                            if(load_word==width[sb]/16-1) ws<=W_CMD;
                            else load_word<=load_word+1'b1;
                        end
                    end
                    W_CMD: if(wr_cmd_ready) ws<=W_DONE;
                    W_DONE: if(wr_done) begin
                        ws<=W_WAIT;
                        if(write_y==height[sb]-1) begin
                            write_y<=0;occupied[sb]<=0;ready_tiles[sb]<=0;
                            ss<=S_WAIT;sb<=~sb;
                            if(last_tile[sb]) begin busy<=0;done<=1;ps<=P_IDLE; end
                        end else write_y<=write_y+1'b1;
                    end
                endcase
            end
        end
    end
endmodule

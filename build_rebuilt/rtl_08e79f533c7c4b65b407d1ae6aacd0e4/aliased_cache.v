`timescale 1ns/1ps
// Eight source-x strips, pooled parity RAMs. 272 bits = 16 RGB565 pixels
// plus the right-neighbour pixel. No colour precision is discarded.
module undistort_band_cache #(
    parameter ADDR_WIDTH=28, parameter ADDR_OFFSET=0,
    parameter LINE_ADDR_WIDTH=22
) (
    input ddr_clk, input ddr_rstn, input vout_clk,
    input rd_fsync, input rd_active, input init_done,
    input [1:0] completed_frame_bank,
    output [1:0] display_frame_bank, output reg [1:0] frame_sel,
    output reg ddr_rreq, output reg [ADDR_WIDTH-1:0] ddr_raddr,
    output [31:0] ddr_rd_len, input ddr_rrdy, input ddr_rdone,
    input [255:0] ddr_rdata, input ddr_rdata_en,
    output reg cache_prefill_ready, output reg cache_underrun,
    input [10:0] src_x, input [10:0] src_y,
    output reg [271:0] even_word, output reg [271:0] odd_word
);
    localparam CACHE_DEPTH=2475;
    // Keep the depth-2475 array from rounding up to a depth-4096 DRM.
    reg [271:0] cache_even_main [0:2047];
    reg [271:0] cache_odd_main [0:2047];
    reg [271:0] cache_even_tail [0:CACHE_DEPTH-2048-1];
    reg [271:0] cache_odd_tail [0:CACHE_DEPTH-2048-1];
    function [2:0] band_for_x;
        input [10:0] x;
        begin
            if(x<240) band_for_x=0;
            else if(x<480) band_for_x=1;
            else if(x<720) band_for_x=2;
            else if(x<960) band_for_x=3;
            else if(x<1200) band_for_x=4;
            else if(x<1440) band_for_x=5;
            else if(x<1680) band_for_x=6;
            else band_for_x=7;
        end
    endfunction
    function [11:0] band_base;
        input [2:0] band;
        begin case(band)
            0:band_base=0; 1:band_base=435; 2:band_base=855; 3:band_base=1050;
            4:band_base=1185; 5:band_base=1320; 6:band_base=1530; 7:band_base=0;
        endcase end
    endfunction

    // Five stages: slots, row/column terms, addresses, RAM, output.
    wire [10:0] even_y = src_y + {10'd0,src_y[0]};
    wire [47:0] even_slots,odd_slots;
    undistort_band_slots slots_even(vout_clk,even_y[10:1],even_slots);
    undistort_band_slots slots_odd(vout_clk,src_y[10:1],odd_slots);
    reg [2:0] pixel_band;
    reg [6:0] pixel_word;
    reg [11:0] even_addr,odd_addr;
    reg [11:0] even_row_word,odd_row_word,region_word;
    reg [271:0] even_main_ram,odd_main_ram,even_tail_ram,odd_tail_ram;
    reg even_tail_sel,odd_tail_sel;
    always @(posedge vout_clk) begin
        pixel_band <= band_for_x(src_x);
        pixel_word <= src_x[10:4];
        even_row_word <= even_slots[pixel_band*6 +: 6]*15;
        odd_row_word <= odd_slots[pixel_band*6 +: 6]*15;
        region_word <= band_base(pixel_band) + pixel_word - pixel_band*15;
        even_addr <= even_row_word + region_word;
        odd_addr <= odd_row_word + region_word;
        even_main_ram <= cache_even_main[even_addr[10:0]];
        odd_main_ram <= cache_odd_main[odd_addr[10:0]];
        even_tail_ram <= cache_even_tail[even_addr[8:0]];
        odd_tail_ram <= cache_odd_tail[odd_addr[8:0]];
        even_tail_sel <= even_addr[11];
        odd_tail_sel <= odd_addr[11];
        even_word <= even_tail_sel ? even_tail_ram : even_main_ram;
        odd_word <= odd_tail_sel ? odd_tail_ram : odd_main_ram;
    end

    reg [1:0] active_sync,fsync_sync;
    reg active_d,fsync_d;
    wire frame_start=fsync_sync[1] && !fsync_d;
    reg frame_restart_pending,frame_active;
    reg [1:0] pending_frame_sel;
    reg [2:0] warmup;
    reg [10:0] output_y;
    wire [87:0] first_rows,current_max,future_max;
    undistort_band_schedule schedule(ddr_clk,output_y,first_rows,current_max,future_max);
    reg [10:0] next_row[0:7];
    reg [10:0] committed_row[0:7];
    reg [7:0] committed_valid;
    reg all_current,all_future;
    integer k,j;
    always @* begin
        all_current=1'b1; all_future=1'b1;
        for(j=0;j<8;j=j+1) begin
            if(!committed_valid[j] || committed_row[j]<current_max[j*11 +: 11]) all_current=1'b0;
            if(!committed_valid[j] || committed_row[j]<future_max[j*11 +: 11]) all_future=1'b0;
        end
    end
    localparam IDLE=0, PREP=1, ISSUE=2, RETURN=3, DRAIN=4, COMMIT=5;
    reg [2:0] req_state,scan_band,req_band;
    reg [10:0] req_row;
    wire [47:0] request_slots;
    undistort_band_slots slots_request(ddr_clk,req_row[10:1],request_slots);
    reg [11:0] req_base;
    reg [4:0] beat_count;
    reg [255:0] previous_beat;
    reg flush_pending,done_seen;
    reg cache_wr_en,cache_wr_odd;
    reg [11:0] cache_wr_addr;
    reg [271:0] cache_wr_data;
    wire [ADDR_WIDTH-1:0] frame_base =
        {{(ADDR_WIDTH-LINE_ADDR_WIDTH-2){1'b0}},frame_sel,{LINE_ADDR_WIDTH{1'b0}}};
    assign display_frame_bank = frame_start ? completed_frame_bank :
                                (frame_restart_pending ? pending_frame_sel : frame_sel);
    // The command adapter supports 16-beat bursts. Bands 0..6 fetch 15 data
    // beats + right halo. Band 7 fetches 104..119, discarding its first beat.
    // No transaction crosses a physical source-row boundary.
    assign ddr_rd_len=32'd16;
    always @(posedge ddr_clk) begin
        if(cache_wr_en) begin
            if(cache_wr_addr[11]) begin
                if(cache_wr_odd) cache_odd_tail[cache_wr_addr[8:0]] <= cache_wr_data;
                else cache_even_tail[cache_wr_addr[8:0]] <= cache_wr_data;
            end else begin
                if(cache_wr_odd) cache_odd_main[cache_wr_addr[10:0]] <= cache_wr_data;
                else cache_even_main[cache_wr_addr[10:0]] <= cache_wr_data;
            end
        end
    end
    always @(posedge ddr_clk) begin
        if(!ddr_rstn) begin
            active_sync<=0;fsync_sync<=0;active_d<=0;fsync_d<=0;
            frame_restart_pending<=0;frame_active<=0;pending_frame_sel<=0;frame_sel<=0;
            warmup<=0;output_y<=0;committed_valid<=0;
            req_state<=IDLE;scan_band<=0;req_band<=0;req_row<=0;req_base<=0;
            beat_count<=0;previous_beat<=0;flush_pending<=0;done_seen<=0;
            cache_wr_en<=0;cache_wr_odd<=0;cache_wr_addr<=0;cache_wr_data<=0;
            ddr_rreq<=0;ddr_raddr<=0;cache_prefill_ready<=0;cache_underrun<=0;
            for(k=0;k<8;k=k+1) begin next_row[k]<=0;committed_row[k]<=0;end
        end else begin
            active_sync<={active_sync[0],rd_active};fsync_sync<={fsync_sync[0],rd_fsync};
            active_d<=active_sync[1];fsync_d<=fsync_sync[1];
            ddr_rreq<=0;cache_wr_en<=0;
            if(frame_start) begin
                pending_frame_sel<=completed_frame_bank;
                frame_restart_pending<=1;cache_prefill_ready<=0;
            end else if(frame_restart_pending && req_state==IDLE && !cache_wr_en && !flush_pending) begin
                frame_sel<=pending_frame_sel;frame_restart_pending<=0;frame_active<=1;
                output_y<=0;warmup<=4;committed_valid<=0;scan_band<=0;
                for(k=0;k<8;k=k+1) next_row[k]<=first_rows[k*11 +: 11];
            end else if(frame_active && active_d && !active_sync[1] && output_y<1079) begin
                output_y<=output_y+1'b1;
            end
            if(warmup!=0) warmup<=warmup-1'b1;
            if(frame_active && warmup==0 && !frame_restart_pending && !frame_start) begin
                if(all_future && output_y==0) cache_prefill_ready<=1;
                if(active_sync[1] && !active_d && !all_current) cache_underrun<=1;
            end
            case(req_state)
                IDLE: begin
                    scan_band<=scan_band+1'b1;
                    if(frame_active && warmup==0 && init_done && !frame_restart_pending && !frame_start &&
                       next_row[scan_band]<=future_max[scan_band*11 +: 11]) begin
                        req_band<=scan_band;req_row<=next_row[scan_band];req_state<=PREP;
                    end
                end
                PREP: begin
                    ddr_raddr<=ADDR_OFFSET+frame_base+req_row*960+
                               ((req_band==7)?832:req_band*120);
                    req_state<=ISSUE;
                end
                ISSUE: if(ddr_rrdy) begin
                    req_base<=band_base(req_band)+request_slots[req_band*6 +: 6]*15;
                    ddr_rreq<=1;beat_count<=0;done_seen<=0;req_state<=RETURN;
                end
                RETURN: begin
                    if(ddr_rdone) done_seen<=1;
                    if(ddr_rdata_en) begin
                        previous_beat<=ddr_rdata;
                        if((req_band!=7 && beat_count>=1) || (req_band==7 && beat_count>=2)) begin
                            cache_wr_en<=1;cache_wr_odd<=req_row[0];
                            cache_wr_addr<=req_base+beat_count-((req_band==7)?2:1);
                            cache_wr_data<={ddr_rdata[15:0],previous_beat};
                        end
                        if(beat_count==15) begin
                            flush_pending<=(req_band==7);req_state<=DRAIN;
                        end else beat_count<=beat_count+1'b1;
                    end
                end
                DRAIN: begin
                    if(ddr_rdone) done_seen<=1;
                    if(flush_pending) begin
                        cache_wr_en<=1;cache_wr_odd<=req_row[0];cache_wr_addr<=req_base+14;
                        cache_wr_data<={previous_beat[255:240],previous_beat};flush_pending<=0;
                    end else if(!cache_wr_en && (done_seen || ddr_rdone)) req_state<=COMMIT;
                end
                COMMIT: begin
                    committed_row[req_band]<=req_row;committed_valid[req_band]<=1;
                    next_row[req_band]<=req_row+1'b1;req_state<=IDLE;
                end
                default:req_state<=IDLE;
            endcase
        end
    end
endmodule

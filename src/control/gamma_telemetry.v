`timescale 1ns/1ps
// Input-domain frame snapshot. Raw stats arrive with the gamma output SOF.
// Register output luma before the accumulator to separate the gamma ROM and
// RGB-weighting delay from the 32-bit carry chain. Metadata follows that stage.
// Packed fields are little-endian when serialized by cp2102_control.
module gamma_telemetry (
    input clk,rstn,stats_valid,out_vs,out_de,
    input [7:0] out_r,out_g,out_b,
    input [31:0] luma_sum,pixel_count,dark_count,highlight_count,
    input [2:0] stats_curve,stats_target,frame_mask,
    input stats_enabled,
    output reg sample_valid,
    output reg [223:0] sample_data
);
    reg [31:0] frame_index,output_sum;
    reg [2:0] mask_q;
    reg vs_d;
    reg [7:0] luma_q;
    reg de_q,sof_q,stats_valid_q;
    reg [191:0] stats_q;
    wire [9:0] luma={2'b0,out_r}+{1'b0,out_g,1'b0}+{2'b0,out_b};
    always @(posedge clk or negedge rstn)
        if(!rstn) begin
            vs_d<=0;output_sum<=0;frame_index<=0;sample_valid<=0;sample_data<=0;
            mask_q<=0;
            luma_q<=0;de_q<=0;sof_q<=0;stats_valid_q<=0;stats_q<=0;
        end else begin
            vs_d<=out_vs;sample_valid<=0;
            luma_q<=luma[9:2];de_q<=out_de;sof_q<=out_vs && !vs_d;
            stats_valid_q<=stats_valid;
            if(out_vs && !vs_d) mask_q<=frame_mask;
            if(sof_q) output_sum<=de_q ? {24'd0,luma_q} : 0;
            else if(de_q) output_sum<=output_sum+luma_q;
            if(stats_valid) begin
                frame_index<=frame_index+1'b1;
                stats_q<={{5'd0,mask_q},{7'd0,stats_enabled},
                    {5'd0,stats_target},{5'd0,stats_curve},
                    highlight_count,dark_count,pixel_count,luma_sum,frame_index};
            end
            // At this edge output_sum includes the last prior-frame pixel;
            // nonblocking reset at sof_q starts the new frame afterwards.
            if(stats_valid_q) begin
                sample_valid<=1;
                sample_data<={stats_q[191:160],output_sum,stats_q[159:0]};
            end
        end
endmodule

`timescale 1ns/1ps
// Commands are acknowledged only when atomically applied at input SOF.
// Source holds the requested mask until that acknowledgement returns.
module video_control_cdc #(parameter [2:0] DEFAULT_MASK=3'b111) (
    input sys_clk, vin_clk, rstn, frame_start,
    input command_valid,
    input [2:0] command_mask,
    output busy,
    output reg [2:0] requested_mask, applied_mask_sys,
    output reg [2:0] applied_mask_vin,
    output [2:0] next_mask_vin
);
    reg request,acknowledge,ack_seen;
    (* ASYNC_REG="TRUE" *) reg [1:0] req_sync,ack_sync;
    assign busy=request!=ack_seen;
    // Gamma samples its enable on the same registered SOF that commits the
    // mask below. Present that commit value before the edge, not one frame late.
    // The source holds requested_mask stable until acknowledge returns.
    assign next_mask_vin=(req_sync[1]!=acknowledge) ? requested_mask : applied_mask_vin;
    always @(posedge sys_clk or negedge rstn)
        if(!rstn) begin
            requested_mask<=DEFAULT_MASK;applied_mask_sys<=DEFAULT_MASK;
            request<=0;ack_sync<=0;ack_seen<=0;
        end else begin
            ack_sync<={ack_sync[0],acknowledge};
            if(command_valid && !busy) begin
                requested_mask<=command_mask;request<=~request;
            end
            if(ack_sync[1]!=ack_seen) begin
                applied_mask_sys<=applied_mask_vin;ack_seen<=ack_sync[1];
            end
        end
    always @(posedge vin_clk or negedge rstn)
        if(!rstn) begin req_sync<=0;acknowledge<=0;applied_mask_vin<=DEFAULT_MASK;end
        else begin
            req_sync<={req_sync[0],request};
            if(frame_start && req_sync[1]!=acknowledge) begin
                applied_mask_vin<=requested_mask;acknowledge<=req_sync[1];
            end
        end
endmodule

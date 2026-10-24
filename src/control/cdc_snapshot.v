`timescale 1ns/1ps
// Bundled-data mailbox with returned acknowledgement. Source data is held
// until the destination has copied it; a busy sample is dropped, never torn.
// Both domains must share the same asynchronous reset assertion.
module cdc_snapshot #(parameter WIDTH=32) (
    input src_clk, dst_clk, rstn,
    input src_valid,
    input [WIDTH-1:0] src_data,
    output src_busy,
    output reg dst_valid,
    output reg [WIDTH-1:0] dst_data
);
    reg [WIDTH-1:0] holding;
    reg request, acknowledge;
    (* ASYNC_REG="TRUE" *) reg [1:0] req_sync,ack_sync;
    assign src_busy=request!=ack_sync[1];
    always @(posedge src_clk or negedge rstn)
        if(!rstn) begin holding<=0;request<=0;ack_sync<=0;end
        else begin
            ack_sync<={ack_sync[0],acknowledge};
            if(src_valid && !src_busy) begin holding<=src_data;request<=~request;end
        end
    always @(posedge dst_clk or negedge rstn)
        if(!rstn) begin req_sync<=0;acknowledge<=0;dst_data<=0;dst_valid<=0;end
        else begin
            req_sync<={req_sync[0],request};dst_valid<=0;
            if(req_sync[1]!=acknowledge) begin
                dst_data<=holding;dst_valid<=1;acknowledge<=req_sync[1];
            end
        end
endmodule

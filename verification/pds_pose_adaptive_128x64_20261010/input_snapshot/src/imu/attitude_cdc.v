`timescale 1ns/1ps
// Snapshot synchronizer. Data is held stable in the source domain while the
// toggle crosses two flops; the destination then captures the whole snapshot.
module attitude_cdc (
    input  wire       src_clk,
    input  wire       src_rstn,
    input  wire [15:0] src_yaw,
    input  wire [15:0] src_pitch,
    input  wire [15:0] src_roll,
    input  wire        src_toggle,
    input  wire        dst_clk,
    input  wire        dst_rstn,
    output reg [15:0] dst_yaw,
    output reg [15:0] dst_pitch,
    output reg [15:0] dst_roll,
    output reg        dst_valid
);
    reg toggle_meta, toggle_sync;
    reg toggle_seen;
    reg [15:0] yaw_meta, pitch_meta, roll_meta;
    always @(posedge dst_clk or negedge dst_rstn) begin
        if (!dst_rstn) begin
            toggle_meta <= 0; toggle_sync <= 0; toggle_seen <= 0;
            yaw_meta <= 0; pitch_meta <= 0; roll_meta <= 0;
            dst_yaw <= 0; dst_pitch <= 0; dst_roll <= 0; dst_valid <= 0;
        end else begin
            toggle_meta <= src_toggle;
            toggle_sync <= toggle_meta;
            yaw_meta <= src_yaw;
            pitch_meta <= src_pitch;
            roll_meta <= src_roll;
            dst_valid <= 1'b0;
            if (toggle_sync != toggle_seen) begin
                dst_yaw <= yaw_meta;
                dst_pitch <= pitch_meta;
                dst_roll <= roll_meta;
                dst_valid <= 1'b1;
                toggle_seen <= toggle_sync;
            end
        end
    end
endmodule

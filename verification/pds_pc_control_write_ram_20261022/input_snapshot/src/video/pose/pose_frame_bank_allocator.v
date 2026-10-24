`timescale 1ns/1ps
// Frame ownership for the arbitrary yaw/pitch renderer.
// Banks 0/1 hold completed camera source frames. Banks 2/3 hold completed
// rendered frames. A bank is published to HDMI only at frame_start, so a
// renderer can never overwrite the frame currently being displayed.
module pose_frame_bank_allocator (
    input        clk,
    input        rstn,
    input        frame_start,
    input        source_frame_done,
    input  [1:0] source_done_bank,
    input        render_frame_done,
    input  [1:0] render_done_bank,
    output reg [1:0] source_write_bank,
    output reg [1:0] source_read_bank,
    output reg [1:0] render_write_bank,
    output reg [1:0] display_bank,
    output reg       source_ready,
    output reg       render_start,
    output reg       render_busy
);
    reg render_done_pending;
    reg [1:0] pending_display_bank;
    reg source_pending;
    reg [1:0] pending_source_bank;
    reg [1:0] last_render_bank;

    function automatic [1:0] next_source_bank(input [1:0] bank);
        next_source_bank = (bank == 2'd0) ? 2'd1 : 2'd0;
    endfunction

    function automatic [1:0] next_render_bank(input [1:0] shown, input [1:0] last);
        // Prefer the bank that is not currently shown and not the last bank.
        if (shown != 2'd2 && last != 2'd2) next_render_bank = 2'd2;
        else next_render_bank = 2'd3;
    endfunction

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            source_write_bank <= 2'd0;
            source_read_bank <= 2'd0;
            render_write_bank <= 2'd2;
            display_bank <= 2'd2;
            source_ready <= 1'b0;
            render_start <= 1'b0;
            render_busy <= 1'b0;
            render_done_pending <= 1'b0;
            pending_display_bank <= 2'd2;
            source_pending <= 1'b0;
            pending_source_bank <= 2'd0;
            last_render_bank <= 2'd3;
        end else begin
            render_start <= 1'b0;

            if (source_frame_done && (source_done_bank < 2)) begin
                source_read_bank <= source_done_bank;
                source_ready <= 1'b1;
                source_write_bank <= next_source_bank(source_done_bank);
                // Always queue the event. Starting on the following clock
                // makes the source-bank publication and renderer launch an
                // explicit handshake rather than a same-edge assumption.
                source_pending <= 1'b1;
                pending_source_bank <= source_done_bank;
            end

            if (render_frame_done && render_busy &&
                (render_done_bank == render_write_bank)) begin
                render_busy <= 1'b0;
                render_done_pending <= 1'b1;
                pending_display_bank <= render_done_bank;
                last_render_bank <= render_done_bank;
            end

            // A completed rendered frame becomes visible only on VS/frame
            // boundary. This is the tear-free handoff point.
            if (frame_start && render_done_pending) begin
                display_bank <= pending_display_bank;
                render_done_pending <= 1'b0;
            end

            // Start one renderer transaction per completed source frame. The
            // destination is always the output bank not visible to HDMI.
            if (!render_busy && source_ready && source_pending) begin
                source_read_bank <= pending_source_bank;
                source_pending <= 1'b0;
                render_write_bank <= next_render_bank(display_bank, last_render_bank);
                render_start <= 1'b1;
                render_busy <= 1'b1;
            end
        end
    end
endmodule

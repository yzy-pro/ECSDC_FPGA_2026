`timescale 1ns/1ps
module tb_pose_frame_bank_allocator;
    reg clk=0, rstn=0, frame_start=0;
    reg source_frame_done=0, render_frame_done=0;
    reg [1:0] source_done_bank=0, render_done_bank=0;
    wire [1:0] source_write_bank, source_read_bank, render_write_bank, display_bank;
    wire source_ready, render_start, render_busy;
    pose_frame_bank_allocator dut(.*);
    always #5 clk=~clk;
    task tick; begin @(posedge clk); #1; end endtask
    initial begin
        repeat(2) tick; rstn=1;
        source_done_bank=0; source_frame_done=1; tick; source_frame_done=0;
        tick;
        if (!source_ready || source_read_bank!==0 || !render_start || !render_busy)
            $fatal(1,"first source did not launch renderer");
        tick;
        render_done_bank=render_write_bank; render_frame_done=1; tick; render_frame_done=0;
        if (render_busy || !dut.render_done_pending) $fatal(1,"render completion lost");
        frame_start=1; tick; frame_start=0;
        if (display_bank!==render_done_bank) $fatal(1,"display bank changed outside VS");
        source_done_bank=1; source_frame_done=1; tick; source_frame_done=0; tick;
        if (source_write_bank!==0 || source_read_bank!==1 || !render_start)
            $fatal(1,"second source bank ownership incorrect");
        tick;
        render_done_bank=render_write_bank; render_frame_done=1; tick; render_frame_done=0;
        frame_start=1; tick; frame_start=0;
        if (display_bank!==render_done_bank) $fatal(1,"second rendered bank not published");
        $display("PASS pose frame bank allocator: source/render/display ownership and VS handoff");
        $finish;
    end
endmodule

`timescale 1ns / 1ps

module tb_pose_inverse_project_q14;
    parameter integer RECIPROCAL_LUT_ENABLE = 0;
    reg clk = 1'b0;
    reg rstn = 1'b0;
    reg pose_load = 1'b0;
    reg signed [15:0] pose_yaw_q2048 = 16'sd0;
    reg signed [15:0] pose_pitch_q2048 = 16'sd0;
    wire pose_clamped;
    wire pose_ready;
    reg in_valid = 1'b0;
    reg [10:0] dst_x = 11'd0;
    reg [10:0] dst_y = 11'd0;
    wire out_valid;
    wire map_valid;
    wire signed [31:0] src_x_q14;
    wire signed [31:0] src_y_q14;
    integer failures = 0;

    pose_inverse_project_q14 #(.RECIPROCAL_LUT_ENABLE(RECIPROCAL_LUT_ENABLE)) dut (
        .clk(clk),
        .rstn(rstn),
        .pose_load(pose_load),
        .pose_yaw_q2048(pose_yaw_q2048),
        .pose_pitch_q2048(pose_pitch_q2048),
        .pose_clamped(pose_clamped),
        .pose_ready(pose_ready),
        .in_valid(in_valid),
        .dst_x(dst_x),
        .dst_y(dst_y),
        .out_valid(out_valid),
        .map_valid(map_valid),
        .src_x_q14(src_x_q14),
        .src_y_q14(src_y_q14)
    );

    always #5 clk = ~clk;

    task load_pose;
        input signed [15:0] yaw;
        input signed [15:0] pitch;
        begin
            pose_yaw_q2048 = yaw;
            pose_pitch_q2048 = pitch;
            pose_load = 1'b1;
            @(posedge clk);
            #1 pose_load = 1'b0;
            wait(pose_ready);
            @(posedge clk);
            #1;
        end
    endtask

    task expect_pixel;
        input [10:0] x;
        input [10:0] y;
        input expected_valid;
        input integer expected_x;
        input integer expected_y;
        input integer tolerance_pixels;
        integer wait_cycles;
        integer error_x;
        integer error_y;
        begin
            dst_x = x;
            dst_y = y;
            in_valid = 1'b1;
            @(posedge clk);
            #1 in_valid = 1'b0;

            wait_cycles = 0;
            while (!out_valid && wait_cycles < 80) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (!out_valid) begin
                $display("FAIL timeout for destination (%0d,%0d)", x, y);
                failures = failures + 1;
            end else if (map_valid != expected_valid) begin
                $display("FAIL map_valid for destination (%0d,%0d): got %0d expected %0d",
                         x, y, map_valid, expected_valid);
                failures = failures + 1;
            end else if (expected_valid) begin
                error_x = ($signed(src_x_q14) >>> 14) - expected_x;
                error_y = ($signed(src_y_q14) >>> 14) - expected_y;
                if (error_x < 0) error_x = -error_x;
                if (error_y < 0) error_y = -error_y;
                if (error_x > tolerance_pixels || error_y > tolerance_pixels) begin
                    $display("FAIL destination (%0d,%0d): got (%0d,%0d), expected (%0d,%0d) +/- %0d",
                             x, y, $signed(src_x_q14) >>> 14,
                             $signed(src_y_q14) >>> 14, expected_x, expected_y,
                             tolerance_pixels);
                    failures = failures + 1;
                end
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        #1 rstn = 1'b1;

        // Identity validates the calibration path and pixel-centre convention.
        load_pose(16'sd0, 16'sd0);
        expect_pixel(11'd944, 11'd522, 1'b1, 944, 522, 2);

        // Expected coordinates come from tools/audit_rotation_tiles.py using
        // the same Q2048 angle convention and camera calibration.
        load_pose(16'sd1072, 16'sd0);       // about +30 degrees yaw
        expect_pixel(11'd944, 11'd522, 1'b1, 1375, 522, 4);

        load_pose(-16'sd1072, 16'sd0);      // about -30 degrees yaw
        expect_pixel(11'd944, 11'd522, 1'b1, 513, 522, 4);

        load_pose(16'sd0, 16'sd715);        // about +20 degrees pitch down
        expect_pixel(11'd944, 11'd522, 1'b1, 944, 250, 4);

        load_pose(16'sd1072, 16'sd715);
        expect_pixel(11'd600, 11'd400, 1'b1, 1022, 117, 5);

        // A 35-degree clamp must flag the pose and leave a source-FOV hole
        // black instead of repeating an edge pixel.
        load_pose(16'sd1600, 16'sd0);
        if (!pose_clamped) begin
            $display("FAIL clamp flag was not asserted");
            failures = failures + 1;
        end
        expect_pixel(11'd1919, 11'd540, 1'b0, 0, 0, 0);

        if (failures != 0)
            $fatal(1, "tb_pose_inverse_project_q14: %0d failure(s)", failures);
        $display("PASS tb_pose_inverse_project_q14");
        $finish;
    end
endmodule

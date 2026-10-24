`timescale 1ns/1ps
// Bounded yaw/pitch inverse sampling; roll does not affect the image.
// Camera axes: x right, y down, z forward. Positive yaw is right-handed
// about UP; positive pitch means head DOWN. Thus sample x increases for
// positive yaw and sample y decreases for positive pitch.
// Angles are signed Q2048 radians. The integration gain is 16 source
// pixels/radian, capped at +/-2 pixels, NOT a calibrated perspective model.
// Preserve three pipeline stages and the roll port for protocol compatibility.
module imu_affine_q14 (
    input clk,
    input signed [31:0] src_x_q14, src_y_q14,
    input signed [15:0] yaw, pitch, roll,
    output reg signed [31:0] dst_x_q14, dst_y_q14
);
    function signed [31:0] translation;
        input signed [15:0] angle;
        reg signed [31:0] wide;
        begin
            wide = {{16{angle[15]}},angle};
            wide = wide <<< 7;
            translation = (wide > 32'sd32768) ? 32'sd32768 :
                          (wide < -32'sd32768) ? -32'sd32768 : wide;
        end
    endfunction
    reg signed [31:0] x_base,y_base,x_base_d,y_base_d;
    reg signed [31:0] tx,ty;
    reg signed [15:0] yaw_d,pitch_d;
    always @(posedge clk) begin
        x_base <= src_x_q14;y_base <= src_y_q14;
        yaw_d <= yaw;pitch_d <= pitch;
        x_base_d <= x_base;y_base_d <= y_base;
        tx <= translation(yaw_d);ty <= translation(pitch_d);
        dst_x_q14 <= x_base_d+tx;
        // Negate after widening/saturation: -32768 int16 must not wrap.
        dst_y_q14 <= y_base_d-ty;
    end
endmodule

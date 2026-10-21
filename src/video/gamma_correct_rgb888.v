`timescale 1ns / 1ps

// Gamma correction after the explicit RGB565 -> RGB888 conversion.
// Quantizing back to the source channel precision selects the same compact
// LUT entries as the original RGB565 gamma path without a large 256-entry ROM.
module gamma_correct_rgb888 #(
    parameter GAMMA_ENABLE = 1'b1
) (
    input              clk,
    input              rstn,
    input              de_in,
    input      [7:0]   r_in,
    input      [7:0]   g_in,
    input      [7:0]   b_in,
    output reg         de_out,
    output reg [7:0]   r_out,
    output reg [7:0]   g_out,
    output reg [7:0]   b_out
);

    function automatic [7:0] gamma5;
        input [4:0] value;
        begin
            case (value)
                5'd0:  gamma5 = 8'd0;
                5'd1:  gamma5 = 8'd54;
                5'd2:  gamma5 = 8'd73;
                5'd3:  gamma5 = 8'd88;
                5'd4:  gamma5 = 8'd101;
                5'd5:  gamma5 = 8'd111;
                5'd6:  gamma5 = 8'd121;
                5'd7:  gamma5 = 8'd130;
                5'd8:  gamma5 = 8'd138;
                5'd9:  gamma5 = 8'd145;
                5'd10: gamma5 = 8'd152;
                5'd11: gamma5 = 8'd159;
                5'd12: gamma5 = 8'd166;
                5'd13: gamma5 = 8'd172;
                5'd14: gamma5 = 8'd178;
                5'd15: gamma5 = 8'd183;
                5'd16: gamma5 = 8'd189;
                5'd17: gamma5 = 8'd194;
                5'd18: gamma5 = 8'd199;
                5'd19: gamma5 = 8'd204;
                5'd20: gamma5 = 8'd209;
                5'd21: gamma5 = 8'd214;
                5'd22: gamma5 = 8'd218;
                5'd23: gamma5 = 8'd223;
                5'd24: gamma5 = 8'd227;
                5'd25: gamma5 = 8'd231;
                5'd26: gamma5 = 8'd235;
                5'd27: gamma5 = 8'd239;
                5'd28: gamma5 = 8'd243;
                5'd29: gamma5 = 8'd247;
                5'd30: gamma5 = 8'd251;
                default: gamma5 = 8'd255;
            endcase
        end
    endfunction

    function automatic [7:0] gamma6;
        input [5:0] value;
        begin
            case (value)
                6'd0:  gamma6 = 8'd0;
                6'd1:  gamma6 = 8'd39;
                6'd2:  gamma6 = 8'd53;
                6'd3:  gamma6 = 8'd64;
                6'd4:  gamma6 = 8'd73;
                6'd5:  gamma6 = 8'd81;
                6'd6:  gamma6 = 8'd88;
                6'd7:  gamma6 = 8'd94;
                6'd8:  gamma6 = 8'd100;
                6'd9:  gamma6 = 8'd105;
                6'd10: gamma6 = 8'd110;
                6'd11: gamma6 = 8'd115;
                6'd12: gamma6 = 8'd120;
                6'd13: gamma6 = 8'd124;
                6'd14: gamma6 = 8'd129;
                6'd15: gamma6 = 8'd133;
                6'd16: gamma6 = 8'd137;
                6'd17: gamma6 = 8'd141;
                6'd18: gamma6 = 8'd144;
                6'd19: gamma6 = 8'd148;
                6'd20: gamma6 = 8'd151;
                6'd21: gamma6 = 8'd155;
                6'd22: gamma6 = 8'd158;
                6'd23: gamma6 = 8'd161;
                6'd24: gamma6 = 8'd164;
                6'd25: gamma6 = 8'd168;
                6'd26: gamma6 = 8'd171;
                6'd27: gamma6 = 8'd173;
                6'd28: gamma6 = 8'd176;
                6'd29: gamma6 = 8'd179;
                6'd30: gamma6 = 8'd182;
                6'd31: gamma6 = 8'd185;
                6'd32: gamma6 = 8'd187;
                6'd33: gamma6 = 8'd190;
                6'd34: gamma6 = 8'd193;
                6'd35: gamma6 = 8'd195;
                6'd36: gamma6 = 8'd198;
                6'd37: gamma6 = 8'd200;
                6'd38: gamma6 = 8'd203;
                6'd39: gamma6 = 8'd205;
                6'd40: gamma6 = 8'd207;
                6'd41: gamma6 = 8'd210;
                6'd42: gamma6 = 8'd212;
                6'd43: gamma6 = 8'd214;
                6'd44: gamma6 = 8'd217;
                6'd45: gamma6 = 8'd219;
                6'd46: gamma6 = 8'd221;
                6'd47: gamma6 = 8'd223;
                6'd48: gamma6 = 8'd225;
                6'd49: gamma6 = 8'd227;
                6'd50: gamma6 = 8'd230;
                6'd51: gamma6 = 8'd232;
                6'd52: gamma6 = 8'd234;
                6'd53: gamma6 = 8'd236;
                6'd54: gamma6 = 8'd238;
                6'd55: gamma6 = 8'd240;
                6'd56: gamma6 = 8'd242;
                6'd57: gamma6 = 8'd244;
                6'd58: gamma6 = 8'd246;
                6'd59: gamma6 = 8'd248;
                6'd60: gamma6 = 8'd249;
                6'd61: gamma6 = 8'd251;
                6'd62: gamma6 = 8'd253;
                default: gamma6 = 8'd255;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (!rstn) begin
            de_out <= 1'b0;
            r_out <= 8'd0;
            g_out <= 8'd0;
            b_out <= 8'd0;
        end else begin
            de_out <= de_in;
            if (!de_in) begin
                r_out <= 8'd0;
                g_out <= 8'd0;
                b_out <= 8'd0;
            end else if (GAMMA_ENABLE) begin
                r_out <= gamma5(r_in[7:3]);
                g_out <= gamma6(g_in[7:2]);
                b_out <= gamma5(b_in[7:3]);
            end else begin
                r_out <= r_in;
                g_out <= g_in;
                b_out <= b_in;
            end
        end
    end
endmodule

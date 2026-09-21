`timescale 1ns / 1ps

module iic_driver #(
    parameter integer CLK_FRE = 27'd50_000_000,
    parameter integer IIC_FREQ = 20'd400_000,
    parameter integer T_WR = 10'd5,
    parameter integer DEVICE_ID = 8'hA0,
    parameter integer ADDR_BYTE = 2'd1,
    parameter integer LEN_WIDTH = 8'd3,
    parameter integer DATA_BYTE = 2'd1
) (
    input clk,
    input rstn,
    input pluse,
    input w_r,
    input [LEN_WIDTH:0] byte_len,
    input [7:0] addr,
    input [7:0] data_in,
    output reg busy = 1'b0,
    output reg byte_over = 1'b0,
    output [7:0] data_out,
    output scl,
    input sda_in,
    output reg sda_out = 1'b1,
    output sda_out_en
);
    localparam integer ClkDiv = CLK_FRE / IIC_FREQ;
    localparam integer IdAddrByte = ADDR_BYTE + 1;
    localparam integer DataSet = ClkDiv >> 2;
    localparam integer TWrDelay = T_WR * CLK_FRE / 1000;

    reg [20:0] fre_cnt;
    always @(posedge clk) begin
        if (!rstn) fre_cnt <= 21'd0;
        else if (fre_cnt == ClkDiv - 1'b1) fre_cnt <= 21'd0;
        else fre_cnt <= fre_cnt + 1'b1;
    end
    wire full_cycle = (fre_cnt == ClkDiv - 1'b1);
    wire half_cycle = (fre_cnt == (ClkDiv >> 1) - 1'b1);
    wire start_h = (fre_cnt == DataSet - 1'b1);
    wire dsu = (fre_cnt == (ClkDiv >> 1) + DataSet - 1'b1);

    wire start;
    reg start_en;
    reg pluse_1d, pluse_2d, pluse_3d;
    always @(posedge clk) begin
        if (!rstn) begin
            pluse_1d <= 1'b0;
            pluse_2d <= 1'b0;
            pluse_3d <= 1'b0;
        end
        else begin
            pluse_1d <= pluse;
            pluse_2d <= pluse_1d;
            pluse_3d <= pluse_2d;
        end
    end
    always @(posedge clk) begin
        if (start || !rstn) start_en <= 1'b0;
        else if (!pluse_3d && pluse_2d) start_en <= 1'b1;
    end
    assign start = start_en && full_cycle;

    reg w_r_1d = 1'b0, w_r_2d = 1'b0;
    always @(posedge clk) begin
        if (!rstn) begin
            w_r_1d <= 1'b0;
            w_r_2d <= 1'b0;
        end
        else begin
            w_r_1d <= w_r;
            w_r_2d <= w_r_1d;
        end
    end

    localparam integer StIdle   = 3'd0;
    localparam integer StStart  = 3'd1;
    localparam integer StSend   = 3'd2;
    localparam integer StSAck   = 3'd3;
    localparam integer StReceiv = 3'd4;
    localparam integer StRAck   = 3'd5;
    localparam integer StStop   = 3'd6;
    reg [2:0] state, state_n;
    reg [2:0] trans_bit = 3'd0;
    reg [LEN_WIDTH:0] trans_byte = 5'd0;
    reg [LEN_WIDTH:0] trans_byte_max = 5'd0;
    reg [7:0] send_data = 8'd0;
    reg [7:0] receiv_data = 8'd0;
    reg trans_en = 1'b0;
    reg scl_out = 1'b1;
    assign scl = scl_out;

    always @(posedge clk) begin
        if (start) trans_en <= 1'b1;
        else if (state == StStop && start_h) trans_en <= 1'b0;
    end
    reg twr_en = 1'b0;
    reg [26:0] twr_cnt = 27'd0;
    always @(posedge clk) begin
        if (state == StStop && dsu) twr_en <= 1'b1;
        else if (twr_cnt == TWrDelay) twr_en <= 1'b0;
    end
    always @(posedge clk) begin
        if (twr_en) begin
            if (twr_cnt == TWrDelay) twr_cnt <= 27'd0;
            else twr_cnt <= twr_cnt + 1'b1;
        end
    end
    always @(posedge clk) begin
        if (start_en) busy <= 1'b1;
        else if (twr_cnt == TWrDelay) busy <= 1'b0;
    end
    always @(posedge clk) begin
        if (trans_en) begin
            if (half_cycle || full_cycle) scl_out <= ~scl_out;
        end
        else scl_out <= 1'b1;
    end
    assign sda_out_en = (state == StSAck) || (state == StReceiv);

    always @(posedge clk) begin
        if (start) send_data <= {DEVICE_ID[7:1], 1'b0};
        else if (state == StSAck && full_cycle) begin
            case (trans_byte)
                5'd0: send_data <= {DEVICE_ID[7:1], 1'b0};
                5'd1: send_data <= addr;
                5'd2: send_data <= w_r_2d ? data_in : {DEVICE_ID[7:1], 1'b1};
                default: send_data <= data_in;
            endcase
        end
    end
    always @(posedge clk) begin
        if (start) begin
            if (w_r_2d) trans_byte_max <= ADDR_BYTE + byte_len + 2'd1;
            else trans_byte_max <= ADDR_BYTE + byte_len + 2'd2;
        end
    end
    always @(posedge clk) begin
        case (state)
            StIdle: sda_out <= 1'b1;
            StStart: begin
                if (start_h) sda_out <= 1'b0;
                else if (dsu) sda_out <= send_data[7-trans_bit];
            end
            StSend: sda_out <= send_data[7-trans_bit];
            StSAck: begin
                if (trans_byte == IdAddrByte && dsu && !w_r_2d) sda_out <= 1'b1;
                else sda_out <= 1'b0;
            end
            StRAck: begin
                if (trans_byte < trans_byte_max) sda_out <= 1'b0;
                else if (dsu) sda_out <= 1'b0;
                else sda_out <= 1'b1;
            end
            StStop: begin
                if (start_h) sda_out <= 1'b1;
            end
            default: sda_out <= 1'b1;
        endcase
    end
    always @(posedge clk) begin
        if (state == StReceiv) begin
            if (full_cycle) receiv_data <= {receiv_data[6:0], sda_in};
        end
        else receiv_data <= 8'd0;
    end
    reg [7:0] data_out_reg = 8'd0;
    always @(posedge clk) begin
        if (!rstn) data_out_reg <= 8'd0;
        else if (state == StReceiv && trans_bit == 3'd7 && half_cycle) data_out_reg <= receiv_data;
    end
    assign data_out = data_out_reg;
    always @(posedge clk) begin
        if (w_r_2d) begin
            if (trans_byte > IdAddrByte - 1'b1 && dsu && trans_bit == 3'd7) byte_over <= 1'b1;
            else byte_over <= 1'b0;
        end
        else begin
            if (trans_byte > IdAddrByte && dsu && trans_bit == 3'd7) byte_over <= 1'b1;
            else byte_over <= 1'b0;
        end
    end
    always @(posedge clk) begin
        if (state == StSend || state == StReceiv) begin
            if (dsu) trans_bit <= trans_bit + 1'b1;
        end
        else trans_bit <= 3'd0;
    end
    always @(posedge clk) begin
        if (start) trans_byte <= 5'd0;
        else if ((state == StSend || state == StReceiv) && dsu && trans_bit == 3'd7)
            trans_byte <= trans_byte + 1'b1;
    end
    always @(posedge clk) begin
        if (!rstn) state <= StIdle;
        else state <= state_n;
    end
    always @(*) begin
        state_n = state;
        case (state)
            StIdle: if (start) state_n = StStart;
            StStart: if (dsu) state_n = StSend;
            StSend: if (trans_bit == 3'd7 && dsu) state_n = StSAck;
            StSAck: begin
                if (dsu) begin
                    if (w_r_2d) begin
                        if (trans_byte < IdAddrByte) state_n = StSend;
                        else if (trans_byte < trans_byte_max) state_n = StSend;
                        else state_n = StStop;
                    end
                    else begin
                        if (trans_byte < IdAddrByte) state_n = StSend;
                        else if (trans_byte == IdAddrByte) state_n = StStart;
                        else state_n = StReceiv;
                    end
                end
            end
            StReceiv: if (trans_bit == 3'd7 && dsu) state_n = StRAck;
            StRAck: begin
                if (dsu) begin
                    if (trans_byte < trans_byte_max) state_n = StReceiv;
                    else state_n = StStop;
                end
            end
            StStop: if (dsu) state_n = StIdle;
            default: state_n = StIdle;
        endcase
    end
endmodule

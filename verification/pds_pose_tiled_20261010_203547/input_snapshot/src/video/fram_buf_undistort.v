`timescale 1ns / 1ps

module fram_buf_undistort #(
    parameter MEM_ROW_WIDTH = 15,
    parameter MEM_COLUMN_WIDTH = 10,
    parameter MEM_BANK_WIDTH = 3,
    parameter CTRL_ADDR_WIDTH = MEM_ROW_WIDTH + MEM_BANK_WIDTH + MEM_COLUMN_WIDTH,
    parameter MEM_DQ_WIDTH = 32,
    parameter H_NUM = 1920,
    parameter V_NUM = 1080,
    parameter PIX_WIDTH = 16,
    parameter INTERPOLATION_MODE = 1,
    parameter signed [17:0] P1_Q14 = 18'sd0,
    parameter signed [17:0] P2_Q14 = 18'sd0,
    parameter ATTITUDE_WARP_ENABLE = 1'b1
) (
    input vin_clk,
    input wr_fsync,
    input wr_active,
    input wr_en,
    input [PIX_WIDTH-1:0] wr_data,
    output reg init_done = 1'b0,
    input ddr_clk,
    input ddr_rstn,
    input vout_clk,
    input rd_fsync,
    input rd_active,
    input rd_en,
    input [15:0] imu_yaw,
    input [15:0] imu_pitch,
    input [15:0] imu_roll,
    input        imu_valid,
    output vout_de,
    output [PIX_WIDTH-1:0] vout_data,
    output [CTRL_ADDR_WIDTH-1:0] axi_awaddr,
    output [3:0] axi_awid,
    output [3:0] axi_awlen,
    output [2:0] axi_awsize,
    output [1:0] axi_awburst,
    input axi_awready,
    output axi_awvalid,
    output [MEM_DQ_WIDTH*8-1:0] axi_wdata,
    output [MEM_DQ_WIDTH-1:0] axi_wstrb,
    input axi_wlast,
    output axi_wvalid,
    input axi_wready,
    input [3:0] axi_bid,
    output [CTRL_ADDR_WIDTH-1:0] axi_araddr,
    output [3:0] axi_arid,
    output [3:0] axi_arlen,
    output [2:0] axi_arsize,
    output [1:0] axi_arburst,
    output axi_arvalid,
    input axi_arready,
    output axi_rready,
    input [MEM_DQ_WIDTH*8-1:0] axi_rdata,
    input axi_rvalid,
    input axi_rlast,
    input [3:0] axi_rid
);
    localparam integer LINE_WORDS = H_NUM * PIX_WIDTH / (MEM_DQ_WIDTH * 8);
    wire ddr_wreq;
    wire [CTRL_ADDR_WIDTH-1:0] ddr_waddr;
    wire [15:0] ddr_wr_len;
    wire ddr_wrdy;
    wire ddr_wdone;
    wire [MEM_DQ_WIDTH*8-1:0] ddr_wdata;
    wire ddr_wdata_req;
    wire frame_wirq;
    wire [CTRL_ADDR_WIDTH-22-1:0] frame_wcnt;
    wire rd_cmd_en;
    wire [CTRL_ADDR_WIDTH-1:0] rd_cmd_addr;
    wire [31:0] rd_cmd_len;
    wire rd_cmd_ready;
    wire rd_cmd_done;
    wire [MEM_DQ_WIDTH*8-1:0] read_rdata;
    wire read_en;
    wire ddr_wr_bac;
    reg [1:0] completed_frame_bank = 2'd0;
    wire [1:0] display_frame_bank;

    wr_buf #(
        .ADDR_WIDTH(CTRL_ADDR_WIDTH),
        .H_NUM(H_NUM),
        .V_NUM(V_NUM),
        .DQ_WIDTH(MEM_DQ_WIDTH),
        .PIX_WIDTH(PIX_WIDTH),
        .LINE_ADDR_WIDTH(22),
        .FRAME_CNT_WIDTH(CTRL_ADDR_WIDTH-22)
    ) u_wr_buf (
        .ddr_clk(ddr_clk), .ddr_rstn(ddr_rstn),
        .wr_clk(vin_clk), .wr_fsync(wr_fsync), .wr_active(wr_active),
        .wr_en(wr_en), .wr_data(wr_data),
        .display_frame_bank(display_frame_bank),
        .rd_bac(ddr_wr_bac), .ddr_wreq(ddr_wreq), .ddr_waddr(ddr_waddr),
        .ddr_wr_len(ddr_wr_len), .ddr_wrdy(ddr_wrdy), .ddr_wdone(ddr_wdone),
        .ddr_wdata(ddr_wdata), .ddr_wdata_req(ddr_wdata_req),
        .frame_wcnt(frame_wcnt), .frame_wirq(frame_wirq)
    );

    always @(posedge ddr_clk) begin
        if (!ddr_rstn) begin
            init_done <= 1'b0;
            completed_frame_bank <= 2'd0;
        end else if (frame_wirq) begin
            init_done <= 1'b1;
            // frame_wcnt is still the bank that was written during the frame
            // ending at frame_wirq.  Latch it before the writer selects the
            // other bank for the next active frame.
            completed_frame_bank <= frame_wcnt[1:0];
        end
    end

    undistort_rd_buf #(
        .ADDR_WIDTH(CTRL_ADDR_WIDTH), .H_NUM(H_NUM), .V_NUM(V_NUM),
        .DQ_WIDTH(MEM_DQ_WIDTH), .PIX_WIDTH(PIX_WIDTH), .LINE_ADDR_WIDTH(22),
        .INTERPOLATION_MODE(INTERPOLATION_MODE),
        .P1_Q14(P1_Q14), .P2_Q14(P2_Q14),
        .ATTITUDE_WARP_ENABLE(ATTITUDE_WARP_ENABLE)
    ) u_undistort_rd_buf (
        .ddr_clk(ddr_clk), .ddr_rstn(ddr_rstn), .vout_clk(vout_clk),
        .rd_fsync(rd_fsync), .rd_active(rd_active), .rd_en(rd_en),
        .imu_yaw(imu_yaw), .imu_pitch(imu_pitch), .imu_roll(imu_roll),
        .imu_valid(imu_valid),
        .vout_de(vout_de), .vout_data(vout_data),
        .init_done(init_done), .completed_frame_bank(completed_frame_bank),
        .display_frame_bank(display_frame_bank),
        .ddr_rreq(rd_cmd_en), .ddr_raddr(rd_cmd_addr),
        .ddr_rd_len(rd_cmd_len), .ddr_rrdy(rd_cmd_ready), .ddr_rdone(rd_cmd_done),
        .ddr_rdata(read_rdata), .ddr_rdata_en(read_en)
    );

    wr_rd_ctrl_top #(
        .CTRL_ADDR_WIDTH(CTRL_ADDR_WIDTH), .MEM_DQ_WIDTH(MEM_DQ_WIDTH)
    ) u_wr_rd_ctrl (
        .clk(ddr_clk), .rstn(ddr_rstn),
        .wr_cmd_en(ddr_wreq), .wr_cmd_addr(ddr_waddr), .wr_cmd_len(ddr_wr_len),
        .wr_cmd_ready(ddr_wrdy), .wr_cmd_done(ddr_wdone), .wr_bac(ddr_wr_bac),
        .wr_ctrl_data(ddr_wdata), .wr_data_re(ddr_wdata_req),
        .rd_cmd_en(rd_cmd_en), .rd_cmd_addr(rd_cmd_addr), .rd_cmd_len(rd_cmd_len),
        .rd_cmd_ready(rd_cmd_ready), .rd_cmd_done(rd_cmd_done),
        .read_ready(1'b1), .read_rdata(read_rdata), .read_en(read_en),
        .axi_awaddr(axi_awaddr), .axi_awid(axi_awid),
        .axi_awlen(axi_awlen), .axi_awsize(axi_awsize), .axi_awburst(axi_awburst),
        .axi_awready(axi_awready), .axi_awvalid(axi_awvalid), .axi_wdata(axi_wdata),
        .axi_wstrb(axi_wstrb), .axi_wlast(axi_wlast), .axi_wvalid(axi_wvalid),
        .axi_wready(axi_wready), .axi_bid(axi_bid), .axi_bresp(2'd0),
        .axi_bvalid(1'b0), .axi_bready(), .axi_araddr(axi_araddr),
        .axi_arid(axi_arid), .axi_arlen(axi_arlen), .axi_arsize(axi_arsize),
        .axi_arburst(axi_arburst), .axi_arvalid(axi_arvalid),
        .axi_arready(axi_arready), .axi_rready(axi_rready), .axi_rdata(axi_rdata),
        .axi_rvalid(axi_rvalid), .axi_rlast(axi_rlast), .axi_rid(axi_rid),
        .axi_rresp(2'd0)
    );
endmodule


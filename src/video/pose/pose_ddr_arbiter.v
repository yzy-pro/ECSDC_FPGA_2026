`timescale 1ns/1ps

// DDR3_50H user-interface arbiter. All signals are synchronous to clk.
// The vendor interface has no WVALID or RREADY: write payloads are buffered
// before AW, and read clients must reserve room for the entire requested burst.
// Addresses use the existing controller's 32-bit-word units (8 per 256-bit
// payload). Capture writes/display reads may request 1..16 beats. The entire
// capture burst is supplied atomically, beat zero in bits 255:0. Renderer
// reads/writes are one beat. Only one read and one write command
// may be outstanding. Capture writes and display reads have fixed priority.
// Done means a real final payload beat was transferred, not a timed estimate.
// A malformed return stops that channel until reset, preventing ownership
// from being reassigned while unexpected beats can still arrive.
module pose_ddr_arbiter #(
    parameter integer ADDR_WIDTH = 28,
    parameter integer RENDER_BURST_ENABLE = 0,
    parameter integer RENDER_WRITE_BURST_ENABLE = 0
) (
    input clk, input rstn,
    input cap_w_valid, output cap_w_ready,
    input [ADDR_WIDTH-1:0] cap_w_addr, input [4095:0] cap_w_data,
    input [4:0] cap_w_len,
    output reg cap_w_done,
    input render_w_valid, output render_w_ready,
    input [ADDR_WIDTH-1:0] render_w_addr, input [255:0] render_w_data,
    input [4095:0] render_w_burst,
    input [4:0] render_w_len,
    output reg render_w_done,
    input display_r_valid, output display_r_ready,
    input [ADDR_WIDTH-1:0] display_r_addr, input [4:0] display_r_len,
    output reg [255:0] display_r_data,
    output reg display_r_data_valid, output reg display_r_done,
    input render_r_valid, output render_r_ready,
    input [ADDR_WIDTH-1:0] render_r_addr,
    input [4:0] render_r_len,
    output reg [255:0] render_r_data,
    output reg render_r_data_valid, output reg render_r_done,
    output reg [ADDR_WIDTH-1:0] axi_awaddr,
    output reg [3:0] axi_awid, output reg [3:0] axi_awlen,
    output axi_awvalid, input axi_awready,
    output reg [255:0] axi_wdata, output [31:0] axi_wstrb,
    input axi_wready, input axi_wlast,
    output reg [ADDR_WIDTH-1:0] axi_araddr,
    output reg [3:0] axi_arid, output reg [3:0] axi_arlen,
    output axi_arvalid, input axi_arready,
    input [255:0] axi_rdata, input axi_rvalid,
    input axi_rlast, input [3:0] axi_rid,
    output protocol_error
);
    localparam IDLE=2'd0, ADDRESS=2'd1, PAYLOAD=2'd2, FAULT=2'd3;
    reg [1:0] write_state, read_state;
    reg write_owner, read_owner; // 0: capture/display, 1: renderer
    reg [4:0] write_remaining;
    reg [3839:0] write_tail;
    reg [4:0] read_remaining;
    reg write_error, read_error;
    wire write_address_accepted = write_state==ADDRESS && axi_awready;
    wire read_address_accepted = read_state==ADDRESS && axi_arready;
    wire write_payload_active = write_state==PAYLOAD || write_address_accepted;
    wire read_payload_active = read_state==PAYLOAD || read_address_accepted;
    wire [4:0] selected_render_len = RENDER_BURST_ENABLE ? render_r_len : 5'd1;
    wire [4:0] selected_write_len = RENDER_WRITE_BURST_ENABLE ? render_w_len : 5'd1;

    assign cap_w_ready = rstn && write_state==IDLE;
    assign render_w_ready = rstn && write_state==IDLE && !cap_w_valid;
    assign display_r_ready = rstn && read_state==IDLE;
    assign render_r_ready = rstn && read_state==IDLE && !display_r_valid;
    assign axi_awvalid = rstn && write_state==ADDRESS;
    assign axi_arvalid = rstn && read_state==ADDRESS;
    assign axi_wstrb = 32'hffffffff;
    assign protocol_error = write_error || read_error;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            write_state<=IDLE; write_owner<=0; write_error<=0;
            write_remaining<=0; write_tail<=0;
            axi_awaddr<=0; axi_awid<=0; axi_awlen<=0; axi_wdata<=0;
            cap_w_done<=0; render_w_done<=0;
        end else begin
            cap_w_done<=0; render_w_done<=0;
            if (write_state==IDLE) begin
                if (cap_w_valid || render_w_valid) begin
                    if ((cap_w_valid && (cap_w_len==0 || cap_w_len>16)) ||
                        (!cap_w_valid && (selected_write_len==0 || selected_write_len>16))) begin
                        write_error<=1; write_state<=FAULT;
                    end else begin
                        write_owner<=!cap_w_valid;
                        axi_awaddr<=cap_w_valid ? cap_w_addr : render_w_addr;
                        axi_awid<=cap_w_valid ? 4'd0 : 4'd1;
                        axi_awlen<=cap_w_valid ? cap_w_len-1'b1 : selected_write_len-1'b1;
                        axi_wdata<=cap_w_valid ? cap_w_data[255:0] :
                            (RENDER_WRITE_BURST_ENABLE ? render_w_burst[255:0] : render_w_data);
                        write_tail<=cap_w_valid ? cap_w_data[4095:256] : render_w_burst[4095:256];
                        write_remaining<=cap_w_valid ? cap_w_len : selected_write_len;
                        write_state<=ADDRESS;
                    end
                end
            end else begin
                if (write_address_accepted) write_state<=PAYLOAD;
                if (write_payload_active && axi_wready) begin
                    if (axi_wlast!=(write_remaining==1)) begin
                        write_error<=1; write_state<=FAULT;
                    end else if (write_remaining==1) begin
                        if (write_owner) render_w_done<=1;
                        else cap_w_done<=1;
                        write_remaining<=0;
                        write_state<=IDLE;
                    end else begin
                        axi_wdata<=write_tail[255:0];
                        write_tail<={256'd0,write_tail[3839:256]};
                        write_remaining<=write_remaining-1'b1;
                    end
                end
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            read_state<=IDLE; read_owner<=0; read_remaining<=0; read_error<=0;
            axi_araddr<=0; axi_arid<=0; axi_arlen<=0;
            display_r_data<=0; display_r_data_valid<=0; display_r_done<=0;
            render_r_data<=0; render_r_data_valid<=0; render_r_done<=0;
        end else begin
            display_r_data_valid<=0; display_r_done<=0;
            render_r_data_valid<=0; render_r_done<=0;
            if (read_state==IDLE) begin
                if (display_r_valid || render_r_valid) begin
                    if ((display_r_valid &&
                         (display_r_len==0 || display_r_len>16)) ||
                        (!display_r_valid && RENDER_BURST_ENABLE &&
                         (render_r_len==0 || render_r_len>16))) begin
                        read_error<=1; read_state<=FAULT;
                    end else begin
                        read_owner<=!display_r_valid;
                        axi_araddr<=display_r_valid ? display_r_addr : render_r_addr;
                        axi_arid<=display_r_valid ? 4'd0 : 4'd1;
                        axi_arlen<=display_r_valid ? display_r_len-1'b1 : selected_render_len-1'b1;
                        read_remaining<=display_r_valid ? display_r_len : selected_render_len;
                        read_state<=ADDRESS;
                    end
                end
            end else if (read_address_accepted) read_state<=PAYLOAD;

            if (axi_rvalid) begin
                if (!read_payload_active || axi_rid!=axi_arid ||
                    axi_rlast!=(read_remaining==1)) begin
                    read_error<=1; read_state<=FAULT;
                end else begin
                    if (read_owner) begin
                        render_r_data<=axi_rdata;
                        render_r_data_valid<=1;
                        render_r_done<=read_remaining==1;
                    end else begin
                        display_r_data<=axi_rdata;
                        display_r_data_valid<=1;
                        display_r_done<=read_remaining==1;
                    end
                    if (read_remaining==1) begin
                        read_remaining<=0; read_state<=IDLE;
                    end else read_remaining<=read_remaining-1'b1;
                end
            end
        end
    end
endmodule

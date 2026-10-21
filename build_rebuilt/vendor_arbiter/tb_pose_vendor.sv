`timescale 1ns/1ps
module tb_pose_vendor;
    wire clk,rstn;
    reg refclk=0,resetn=0,grs_n=0; always #10 refclk=~refclk;
    reg cap_w_valid=0,render_w_valid=0,display_r_valid=0,render_r_valid=0;
    wire cap_w_ready,render_w_ready,display_r_ready,render_r_ready;
    reg [27:0] cap_w_addr=0,render_w_addr=0,display_r_addr=0,render_r_addr=0;
    reg [4095:0] cap_w_data=0;
    reg [255:0] render_w_data=0;
    reg [4:0] cap_w_len=1;
    reg [4:0] display_r_len=1;
    wire cap_w_done,render_w_done,display_r_done,render_r_done;
    wire [255:0] display_r_data,render_r_data;
    wire display_r_data_valid,render_r_data_valid;
    wire [27:0] axi_awaddr,axi_araddr;
    wire [3:0] axi_awid,axi_arid,axi_awlen,axi_arlen;
    wire axi_awvalid,axi_arvalid;
    wire axi_awready,axi_arready,axi_wready,axi_wlast;
    wire [255:0] axi_wdata;
    wire [31:0] axi_wstrb;
    wire [255:0] axi_rdata;
    wire axi_rvalid,axi_rlast;
    wire [3:0] axi_rid;
    wire protocol_error;
    pose_ddr_arbiter dut(.*);

    function automatic [255:0] payload(input [27:0] address);
        integer lane;
        begin
            for(lane=0;lane<8;lane=lane+1)
                payload[lane*32 +: 32] = {4'ha,address} ^ (32'h1020304*lane);
        end
    endfunction


    wire mem_rst_n,mem_ck,mem_ck_n,mem_cke,mem_cs_n,mem_ras_n,mem_cas_n,mem_we_n,mem_odt;
    wire [14:0] mem_a;
    wire [2:0] mem_ba;
    wire [3:0] mem_dqs,mem_dqs_n,mem_dm;
    wire [31:0] mem_dq;
    GTP_GRS GRS_INST(.GRS_N(grs_n));
    DDR3_50H u_ddr3 (
        .ref_clk                (refclk),
        .resetn                 (resetn),
        .ddrphy_clkin           (clk),
        .pll_lock               (),
        .ddr_init_done          (rstn),
        .axi_awaddr             (axi_awaddr),
        .axi_awuser_ap          (1'b0),
        .axi_awuser_id          (axi_awid),
        .axi_awlen              (axi_awlen),
        .axi_awready            (axi_awready),
        .axi_awvalid            (axi_awvalid),
        .axi_wdata              (axi_wdata),
        .axi_wstrb              (axi_wstrb),
        .axi_wready             (axi_wready),
        .axi_wusero_id          (),
        .axi_wusero_last        (axi_wlast),
        .axi_araddr             (axi_araddr),
        .axi_aruser_ap          (1'b0),
        .axi_aruser_id          (axi_arid),
        .axi_arlen              (axi_arlen),
        .axi_arready            (axi_arready),
        .axi_arvalid            (axi_arvalid),
        .axi_rdata              (axi_rdata),
        .axi_rid                (axi_rid),
        .axi_rlast              (axi_rlast),
        .axi_rvalid             (axi_rvalid),
        .apb_clk                (1'b0),
        .apb_rst_n              (1'b1),
        .apb_sel                (1'b0),
        .apb_enable             (1'b0),
        .apb_addr               (8'd0),
        .apb_write              (1'b0),
        .apb_ready              (),
        .apb_wdata              (16'd0),
        .apb_rdata              (),
        .apb_int                (),
        .debug_data             (),
        .debug_slice_state      (),
        .debug_calib_ctrl       (),
        .ck_dly_set_bin         (),
        .force_ck_dly_en        (1'b0),
        .force_ck_dly_set_bin   (8'd0),
        .dll_step               (),
        .dll_lock               (),
        .init_read_clk_ctrl     (2'd0),
        .init_slip_step         (4'd0),
        .force_read_clk_ctrl    (1'b0),
        .ddrphy_gate_update_en  (1'b0),
        .update_com_val_err_flag(),
        .rd_fake_stop           (1'b0),
        .mem_cs_n               (mem_cs_n),
        .mem_rst_n              (mem_rst_n),
        .mem_ck                 (mem_ck),
        .mem_ck_n               (mem_ck_n),
        .mem_cke                (mem_cke),
        .mem_ras_n              (mem_ras_n),
        .mem_cas_n              (mem_cas_n),
        .mem_we_n               (mem_we_n),
        .mem_odt                (mem_odt),
        .mem_a                  (mem_a),
        .mem_ba                 (mem_ba),
        .mem_dqs                (mem_dqs),
        .mem_dqs_n              (mem_dqs_n),
        .mem_dq                 (mem_dq),
        .mem_dm                 (mem_dm)
    );


    genvar chip;
    generate for(chip=0;chip<2;chip=chip+1) begin:g_mem
        ddr3 mem_core(.rst_n(mem_rst_n),.ck(mem_ck),.ck_n(mem_ck_n),.cs_n(mem_cs_n),
          .addr({1'b0,mem_a}),.dq(mem_dq[chip*16+:16]),.dqs(mem_dqs[chip*2+:2]),
          .dqs_n(mem_dqs_n[chip*2+:2]),.dm_tdqs(mem_dm[chip*2+:2]),.tdqs_n(),
          .cke(mem_cke),.odt(mem_odt),.ras_n(mem_ras_n),.cas_n(mem_cas_n),.we_n(mem_we_n),.ba(mem_ba));
    end endgenerate
    integer n,beat,returned=0,render_returns=0,write_beats=0;
    always @(posedge clk) if(rstn) begin
        if(axi_wready) begin
            write_beats=write_beats+1;
            if(axi_wlast) $display("VENDOR WRITE LAST id=%0d awlen=%0d @%0t",axi_awid,axi_awlen,$time);
        end
        if(protocol_error) $fatal(1,"vendor arbiter protocol error");
        if(display_r_data_valid) begin
            if(display_r_data!==payload(returned*8))
                $fatal(1,"vendor readback mismatch word %0d got %h expected %h",returned,display_r_data,payload(returned*8));
            returned=returned+1;
        end
        if(render_r_data_valid) begin
            if(!render_r_done || render_r_data!==payload(28'h400000))
                $fatal(1,"renderer ID1 single readback mismatch");
            render_returns=render_returns+1;
        end
    end
    initial begin
        #5 grs_n=1; #5 resetn=0; #50 resetn=1;
        wait(rstn); $display("VENDOR CALIBRATED @%0t",$time);
        for(n=0;n<8;n=n+1) begin
            @(negedge clk);cap_w_valid=1;cap_w_addr=n*128;cap_w_len=16;
            for(beat=0;beat<16;beat=beat+1) cap_w_data[beat*256 +: 256]=payload(n*128+beat*8);
            @(posedge clk);while(!cap_w_ready) @(posedge clk);
            @(negedge clk);cap_w_valid=0;cap_w_data='1;
            wait(cap_w_done);
        end
        for(n=0;n<8;n=n+1) begin
            @(negedge clk);display_r_valid=1;display_r_addr=n*128;display_r_len=16;
            @(posedge clk);while(!display_r_ready) @(posedge clk);
            @(negedge clk);display_r_valid=0;
            wait(display_r_done);repeat(3) @(negedge clk);
        end
        @(negedge clk);render_w_valid=1;render_w_addr=28'h400000;render_w_data=payload(28'h400000);
        @(posedge clk);while(!render_w_ready) @(posedge clk);
        @(negedge clk);render_w_valid=0;render_w_data='1;
        wait(render_w_done);
        @(negedge clk);render_r_valid=1;render_r_addr=28'h400000;
        @(posedge clk);while(!render_r_ready) @(posedge clk);
        @(negedge clk);render_r_valid=0;
        wait(render_r_done);repeat(3) @(negedge clk);
        if(returned!=128 || render_returns!=1 || write_beats!=129) $fatal(1,"missing vendor response");
        $display("PASS real vendor DDR3 arbiter:128 capture/display beats + renderer ID1 write/read");$finish;
    end
    initial begin #800000;$fatal(1,"vendor simulation timeout");end
endmodule

`timescale 1ns/1ps
module tb_pose_vendor;
    wire clk,rstn;
    reg refclk=0,resetn=0,grs_n=0; always #10 refclk=~refclk;
    reg cap_w_valid=0,render_w_valid=0,display_r_valid=0,render_r_valid=0;
    wire cap_w_ready,render_w_ready,display_r_ready,render_r_ready;
    reg [27:0] cap_w_addr=0,render_w_addr=0,display_r_addr=0,render_r_addr=0;
    reg [4095:0] cap_w_data=0;
    reg [255:0] render_w_data=0;
    reg [4095:0] render_w_burst=0;
    reg [4:0] render_w_len=1;
    reg [4:0] cap_w_len=1;
    reg [4:0] display_r_len=1,render_r_len=1;
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
    pose_ddr_arbiter #(.RENDER_BURST_ENABLE(1),.RENDER_WRITE_BURST_ENABLE(1)) dut(.*);

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
    integer expected_render_len=0,expected_render_index=0,expected_render_total=0;
    reg [27:0] expected_render_addr=0;
    integer ui_cycle=0,read_accept_cycle=0,read_first_cycle=0,read_payloads=0;
    integer latency_min[1:16],latency_max[1:16],latency_sum[1:16],read_count[1:16];
    integer first_min[1:16],first_max[1:16];
    integer request_min[1:16],request_max[1:16],request_sum[1:16];
    integer read_offer_cycle=0,write_offer_cycle=0;
    integer read_stall_max=0,write_stall_max=0,write_request_max=0;
    reg read_offered=0,write_offered=0;
    integer measured_len=0,case_len,single_beat;
    reg [27:0] case_addr;
    always @(posedge clk) if(rstn) begin
        ui_cycle=ui_cycle+1;
        if(axi_arvalid && !read_offered) begin
            read_offer_cycle=ui_cycle;read_offered=1;
        end
        if(axi_arvalid && axi_arready) begin
            read_accept_cycle=ui_cycle; read_payloads=0;
            measured_len=axi_arlen+1;
            if(ui_cycle-read_offer_cycle>read_stall_max)
                read_stall_max=ui_cycle-read_offer_cycle;
            read_offered=0;
        end
        if(axi_awvalid && !write_offered) begin
            write_offer_cycle=ui_cycle;write_offered=1;
        end
        if(axi_awvalid && axi_awready) begin
            if(ui_cycle-write_offer_cycle>write_stall_max)
                write_stall_max=ui_cycle-write_offer_cycle;
            write_offered=0;
        end
        if(axi_rvalid) begin
            if(read_payloads==0) read_first_cycle=ui_cycle;
            read_payloads=read_payloads+1;
            if(axi_rlast) begin
                if(ui_cycle-read_accept_cycle<latency_min[measured_len])
                    latency_min[measured_len]=ui_cycle-read_accept_cycle;
                if(ui_cycle-read_accept_cycle>latency_max[measured_len])
                    latency_max[measured_len]=ui_cycle-read_accept_cycle;
                if(read_first_cycle-read_accept_cycle<first_min[measured_len])
                    first_min[measured_len]=read_first_cycle-read_accept_cycle;
                if(read_first_cycle-read_accept_cycle>first_max[measured_len])
                    first_max[measured_len]=read_first_cycle-read_accept_cycle;
                latency_sum[measured_len]=latency_sum[measured_len]+ui_cycle-read_accept_cycle;
                read_count[measured_len]=read_count[measured_len]+1;
                if(ui_cycle-read_offer_cycle<request_min[measured_len])
                    request_min[measured_len]=ui_cycle-read_offer_cycle;
                if(ui_cycle-read_offer_cycle>request_max[measured_len])
                    request_max[measured_len]=ui_cycle-read_offer_cycle;
                request_sum[measured_len]=request_sum[measured_len]+ui_cycle-read_offer_cycle;
            end
        end
        if(axi_wready) begin
            write_beats=write_beats+1;
            if(axi_wlast) begin
                if(ui_cycle-write_offer_cycle>write_request_max)
                    write_request_max=ui_cycle-write_offer_cycle;
                if(axi_awlen!=0) $display("VENDOR WRITE LAST id=%0d awlen=%0d @%0t",axi_awid,axi_awlen,$time);
            end
        end
        if(protocol_error) $fatal(1,"vendor arbiter protocol error");
        if(display_r_data_valid) begin
            if(display_r_data!==payload(returned*8))
                $fatal(1,"vendor readback mismatch word %0d got %h expected %h",returned,display_r_data,payload(returned*8));
            returned=returned+1;
        end
        if(render_r_data_valid) begin
            if(render_r_done!=(expected_render_index==expected_render_len-1) ||
               render_r_data!==payload(expected_render_addr+expected_render_index*8))
                $fatal(1,"renderer ID1 burst readback mismatch address=%h beat=%0d/%0d got=%h expected=%h",
                    expected_render_addr,expected_render_index,expected_render_len,
                    render_r_data,payload(expected_render_addr+expected_render_index*8));
            expected_render_index=expected_render_index+1;
            render_returns=render_returns+1;
        end
    end
    task automatic renderer_write(input [27:0] address,input integer length);
        integer b;
        begin
            @(negedge clk);render_w_valid=1;render_w_addr=address;
            render_w_data=payload(address);render_w_len=length;
            for(b=0;b<length;b=b+1)
                render_w_burst[b*256+:256]=payload(address+b*8);
            @(posedge clk);while(!render_w_ready) @(posedge clk);
            @(negedge clk);render_w_valid=0;render_w_data='1;render_w_burst='1;
            wait(render_w_done);
        end
    endtask
    task automatic renderer_read(input [27:0] address,input integer length);
        begin
            @(negedge clk);render_r_valid=1;render_r_addr=address;render_r_len=length;
            expected_render_addr=address;expected_render_len=length;expected_render_index=0;
            expected_render_total=expected_render_total+length;
            @(posedge clk);while(!render_r_ready) @(posedge clk);
            @(negedge clk);render_r_valid=0;
            wait(render_r_done);repeat(3) @(negedge clk);
            if(expected_render_index!=length) $fatal(1,"missing renderer readback");
        end
    endtask
    initial begin
        for(n=1;n<=16;n=n+1) begin
            latency_min[n]=1000000;latency_max[n]=0;latency_sum[n]=0;read_count[n]=0;
            first_min[n]=1000000;first_max[n]=0;
            request_min[n]=1000000;request_max[n]=0;request_sum[n]=0;
        end
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
        renderer_write(28'h400000,8);
        renderer_read(28'h400000,8);
        // A tiled source rectangle can begin at any 256-bit beat. Exercise
        // every legal length immediately before alternating 512-word and
        // 1024-word boundaries (the latter is 4 KiB in this 32-bit-word UI). Singleton
        // readback ensures a burst write/read pair cannot hide matching wrap.
        for(case_len=1;case_len<=16;case_len=case_len+1) begin
            case_addr=28'h400000+case_len*2048+((case_len%2)?512:1024)-8;
            renderer_write(case_addr,case_len);
            for(single_beat=0;single_beat<case_len;single_beat=single_beat+1)
                renderer_read(case_addr+single_beat*8,1);
            renderer_read(case_addr,case_len);
            $display("VENDOR BOUNDARY address=%h beats=%0d singleton/burst readback checked",case_addr,case_len);
        end
        // Source tile rows are separated by 1920 RGB565 pixels = 960 UI
        // address units. Prime with singleton writes, then read irregular
        // 9-beat and full 16-beat bursts, including row-boundary crossings.
        for(n=0;n<16;n=n+1) begin
            case_addr=28'h800000+n*960+504;case_len=(n%2)?16:9;
            for(single_beat=0;single_beat<case_len;single_beat=single_beat+1)
                renderer_write(case_addr+single_beat*8,1);
            renderer_read(case_addr,case_len);
        end
        if(returned!=128 || render_returns!=expected_render_total || write_beats!=472)
            $fatal(1,"missing vendor response writes=%0d reads=%0d/%0d",write_beats,render_returns,expected_render_total);
        for(n=1;n<=16;n=n+1) if(read_count[n]>0) begin
            $display("VENDOR READ LATENCY beats=%0d commands=%0d first_min=%0d first_max=%0d last_min=%0d last_max=%0d last_mean=%0f clocks",
                n,read_count[n],first_min[n],first_max[n],latency_min[n],latency_max[n],real'(latency_sum[n])/read_count[n]);
            $display("VENDOR REQUEST LATENCY beats=%0d offer_to_last_min=%0d offer_to_last_max=%0d offer_to_last_mean=%0f clocks",
                n,request_min[n],request_max[n],real'(request_sum[n])/read_count[n]);
        end
        $display("VENDOR COMMAND STALL ar_max=%0d aw_max=%0d write_offer_to_last_max=%0d clocks",
            read_stall_max,write_stall_max,write_request_max);
        $display("PASS real vendor DDR3 arbiter:128 capture/display beats + renderer lengths 1..16, boundary crossings and 1920-pixel row stride");$finish;
    end
    initial begin #800000;$fatal(1,"vendor simulation timeout");end
endmodule

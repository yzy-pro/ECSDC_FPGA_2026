from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
vendor=Path(r'D:\pango\works\EmbFPGA\HDMI_IN_DDR3_HDMI_OUT\source\rtl\DDR3_50H')
build=root/'build_rebuilt/vendor_arbiter'
build.mkdir(exist_ok=True)
sim=Path(r'D:\pango\modeltech64_10.6e\win64')
lib=Path(r'D:\pango\PDS_2025.2-ads\arch\vendor\pango\verilog\simulation')
base=(root/'tests/tb_pose_ddr_arbiter.sv').read_text()
bench=base[:base.index('    bit model_enable')]
bench=bench.replace('module tb_pose_ddr_arbiter;', 'module tb_pose_vendor;')
bench=bench.replace('reg clk=0, rstn=0;\n    always #5 clk=~clk;', 'wire clk,rstn;\n    reg refclk=0,resetn=0,grs_n=0; always #10 refclk=~refclk;')
bench=bench.replace('reg axi_awready=0,axi_arready=0,axi_wready=0,axi_wlast=0;', 'wire axi_awready,axi_arready,axi_wready,axi_wlast;')
bench=bench.replace('reg [255:0] axi_rdata=0;', 'wire [255:0] axi_rdata;')
bench=bench.replace('reg axi_rvalid=0,axi_rlast=0;', 'wire axi_rvalid,axi_rlast;')
bench=bench.replace('reg [3:0] axi_rid=0;', 'wire [3:0] axi_rid;')
bench+='''
    wire mem_rst_n,mem_ck,mem_ck_n,mem_cke,mem_cs_n,mem_ras_n,mem_cas_n,mem_we_n,mem_odt;
    wire [14:0] mem_a;
    wire [2:0] mem_ba;
    wire [3:0] mem_dqs,mem_dqs_n,mem_dm;
    wire [31:0] mem_dq;
    GTP_GRS GRS_INST(.GRS_N(grs_n));
'''
top=(root/'src/hdmi_ddr3_top.v').read_text()
ddr=top[top.index('    DDR3_50H u_ddr3 ('):top.rindex('endmodule')]
ddr=ddr.replace('(sys_clk)','(refclk)').replace('(rstn_out)','(resetn)').replace('(ddr_core_clk)','(clk)').replace('(ddr_init_done)','(rstn)').replace('(ddr_pll_lock)','()').replace('(ddr_dll_lock)','()')
bench+=ddr
bench+='''
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
'''
(build/'tb_pose_vendor.sv').write_text(bench)
sources=[]
filelist=vendor/'sim/modelsim/sim_file_list.f'
for line in filelist.read_text().splitlines():
    line=line.strip()
    if not line or line.startswith('+'):continue
    if line.startswith('C:/'):continue
    path=(filelist.parent/line).resolve()
    if '/example_design/' in path.as_posix() and path.name!='ddr3.v':continue
    sources.append(path)
args=[str(sim/'vlog.exe'),'-sv','-work',str(build/'work'),'-mfcu','+define+SIMULATION','+define+den4096Mb','+define+sg25E','+define+x16','+incdir+'+str(vendor/'sim/modelsim'),'-y',str(lib),'+libext+.v',str(lib/'GTP_GRS.v'),str(build/'tb_pose_vendor.sv'),str(root/'src/video/pose_ddr_arbiter.v'),*map(str,sources)]
subprocess.run([str(sim/'vlib.exe'),str(build/'work')],check=True,cwd=build)
with (build/'compile.log').open('w') as out:
    subprocess.run(args,cwd=build,stdout=out,stderr=subprocess.STDOUT,check=True)
with (build/'sim.log').open('w') as out:
    subprocess.run([str(sim/'vsim.exe'),'-c','-quiet','-lib',str(build/'work'),'tb_pose_vendor','-do','onerror {quit -code 1}; run -all; quit -f'],cwd=build,stdout=out,stderr=subprocess.STDOUT,check=True)
print((build/'sim.log').read_text()[-12000:])

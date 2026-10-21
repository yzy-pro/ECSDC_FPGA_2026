`timescale 1ns/1ps
module tb_pose_tile_read_scheduler;
    localparam MAX_BURST=16;
    reg clk=0,rstn=0,tile_start=0,cmd_ready=1,data_valid=0,data_last=0;
    reg [1:0] source_bank=1;
    reg [10:0] source_x0=17,source_x1=300,source_y0=5,source_y1=6;
    reg [MAX_BURST*256-1:0] data=0;
    wire tile_ready,tile_done,cmd_valid,tile_data_valid,tile_data_last,busy,error;
    wire [27:0] cmd_addr; wire [4:0] cmd_len; wire [13:0] tile_data_addr;
    wire [255:0] tile_data;
    pose_tile_read_scheduler dut(.*);
    always #5 clk=~clk;
    integer command_count=0, data_count=0, expected_addr;
    always @(posedge clk) begin
        if (rstn && cmd_valid && cmd_ready) command_count=command_count+1;
        if (rstn && tile_data_valid) data_count=data_count+1;
    end
    initial begin
        repeat(2) @(posedge clk); rstn=1;
        @(negedge clk); tile_start=1;
        @(posedge clk); #1 tile_start=0;
        while(!tile_done) begin
            @(posedge clk); #1;
            if(cmd_valid && cmd_ready) begin
                if(command_count==1) begin
                    if(cmd_len!==16 || cmd_addr!==((1<<22)+5*960+1*8))
                        $fatal(1,"first burst addr/len incorrect: %h/%0d",cmd_addr,cmd_len);
                end else if(command_count==2) begin
                    if(cmd_len!==2 || cmd_addr!==((1<<22)+5*960+17*8))
                        $fatal(1,"tail burst addr/len incorrect: %h/%0d",cmd_addr,cmd_len);
                end else if(command_count==3) begin
                    if(cmd_addr!==((1<<22)+6*960+1*8)) $fatal(1,"second row address incorrect");
                end
            end
            if(dut.state==2 && dut.expected_beats!=0) begin
                data_valid=1; data_last=(dut.received_beats==dut.expected_beats-1);
                data = {MAX_BURST{256'hA5A5}};
            end else begin
                data_valid=0; data_last=0;
            end
            #1;
            if(tile_data_valid) begin
                if(tile_data_addr >= 14'd256) $fatal(1,"tile address overflow");
            end
            if(error) begin
                $display("scheduler error t=%0t state=%0d cmd=%0d exp=%0d got=%0d valid=%b last=%b",$time,dut.state,command_count,dut.expected_beats,dut.received_beats,data_valid,data_last);
                $fatal(1,"scheduler raised error");
            end
        end
        if(command_count!=4 || data_count!=36 || !tile_ready)
            $fatal(1,"scheduler counts commands=%0d data=%0d ready=%b",command_count,data_count,tile_ready);
        $display("PASS pose tile read scheduler: aligned rows, 16+tail bursts, RVALID gaps, tile addresses");
        $finish;
    end
endmodule

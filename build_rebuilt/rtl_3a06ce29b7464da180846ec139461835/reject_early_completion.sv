`timescale 1ns/1ps
module tb_read_completion;
    reg clk=0;
    always #5 clk=~clk;
    reg rstn=0, cmd=0, valid=0;
    reg [31:0] length=100;
    wire done;
    wr_cmd_trans #(.MEM_DQ_WIDTH(32)) dut (
        .clk(clk), .rstn(rstn), .wr_cmd_en(1'b0), .wr_cmd_addr(28'd0),
        .wr_cmd_len(32'd0), .wr_bac(1'b0), .wr_ctrl_data(256'd0),
        .wr_ready(1'b0), .wr_done(1'b0), .rd_cmd_en(cmd),
        .rd_cmd_addr(28'd0), .rd_cmd_len(length), .rd_cmd_done(done),
        .read_en(valid), .rd_done_p(1'b0)
    );
    integer received=0, pulses=0, expected=0;
    always @(posedge clk) begin
        if (rstn && valid) received=received+1;
        #1;
        if (rstn && done) begin
            if (received != expected)
                $fatal(1,"early completion: received=%0d expected=%0d", received, expected);
            pulses=pulses+1;
        end
    end
    task tick(input bit value);
        begin @(negedge clk); valid=value; @(posedge clk); #2; end
    endtask
    task transaction(input integer size, input integer tail_gap);
        integer i;
        begin
            @(negedge clk); rstn=0; valid=0; cmd=0;
            repeat(3) @(negedge clk);
            received=0; pulses=0; expected=size; length=size;
            rstn=1; cmd=1;
            @(negedge clk); cmd=0;
            for (i=0;i<size;i=i+1) begin
                if (i==size-1) repeat(tail_gap) tick(0);
                else if (i%17==3) repeat(2) tick(0);
                tick(1);
            end
            repeat(5) tick(0);
            if (pulses != 1) $fatal(1,"done must be one pulse: %0d",pulses);
        end
    endtask
    initial begin
        transaction(100,0);
        transaction(100,1);
        transaction(100,2);
        transaction(100,31);
        transaction(76,9); // September 19 line size
        transaction(120,9); // full 1920 writer/linear-reader line size
        transaction(16,0); // eight-band segment with halo
        transaction(16,31);
        $display("PASS read completion: stalls, exact beat count, single done pulse");
        $finish;
    end
    initial begin #1000000; $fatal(1,"timeout"); end
endmodule

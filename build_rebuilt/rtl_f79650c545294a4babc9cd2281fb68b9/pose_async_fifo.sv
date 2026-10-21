`timescale 1ns/1ps

module tb_pose_async_fifo;
    wire [2:0] finished;
    pose_fifo_exerciser #(.WIDTH(256), .ADDR_BITS(9), .WR_HALF(5), .RD_HALF(7))
        default_size (.finished(finished[0]));
    pose_fifo_exerciser #(.WIDTH(37), .ADDR_BITS(3), .WR_HALF(7), .RD_HALF(3))
        fast_reader (.finished(finished[1]));
    pose_fifo_exerciser #(.WIDTH(8), .ADDR_BITS(1), .WR_HALF(3), .RD_HALF(5))
        minimum_size (.finished(finished[2]));
    initial begin
        wait (&finished);
        $display("PASS pose async FIFO: independent clocks, 512/8/2 entries, full/empty, wrap, randomized stalls, credits, occupied reset");
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "asynchronous FIFO test timeout");
    end
endmodule

module pose_fifo_exerciser #(
    parameter WIDTH=256, ADDR_BITS=9, WR_HALF=5, RD_HALF=7
) (output reg finished=0);
    localparam DEPTH=1 << ADDR_BITS;
    reg wr_clk=0, rd_clk=0, rstn=0;
    always #WR_HALF wr_clk=~wr_clk;
    // The one-nanosecond phase offset avoids coincident monitor events.
    initial begin
        #1;
        forever #RD_HALF rd_clk=~rd_clk;
    end
    reg wr_valid=0, rd_ready=0;
    reg [WIDTH-1:0] wr_data=0;
    wire wr_ready, rd_valid;
    wire [WIDTH-1:0] rd_data;
    wire [ADDR_BITS:0] wr_free, rd_count;
    pose_async_fifo #(.WIDTH(WIDTH), .ADDR_BITS(ADDR_BITS)) dut (.*);

    reg [WIDTH-1:0] expected [0:65535];
    integer write_count=0, read_count=0;
    integer all_writes=0, all_reads=0, full_cycles=0, empty_cycles=0;
    integer writer_mode=0, reader_mode=0, epoch=0;
    reg [31:0] wr_rng=32'h31415926 ^ WIDTH;
    reg [31:0] rd_rng=32'h27182818 ^ ADDR_BITS;
    reg held=0;
    reg wr_accepted_last=0;
    reg [WIDTH-1:0] held_data;

    function [WIDTH-1:0] pattern(input integer sequence_number, input integer generation);
        integer i;
        begin
            for (i=0; i<WIDTH; i=i+1)
                pattern[i] = ((sequence_number >> (i%24)) ^
                              (generation >> (i%4)) ^ ((i*13) >> 3)) & 1;
        end
    endfunction

    always @(negedge wr_clk) begin
        wr_rng = {wr_rng[30:0],wr_rng[31]^wr_rng[21]^wr_rng[1]^wr_rng[0]};
        if (!rstn) begin
            wr_valid=0;
            wr_data=0;
        end else if (!wr_valid || wr_accepted_last) begin
            wr_valid = writer_mode==1 || (writer_mode==2 && wr_rng[2:0]<6);
            wr_data = pattern(write_count,epoch);
        end
    end
    always @(negedge rd_clk) begin
        rd_rng = {rd_rng[30:0],rd_rng[31]^rd_rng[21]^rd_rng[1]^rd_rng[0]};
        rd_ready = rstn && (reader_mode==1 || (reader_mode==2 && rd_rng[2:0]<5));
    end

    always @(posedge wr_clk or negedge rstn) begin
        if (!rstn) begin
            write_count=0;
            wr_accepted_last=0;
        end else begin
            wr_accepted_last=wr_valid && wr_ready;
            if (wr_free>DEPTH || wr_free>DEPTH-(write_count-read_count))
                $fatal(1,"WIDTH=%0d write credit overstates free capacity: credit=%0d used=%0d",
                       WIDTH,wr_free,write_count-read_count);
            if (!wr_ready && wr_valid) full_cycles=full_cycles+1;
            if (wr_valid && wr_ready) begin
                if (write_count-read_count>=DEPTH)
                    $fatal(1,"WIDTH=%0d FIFO accepted write while full",WIDTH);
                expected[write_count]=wr_data;
                write_count=write_count+1;
                all_writes=all_writes+1;
            end
        end
    end
    always @(posedge rd_clk or negedge rstn) begin
        if (!rstn) begin
            read_count=0;
            held=0;
        end else begin
            if (rd_count>DEPTH || rd_count>write_count-read_count)
                $fatal(1,"WIDTH=%0d read count overstates available data",WIDTH);
            if (held && (!rd_valid || rd_data!==held_data))
                $fatal(1,"WIDTH=%0d stalled output changed",WIDTH);
            if (rd_valid && rd_count==0)
                $fatal(1,"WIDTH=%0d valid output missing from occupancy",WIDTH);
            if (!rd_valid && rd_ready) empty_cycles=empty_cycles+1;
            if (rd_valid && rd_ready) begin
                if (read_count>=write_count)
                    $fatal(1,"WIDTH=%0d FIFO returned unaccepted data",WIDTH);
                if (rd_data!==expected[read_count])
                    $fatal(1,"WIDTH=%0d ordering/data mismatch at %0d: got %h expected %h",
                           WIDTH,read_count,rd_data,expected[read_count]);
                read_count=read_count+1;
                all_reads=all_reads+1;
            end
            held=rd_valid && !rd_ready;
            held_data=rd_data;
        end
    end

    task reset_fifo;
        begin
            #1.3;
            rstn=0;
            writer_mode=0;
            reader_mode=0;
            epoch=epoch+1;
            #0.1;
            if (wr_ready || rd_valid || wr_free!=0 || rd_count!=0)
                $fatal(1,"WIDTH=%0d reset did not suppress interfaces",WIDTH);
            repeat (4) @(negedge wr_clk);
            #0.3 rstn=1;
            repeat (5) @(negedge wr_clk);
            repeat (5) @(negedge rd_clk);
            if (!wr_ready || wr_free!=DEPTH || rd_valid || rd_count!=0)
                $fatal(1,"WIDTH=%0d FIFO not empty after reset",WIDTH);
        end
    endtask

    task drain_fifo;
        begin
            writer_mode=0;
            reader_mode=1;
            // Any held producer transaction must finish before the producer stops.
            wait (!wr_valid);
            wait (read_count==write_count);
            repeat (8) @(negedge rd_clk);
            repeat (8) @(negedge wr_clk);
            if (rd_valid || rd_count!=0 || wr_free!=DEPTH || !wr_ready)
                $fatal(1,"WIDTH=%0d final empty/count state incorrect",WIDTH);
        end
    endtask

    integer pass;
    initial begin
        reset_fifo;
        reader_mode=1;
        repeat (30) @(negedge rd_clk);
        reader_mode=0;
        writer_mode=1;
        repeat (DEPTH+40) @(negedge wr_clk);
        repeat (8) @(negedge rd_clk);
        if (write_count!=DEPTH || read_count!=0 || wr_ready ||
            wr_free!=0 || rd_count!=DEPTH || !rd_valid)
            $fatal(1,"WIDTH=%0d FIFO did not enforce exact depth %0d",WIDTH,DEPTH);
        drain_fifo;

        for (pass=0; pass<3; pass=pass+1) begin
            writer_mode=2;
            reader_mode=2;
            repeat (5000) @(negedge wr_clk);
            drain_fifo;
        end

        // Flush a completely full FIFO with a prefetched output under stall.
        reader_mode=0;
        writer_mode=1;
        repeat (DEPTH+40) @(negedge wr_clk);
        reset_fifo;
        // Flush partially occupied traffic while both sides are active.
        writer_mode=1;
        reader_mode=0;
        repeat (DEPTH/2+1) @(negedge wr_clk);
        reader_mode=2;
        repeat (3) @(negedge rd_clk);
        reset_fifo;
        writer_mode=2;
        reader_mode=2;
        repeat (5000) @(negedge wr_clk);
        drain_fifo;

        if (all_reads<DEPTH*4 || full_cycles<10 || empty_cycles<10)
            $fatal(1,"WIDTH=%0d insufficient FIFO exercise",WIDTH);
        $display("PASS FIFO WIDTH=%0d DEPTH=%0d: writes=%0d reads=%0d full=%0d empty=%0d",
                 WIDTH,DEPTH,all_writes,all_reads,full_cycles,empty_cycles);
        finished=1;
    end
endmodule

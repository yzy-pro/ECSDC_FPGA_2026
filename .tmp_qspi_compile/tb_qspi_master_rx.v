`timescale 1ns/1ps
module tb_qspi_master_rx;
    parameter MODE = 0;
    reg clk = 1'b0;
    reg rstn = 1'b0;
    wire csn;
    wire sck;
    tri [3:0] dq;
    wire valid;
    wire [7:0] data;
    reg flash_oe = 1'b0;
    reg [3:0] flash_dq = 4'h0;
    integer edge_count = 0;
    reg [7:0] command = 8'h00;
    reg [23:0] address = 24'h000000;
    integer valid_count = 0;

    assign dq = flash_oe ? flash_dq : 4'bz;
    always #10 clk = ~clk;

    qspi_master_rx #(
        .QSPI_CLK_FREQ(50_000_000),
        .QSPI_SCK_FREQ(12_500_000),
        .QSPI_MODE(MODE),
        .READ_START_ADDRESS(24'h123456)
    ) dut (
        .qspi_clk(clk), .sys_rstn(rstn), .sys_qspi_csn(csn),
        .sys_qspi_dq(dq), .sys_qspi_sck(sck),
        .rx_data_valid(valid), .rx_data(data)
    );

    always @(negedge csn) begin
        edge_count = 0;
        command = 0;
        address = 0;
        flash_oe = 0;
    end

    always @(sck) begin
        if (!csn && (sck == (((MODE == 1) || (MODE == 3)) ?
                            ((MODE == 2) || (MODE == 3)) :
                            !((MODE == 2) || (MODE == 3))))) begin
            if (edge_count < 8)
                command = {command[6:0], dq[0]};
            else if (edge_count < 32)
                address = {address[22:0], dq[0]};
            else if (edge_count == 39) begin
                flash_oe = 1'b1;
                flash_dq = 4'hA;
            end
            edge_count = edge_count + 1;
        end
    end

    always @(sck) begin
        if (!csn && (sck != (((MODE == 1) || (MODE == 3)) ?
                             ((MODE == 2) || (MODE == 3)) :
                             !((MODE == 2) || (MODE == 3)))) &&
            flash_oe) begin
            if (edge_count == 41) flash_dq = 4'h5;
            else if (edge_count == 42) flash_dq = 4'h3;
            else if (edge_count == 43) flash_dq = 4'hC;
        end
    end

    always @(posedge clk) begin
        if (valid) begin
            if (command !== 8'h6B) $fatal(1, "bad command: %02h", command);
            if (address !== 24'h123456)
                $fatal(1, "bad address: %06h", address);
            if ((valid_count == 0) && (data !== 8'hA5))
                $fatal(1, "bad first data: %02h", data);
            if ((valid_count == 1) && (data !== 8'h3C))
                $fatal(1, "bad second data: %02h", data);
            $display("PASS command=%02h address=%06h data=%02h", command, address, data);
            if (valid_count == 1) $finish;
            valid_count = valid_count + 1;
        end
    end

    initial begin
        #100 rstn = 1'b1;
        #10000 $fatal(1, "timeout");
    end
endmodule

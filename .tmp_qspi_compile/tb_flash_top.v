`timescale 1ns/1ps
module tb_flash_top;
    reg clk = 0;
    reg rstn = 0;
    wire csn, sck, tx;
    tri [3:0] dq;
    reg flash_oe = 0;
    reg [3:0] flash_dq = 0;
    integer edge_count = 0;
    integer tx_count = 0;
    integer rx_byte_count = 0;
    reg [31:0] expected_hash;
    reg [7:0] rx_byte;
    always #10 clk = ~clk;
    assign dq = flash_oe ? flash_dq : 4'bz;
    always @(tx) $display("TX t=%0t v=%b shift=%b busy=%b div=%0d bit=%0d", $time, tx, dut.uart_shift, dut.uart_busy, dut.uart_div_count, dut.uart_bit_index);
    always @(dut.uart_bit_index) $display("BIT t=%0t idx=%0d shift=%b div=%0d", $time, dut.uart_bit_index, dut.uart_shift, dut.uart_div_count);
    always @(dut.hash_word) $display("HASHREG t=%0t hash=%08h req=%b", $time, dut.hash_word, dut.uart_request);

    flash_top #(.HASH_ADDRESS(24'h202000), .UART_BAUD_RATE(1_000_000)) dut (
        .sys_clk_50mhz(clk), .sys_rst_n(rstn), .sys_uart_tx(tx),
        .sys_qspi_csn(csn), .sys_qspi_dq(dq), .sys_qspi_sck(sck), .sys_led()
    );

    always @(negedge csn) begin edge_count = 0; flash_oe = 0; end
    always @(sck) begin
        if (!csn && sck == 1'b1) begin
            if (edge_count == 39) begin flash_oe = 1; flash_dq = 4'h4; end
            edge_count = edge_count + 1;
        end
        if (!csn && sck == 1'b0 && flash_oe) begin
            if (edge_count == 41) flash_dq = 4'h3;
            else if (edge_count == 42) flash_dq = 4'h2;
            else if (edge_count == 43) flash_dq = 4'h1;
        end
    end

    // 以 1 Mbaud 对 UART 发送的 8N1 数据进行采样。
    always @(negedge tx) begin
        if (rx_byte_count < 4) begin
            $display("UART start candidate t=%0t", $time);
            #500;
            if (tx !== 1'b0) $fatal(1, "UART start bit error");
            #1000; rx_byte[0] = tx;
            #1000; rx_byte[1] = tx;
            #1000; rx_byte[2] = tx;
            #1000; rx_byte[3] = tx;
            #1000; rx_byte[4] = tx;
            #1000; rx_byte[5] = tx;
            #1000; rx_byte[6] = tx;
            #1000; rx_byte[7] = tx;
            #1000;
            if (tx !== 1'b1) $fatal(1, "UART stop bit error");
            if (rx_byte !== expected_hash[rx_byte_count*8 +: 8])
                $fatal(1, "UART byte %0d mismatch: got %02h expected %02h",
                       rx_byte_count, rx_byte, expected_hash[rx_byte_count*8 +: 8]);
            $display("PASS UART byte%0d=%02h", rx_byte_count, rx_byte);
            rx_byte_count = rx_byte_count + 1;
        end
    end

    initial begin
        #100 rstn = 1;
        wait (dut.u_flash_driver.fifo_wr_en);
        expected_hash = dut.u_flash_driver.fifo_wr_data;
        $display("HASH=%08h", expected_hash);
        wait (dut.hash_sent);
        if (rx_byte_count != 4) $fatal(1, "UART byte count=%0d", rx_byte_count);
        $display("PASS hash_sent");
        $finish;
    end
endmodule

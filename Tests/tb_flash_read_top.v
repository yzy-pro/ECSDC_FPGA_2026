`timescale 1ns/1ps

module tb_flash_read_top;
    reg clk = 1'b0;
    reg rstn = 1'b0;
    tri [3:0] dq;
    reg flash_oe = 1'b0;
    reg [3:0] flash_dq = 4'd0;
    wire csn;
    wire sck;
    wire tx;
    wire [7:0] leds;
    reg [7:0] digest [0:31];
    reg [7:0] rx_byte;
    reg [7:0] xor_checksum;
    reg [7:0] command;
    reg [23:0] address;
    integer qspi_edges = 0;
    integer rx_count = 0;
    integer i;
    integer bit_index;
    integer data_bit_index;

    always #10 clk = ~clk;
    assign dq = flash_oe ? flash_dq : 4'bz;

    flash_read_top dut (
        .sys_clk_50mhz(clk), .sys_rstn(rstn), .sys_cp2102_tx(tx),
        .sys_qspi_csn(csn), .sys_qspi_dq(dq), .sys_qspi_sck(sck), .sys_led(leds)
    );

    always @(negedge csn) begin
        qspi_edges = 0;
        command = 8'd0;
        address = 24'd0;
        flash_oe = 1'b0;
    end

    always @(posedge sck) begin
        if (!csn) begin
            if (qspi_edges < 8) command = {command[6:0], dq[0]};
            else if (qspi_edges < 32) address = {address[22:0], dq[0]};

            if (qspi_edges >= 39 && qspi_edges < 295) begin
                data_bit_index = qspi_edges - 39;
                flash_oe = 1'b1;
                flash_dq = {2'b11, digest[data_bit_index / 8][7 - (data_bit_index % 8)], 1'bz};
            end
            qspi_edges = qspi_edges + 1;
        end
    end

    always @(negedge tx) begin
        if (rstn) begin
            #540;
            if (tx !== 1'b0) $fatal(1, "UART start bit %0d", rx_count);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                #1080;
                rx_byte[bit_index] = tx;
            end
            #1080;
            if (tx !== 1'b1) $fatal(1, "UART stop bit %0d", rx_count);
            if (rx_count == 0 && rx_byte !== 8'hAA)
                $fatal(1, "header 0: %02h", rx_byte);
            if (rx_count == 1 && rx_byte !== 8'h55)
                $fatal(1, "header 1: %02h", rx_byte);
            if (rx_count >= 2 && rx_count < 34) begin
                if (rx_byte !== digest[rx_count-2])
                    $fatal(1, "payload %0d: %02h expected %02h",
                           rx_count-2, rx_byte, digest[rx_count-2]);
            end
            if (rx_count == 34 && rx_byte !== xor_checksum)
                $fatal(1, "XOR: %02h expected %02h", rx_byte, xor_checksum);
            if (rx_count == 35 && rx_byte !== 8'h0D)
                $fatal(1, "tail: %02h", rx_byte);
            rx_count = rx_count + 1;
        end
    end

    initial begin
        {digest[0], digest[1], digest[2], digest[3],
         digest[4], digest[5], digest[6], digest[7],
         digest[8], digest[9], digest[10], digest[11],
         digest[12], digest[13], digest[14], digest[15],
         digest[16], digest[17], digest[18], digest[19],
         digest[20], digest[21], digest[22], digest[23],
         digest[24], digest[25], digest[26], digest[27],
         digest[28], digest[29], digest[30], digest[31]} =
         256'hf3a4badd6e7694538b14aeaa452f300e1f067cf6255a2b63356edaa13d8be64a;
        xor_checksum = 8'd0;
        for (i = 0; i < 32; i = i + 1)
            xor_checksum = xor_checksum ^ digest[i];
        #100 rstn = 1'b1;
        wait (leds[5]);
        #1;
        if (command !== 8'h0B || address !== 24'h20_2000)
            $fatal(1, "QSPI command/address %02h/%06h", command, address);
        if (rx_count !== 36) $fatal(1, "UART frame length %0d", rx_count);
        if (xor_checksum !== 8'hBE) $fatal(1, "test digest XOR mismatch");
        if (csn !== 1'b1 || !leds[2] ||
            dut.flash_word_count !== 32'd8 || leds[3] || !leds[4])
            $fatal(1, "flash transfer status invalid");
        $display("PASS flash_read_top: QSPI 32B, UART 36B, XOR=%02h", xor_checksum);
        $finish;
    end

    initial begin
        #500_000;
        $fatal(1, "end-to-end timeout: UART bytes=%0d", rx_count);
    end
endmodule

// Behavioral stand-in for the generated 32-bit FIFO IP during RTL simulation.
module cp2102_tx_fifo (
    input wire wr_clk, input wire wr_rst, input wire wr_en,
    input wire [31:0] wr_data, output wire wr_full, output wire almost_full,
    input wire rd_clk, input wire rd_rst, input wire rd_en,
    output reg [31:0] rd_data, output wire rd_empty, output wire almost_empty
);
    reg [31:0] memory [0:31];
    reg [5:0] write_pointer;
    reg [5:0] read_pointer;
    assign wr_full = (write_pointer[4:0] == read_pointer[4:0]) &&
                     (write_pointer[5] != read_pointer[5]);
    assign rd_empty = (write_pointer == read_pointer);
    assign almost_full = 1'b0;
    assign almost_empty = rd_empty;

    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) write_pointer <= 6'd0;
        else if (wr_en && !wr_full) begin
            memory[write_pointer[4:0]] <= wr_data;
            write_pointer <= write_pointer + 1'b1;
        end
    end
    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) begin
            read_pointer <= 6'd0;
            rd_data <= 32'd0;
        end else if (rd_en && !rd_empty) begin
            rd_data <= memory[read_pointer[4:0]];
            read_pointer <= read_pointer + 1'b1;
        end
    end
endmodule

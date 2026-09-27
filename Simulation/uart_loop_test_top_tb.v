`timescale 1ns/1ps

// 仅供功能仿真测试平台使用的简化PLL模型。
module pll_50mhz (
    input  wire clkin1,
    output reg  pll_lock,
    output wire clkout0,
    output reg  clkout1
);
    assign clkout0 = clkin1;

    initial begin
        pll_lock = 1'b0;
        clkout1  = 1'b0;
        #200 pll_lock = 1'b1;
    end

    always #33.913 clkout1 = ~clkout1;
endmodule

module uart_loop_test_top_tb;
    localparam integer BIT_TIME_NS = 1085;

    reg        sys_clk_50mhz;
    reg        sys_rst_n;
    reg        sys_uart_rx;
    wire       sys_uart_tx;
    wire [7:0] sys_led;

    integer error_count;
    reg [7:0] tx_byte;

    uart_loop_test_top #(
        .LED_ON_MS(1)
    ) dut (
        .sys_clk_50mhz(sys_clk_50mhz),
        .sys_rst_n    (sys_rst_n),
        .sys_uart_rx  (sys_uart_rx),
        .sys_uart_tx  (sys_uart_tx),
        .sys_led      (sys_led)
    );

    initial begin
        sys_clk_50mhz = 1'b0;
        forever #10 sys_clk_50mhz = ~sys_clk_50mhz;
    end

    task send_uart_byte;
        input [7:0] data;
        integer i;
        begin
            sys_uart_rx = 1'b0;
            #(BIT_TIME_NS);
            for (i = 0; i < 8; i = i + 1) begin
                sys_uart_rx = data[i];
                #(BIT_TIME_NS);
            end
            sys_uart_rx = 1'b1;
            #(BIT_TIME_NS);
        end
    endtask

    task receive_uart_byte;
        output [7:0] data;
        integer i;
        begin
            @(negedge sys_uart_tx);
            #(BIT_TIME_NS + BIT_TIME_NS/2);
            for (i = 0; i < 8; i = i + 1) begin
                data[i] = sys_uart_tx;
                #(BIT_TIME_NS);
            end
            if (sys_uart_tx !== 1'b1) begin
                $display("ERROR: invalid stop bit at %0t", $time);
                error_count = error_count + 1;
            end
        end
    endtask

    task check_loopback;
        input [7:0] expected;
        begin
            fork
                send_uart_byte(expected);
                receive_uart_byte(tx_byte);
            join

            if (tx_byte !== expected) begin
                $display("ERROR: expected %02h, received %02h", expected, tx_byte);
                error_count = error_count + 1;
            end else begin
                $display("PASS: looped back %02h", tx_byte);
            end
            #(BIT_TIME_NS * 2);
        end
    endtask

    initial begin
        sys_rst_n  = 1'b0;
        sys_uart_rx = 1'b1;
        error_count = 0;
        tx_byte     = 8'd0;

        #100 sys_rst_n = 1'b1;
        #1000;

        check_loopback(8'h55);
        check_loopback(8'hA3);
        check_loopback(8'h00);
        check_loopback(8'hFF);

        if (error_count == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED: %0d error(s)", error_count);

        $finish;
    end
endmodule

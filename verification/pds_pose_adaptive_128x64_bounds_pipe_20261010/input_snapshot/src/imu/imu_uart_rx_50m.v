`timescale 1ns/1ps
// Fractional 16x oversampling UART receiver.  The accumulator produces an
// average 14.7456 MHz sampling tick from the existing 50 MHz system clock.
module imu_uart_rx_50m #(
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer BAUD    = 921600
) (
    input  wire       clk,
    input  wire       rstn,
    input  wire       rx,
    output reg [7:0]  data,
    output reg        data_valid
);
    localparam integer TICK_HZ = BAUD * 16;
    reg rx_meta, rx_sync;
    reg [31:0] phase;
    reg [3:0] sample_count;
    reg [3:0] bit_index;
    reg [7:0] shift;
    reg busy;
    // Keep the fractional divider entirely combinational between clocked
    // accumulator updates.  The previous implementation assigned a helper
    // register with blocking assignment inside the sequential block; that
    // relied on simulator event ordering and could infer an unintended state
    // element in synthesis.
    localparam [32:0] CLK_HZ_W  = CLK_HZ;
    localparam [32:0] TICK_HZ_W = TICK_HZ;
    wire [32:0] phase_sum_next = {1'b0, phase} + TICK_HZ_W;
    wire tick = (phase_sum_next >= CLK_HZ_W);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rx_meta <= 1'b1; rx_sync <= 1'b1;
            phase <= 0; sample_count <= 0; bit_index <= 0;
            shift <= 0; busy <= 1'b0; data <= 0; data_valid <= 1'b0;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            data_valid <= 1'b0;
            if (tick) phase <= phase_sum_next - CLK_HZ_W;
            else phase <= phase_sum_next[31:0];

            if (!busy) begin
                sample_count <= 0;
                bit_index <= 0;
                if (!rx_sync) begin
                    busy <= 1'b1;
                    sample_count <= 0;
                end
            end else if (tick) begin
                if (((bit_index == 0) && (sample_count == 4'd7)) ||
                    ((bit_index != 0) && (sample_count == 4'd15))) begin
                    // Confirm the start bit at its centre.
                    if (bit_index == 0) begin
                        if (rx_sync) begin
                            busy <= 1'b0;
                            sample_count <= 0;
                        end else begin
                            bit_index <= 1;
                            sample_count <= 0;
                        end
                    end else if (bit_index <= 8) begin
                        shift[bit_index-1] <= rx_sync;
                        bit_index <= bit_index + 1'b1;
                        sample_count <= 0;
                    end else begin
                        // Stop bit. A low stop bit drops the byte.
                        if (rx_sync) begin
                            data <= shift;
                            data_valid <= 1'b1;
                        end
                        busy <= 1'b0;
                        sample_count <= 0;
                        bit_index <= 0;
                    end
                end else begin
                    sample_count <= sample_count + 1'b1;
                end
            end
        end
    end
endmodule

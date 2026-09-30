// Map subsystem status signals to board LEDs.
module led_top (
    input wire flash_fifo_wr_full,
    input wire flash_busy,
    input wire flash_done,
    input wire flash_overflow,
    input wire tx_activity_toggle,
    input wire frame_done,
    output wire [7:0] sys_led
);
    assign sys_led = {2'b00, frame_done, tx_activity_toggle,
                      flash_overflow, flash_done, flash_busy, flash_fifo_wr_full};
endmodule

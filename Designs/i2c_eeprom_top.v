// I2C EEPROM demonstration top level.
// Keys 1..7 write fixed test bytes to address 0x0000; key 8 reads the byte
// back and displays it on the LEDs.
module i2c_eeprom_top (
    input  wire       sys_clk_50mhz,
    input  wire       sys_rst_n,
    inout  wire       eeprom_i2c_sda,
    output wire       eeprom_i2c_scl,
    input  wire [7:0] key_in,
    output wire [7:0] led_out
);

    localparam [12:0] EEPROM_DEBUG_ADDR = 13'h0000;

    wire clk_50mhz;
    wire pll_lock;
    wire [7:0] key_data;
    reg  [7:0] key_data_d;
    wire [7:0] key_press;

    wire       eeprom_write_full;
    wire       eeprom_read_ready;
    wire       eeprom_read_accept;
    wire [7:0]  eeprom_read_data;
    wire        eeprom_read_data_empty;
    wire        eeprom_read_data_full;
    wire        eeprom_busy;

    reg         read_pending;
    reg  [7:0]  led_data;
    wire        write_req;
    wire [7:0]  write_data;
    wire        read_req;
    wire        read_data_rd_en;

    pll_50mhz u_pll_50mhz (
        .clkin1  (sys_clk_50mhz),
        .clkout0 (clk_50mhz),
        .pll_lock(pll_lock)
    );

    key u_key (
        .clk     (clk_50mhz),
        .rst_n   (sys_rst_n),
        .key_in  (key_in),
        .key_data(key_data)
    );

    // key_data is active high and changes only at the key sampler interval.
    // Detecting its rising edge makes a held key issue one transaction only.
    always @(posedge clk_50mhz or negedge sys_rst_n) begin
        if (!sys_rst_n)
            key_data_d <= 8'd0;
        else
            key_data_d <= key_data;
    end
    assign key_press = key_data & ~key_data_d;

    // A read request is retained until the EEPROM controller accepts it, so a
    // key press during a write or the EEPROM write-cycle delay is not lost.
    always @(posedge clk_50mhz or negedge sys_rst_n) begin
        if (!sys_rst_n)
            read_pending <= 1'b0;
        else begin
            if (key_press[7])
                read_pending <= 1'b1;
            if (eeprom_read_accept)
                read_pending <= 1'b0;
        end
    end

    assign read_req        = read_pending | key_press[7];
    assign read_data_rd_en = !eeprom_read_data_empty;
    assign write_req       = (|key_press[6:0]) && !eeprom_write_full;

    // Priority is only relevant if more than one key is pressed at once.
    assign write_data = key_press[0] ? 8'h55 :
                        key_press[1] ? 8'hAA :
                        key_press[2] ? 8'hFF :
                        key_press[3] ? 8'h00 :
                        key_press[4] ? 8'hA5 :
                        key_press[5] ? 8'h5A :
                        key_press[6] ? 8'h0F : 8'h00;

    // Capture each byte removed from the EEPROM result FIFO for display.
    always @(posedge clk_50mhz or negedge sys_rst_n) begin
        if (!sys_rst_n)
            led_data <= 8'd0;
        else if (!eeprom_read_data_empty)
            led_data <= eeprom_read_data;
    end

    led u_led (
        .clk     (clk_50mhz),
        .rst_n   (sys_rst_n),
        .led_data(led_data),
        .led_out (led_out)
    );

    eeprom #(
        .DEVICE_ADDR         (7'b1010_000),
        .I2C_CLK_FREQ        (50_000_000),
        .I2C_SCL_FREQ        (250_000),
        .WRITE_CYCLE_TIME_US (5_000)
    ) u_eeprom (
        .clk               (clk_50mhz),
        .rst_n             (sys_rst_n),
        .write_req         (write_req),
        .write_addr        (EEPROM_DEBUG_ADDR),
        .write_data        (write_data),
        .write_full        (eeprom_write_full),
        .read_req          (read_req),
        .read_addr         (EEPROM_DEBUG_ADDR),
        .read_ready        (eeprom_read_ready),
        .read_accept       (eeprom_read_accept),
        .read_data_rd_en   (read_data_rd_en),
        .read_data         (eeprom_read_data),
        .read_data_empty   (eeprom_read_data_empty),
        .read_data_full    (eeprom_read_data_full),
        .busy              (eeprom_busy),
        .scl               (eeprom_i2c_scl),
        .sda               (eeprom_i2c_sda)
    );

endmodule

module i2c_eeprom_top (
    input wire sys_clk_50mhz,
    input wire sys_rst_n,

    inout wire eeprom_i2c_sda,
    output wire eeprom_i2c_scl,

    input wire [7:0] key_in,
    output reg [7:0] led_out
);

    localparam integer [7:0] DebugData = 8'b10101010;
    localparam integer [7:0] DebugAddr = 8'b10101010;

    reg eeprom_wr_en;
    reg eeprom_rd_en;

    reh i2c_start;

    reg [7:0] eeprom_rd_data;
    wire i2c_done;

    pll_50mhz u_pll_50mhz (
        .clkin1(sys_clk),
        .clkout0(pll_clk_50mhz),
        .clkout1(i2c_clk_1mhz),
        .pll_lock()
    );

    led u_led (
        .clk(pll_clk_50mhz),
        .rst_n(sys_rst_n),
        .led_data(DebugData),
        .led_out(led_out)
    );

    key u_key (
        .clk(pll_clk_50mhz),
        .io_rst_n(sys_rst_n),
        .io_key_in(key_in),
        .key_data(DebugData)
    );

    i2c u_eeprom (
        .clk(i2c_clk_1mhz),
        .rst_n(sys_rst_n),

        .wr_en(eeprom_wr_en),
        .rd_en(eeprom_rd_en),

        .addr_length(8'd1),
        .addr(DebugAddr),
        .wr_data(DebugData),
        .rd_data(eeprom_rd_data),

        .i2c_start(i2c_start),
        .i2c_done(i2c_done),

        .sda(i2c_sda),
        .scl(i2c_scl)
    );

    always @(posedge pll_clk_50mhz or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            led_out <= 8'b0;
        end
        else begin
            if (i2c_done) begin
                led_out <= eeprom_rd_data;
            end
            else if (key_in[7]) begin
                led_out <= 8'b0;
            end
        end
    end

    always @(posedge pll_50mhz_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            eeprom_wr_en <= 1'b0;
            eeprom_rd_en <= 1'b0;
            i2c_start <= 1'b0;
        end
        else begin
            if (key_in[0]) begin
                eeprom_wr_en <= 1'b1;
                eeprom_rd_en <= 1'b0;
                i2c_start <= 1'b1;
            end
            else if (key_in[1]) begin
                eeprom_wr_en <= 1'b0;
                eeprom_rd_en <= 1'b1;
                i2c_start <= 1'b1;
            end
            else begin
                eeprom_wr_en <= 1'b0;
                eeprom_rd_en <= 1'b0;
                i2c_start <= 1'b0;
            end
        end
    end

endmodule

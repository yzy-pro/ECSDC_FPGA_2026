module i2c_eeprom_top (
    input wire sys_clk_50mhz,
    input wire sys_rst_n,

    inout wire eeprom_i2c_sda,
    output wire eeprom_i2c_scl,

    input wire [7:0] key_in,
    output wire [7:0] led_out
);
    wire pll_clk_50mhz;
    reg i2c_clk_1mhz;

    //实现一个i2c测试模块
    //按下0号按键时，向eeprom写入数据0x55到地址0x55
    //按下1号按键时，从eeprom地址0x55读取数据，并显示在led上
    //按下7号按键时，全部led熄灭

    localparam integer DebugData = 8'b10101010;
    localparam integer DebugAddr = 8'b10101010;

    reg eeprom_wr_en;
    reg eeprom_rd_en;

    reg i2c_start;

    wire [7:0] eeprom_rd_data;
    wire i2c_done;

    pll_50mhz u_pll_50mhz (
        .clkin1(sys_clk),
        .clkout0(pll_clk_50mhz),
        .pll_lock()
    );

    localparam integer I2cClkCnt = 50_000_000 / 1_000_000 / 2;  // 50MHz / 1MHz / 2 = 25
    reg [4:0] i2c_clk_cnt;
    always @(posedge pll_clk_50mhz or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            i2c_clk_cnt <= 5'd0;
            i2c_clk_1mhz <= 1'b0;
        end
        else begin
            if (i2c_clk_cnt < I2cClkCnt - 1) begin
                i2c_clk_cnt <= i2c_clk_cnt + 1;
            end
            else begin
                i2c_clk_cnt <= 5'd0;
                i2c_clk_1mhz <= ~i2c_clk_1mhz;
            end
        end
    end

    reg [7:0] led_data;
    led u_led (
        .clk(pll_clk_50mhz),
        .rst_n(sys_rst_n),
        .led_data(led_data),
        .led_out(led_out)
    );

    wire [7:0] key_data;
    key u_key (
        .clk(pll_clk_50mhz),
        .rst_n(sys_rst_n),
        .key_in(key_in),
        .key_data(key_data)
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
            led_data <= 8'b0;
        end
        else begin
            if (i2c_done) begin
                led_data <= eeprom_rd_data;
            end
            else if (key_data[7]) begin
                led_data <= 8'b0;
            end
        end
    end

    always @(posedge pll_clk_50mhz or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            eeprom_wr_en <= 1'b0;
            eeprom_rd_en <= 1'b0;
            i2c_start <= 1'b0;
        end
        else begin
            if (key_data[0]) begin
                eeprom_wr_en <= 1'b1;
                eeprom_rd_en <= 1'b0;
                i2c_start <= 1'b1;
            end
            else if (key_data[1]) begin
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

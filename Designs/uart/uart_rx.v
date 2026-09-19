module uart_rx #(
    // parameter integer UART_SYSCLK_FREQ = 50_000_000,
    parameter integer UART_BAUD_RATE = 921600,
    parameter integer UART_OVER_SAMPLING = 16
) (
    input wire clk,
    input wire rst_n,
    input wire rx,
    output reg [7:0] data_out,
    output reg data_valid
);
    reg [2:0] tmp_reg;  // 用于消除亚稳态的临时寄存器
    reg rx_start;  // 检测到下降沿时start_nedge产生一个时钟的高电平
    reg rx_busy;  // 接收忙标志
    reg [3:0] bit_count;  // 接收的位计数器
    reg sample_flag;  // 采样标志
    reg [3:0] sample_count;  // 采样计数器

    reg [7:0] data_out_temp;  // 接收数据的移位寄存器
    reg data_valid_temp;  // 数据有效标志

    // 消亚稳态寄存器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tmp_reg <= 3'b111;
        end
        else begin
            tmp_reg <= {tmp_reg[1:0], rx};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_start <= 1'b0;
        end
        else if (tmp_reg[2:1] == 2'b10) begin
            // 检测到下降沿，产生一个时钟周期的高电平信号
            rx_start <= 1'b1;
        end
        else begin
            rx_start <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_busy <= 1'b0;
        end
        else if (rx_start) begin
            rx_busy <= 1'b1;  // 开始接收数据，设置接收忙标志
        end
        else if (bit_count == 4'd8 && sample_flag) begin
            rx_busy <= 1'b0;  // 接收完成，清除接收忙标志
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count <= 4'b0;
        end
        else if ((sample_count == UART_OVER_SAMPLING - 1) || !rx_busy) begin
            sample_count <= 4'b0;
        end
        else if (rx_busy) begin
            sample_count <= sample_count + 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_flag <= 1'b0;
        end
        else if (sample_count == UART_OVER_SAMPLING / 2 - 1) begin
            sample_flag <= 1'b1;  // 在计数中间点产生采样标志
        end
        else begin
            sample_flag <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_count <= 4'b0;
        end
        else if ((bit_count == 4'd8) && sample_flag) begin
            bit_count <= 4'b0;  // 接收到下降沿，开始接收数据，清零计数器
        end
        else if (sample_flag) begin
            bit_count <= bit_count + 1'b1;  // 每次采样标志有效时，计数器加1
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out_temp <= 8'b0;
        end
        else if (bit_count >= 4'd1 && bit_count <= 4'd8 && sample_flag) begin
            data_out_temp <= {
                tmp_reg[2], data_out_temp[7:1]
            };  // 将采样到的数据移入寄存器
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_valid_temp <= 1'b0;
        end
        else if (bit_count == 4'd8 && sample_flag) begin
            data_valid_temp <= 1'b1;  // 接收完成，数据有效标志置高
        end
        else begin
            data_valid_temp <= 1'b0;  // 数据有效标志清零
        end
    end

    //数据输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= 8'b0;
            data_valid <= 1'b0;
        end
        else begin
            data_out <= data_out_temp;  // 将接收到的数据输出
            data_valid <= data_valid_temp;  // 将数据有效标志输出
        end
    end

endmodule

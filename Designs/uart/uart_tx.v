module uart_tx #(
    parameter integer UART_BAUD_RATE = 921600,
    parameter integer UART_OVER_SAMPLING = 16
) (
    input wire clk,
    input wire rst_n,

    input wire [7:0] data_in,
    input wire data_valid,

    output reg data_out
);
    reg [3:0] state;  //状态机状态寄存器
    localparam integer StateTxIdle = 4'b0000;  //空闲状态
    localparam integer StateTxDataBegin = StateTxIdle + 4'b0001;  //采集起始位
    localparam integer StateTxData1 = StateTxDataBegin + 4'b0001;  //采集数据位1
    localparam integer StateTxData2 = StateTxData1 + 4'b0001;  //采集数据位2
    localparam integer StateTxData3 = StateTxData2 + 4'b0001;  //采集数据位3
    localparam integer StateTxData4 = StateTxData3 + 4'b0001;  //采集数据位4
    localparam integer StateTxData5 = StateTxData4 + 4'b0001;  //采集数据位5
    localparam integer StateTxData6 = StateTxData5 + 4'b0001;  //采集数据位6
    localparam integer StateTxData7 = StateTxData6 + 4'b0001;  //采集数据位7
    localparam integer StateTxData8 = StateTxData7 + 4'b0001;  //采集数据位8
    localparam integer StateTxDataEnd = StateTxData8 + 4'b0001;  //采集停止位
    localparam integer StateTxDataAll = StateTxDataEnd + 4'b0001;  //采集完成，数据有效

    localparam
        integer SampleCount = UART_OVER_SAMPLING / 2 - 1;  //采样计数器为中值时进行采样

    reg [3:0] sample_count;  //采样计数器
    reg [7:0] data_in_locked;  //数据缓存寄存器

    //采样计数器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count <= 8'd0;
        end
        else begin
            if (state == StateTxIdle) begin
                sample_count <= 8'd0;
            end
            else begin
                sample_count <= sample_count + 1'b1;
            end
        end
    end

    //状态机状态切换描述
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= StateTxIdle;
        end
        else begin

            case (state)
                StateTxIdle: begin
                    if (data_valid == 1'b1) begin
                        state <= StateTxDataBegin;
                    end
                end

                StateTxDataBegin: begin
                    if (sample_count == SampleCount) begin
                        state <= StateTxData1;
                    end
                end

                StateTxData1: begin
                    if (sample_count == SampleCount) begin
                        state <= StateTxData2;
                    end
                end

                StateTxData2: begin
                    if (sample_count == SampleCount) begin
                        state <= StateTxData3;
                    end
                end

                StateTxData3: begin
                    if (sample_count == SampleCount) begin
                        state <= StateTxData4;
                    end
                end

                StateTxData4: begin
                    if (sample_count == SampleCount) begin
                        state <= StateTxData5;
                    end
                end

                StateTxData5: begin
                    if (sample_count == SampleCount) begin
                        state <= StateTxData6;
                    end
                end

                StateTxData6: begin
                    if (sample_count == SampleCount) begin
                        state <= StateTxData7;
                    end
                end

                StateTxData7: begin
                    if (sample_count == SampleCount) begin
                        state <= StateTxData8;
                    end
                end

                StateTxData8: begin
                    if (sample_count == SampleCount) begin
                        state <= StateTxDataEnd;
                    end
                end

                StateTxDataEnd: begin
                    if (sample_count == SampleCount) begin
                        state <= StateTxDataAll;
                    end
                end

                StateTxDataAll: begin
                    state <= StateTxIdle;
                end

                default: begin
                    state <= StateTxIdle;
                end
            endcase
        end
    end

    //状态机输出描述
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= 1'd0;
        end
        else begin

            case (state)
                StateTxIdle: begin
                    data_out <= 1'd1;  //空闲状态输出高电平
                    if (data_valid) begin
                        data_in_locked <= data_in;  //锁存数据
                    end
                end

                StateTxDataBegin: begin
                    if (sample_count == SampleCount) begin
                        data_out <= 1'd0;  //输出起始位，输出低电平
                    end
                end

                StateTxData1: begin
                    if (sample_count == SampleCount) begin
                        data_out <= data_in_locked[0];  //输出数据位1
                    end
                end

                StateTxData2: begin
                    if (sample_count == SampleCount) begin
                        data_out <= data_in_locked[1];  //输出数据位2
                    end
                end

                StateTxData3: begin
                    if (sample_count == SampleCount) begin
                        data_out <= data_in_locked[2];  //输出数据位3
                    end
                end

                StateTxData4: begin
                    if (sample_count == SampleCount) begin
                        data_out <= data_in_locked[3];  //输出数据位4
                    end
                end

                StateTxData5: begin
                    if (sample_count == SampleCount) begin
                        data_out <= data_in_locked[4];  //输出数据位5
                    end
                end

                StateTxData6: begin
                    if (sample_count == SampleCount) begin
                        data_out <= data_in_locked[5];  //输出数据位6
                    end
                end

                StateTxData7: begin
                    if (sample_count == SampleCount) begin
                        data_out <= data_in_locked[6];  //输出数据位7
                    end
                end

                StateTxData8: begin
                    if (sample_count == SampleCount) begin
                        data_out <= data_in_locked[7];  //输出数据位8
                    end
                end

                StateTxDataEnd: begin
                    if (sample_count == SampleCount) begin
                        data_out <= 1'd1;  //输出停止位，输出高电平
                    end
                end

                StateTxDataAll: begin
                    data_out <= 1'd1;  //输出停止位，输出高电平
                end

                default: begin
                    data_out <= 1'd1;  //输出停止位，输出高电平
                end
            endcase
        end
    end

endmodule

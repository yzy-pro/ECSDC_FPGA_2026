module uart_rx #(
    parameter integer UART_BAUD_RATE = 921600,
    parameter integer UART_OVER_SAMPLING = 16
) (
    input wire clk,
    input wire rst_n,

    input wire data_in,

    output reg [7:0] data_out,
    output reg data_valid
);
    reg [3:0] state;  //状态机状态寄存器
    localparam integer StateRxIdle = 4'b0000;  //空闲状态
    localparam integer StateRxDataBegin = StateRxIdle + 4'b0001;  //采集起始位
    localparam integer StateRxData1 = StateRxDataBegin + 4'b0001;  //采集数据位1
    localparam integer StateRxData2 = StateRxData1 + 4'b0001;  //采集数据位2
    localparam integer StateRxData3 = StateRxData2 + 4'b0001;  //采集数据位3
    localparam integer StateRxData4 = StateRxData3 + 4'b0001;  //采集数据位4
    localparam integer StateRxData5 = StateRxData4 + 4'b0001;  //采集数据位5
    localparam integer StateRxData6 = StateRxData5 + 4'b0001;  //采集数据位6
    localparam integer StateRxData7 = StateRxData6 + 4'b0001;  //采集数据位7
    localparam integer StateRxData8 = StateRxData7 + 4'b0001;  //采集数据位8
    localparam integer StateRxDataEnd = StateRxData8 + 4'b0001;  //采集停止位
    localparam integer StateRxDataAll = StateRxDataEnd + 4'b0001;  //采集完成，数据有效

    localparam
        integer SampleCount = UART_OVER_SAMPLING / 2 - 1;  //采样计数器为中值时进行采样

    reg [3:0] sample_count;  //采样计数器

    reg [2:0] tmp_reg;  //二级缓存寄存器
    reg [7:0] tmp_data_out;  //数据缓存寄存器

    //二级缓存避免亚稳态
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tmp_reg <= 3'b111;
        end
        else begin
            tmp_reg <= {tmp_reg[1:0], data_in};
        end
    end

    //采样计数器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count <= 8'd0;
        end
        else begin
            if (state == StateRxIdle) begin
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
            state <= StateRxIdle;
        end
        else begin

            case (state)
                StateRxIdle: begin
                    if (tmp_reg[2:1] == 2'b10) begin
                        state <= StateRxDataBegin;
                    end
                end

                StateRxDataBegin: begin
                    if (sample_count == SampleCount) begin
                        state <= StateRxData1;
                    end
                end

                StateRxData1: begin
                    if (sample_count == SampleCount) begin
                        state <= StateRxData2;
                    end
                end

                StateRxData2: begin
                    if (sample_count == SampleCount) begin
                        state <= StateRxData3;
                    end
                end

                StateRxData3: begin
                    if (sample_count == SampleCount) begin
                        state <= StateRxData4;
                    end
                end

                StateRxData4: begin
                    if (sample_count == SampleCount) begin
                        state <= StateRxData5;
                    end
                end

                StateRxData5: begin
                    if (sample_count == SampleCount) begin
                        state <= StateRxData6;
                    end
                end

                StateRxData6: begin
                    if (sample_count == SampleCount) begin
                        state <= StateRxData7;
                    end
                end

                StateRxData7: begin
                    if (sample_count == SampleCount) begin
                        state <= StateRxData8;
                    end
                end

                StateRxData8: begin
                    if (sample_count == SampleCount) begin
                        state <= StateRxDataEnd;
                    end
                end

                StateRxDataEnd: begin
                    if (sample_count == SampleCount) begin
                        state <= StateRxDataAll;
                    end
                end

                StateRxDataAll: begin
                    state <= StateRxIdle;
                end

                default: begin
                    state <= StateRxIdle;
                end
            endcase
        end
    end

    //状态机输出描述
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tmp_data_out <= 8'd0;
            data_out <= 8'd0;
            data_valid <= 1'b0;
        end
        else begin

            case (state)
                StateRxIdle: begin
                    tmp_data_out <= 8'd0;
                    data_out <= 8'd0;
                    data_valid <= 1'b0;
                end

                StateRxDataBegin: begin
                    if (sample_count == SampleCount) begin
                        tmp_data_out <= 8'd0;
                        data_out <= 8'd0;
                        data_valid <= 1'b0;
                    end
                end

                StateRxData1: begin
                    if (sample_count == SampleCount) begin
                        tmp_data_out <= {tmp_reg[2], tmp_data_out[7:1]};
                        data_out <= 8'd0;
                        data_valid <= 1'b0;
                    end
                end

                StateRxData2: begin
                    if (sample_count == SampleCount) begin
                        tmp_data_out <= {tmp_reg[2], tmp_data_out[7:1]};
                        data_out <= 8'd0;
                        data_valid <= 1'b0;
                    end
                end

                StateRxData3: begin
                    if (sample_count == SampleCount) begin
                        tmp_data_out <= {tmp_reg[2], tmp_data_out[7:1]};
                        data_out <= 8'd0;
                        data_valid <= 1'b0;
                    end
                end

                StateRxData4: begin
                    if (sample_count == SampleCount) begin
                        tmp_data_out <= {tmp_reg[2], tmp_data_out[7:1]};
                        data_out <= 8'd0;
                        data_valid <= 1'b0;
                    end
                end

                StateRxData5: begin
                    if (sample_count == SampleCount) begin
                        tmp_data_out <= {tmp_reg[2], tmp_data_out[7:1]};
                        data_out <= 8'd0;
                        data_valid <= 1'b0;
                    end
                end

                StateRxData6: begin
                    if (sample_count == SampleCount) begin
                        tmp_data_out <= {tmp_reg[2], tmp_data_out[7:1]};
                        data_out <= 8'd0;
                        data_valid <= 1'b0;
                    end
                end

                StateRxData7: begin
                    if (sample_count == SampleCount) begin
                        tmp_data_out <= {tmp_reg[2], tmp_data_out[7:1]};
                        data_out <= 8'd0;
                        data_valid <= 1'b0;
                    end
                end

                StateRxData8: begin
                    if (sample_count == SampleCount) begin
                        tmp_data_out <= {tmp_reg[2], tmp_data_out[7:1]};
                        data_out <= 8'd0;
                        data_valid <= 1'b0;
                    end
                end

                StateRxDataEnd: begin
                    if (sample_count == SampleCount) begin
                        //采集停止位，但是不需要保存数据
                        data_out <= 8'd0;
                        data_valid <= 1'b0;
                    end
                end

                StateRxDataAll: begin
                    data_out <= tmp_data_out;
                    data_valid <= 1'b1;
                end

                default: begin
                    tmp_data_out <= 8'd0;
                    data_out <= 8'd0;
                    data_valid <= 1'b0;
                end
            endcase
        end
    end

endmodule

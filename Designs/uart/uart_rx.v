module uart_rx #(
    // parameter integer UART_SYSCLK_FREQ = 50_000_000,
    parameter integer UART_BAUD_RATE = 921600,
    parameter integer UART_OVER_SAMPLING = 16
) (
    input wire clk,  //串口时钟，理论上应为 UART_BAUD_RATE * UART_OVER_SAMPLING
    input wire rst_n,  // 异步复位信号，低电平有效
    input wire data_in,  // 串口接收数据输入
    output reg [7:0] data_out,  // 接收到的数据输出
    output reg data_valid  // 数据有效信号，表示接收到的数据有效
);
    reg [3:0] state;  // 状态寄存器
    localparam integer StateRxIdle = 4'b0000;  // 空闲状态,
    localparam integer StateRxReady = StateRxIdle + 4'b0001;  //电平拉低，接受准备状态
    localparam integer StateRxDataBegin = StateRxReady + 4'b0001;  // 接收起始位
    localparam integer StateRxData1 = StateRxDataBegin + 4'b0001;  // 接收第1位数据
    localparam integer StateRxData2 = StateRxData1 + 4'b0001;  // 接收第2位数据
    localparam integer StateRxData3 = StateRxData2 + 4'b0001;  // 接收第3位数据
    localparam integer StateRxData4 = StateRxData3 + 4'b0001;  // 接收第4位数据
    localparam integer StateRxData5 = StateRxData4 + 4'b0001;  // 接收第5位数据
    localparam integer StateRxData6 = StateRxData5 + 4'b0001;  // 接收第6位数据
    localparam integer StateRxData7 = StateRxData6 + 4'b0001;  // 接收第7位数据
    localparam integer StateRxData8 = StateRxData7 + 4'b0001;  // 接收第8位数据
    localparam integer StateRxDataEnd = StateRxData8 + 4'b0001;  // 接收停止位
    localparam integer StateRxDataAll = StateRxDataEnd + 4'b0001;  // 全部数据接受完成

    reg [2:0] tmp_reg;  // 用于消除亚稳态的临时寄存器
    reg [3:0] sample_count
        ;  // 采样计数器,从1到UART_OVER_SAMPLING，采样到中间时进行一次数据采样
    reg [7:0] tmp_data_out;  // 用于存储接收到的数据，接收完成后再输出到data_out


    // 消亚稳态寄存器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tmp_reg <= 3'b111;
        end
        else begin
            tmp_reg <= {tmp_reg[1:0], data_in};
        end
    end

    // 采样计数器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count <= 4'b0;
        end
        else if ((sample_count == UART_OVER_SAMPLING - 1)) begin
            // 采样计数器达到最大值，重置为0
            sample_count <= 4'b0;
        end
        else if (state != StateRxIdle) begin
            // 采样计数器自增
            sample_count <= sample_count + 1'b1;
        end
        else begin
            sample_count <= 4'b0;
        end
    end

    //  状态切换
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= StateRxIdle;
        end
        else begin
            case (state)
                StateRxIdle: begin
                    if (tmp_reg[2:1] == 2'b10) begin
                        // 检测到起始位(下降沿)，进入接收准备状态
                        state <= StateRxReady;
                    end
                end
                StateRxReady: begin
                    if ((sample_count == UART_OVER_SAMPLING)) begin
                        // 等待14个采样周期后，接受起始位（因为两级寄存器缓存了两个采样周期），进入接收开始状态
                        state <= StateRxDataBegin;
                    end
                end
                StateRxDataBegin: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        // 接收完成第一个数据，准备接受下一个数据
                        state <= StateRxData1;
                    end
                end
                StateRxData1: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        state <= StateRxData2;
                    end
                end
                StateRxData2: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        state <= StateRxData3;
                    end
                end
                StateRxData3: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        state <= StateRxData4;
                    end
                end
                StateRxData4: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        state <= StateRxData5;
                    end
                end
                StateRxData5: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        state <= StateRxData6;
                    end
                end
                StateRxData6: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        state <= StateRxData7;
                    end
                end
                StateRxData7: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        state <= StateRxData8;
                    end
                end
                StateRxData8: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        // 接收完成，接收到停止位(高电平)，进入空闲状态
                        state <= StateRxDataAll;
                    end
                end
                StateRxDataAll: begin
                    if (tmp_reg[2] == 1'b1) begin
                        // 检测到停止位(高电平)，进入空闲状态
                        state <= StateRxIdle;
                    end
                end
                default: begin
                    state <= StateRxIdle;  // 默认状态，进入空闲状态
                end
            endcase
        end
    end


    //  状态输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tmp_data_out <= 8'b0;
            data_out <= 8'b0;
            data_valid <= 1'b0;
        end
        else begin
            case (state)
                StateRxIdle: begin
                    data_out <= 7'b0;
                    data_valid <= 1'b0;
                end
                StateRxReady: begin
                    data_out <= 7'b0;
                    data_valid <= 1'b0;
                end
                StateRxDataBegin: begin
                    data_out <= 7'b0;
                    data_valid <= 1'b0;
                end
                StateRxData1: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        tmp_data_out <= {
                            tmp_reg[2], tmp_data_out[7:1]
                        };  // 将采样到的数据移入寄存器
                    end
                    data_out <= 7'b0;
                    data_valid <= 1'b0;
                end
                StateRxData2: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        tmp_data_out <= {
                            tmp_reg[2], tmp_data_out[7:1]
                        };  // 将采样到的数据移入寄存器
                    end
                    data_out <= 7'b0;
                    data_valid <= 1'b0;
                end
                StateRxData3: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        tmp_data_out <= {
                            tmp_reg[2], tmp_data_out[7:1]
                        };  // 将采样到的数据移入寄存器
                    end
                    data_out <= 7'b0;
                    data_valid <= 1'b0;
                end
                StateRxData4: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        tmp_data_out <= {
                            tmp_reg[2], tmp_data_out[7:1]
                        };  // 将采样到的数据移入寄存器
                    end
                    data_out <= 7'b0;
                    data_valid <= 1'b0;
                end
                StateRxData5: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        tmp_data_out <= {
                            tmp_reg[2], tmp_data_out[7:1]
                        };  // 将采样到的数据移入寄存器
                    end
                    data_out <= 7'b0;
                    data_valid <= 1'b0;
                end
                StateRxData6: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        tmp_data_out <= {
                            tmp_reg[2], tmp_data_out[7:1]
                        };  // 将采样到的数据移入寄存器
                    end
                    data_out <= 7'b0;
                    data_valid <= 1'b0;
                end
                StateRxData7: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        tmp_data_out <= {
                            tmp_reg[2], tmp_data_out[7:1]
                        };  // 将采样到的数据移入寄存器
                    end
                    data_out <= 7'b0;
                    data_valid <= 1'b0;
                end
                StateRxData8: begin
                    if ((sample_count == UART_OVER_SAMPLING / 2 - 1)) begin
                        tmp_data_out <= {
                            tmp_reg[2], tmp_data_out[7:1]
                        };  // 将采样到的数据移入寄存器
                    end
                    data_out <= 7'b0;
                    data_valid <= 1'b0;
                end
                StateRxDataAll: begin
                    data_out <= tmp_data_out;  // 将接收到的数据输出
                    data_valid <= 1'b1;  // 数据有效信号拉高
                end
                default: begin
                    ;
                end
            endcase
        end
    end

endmodule

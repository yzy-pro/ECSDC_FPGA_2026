// QSPI Flash 连续读取主机。
// 模块没有启动或停止接口，复位释放后自动开始连续读取，
// 直到再次复位为止。
module qspi_master_rx #(
    parameter integer QSPI_CLK_FREQ = 50_000_000,
    parameter integer QSPI_SCK_FREQ = 12_500_000,
    parameter integer QSPI_MODE = 0,
    // 直接例化模块时使用的默认配置。
    // 下面的输入配置会在每次读取开始时锁存，并优先于参数配置。
    parameter [7:0] READ_OPCODE = 8'h6B,
    parameter [23:0] READ_START_ADDRESS = 24'h000000,
    parameter [7:0] READ_DUMMY_CYCLES = 8'd8
) (
    input wire qspi_clk,
    input wire sys_rstn,
    output wire sys_qspi_csn,
    inout wire [3:0] sys_qspi_dq,
    output wire sys_qspi_sck,
    output wire rx_data_valid,
    output wire [7:0] rx_data,
    input wire [7:0] read_opcode,  // 读取指令，例如 8'h6B
    input wire [23:0] read_start_address,  // 起始字节地址
    input wire [7:0] read_dummy_cycles  // 地址之后的空闲 SCK 周期数
);

    // 分频系数向上取整，确保 SCK 频率不会超过 QSPI_SCK_FREQ。
    localparam
        integer SCK_DIV_CALC = (QSPI_CLK_FREQ + (2 * QSPI_SCK_FREQ) - 1) / (2 * QSPI_SCK_FREQ);
    localparam integer SCK_DIV = (SCK_DIV_CALC < 1) ? 1 : SCK_DIV_CALC;
    localparam integer DIV_CNT_W = (SCK_DIV < 2) ? 1 : $clog2(SCK_DIV);
    localparam integer DUMMY_CNT_W = 8;
    localparam integer CPOL = ((QSPI_MODE == 2) || (QSPI_MODE == 3));
    localparam integer CPHA = ((QSPI_MODE == 1) || (QSPI_MODE == 3));
    // 保证该值为 1 位。直接对 integer 类型的 CPOL 使用 '~' 会得到
    // 32 位全 1 数值，与 1 位 SCK 比较时会导致 CPHA=1 模式失效。
    localparam integer SAMPLE_LEVEL = CPHA ? (CPOL ? 1'b0 : 1'b1) : CPOL;

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_CMD   = 3'd1;
    localparam [2:0] ST_ADDR  = 3'd2;
    localparam [2:0] ST_DUMMY = 3'd3;
    localparam [2:0] ST_DATA  = 3'd4;

    reg [2:0] state_current;
    reg [2:0] state_next;
    reg [DIV_CNT_W-1:0] div_count;
    reg sck_reg;
    reg [7:0] command_shift;
    reg [23:0] address_shift;
    reg [7:0] dummy_cycles_reg;
    reg [3:0] command_count;
    reg [4:0] address_count;
    reg [DUMMY_CNT_W-1:0] dummy_count;
    reg data_nibble;
    reg [2:0] data_bit_count;
    reg single_data_reg;
    reg [7:0] data_shift;
    reg [7:0] rx_data_reg;
    reg rx_data_valid_reg;
    reg [3:0] dq_out_reg;
    reg dq_oe_reg;

    wire sck_tick;
    wire sample_edge;

    // 顶层实例通常会连接这三个配置输入。
    // 如果输入完全悬空，则使用参数默认值，保证模块单独使用时行为确定。
    function [7:0] opcode_or_default;
        input [7:0] value;
        begin
            case (value)
                8'bzzzzzzzz: opcode_or_default = READ_OPCODE;
                default: opcode_or_default = value;
            endcase
        end
    endfunction

    function [23:0] address_or_default;
        input [23:0] value;
        begin
            case (value)
                24'bzzzzzzzzzzzzzzzzzzzzzzzz: address_or_default = READ_START_ADDRESS;
                default: address_or_default = value;
            endcase
        end
    endfunction

    function [7:0] dummy_or_default;
        input [7:0] value;
        begin
            case (value)
                8'bzzzzzzzz: dummy_or_default = READ_DUMMY_CYCLES;
                default: dummy_or_default = value;
            endcase
        end
    endfunction

    wire [7:0] opcode_config = opcode_or_default(read_opcode);
    wire [23:0] address_config = address_or_default(read_start_address);
    wire [7:0] dummy_config = dummy_or_default(read_dummy_cycles);

    assign sck_tick = (div_count == SCK_DIV - 1);
    assign sample_edge = sck_tick && (sck_reg == SAMPLE_LEVEL);

    // 0x0B reads data on IO1; 0x6B reads data on all four IO lines.
    // 指令和地址阶段只驱动 IO0，IO1~IO3 保持高阻，避免影响
    // Flash 的 MISO、WP# 和 HOLD# 信号。
    assign sys_qspi_dq[0] = dq_oe_reg ? dq_out_reg[0] : 1'bz;
    assign sys_qspi_dq[3:1] = 3'bzzz;
    assign sys_qspi_csn = (state_current == ST_IDLE);
    assign sys_qspi_sck = sck_reg;
    assign rx_data = rx_data_reg;
    assign rx_data_valid = rx_data_valid_reg;

    // 状态机第一段：状态寄存器。
    always @(posedge qspi_clk or negedge sys_rstn) begin
        if (!sys_rstn) state_current <= ST_IDLE;
        else state_current <= state_next;
    end

    // 状态机第二段：组合逻辑计算下一状态。
    always @(*) begin
        state_next = state_current;
        case (state_current)
            ST_IDLE: state_next = ST_CMD;
            ST_CMD: begin
                if (sample_edge && (command_count == 4'd7)) state_next = ST_ADDR;
            end
            ST_ADDR: begin
                if (sample_edge && (address_count == 5'd23)) begin
                    if (dummy_cycles_reg == 0) state_next = ST_DATA;
                    else state_next = ST_DUMMY;
                end
            end
            ST_DUMMY: begin
                // 在最后一个 dummy 采样边沿切换到数据状态。
                // 该写法避免计数值为 0 时发生下溢；dummy 为 0 时，
                // 地址状态会直接跳转到数据状态。
                if (sample_edge && ((dummy_count + 1'b1) >= dummy_cycles_reg)) state_next = ST_DATA;
            end
            ST_DATA: begin
                state_next = ST_DATA;
            end
            default: state_next = ST_IDLE;
        endcase
    end

    // 状态机第三段：输出信号和数据通路寄存器。
    always @(posedge qspi_clk or negedge sys_rstn) begin
        if (!sys_rstn) begin
            div_count <= {DIV_CNT_W{1'b0}};
            sck_reg <= CPOL;
            command_shift <= 8'd0;
            address_shift <= 24'd0;
            dummy_cycles_reg <= 8'd0;
            command_count <= 4'd0;
            address_count <= 5'd0;
            dummy_count <= {DUMMY_CNT_W{1'b0}};
            data_nibble <= 1'b0;
            data_bit_count <= 3'd0;
            single_data_reg <= 1'b0;
            data_shift <= 8'd0;
            rx_data_reg <= 8'd0;
            rx_data_valid_reg <= 1'b0;
            dq_out_reg <= 4'd0;
            dq_oe_reg <= 1'b0;
        end
        else begin
            rx_data_valid_reg <= 1'b0;
            if (state_current == ST_IDLE) begin
                div_count <= {DIV_CNT_W{1'b0}};
                sck_reg <= CPOL;
                dummy_cycles_reg <= dummy_config;
                command_shift <= opcode_config;
                address_shift <= address_config;
                command_count <= 4'd0;
                address_count <= 5'd0;
                dummy_count <= {DUMMY_CNT_W{1'b0}};
                data_nibble <= 1'b0;
                data_bit_count <= 3'd0;
                single_data_reg <= (opcode_config == 8'h0B) || (opcode_config == 8'h03);
                data_shift <= 8'd0;
                dq_out_reg <= {3'b000, opcode_config[7]};
                dq_oe_reg <= 1'b1;
            end
            else if (sck_tick) begin
                div_count <= {DIV_CNT_W{1'b0}};
                sck_reg <= ~sck_reg;

                if (sample_edge) begin
                    case (state_current)
                        ST_CMD: begin
                            command_count <= command_count + 1'b1;
                        end
                        ST_ADDR: begin
                            address_count <= address_count + 1'b1;
                        end
                        ST_DUMMY: begin
                            dummy_count <= dummy_count + 1'b1;
                        end
                        ST_DATA: begin
                            if (single_data_reg) begin
                                data_shift <= {data_shift[6:0], sys_qspi_dq[1]};
                                if (data_bit_count == 3'd7) begin
                                    rx_data_reg <= {data_shift[6:0], sys_qspi_dq[1]};
                                    rx_data_valid_reg <= 1'b1;
                                    data_bit_count <= 3'd0;
                                end else begin
                                    data_bit_count <= data_bit_count + 1'b1;
                                end
                            end else begin
                                data_shift <= {data_shift[3:0], sys_qspi_dq};
                                if (!data_nibble) data_nibble <= 1'b1;
                                else begin
                                    rx_data_reg <= {data_shift[3:0], sys_qspi_dq};
                                    rx_data_valid_reg <= 1'b1;
                                    data_nibble <= 1'b0;
                                end
                            end
                        end
                        default: begin
                        end
                    endcase
                end
                else begin
                    // 只在非采样边沿更新发送数据。
                    // 计数值为 0 时保持首位数据，以适配 CPHA=1 模式。
                    case (state_current)
                        ST_CMD: begin
                            dq_oe_reg <= 1'b1;
                            if (command_count != 0) begin
                                command_shift <= {command_shift[6:0], 1'b0};
                                dq_out_reg <= {3'b000, command_shift[6]};
                            end
                        end
                        ST_ADDR: begin
                            dq_oe_reg <= 1'b1;
                            if (address_count == 0) dq_out_reg <= {3'b000, address_shift[23]};
                            else begin
                                address_shift <= {address_shift[22:0], 1'b0};
                                dq_out_reg <= {3'b000, address_shift[22]};
                            end
                        end
                        ST_DUMMY, ST_DATA: begin
                            dq_oe_reg <= 1'b0;
                        end
                        default: begin
                        end
                    endcase
                end
            end
            else begin
                div_count <= div_count + 1'b1;
            end
        end
    end

endmodule

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
    parameter [7:0] READ_DUMMY_CYCLES = 8'd8,
    // W25Q128 powers up with QE=0 on a fresh device.  Set SR2.QE before
    // the first 6Bh transaction so quad output does not depend on how the
    // flash was previously programmed.
    parameter integer INIT_QUAD_ENABLE = 1,
    parameter integer INIT_CS_HIGH_CYCLES = 4,
    parameter integer QE_INIT_DELAY_CYCLES = 1_000_000
) (
    input wire qspi_clk,
    input wire sys_rstn,
    output wire sys_qspi_csn,
    inout wire [3:0] sys_qspi_dq,
    output wire sys_qspi_sck,
    output wire rx_data_valid,
    output wire [7:0] rx_data,
    input wire rx_data_ready,
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
    localparam integer INIT_GAP_CNT_W =
        (INIT_CS_HIGH_CYCLES < 2) ? 1 : $clog2(INIT_CS_HIGH_CYCLES + 1);
    localparam integer CPOL = ((QSPI_MODE == 2) || (QSPI_MODE == 3));
    localparam integer CPHA = ((QSPI_MODE == 1) || (QSPI_MODE == 3));
    // 保证该值为 1 位。直接对 integer 类型的 CPOL 使用 '~' 会得到
    // 32 位全 1 数值，与 1 位 SCK 比较时会导致 CPHA=1 模式失效。
    localparam integer SAMPLE_LEVEL = CPHA ? (CPOL ? 1'b0 : 1'b1) : CPOL;

    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_CMD        = 4'd1;
    localparam [3:0] ST_ADDR       = 4'd2;
    localparam [3:0] ST_DUMMY      = 4'd3;
    localparam [3:0] ST_DATA       = 4'd4;
    localparam [3:0] ST_INIT_WREN  = 4'd5;
    localparam [3:0] ST_INIT_GAP   = 4'd6;
    localparam [3:0] ST_INIT_WRSR  = 4'd7;
    localparam [3:0] ST_INIT_DATA  = 4'd8;
    localparam [3:0] ST_INIT_WAIT  = 4'd9;

    reg [3:0] state_current;
    reg [3:0] state_next;
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
    reg init_done;
    reg [INIT_GAP_CNT_W-1:0] init_gap_count;
    reg [31:0] init_wait_count;
    reg [7:0] init_data_shift;
    reg [3:0] init_data_count;
    // Keep W25Q128 WP# and HOLD#/RESET# inactive while the FPGA owns the bus.
    // They are released before the flash starts driving quad read data.
    reg aux_oe_reg;

    wire sck_tick;
    wire sample_edge;
    wire transfer_tick;

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
    assign transfer_tick = sck_tick &&
                           ((state_current != ST_DATA) || rx_data_ready);
    assign sample_edge = transfer_tick && (sck_reg == SAMPLE_LEVEL);

    // 0x0B reads data on IO1; 0x6B reads data on all four IO lines.
    // 指令和地址阶段只驱动 IO0，IO1~IO3 保持高阻，避免影响
    // Flash 的 MISO、WP# 和 HOLD# 信号。
    assign sys_qspi_dq[0] = dq_oe_reg ? dq_out_reg[0] : 1'bz;
    assign sys_qspi_dq[1] = 1'bz;
    assign sys_qspi_dq[3:2] = aux_oe_reg ? 2'b11 : 2'bzz;
    assign sys_qspi_csn = (state_current == ST_IDLE) ||
                          (state_current == ST_INIT_GAP) ||
                          (state_current == ST_INIT_WAIT);
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
            ST_IDLE: begin
                if (INIT_QUAD_ENABLE && !init_done) state_next = ST_INIT_WREN;
                else state_next = ST_CMD;
            end
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
            ST_INIT_WREN: begin
                if (sample_edge && (command_count == 4'd7))
                    state_next = ST_INIT_GAP;
            end
            ST_INIT_GAP: begin
                if (init_gap_count >= INIT_CS_HIGH_CYCLES - 1)
                    state_next = ST_INIT_WRSR;
            end
            ST_INIT_WRSR: begin
                if (sample_edge && (command_count == 4'd7))
                    state_next = ST_INIT_DATA;
            end
            ST_INIT_DATA: begin
                if (sample_edge && (init_data_count == 4'd7))
                    state_next = ST_INIT_WAIT;
            end
            ST_INIT_WAIT: begin
                if (init_wait_count >= QE_INIT_DELAY_CYCLES - 1)
                    state_next = ST_IDLE;
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
            init_done <= (INIT_QUAD_ENABLE == 0);
            init_gap_count <= {INIT_GAP_CNT_W{1'b0}};
            init_wait_count <= 32'd0;
            init_data_shift <= 8'd0;
            init_data_count <= 4'd0;
            aux_oe_reg <= 1'b0;
        end
        else begin
            rx_data_valid_reg <= 1'b0;
            if (state_current == ST_IDLE) begin
                div_count <= {DIV_CNT_W{1'b0}};
                sck_reg <= CPOL;
                if (INIT_QUAD_ENABLE && !init_done) begin
                    command_shift <= 8'h06;
                    command_count <= 4'd0;
                    init_gap_count <= {INIT_GAP_CNT_W{1'b0}};
                    dq_out_reg <= 4'h0;
                    dq_oe_reg <= 1'b1;
                    aux_oe_reg <= 1'b1;
                end else begin
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
                    aux_oe_reg <= 1'b1;
                end
            end
            else if (state_current == ST_INIT_GAP) begin
                div_count <= {DIV_CNT_W{1'b0}};
                sck_reg <= CPOL;
                command_shift <= 8'h31;
                command_count <= 4'd0;
                init_data_count <= 4'd0;
                if (init_gap_count < INIT_CS_HIGH_CYCLES)
                    init_gap_count <= init_gap_count + 1'b1;
                dq_out_reg <= 4'h0;
                dq_oe_reg <= 1'b1;
                aux_oe_reg <= 1'b1;
            end
            else if (state_current == ST_INIT_WAIT) begin
                div_count <= {DIV_CNT_W{1'b0}};
                sck_reg <= CPOL;
                dq_oe_reg <= 1'b0;
                aux_oe_reg <= 1'b0;
                if (init_wait_count < QE_INIT_DELAY_CYCLES)
                    init_wait_count <= init_wait_count + 1'b1;
                if (init_wait_count >= QE_INIT_DELAY_CYCLES - 1)
                    init_done <= 1'b1;
            end
            else if (transfer_tick) begin
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
                            if ((dummy_count + 1'b1) >= dummy_cycles_reg)
                                aux_oe_reg <= 1'b0;
                        end
                        ST_DATA: begin
                            aux_oe_reg <= 1'b0;
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
                        ST_INIT_WREN: begin
                            command_count <= command_count + 1'b1;
                        end
                        ST_INIT_WRSR: begin
                            command_count <= command_count + 1'b1;
                        end
                        ST_INIT_DATA: begin
                            init_data_count <= init_data_count + 1'b1;
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
                            aux_oe_reg <= 1'b1;
                            if (command_count != 0) begin
                                command_shift <= {command_shift[6:0], 1'b0};
                                dq_out_reg <= {3'b000, command_shift[6]};
                            end
                        end
                        ST_ADDR: begin
                            dq_oe_reg <= 1'b1;
                            aux_oe_reg <= 1'b1;
                            if (address_count == 0) dq_out_reg <= {3'b000, address_shift[23]};
                            else begin
                                address_shift <= {address_shift[22:0], 1'b0};
                                dq_out_reg <= {3'b000, address_shift[22]};
                            end
                        end
                        ST_DUMMY, ST_DATA: begin
                            dq_oe_reg <= 1'b0;
                            if (state_current == ST_DATA)
                                aux_oe_reg <= 1'b0;
                        end
                        ST_INIT_WREN, ST_INIT_WRSR: begin
                            dq_oe_reg <= 1'b1;
                            aux_oe_reg <= 1'b1;
                            if (command_count != 0) begin
                                command_shift <= {command_shift[6:0], 1'b0};
                                dq_out_reg <= {3'b000, command_shift[6]};
                            end
                        end
                        ST_INIT_DATA: begin
                            dq_oe_reg <= 1'b1;
                            aux_oe_reg <= 1'b1;
                            if (init_data_count == 0) begin
                                init_data_shift <= 8'h02;
                                dq_out_reg <= 4'h0;
                            end else begin
                                init_data_shift <= {init_data_shift[6:0], 1'b0};
                                dq_out_reg <= {3'b000, init_data_shift[6]};
                            end
                        end
                        default: begin
                        end
                    endcase
                end
            end
            else if (!sck_tick) begin
                div_count <= div_count + 1'b1;
            end
        end
    end

endmodule

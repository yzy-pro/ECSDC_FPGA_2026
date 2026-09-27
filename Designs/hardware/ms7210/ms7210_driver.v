module ms7210_driver #(
    parameter integer SYS_CLK_FREQ_HZ = 50_000_000,
    parameter integer STARTUP_WAIT_MS = 320
) (
    // 系统时钟与低有效异步复位
    input  wire        sys_clk,
    input  wire        sys_rstn,

    // MS7210 I2C 寄存器访问接口
    output wire [7:0]  device_id,
    output reg         iic_start,
    output reg         iic_dir,       // 1：写寄存器；0：读寄存器
    output reg  [15:0] iic_addr,
    output reg  [7:0]  iic_wr_data,
    input  wire [7:0]  iic_rd_data,
    input  wire        iic_done,
    input  wire        iic_busy,

    // MS7210 初始化完成标志
    output reg         ms7210_done
);
    assign device_id = 8'hB2;
    function [23:0] cmd_data;
        input [5:0] index;
        begin
            case (index)
                6'd0: cmd_data = {16'h1281, 8'h04};
                6'd1: cmd_data = {16'h0016, 8'h04};  //
                6'd2: cmd_data = {16'h0009, 8'h01};  //
                6'd3: cmd_data = {16'h0007, 8'h09};  //
                6'd4: cmd_data = {16'h0008, 8'hF0};  //
                6'd5: cmd_data = {16'h000A, 8'hF0};  //
                6'd6: cmd_data = {16'h0006, 8'h11};  //
                6'd7: cmd_data = {16'h0531, 8'h84};  //
                6'd8: cmd_data = {16'h0900, 8'h20};  //
                6'd9: cmd_data = {16'h0901, 8'h47};  //
                6'd10: cmd_data = {16'h0904, 8'h09};
                6'd11: cmd_data = {16'h0923, 8'h07};  //
                6'd12: cmd_data = {16'h0924, 8'h44};  //
                6'd13: cmd_data = {16'h0925, 8'h44};  //
                6'd14: cmd_data = {16'h090F, 8'h80};  //
                6'd15: cmd_data = {16'h091F, 8'h07};  //
                6'd16: cmd_data = {16'h0920, 8'h1E};  // 使能相关中断
                6'd17: cmd_data = {16'h0018, 8'h20};  //
                6'd18: cmd_data = {16'h05c0, 8'hFE};  //
                6'd19: cmd_data = {16'h000B, 8'h00};  // 开始输出参数配置
                6'd20: cmd_data = {16'h0507, 8'h06};
                6'd21: cmd_data = {16'h0906, 8'h04};  //
                6'd22: cmd_data = {16'h0920, 8'h5E};  //
                6'd23: cmd_data = {16'h0926, 8'hDD};  //
                6'd24: cmd_data = {16'h0927, 8'h0D};  //
                6'd25: cmd_data = {16'h0928, 8'h88};  //
                6'd26: cmd_data = {16'h0929, 8'h08};  //
                6'd27: cmd_data = {16'h0910, 8'h01};  //
                6'd28: cmd_data = {16'h000B, 8'h11};  //
                6'd29: cmd_data = {16'h050E, 8'h00};  //
                6'd30: cmd_data = {16'h050A, 8'h82};
                6'd31: cmd_data = {16'h0509, 8'h02};  //
                6'd32: cmd_data = {16'h050B, 8'h0D};  //
                6'd33: cmd_data = {16'h050D, 8'h06};  //
                6'd34: cmd_data = {16'h050D, 8'h11};  //
                6'd35: cmd_data = {16'h050D, 8'h58};  //
                6'd36: cmd_data = {16'h050D, 8'h00};  //
                6'd37: cmd_data = {16'h050D, 8'h00};  //
                6'd38: cmd_data = {16'h050D, 8'h00};  //
                6'd39: cmd_data = {16'h050D, 8'h00};  //
                6'd40: cmd_data = {16'h050D, 8'h00};
                6'd41: cmd_data = {16'h050D, 8'h00};  //
                6'd42: cmd_data = {16'h050D, 8'h00};  //
                6'd43: cmd_data = {16'h050D, 8'h00};  //
                6'd44: cmd_data = {16'h050D, 8'h00};  //
                6'd45: cmd_data = {16'h050D, 8'h00};  //
                6'd46: cmd_data = {16'h050D, 8'h00};  //
                6'd47: cmd_data = {16'h050E, 8'h40};  //
                6'd48: cmd_data = {16'h0507, 8'h00};  //
                default: cmd_data = 24'h000000;
            endcase
        end
    endfunction

    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_CHECK  = 3'd1;
    localparam [2:0] ST_INIT   = 3'd2;
    localparam [2:0] ST_WAIT   = 3'd3;
    localparam [2:0] ST_CONFIG = 3'd4;
    localparam [2:0] ST_DONE   = 3'd5;

    localparam integer INIT_LAST_INDEX   = 18;
    localparam integer CONFIG_LAST_INDEX = 48;
    localparam integer WAIT_CYCLES_RAW   = (SYS_CLK_FREQ_HZ / 1000) * STARTUP_WAIT_MS;
    localparam integer WAIT_CYCLES       = (WAIT_CYCLES_RAW < 1) ? 1 : WAIT_CYCLES_RAW;

    reg [2:0] state_current;
    reg [2:0] state_next;
    reg       check_step;
    reg [5:0] command_index;
    reg [31:0] wait_counter;

    // I2C 完成和忙信号可能来自较慢时钟域，先进行两级同步。
    reg iic_busy_meta;
    reg iic_busy_sync;
    reg iic_done_meta;
    reg iic_done_sync;
    reg iic_done_sync_d;
    reg transaction_active;

    wire transaction_complete;
    wire wait_finished;
    wire [23:0] selected_command;

    assign transaction_complete = transaction_active && !iic_start &&
                                  iic_done_sync && !iic_done_sync_d;
    assign wait_finished = (wait_counter >= WAIT_CYCLES - 1);
    assign selected_command = cmd_data(command_index);

    always @(posedge sys_clk or negedge sys_rstn) begin
        if (!sys_rstn) begin
            iic_busy_meta <= 1'b0;
            iic_busy_sync <= 1'b0;
            iic_done_meta <= 1'b0;
            iic_done_sync <= 1'b0;
            iic_done_sync_d <= 1'b0;
        end
        else begin
            iic_busy_meta <= iic_busy;
            iic_busy_sync <= iic_busy_meta;
            iic_done_meta <= iic_done;
            iic_done_sync <= iic_done_meta;
            iic_done_sync_d <= iic_done_sync;
        end
    end

    // 第一段：状态寄存器。
    always @(posedge sys_clk or negedge sys_rstn) begin
        if (!sys_rstn) state_current <= ST_IDLE;
        else state_current <= state_next;
    end

    // 第二段：次态组合逻辑。
    always @(*) begin
        state_next = state_current;

        case (state_current)
            ST_IDLE: state_next = ST_CHECK;

            ST_CHECK: begin
                if (transaction_complete && check_step && (iic_rd_data == 8'h5A))
                    state_next = ST_INIT;
            end

            ST_INIT: begin
                if (transaction_complete && (command_index == INIT_LAST_INDEX))
                    state_next = ST_WAIT;
            end

            ST_WAIT: begin
                if (wait_finished) state_next = ST_CONFIG;
            end

            ST_CONFIG: begin
                if (transaction_complete && (command_index == CONFIG_LAST_INDEX))
                    state_next = ST_DONE;
            end

            ST_DONE: state_next = ST_DONE;
            default: state_next = ST_IDLE;
        endcase
    end

    // 第三段：状态输出、计数器和 I2C 事务控制。
    always @(posedge sys_clk or negedge sys_rstn) begin
        if (!sys_rstn) begin
            check_step <= 1'b0;
            command_index <= 6'd0;
            wait_counter <= 32'd0;
            transaction_active <= 1'b0;
            iic_start <= 1'b0;
            iic_dir <= 1'b1;
            iic_addr <= 16'd0;
            iic_wr_data <= 8'd0;
            ms7210_done <= 1'b0;
        end
        else begin
            // 请求保持为高，直到下层 I2C 主机用 busy 确认已经接收。
            if (transaction_active && iic_start && iic_busy_sync)
                iic_start <= 1'b0;

            if (transaction_complete) begin
                transaction_active <= 1'b0;
                iic_start <= 1'b0;

                case (state_current)
                    ST_CHECK: begin
                        if (!check_step) begin
                            check_step <= 1'b1;
                        end
                        else if (iic_rd_data == 8'h5A) begin
                            check_step <= 1'b0;
                            command_index <= 6'd0;
                        end
                        else begin
                            // 设备标识不正确时重新执行写入、读回检测。
                            check_step <= 1'b0;
                        end
                    end

                    ST_INIT: begin
                        if (command_index != INIT_LAST_INDEX)
                            command_index <= command_index + 1'b1;
                        else
                            command_index <= 6'd19;
                    end

                    ST_CONFIG: begin
                        if (command_index != CONFIG_LAST_INDEX)
                            command_index <= command_index + 1'b1;
                    end

                    default: begin
                    end
                endcase
            end

            if (state_current == ST_WAIT) begin
                if (!wait_finished) wait_counter <= wait_counter + 1'b1;
            end
            else begin
                wait_counter <= 32'd0;
            end

            if (state_current == ST_DONE) ms7210_done <= 1'b1;

            // 当前没有事务时，根据状态准备并发起下一次寄存器访问。
            if (!transaction_active && !iic_busy_sync) begin
                case (state_current)
                    ST_CHECK: begin
                        transaction_active <= 1'b1;
                        iic_start <= 1'b1;
                        iic_dir <= !check_step;
                        iic_addr <= 16'h0003;
                        iic_wr_data <= 8'h5A;
                    end

                    ST_INIT,
                    ST_CONFIG: begin
                        transaction_active <= 1'b1;
                        iic_start <= 1'b1;
                        iic_dir <= 1'b1;
                        iic_addr <= selected_command[23:8];
                        iic_wr_data <= selected_command[7:0];
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

endmodule

// 参数化时钟变换模块。
// 对低于输入频率的目标时钟使用整数分频；目标频率不低于输入频率时旁路输入时钟。
// 输出频率按最接近的整数分频比实现，适用于本项目的 50 MHz 到 1 MHz 时钟变换。
module user_pll #(
    parameter integer INPUT_FREQ  = 50_000_000,
    parameter integer OUTPUT_FREQ = 1_000_000
) (
    input wire clk,
    output wire target_clk
);

    // 目标频率低于输入频率时，输出周期由两个半周期组成。
    localparam integer DIVIDE_RATIO =
        (OUTPUT_FREQ <= 0) ? 1 : ((INPUT_FREQ + OUTPUT_FREQ / 2) / OUTPUT_FREQ);
    localparam integer HALF_PERIOD =
        (DIVIDE_RATIO < 2) ? 1 : ((DIVIDE_RATIO + 1) / 2);
    localparam integer COUNT_WIDTH =
        (HALF_PERIOD <= 1) ? 1 : $clog2(HALF_PERIOD);

    generate
        if (OUTPUT_FREQ >= INPUT_FREQ) begin : gen_bypass
            // 整数分频无法升频，目标频率不低于输入频率时直接旁路。
            assign target_clk = clk;
        end
        else begin : gen_divider
            reg [COUNT_WIDTH-1:0] div_cnt = {COUNT_WIDTH{1'b0}};
            reg                   clk_reg = 1'b0;

            always @(posedge clk) begin
                if (div_cnt == HALF_PERIOD - 1) begin
                    div_cnt <= {COUNT_WIDTH{1'b0}};
                    clk_reg <= ~clk_reg;
                end
                else begin
                    div_cnt <= div_cnt + 1'b1;
                end
            end

            assign target_clk = clk_reg;
        end
    endgenerate

endmodule

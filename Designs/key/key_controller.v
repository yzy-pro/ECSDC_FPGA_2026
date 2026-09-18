module key_controller #(
    parameter integer KEY_SYSCLK_FREQ = 50_000_000,
    parameter integer KEY_WIDTH = 8
) (
    input wire clk,
    input wire io_rst_n,
    input wire [7:0] io_key_in,  //按键低电平有效
    output reg [7:0] key_data
);

    localparam integer KeyDetectFreq  = 20;
    localparam integer KeyDetectCount = KEY_SYSCLK_FREQ / KeyDetectFreq / 2;


    reg clk_detect;
    reg [21:0] cnt_detect;


    always @(posedge clk or negedge io_rst_n) begin
        if (!io_rst_n) begin
            cnt_detect <= 32'b0;
            clk_detect <= 1'b0;
        end
        else begin
            if (cnt_detect < KeyDetectCount - 1) begin
                cnt_detect <= cnt_detect + 1;
            end
            else begin
                cnt_detect <= 32'b0;
                clk_detect <= ~clk_detect;
            end
        end
    end


    always @(posedge clk_detect or negedge io_rst_n) begin
        if (!io_rst_n) begin
            key_data <= 8'b0;
        end
        else begin
            key_data <= ~io_key_in;  //按键低电平有效
        end
    end

endmodule

module probe(input clk_a,clk_b, output [3:0] result);
reg [3:0] counter=0;
reg [3:0] gray=0;
reg [3:0] sync1 /* synthesis PAP_ASYNC_REG=1 */;
reg [3:0] sync2 /* synthesis PAP_ASYNC_REG=1 */;
always @(posedge clk_a) begin
counter<=counter+1'b1;
gray<=((counter+1'b1)>>1)^(counter+1'b1);
end
always @(posedge clk_b) begin sync1<=gray; sync2<=sync1; end
assign result=sync2;
endmodule

module ms7200_driver (
    // 系统时钟与低有效异步复位
    input  wire        sys_clk,
    input  wire        sys_rstn,

    // MS7200 I2C 寄存器访问接口
    output wire [7:0]  device_id,
    output reg         iic_start,
    output reg         iic_dir,       // 1：写寄存器；0：读寄存器
    output reg  [15:0] iic_addr,
    output reg  [7:0]  iic_wr_data,
    input  wire [7:0]  iic_rd_data,
    input  wire        iic_done,
    input  wire        iic_busy,

    // 完成首次输入状态配置后置位，并保持为高
    output reg         ms7200_done
);
    assign device_id = 8'h56;
    function [23:0] cmd_data;
        input [9:0] index;
        begin
            case (index)
                9'd0: cmd_data = {16'h0204, 8'h02};
                9'd1: cmd_data = {16'h0205, 8'h40};
                9'd2: cmd_data = {16'h0004, 8'h01};
                9'd3: cmd_data = {16'h0009, 8'h26};
                9'd4: cmd_data = {16'h102E, 8'h01};
                9'd5: cmd_data = {16'h1025, 8'hB0};
                9'd6: cmd_data = {16'h102D, 8'h83};
                9'd7: cmd_data = {16'h1000, 8'h20};
                9'd8: cmd_data = {16'h100F, 8'h04};
                9'd9: cmd_data = {16'h0003, 8'hC3};
                9'd10: cmd_data = {16'h103B, 8'h02};
                9'd11: cmd_data = {16'h00E1, 8'h00};
                9'd12: cmd_data = {16'h00A8, 8'h08};
                9'd13: cmd_data = {16'h000A, 8'h00};
                9'd14: cmd_data = {16'h0016, 8'h02};
                9'd15: cmd_data = {16'h00E2, 8'h01};
                9'd16: cmd_data = {16'h00C2, 8'h14};
                9'd17: cmd_data = {16'h102D, 8'hC7};
                9'd18: cmd_data = {16'h1005, 8'h04};
                9'd19: cmd_data = {16'h1003, 8'h14};
                9'd20: cmd_data = {16'h1004, 8'h01};
                9'd21: cmd_data = {16'h1000, 8'h60};
                9'd22: cmd_data = {16'h1020, 8'h13};
                9'd23: cmd_data = {16'h1021, 8'h04};
                9'd24: cmd_data = {16'h1022, 8'h04};
                9'd25: cmd_data = {16'h1023, 8'h0C};
                9'd26: cmd_data = {16'h102B, 8'h33};
                9'd27: cmd_data = {16'h102C, 8'h33};
                9'd28: cmd_data = {16'h00F0, 8'h10};
                9'd29: cmd_data = {16'h000C, 8'h80};
                9'd30: cmd_data = {16'h0D00, 8'h00};
                9'd31: cmd_data = {16'h0D01, 8'hFF};
                9'd32: cmd_data = {16'h0D02, 8'hFF};
                9'd33: cmd_data = {16'h0D03, 8'hFF};
                9'd34: cmd_data = {16'h0D04, 8'hFF};
                9'd35: cmd_data = {16'h0D05, 8'hFF};
                9'd36: cmd_data = {16'h0D06, 8'hFF};
                9'd37: cmd_data = {16'h0D07, 8'h00};
                9'd38: cmd_data = {16'h0D00, 8'h00};
                9'd39: cmd_data = {16'h0D01, 8'hFF};
                9'd40: cmd_data = {16'h0D02, 8'hFF};
                9'd41: cmd_data = {16'h0D03, 8'hFF};
                9'd42: cmd_data = {16'h0D04, 8'hFF};
                9'd43: cmd_data = {16'h0D05, 8'hFF};
                9'd44: cmd_data = {16'h0D06, 8'hFF};
                9'd45: cmd_data = {16'h0D07, 8'h00};
                9'd46: cmd_data = {16'h0D08, 8'h4C};
                9'd47: cmd_data = {16'h0D09, 8'h2D};
                9'd48: cmd_data = {16'h0D0A, 8'hFF};
                9'd49: cmd_data = {16'h0D0B, 8'h0D};
                9'd50: cmd_data = {16'h0D0C, 8'h58};
                9'd51: cmd_data = {16'h0D0D, 8'h4D};
                9'd52: cmd_data = {16'h0D0E, 8'h51};
                9'd53: cmd_data = {16'h0D0F, 8'h30};
                9'd54: cmd_data = {16'h0D10, 8'h1C};
                9'd55: cmd_data = {16'h0D11, 8'h1C};
                9'd56: cmd_data = {16'h0D12, 8'h01};
                9'd57: cmd_data = {16'h0D13, 8'h03};
                9'd58: cmd_data = {16'h0D14, 8'h80};
                9'd59: cmd_data = {16'h0D15, 8'h3D};
                9'd60: cmd_data = {16'h0D16, 8'h23};
                9'd61: cmd_data = {16'h0D17, 8'h78};
                9'd62: cmd_data = {16'h0D18, 8'h2A};
                9'd63: cmd_data = {16'h0D19, 8'h5F};
                9'd64: cmd_data = {16'h0D1A, 8'hB1};
                9'd65: cmd_data = {16'h0D1B, 8'hA2};
                9'd66: cmd_data = {16'h0D1C, 8'h57};
                9'd67: cmd_data = {16'h0D1D, 8'h4F};
                9'd68: cmd_data = {16'h0D1E, 8'hA2};
                9'd69: cmd_data = {16'h0D1F, 8'h28};
                9'd70: cmd_data = {16'h0D20, 8'h0F};
                9'd71: cmd_data = {16'h0D21, 8'h50};
                9'd72: cmd_data = {16'h0D22, 8'h54};
                9'd73: cmd_data = {16'h0D23, 8'hBF};
                9'd74: cmd_data = {16'h0D24, 8'hEF};
                9'd75: cmd_data = {16'h0D25, 8'h80};
                9'd76: cmd_data = {16'h0D26, 8'h71};
                9'd77: cmd_data = {16'h0D27, 8'h4F};
                9'd78: cmd_data = {16'h0D28, 8'h81};
                9'd79: cmd_data = {16'h0D29, 8'h00};
                9'd80: cmd_data = {16'h0D2A, 8'h81};
                9'd81: cmd_data = {16'h0D2B, 8'hC0};
                9'd82: cmd_data = {16'h0D2C, 8'h81};
                9'd83: cmd_data = {16'h0D2D, 8'h80};
                9'd84: cmd_data = {16'h0D2E, 8'h95};
                9'd85: cmd_data = {16'h0D2F, 8'h00};
                9'd86: cmd_data = {16'h0D30, 8'hA9};
                9'd87: cmd_data = {16'h0D31, 8'hC0};
                9'd88: cmd_data = {16'h0D32, 8'hB3};
                9'd89: cmd_data = {16'h0D33, 8'h00};
                9'd90: cmd_data = {16'h0D34, 8'h01};
                9'd91: cmd_data = {16'h0D35, 8'h01};
                9'd92: cmd_data = {16'h0D36, 8'h04};
                9'd93: cmd_data = {16'h0D37, 8'h74};
                9'd94: cmd_data = {16'h0D38, 8'h00};
                9'd95: cmd_data = {16'h0D39, 8'h30};
                9'd96: cmd_data = {16'h0D3A, 8'hF2};
                9'd97: cmd_data = {16'h0D3B, 8'h70};
                9'd98: cmd_data = {16'h0D3C, 8'h5A};
                9'd99: cmd_data = {16'h0D3D, 8'h80};
                9'd100: cmd_data = {16'h0D3E, 8'hB0};
                9'd101: cmd_data = {16'h0D3F, 8'h58};
                9'd102: cmd_data = {16'h0D40, 8'h8A};
                9'd103: cmd_data = {16'h0D41, 8'h00};
                9'd104: cmd_data = {16'h0D42, 8'h60};
                9'd105: cmd_data = {16'h0D43, 8'h59};
                9'd106: cmd_data = {16'h0D44, 8'h21};
                9'd107: cmd_data = {16'h0D45, 8'h00};
                9'd108: cmd_data = {16'h0D46, 8'h00};
                9'd109: cmd_data = {16'h0D47, 8'h1E};
                9'd110: cmd_data = {16'h0D48, 8'h00};
                9'd111: cmd_data = {16'h0D49, 8'h00};
                9'd112: cmd_data = {16'h0D4A, 8'h00};
                9'd113: cmd_data = {16'h0D4B, 8'hFD};
                9'd114: cmd_data = {16'h0D4C, 8'h00};
                9'd115: cmd_data = {16'h0D4D, 8'h18};
                9'd116: cmd_data = {16'h0D4E, 8'h4B};
                9'd117: cmd_data = {16'h0D4F, 8'h1E};
                9'd118: cmd_data = {16'h0D50, 8'h5A};
                9'd119: cmd_data = {16'h0D51, 8'h1E};
                9'd120: cmd_data = {16'h0D52, 8'h00};
                9'd121: cmd_data = {16'h0D53, 8'h0A};
                9'd122: cmd_data = {16'h0D54, 8'h20};
                9'd123: cmd_data = {16'h0D55, 8'h20};
                9'd124: cmd_data = {16'h0D56, 8'h20};
                9'd125: cmd_data = {16'h0D57, 8'h20};
                9'd126: cmd_data = {16'h0D58, 8'h20};
                9'd127: cmd_data = {16'h0D59, 8'h20};
                9'd128: cmd_data = {16'h0D5A, 8'h00};
                9'd129: cmd_data = {16'h0D5B, 8'h00};
                9'd130: cmd_data = {16'h0D5C, 8'h00};
                9'd131: cmd_data = {16'h0D5D, 8'hFC};
                9'd132: cmd_data = {16'h0D5E, 8'h00};
                9'd133: cmd_data = {16'h0D5F, 8'h55};
                9'd134: cmd_data = {16'h0D60, 8'h32};
                9'd135: cmd_data = {16'h0D61, 8'h38};
                9'd136: cmd_data = {16'h0D62, 8'h48};
                9'd137: cmd_data = {16'h0D63, 8'h37};
                9'd138: cmd_data = {16'h0D64, 8'h35};
                9'd139: cmd_data = {16'h0D65, 8'h78};
                9'd140: cmd_data = {16'h0D66, 8'h0A};
                9'd141: cmd_data = {16'h0D67, 8'h20};
                9'd142: cmd_data = {16'h0D68, 8'h20};
                9'd143: cmd_data = {16'h0D69, 8'h20};
                9'd144: cmd_data = {16'h0D6A, 8'h20};
                9'd145: cmd_data = {16'h0D6B, 8'h20};
                9'd146: cmd_data = {16'h0D6C, 8'h00};
                9'd147: cmd_data = {16'h0D6D, 8'h00};
                9'd148: cmd_data = {16'h0D6E, 8'h00};
                9'd149: cmd_data = {16'h0D6F, 8'hFF};
                9'd150: cmd_data = {16'h0D70, 8'h00};
                9'd151: cmd_data = {16'h0D71, 8'h48};
                9'd152: cmd_data = {16'h0D72, 8'h54};
                9'd153: cmd_data = {16'h0D73, 8'h50};
                9'd154: cmd_data = {16'h0D74, 8'h4B};
                9'd155: cmd_data = {16'h0D75, 8'h37};
                9'd156: cmd_data = {16'h0D76, 8'h30};
                9'd157: cmd_data = {16'h0D77, 8'h30};
                9'd158: cmd_data = {16'h0D78, 8'h30};
                9'd159: cmd_data = {16'h0D79, 8'h35};
                9'd160: cmd_data = {16'h0D7A, 8'h31};
                9'd161: cmd_data = {16'h0D7B, 8'h0A};
                9'd162: cmd_data = {16'h0D7C, 8'h20};
                9'd163: cmd_data = {16'h0D7D, 8'h20};
                9'd164: cmd_data = {16'h0D7E, 8'h01};
                9'd165: cmd_data = {16'h0D7F, 8'hF7};
                9'd166: cmd_data = {16'h0D80, 8'h02};
                9'd167: cmd_data = {16'h0D81, 8'h03};
                9'd168: cmd_data = {16'h0D82, 8'h26};
                9'd169: cmd_data = {16'h0D83, 8'hF0};
                9'd170: cmd_data = {16'h0D84, 8'h4B};
                9'd171: cmd_data = {16'h0D85, 8'h5F};
                9'd172: cmd_data = {16'h0D86, 8'h10};
                9'd173: cmd_data = {16'h0D87, 8'h04};
                9'd174: cmd_data = {16'h0D88, 8'h1F};
                9'd175: cmd_data = {16'h0D89, 8'h13};
                9'd176: cmd_data = {16'h0D8A, 8'h03};
                9'd177: cmd_data = {16'h0D8B, 8'h12};
                9'd178: cmd_data = {16'h0D8C, 8'h20};
                9'd179: cmd_data = {16'h0D8D, 8'h22};
                9'd180: cmd_data = {16'h0D8E, 8'h5E};
                9'd181: cmd_data = {16'h0D8F, 8'h5D};
                9'd182: cmd_data = {16'h0D90, 8'h23};
                9'd183: cmd_data = {16'h0D91, 8'h09};
                9'd184: cmd_data = {16'h0D92, 8'h07};
                9'd185: cmd_data = {16'h0D93, 8'h07};
                9'd186: cmd_data = {16'h0D94, 8'h83};
                9'd187: cmd_data = {16'h0D95, 8'h01};
                9'd188: cmd_data = {16'h0D96, 8'h00};
                9'd189: cmd_data = {16'h0D97, 8'h00};
                9'd190: cmd_data = {16'h0D98, 8'h6D};
                9'd191: cmd_data = {16'h0D99, 8'h03};
                9'd192: cmd_data = {16'h0D9A, 8'h0C};
                9'd193: cmd_data = {16'h0D9B, 8'h00};
                9'd194: cmd_data = {16'h0D9C, 8'h10};
                9'd195: cmd_data = {16'h0D9D, 8'h00};
                9'd196: cmd_data = {16'h0D9E, 8'h80};
                9'd197: cmd_data = {16'h0D9F, 8'h3C};
                9'd198: cmd_data = {16'h0DA0, 8'h20};
                9'd199: cmd_data = {16'h0DA1, 8'h10};
                9'd200: cmd_data = {16'h0DA2, 8'h60};
                9'd201: cmd_data = {16'h0DA3, 8'h01};
                9'd202: cmd_data = {16'h0DA4, 8'h02};
                9'd203: cmd_data = {16'h0DA5, 8'h03};
                9'd204: cmd_data = {16'h0DA6, 8'h02};
                9'd205: cmd_data = {16'h0DA7, 8'h3A};
                9'd206: cmd_data = {16'h0DA8, 8'h80};
                9'd207: cmd_data = {16'h0DA9, 8'h18};
                9'd208: cmd_data = {16'h0DAA, 8'h71};
                9'd209: cmd_data = {16'h0DAB, 8'h38};
                9'd210: cmd_data = {16'h0DAC, 8'h2D};
                9'd211: cmd_data = {16'h0DAD, 8'h40};
                9'd212: cmd_data = {16'h0DAE, 8'h58};
                9'd213: cmd_data = {16'h0DAF, 8'h2C};
                9'd214: cmd_data = {16'h0DB0, 8'h45};
                9'd215: cmd_data = {16'h0DB1, 8'h00};
                9'd216: cmd_data = {16'h0DB2, 8'h60};
                9'd217: cmd_data = {16'h0DB3, 8'h59};
                9'd218: cmd_data = {16'h0DB4, 8'h21};
                9'd219: cmd_data = {16'h0DB5, 8'h00};
                9'd220: cmd_data = {16'h0DB6, 8'h00};
                9'd221: cmd_data = {16'h0DB7, 8'h1E};
                9'd222: cmd_data = {16'h0DB8, 8'h02};
                9'd223: cmd_data = {16'h0DB9, 8'h3A};
                9'd224: cmd_data = {16'h0DBA, 8'h80};
                9'd225: cmd_data = {16'h0DBB, 8'hD0};
                9'd226: cmd_data = {16'h0DBC, 8'h72};
                9'd227: cmd_data = {16'h0DBD, 8'h38};
                9'd228: cmd_data = {16'h0DBE, 8'h2D};
                9'd229: cmd_data = {16'h0DBF, 8'h40};
                9'd230: cmd_data = {16'h0DC0, 8'h10};
                9'd231: cmd_data = {16'h0DC1, 8'h2C};
                9'd232: cmd_data = {16'h0DC2, 8'h45};
                9'd233: cmd_data = {16'h0DC3, 8'h80};
                9'd234: cmd_data = {16'h0DC4, 8'h60};
                9'd235: cmd_data = {16'h0DC5, 8'h59};
                9'd236: cmd_data = {16'h0DC6, 8'h21};
                9'd237: cmd_data = {16'h0DC7, 8'h00};
                9'd238: cmd_data = {16'h0DC8, 8'h00};
                9'd239: cmd_data = {16'h0DC9, 8'h1E};
                9'd240: cmd_data = {16'h0DCA, 8'h01};
                9'd241: cmd_data = {16'h0DCB, 8'h1D};
                9'd242: cmd_data = {16'h0DCC, 8'h00};
                9'd243: cmd_data = {16'h0DCD, 8'h72};
                9'd244: cmd_data = {16'h0DCE, 8'h51};
                9'd245: cmd_data = {16'h0DCF, 8'hD0};
                9'd246: cmd_data = {16'h0DD0, 8'h1E};
                9'd247: cmd_data = {16'h0DD1, 8'h20};
                9'd248: cmd_data = {16'h0DD2, 8'h6E};
                9'd249: cmd_data = {16'h0DD3, 8'h28};
                9'd250: cmd_data = {16'h0DD4, 8'h55};
                9'd251: cmd_data = {16'h0DD5, 8'h00};
                9'd252: cmd_data = {16'h0DD6, 8'h60};
                9'd253: cmd_data = {16'h0DD7, 8'h59};
                9'd254: cmd_data = {16'h0DD8, 8'h21};
                9'd255: cmd_data = {16'h0DD9, 8'h00};
                9'd256: cmd_data = {16'h0DDA, 8'h00};
                9'd257: cmd_data = {16'h0DDB, 8'h1E};
                9'd258: cmd_data = {16'h0DDC, 8'h56};
                9'd259: cmd_data = {16'h0DDD, 8'h5E};
                9'd260: cmd_data = {16'h0DDE, 8'h00};
                9'd261: cmd_data = {16'h0DDF, 8'hA0};
                9'd262: cmd_data = {16'h0DE0, 8'hA0};
                9'd263: cmd_data = {16'h0DE1, 8'hA0};
                9'd264: cmd_data = {16'h0DE2, 8'h29};
                9'd265: cmd_data = {16'h0DE3, 8'h50};
                9'd266: cmd_data = {16'h0DE4, 8'h30};
                9'd267: cmd_data = {16'h0DE5, 8'h20};
                9'd268: cmd_data = {16'h0DE6, 8'h35};
                9'd269: cmd_data = {16'h0DE7, 8'h00};
                9'd270: cmd_data = {16'h0DE8, 8'h60};
                9'd271: cmd_data = {16'h0DE9, 8'h59};
                9'd272: cmd_data = {16'h0DEA, 8'h21};
                9'd273: cmd_data = {16'h0DEB, 8'h00};
                9'd274: cmd_data = {16'h0DEC, 8'h00};
                9'd275: cmd_data = {16'h0DED, 8'h1A};
                9'd276: cmd_data = {16'h0DEE, 8'h00};
                9'd277: cmd_data = {16'h0DEF, 8'h00};
                9'd278: cmd_data = {16'h0DF0, 8'h00};
                9'd279: cmd_data = {16'h0DF1, 8'h00};
                9'd280: cmd_data = {16'h0DF2, 8'h00};
                9'd281: cmd_data = {16'h0DF3, 8'h00};
                9'd282: cmd_data = {16'h0DF4, 8'h00};
                9'd283: cmd_data = {16'h0DF5, 8'h00};
                9'd284: cmd_data = {16'h0DF6, 8'h00};
                9'd285: cmd_data = {16'h0DF7, 8'h00};
                9'd286: cmd_data = {16'h0DF8, 8'h00};
                9'd287: cmd_data = {16'h0DF9, 8'h00};
                9'd288: cmd_data = {16'h0DFA, 8'h00};
                9'd289: cmd_data = {16'h0DFB, 8'h00};
                9'd290: cmd_data = {16'h0DFC, 8'h00};
                9'd291: cmd_data = {16'h0DFD, 8'h00};
                9'd292: cmd_data = {16'h0DFE, 8'h00};
                9'd293: cmd_data = {16'h0DFF, 8'hA8};
                9'd294: cmd_data = {16'h000C, 8'h00};
                9'd295: cmd_data = {16'h000A, 8'h04};
                9'd296: cmd_data = {16'h2000, 8'h0F};
                9'd297: cmd_data = {16'h2001, 8'h00};
                9'd298: cmd_data = {16'h2002, 8'h00};
                9'd299: cmd_data = {16'h2003, 8'h01};

                9'd300: cmd_data = {16'h209C, 8'h00};
                9'd301: cmd_data = {16'h209D, 8'h00};
                9'd302: cmd_data = {16'h209E, 8'h00};
                9'd303: cmd_data = {16'h209F, 8'h00};

                9'd304: cmd_data = {16'h1010, 8'h01};
                9'd305: cmd_data = {16'h1024, 8'h00};
                9'd306: cmd_data = {16'h0200, 8'h00};
                9'd307: cmd_data = {16'h1024, 8'h70};
                9'd308: cmd_data = {16'h0200, 8'h07};
                9'd309: cmd_data = {16'h0215, 8'h01};
                9'd310: cmd_data = {16'h0215, 8'h00};
                default: cmd_data = 24'h000000;
            endcase
        end
    endfunction

    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_CHECK   = 3'd1;
    localparam [2:0] ST_INIT    = 3'd2;
    localparam [2:0] ST_MONITOR = 3'd3;
    localparam [2:0] ST_CONFIG  = 3'd4;

    localparam integer INIT_LAST_INDEX   = 299;
    localparam integer CONFIG_BASE_INDEX = 304;
    localparam integer CONFIG_LAST_STEP  = 6;

    reg [2:0] state_current;
    reg [2:0] state_next;
    reg       check_step;
    reg [8:0] command_index;
    reg [1:0] monitor_index;
    reg [2:0] config_step;
    reg [31:0] frequency_sample;
    reg [31:0] frequency_previous;

    // I2C 完成和忙信号可能来自较慢时钟域，先进行两级同步。
    reg iic_busy_meta;
    reg iic_busy_sync;
    reg iic_done_meta;
    reg iic_done_sync;
    reg iic_done_sync_d;
    reg transaction_active;

    wire transaction_complete;
    wire [31:0] completed_frequency;
    wire frequency_event;
    wire [23:0] selected_command;

    assign transaction_complete = transaction_active && !iic_start &&
                                  iic_done_sync && !iic_done_sync_d;
    assign completed_frequency = {iic_rd_data, frequency_sample[23:0]};
    assign frequency_event = (frequency_previous[17:16] == 2'b00) &&
                             (completed_frequency[17:16] == 2'b10);
    assign selected_command = (state_current == ST_CONFIG) ?
                              cmd_data(CONFIG_BASE_INDEX + config_step) :
                              cmd_data(command_index);

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
                    state_next = ST_MONITOR;
            end

            ST_MONITOR: begin
                if (transaction_complete && (monitor_index == 2'd3) && frequency_event)
                    state_next = ST_CONFIG;
            end

            ST_CONFIG: begin
                if (transaction_complete && (config_step == CONFIG_LAST_STEP))
                    state_next = ST_MONITOR;
            end

            default: state_next = ST_IDLE;
        endcase
    end

    // 第三段：状态输出、计数器、状态采样和 I2C 事务控制。
    always @(posedge sys_clk or negedge sys_rstn) begin
        if (!sys_rstn) begin
            check_step <= 1'b0;
            command_index <= 9'd0;
            monitor_index <= 2'd0;
            config_step <= 3'd0;
            frequency_sample <= 32'd0;
            frequency_previous <= 32'd0;
            transaction_active <= 1'b0;
            iic_start <= 1'b0;
            iic_dir <= 1'b1;
            iic_addr <= 16'd0;
            iic_wr_data <= 8'd0;
            ms7200_done <= 1'b0;
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
                            command_index <= 9'd0;
                        end
                        else begin
                            // 设备标识不正确时重新执行写入、读回检测。
                            check_step <= 1'b0;
                        end
                    end

                    ST_INIT: begin
                        if (command_index != INIT_LAST_INDEX)
                            command_index <= command_index + 1'b1;
                        else begin
                            command_index <= 9'd0;
                            monitor_index <= 2'd0;
                        end
                    end

                    ST_MONITOR: begin
                        case (monitor_index)
                            2'd0: frequency_sample[7:0]   <= iic_rd_data;
                            2'd1: frequency_sample[15:8]  <= iic_rd_data;
                            2'd2: frequency_sample[23:16] <= iic_rd_data;
                            2'd3: begin
                                frequency_sample[31:24] <= iic_rd_data;
                                frequency_previous <= completed_frequency;
                            end
                            default: begin
                            end
                        endcase

                        if (monitor_index == 2'd3) begin
                            monitor_index <= 2'd0;
                            if (frequency_event) config_step <= 3'd0;
                        end
                        else begin
                            monitor_index <= monitor_index + 1'b1;
                        end
                    end

                    ST_CONFIG: begin
                        if (config_step == CONFIG_LAST_STEP) begin
                            config_step <= 3'd0;
                            monitor_index <= 2'd0;
                            ms7200_done <= 1'b1;
                        end
                        else begin
                            config_step <= config_step + 1'b1;
                        end
                    end

                    default: begin
                    end
                endcase
            end

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

                    ST_INIT: begin
                        transaction_active <= 1'b1;
                        iic_start <= 1'b1;
                        iic_dir <= 1'b1;
                        iic_addr <= selected_command[23:8];
                        iic_wr_data <= selected_command[7:0];
                    end

                    ST_MONITOR: begin
                        transaction_active <= 1'b1;
                        iic_start <= 1'b1;
                        iic_dir <= 1'b0;
                        iic_addr <= 16'h209C + monitor_index;
                        iic_wr_data <= 8'h00;
                    end

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

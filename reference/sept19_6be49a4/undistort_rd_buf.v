`timescale 1ns / 1ps

module undistort_rd_buf #(
    parameter ADDR_WIDTH      = 28,
    parameter ADDR_OFFSET     = 32'h0000_0000,
    parameter H_NUM           = 1440,
    parameter V_NUM           = 1080,
    parameter DQ_WIDTH        = 32,
    parameter LEN_WIDTH       = 32,
    parameter PIX_WIDTH       = 16,
    parameter LINE_ADDR_WIDTH = 22,
    parameter FRAME_CNT_WIDTH = 8,
    // 0 = bilinear interpolation, 1 = nearest-neighbor.
    parameter INTERPOLATION_MODE = 1
) (
    input                         ddr_clk,
    input                         ddr_rstn,
    input                         vout_clk,
    input                         rd_fsync,
    input                         rd_active,
    input                         rd_en,
    output reg                    vout_de,
    output reg [PIX_WIDTH-1:0]    vout_data,
    input                         init_done,
    input  [1:0]                  completed_frame_bank,
    output [1:0]                  display_frame_bank,
    output reg                    ddr_rreq,
    output reg [ADDR_WIDTH-1:0]   ddr_raddr,
    output      [LEN_WIDTH-1:0]   ddr_rd_len,
    input                         ddr_rrdy,
    input                         ddr_rdone,
    input  [8*DQ_WIDTH-1:0]       ddr_rdata,
    input                         ddr_rdata_en
);

    localparam integer DDR_DATA_WIDTH = DQ_WIDTH * 8;
    localparam integer PIXELS_PER_BEAT = DDR_DATA_WIDTH / PIX_WIDTH;
    localparam integer LINE_WORDS = H_NUM / PIXELS_PER_BEAT;
    // This calibration maps all output pixels into source x=138..1339.
    // Cache complete DDR words x=128..1343, including interpolation margin.
    localparam integer CACHE_X_WORD_FIRST = 8;
    localparam integer CACHE_LINE_WORDS = 76;
    localparam integer CACHE_LINES = 66;
    localparam integer CACHE_LO_ROWS = 16;
    localparam integer CACHE_HI_ROWS = CACHE_LINES / 2 - CACHE_LO_ROWS;
    localparam integer CACHE_LO_WORDS = CACHE_LO_ROWS * CACHE_LINE_WORDS;
    localparam integer CACHE_HI_WORDS = CACHE_HI_ROWS * CACHE_LINE_WORDS;
    localparam integer CACHE_WORD_WIDTH = 272;

    // Q14 is much finer than the Q5 interpolation fraction, while keeping
    // every radial-distortion multiplication within one 18x18 APM block.
    localparam integer FRAC_BITS = 14;
    localparam signed [31:0] FX_Q14  = 32'sd13534816;
    localparam signed [31:0] FY_Q14  = 32'sd13549673;
    localparam signed [31:0] CX_Q14  = 32'sd12552715;
    localparam signed [31:0] CY_Q14  = 32'sd9197458;
    localparam signed [31:0] INV_FX_Q22 = 32'sd5077;
    localparam signed [31:0] INV_FY_Q22 = 32'sd5072;
    localparam signed [17:0] K1_Q14 = -18'sd4687;
    localparam signed [17:0] K2_Q14 = 18'sd1455;

    // Normalized coordinate accumulators use Q22 so their accumulated error
    // stays well below one Q5 interpolation step over a complete line/frame.
    localparam signed [23:0] XN_START_Q22 = -24'sd3884883;
    localparam signed [23:0] YN_START_Q22 = -24'sd2842003;
    localparam signed [23:0] XN_STEP_Q22  =  24'sd5077;
    localparam signed [23:0] YN_STEP_Q22  =  24'sd5072;

    // Four shallower memories fit the DRM18K 2048x9 mode. A single deep
    // memory would be forced into the wasteful 4096x4 mode on this device.
    reg [CACHE_WORD_WIDTH-1:0] cache_even_lo [0:CACHE_LO_WORDS-1];
    reg [CACHE_WORD_WIDTH-1:0] cache_even_hi [0:CACHE_HI_WORDS-1];
    reg [CACHE_WORD_WIDTH-1:0] cache_odd_lo  [0:CACHE_LO_WORDS-1];
    reg [CACHE_WORD_WIDTH-1:0] cache_odd_hi  [0:CACHE_HI_WORDS-1];

    reg [1:0]  req_state;
    reg [10:0] load_y;
    reg [6:0]  load_slot;
    reg [10:0] output_y;
    reg [10:0] target_max_y;
    reg [1:0]  frame_sel;
    reg [1:0]  pending_frame_sel;
    reg        frame_restart_pending;
    reg [1:0]  rd_active_sync, rd_fsync_sync;
    reg        ddr_rd_active_d, ddr_rd_fsync_d;
    reg [6:0]  req_slot;
    reg [10:0] req_line;
    reg [7:0]  beat_count;
    reg [255:0] previous_beat;
    reg         flush_pending;
    reg [255:0] flush_beat;
    reg [6:0]   flush_slot;
    reg [10:0]  flush_line;
    reg         flush_bank;
    reg         flush_half;
    reg         cache_wr_en;
    reg         cache_wr_bank;
    reg         cache_wr_half;
    reg [6:0]   cache_wr_slot;
    reg [10:0]  cache_wr_line;
    reg         cache_wr_line_done;
    reg [10:0]  cache_wr_addr;
    reg [CACHE_WORD_WIDTH-1:0] cache_wr_data;

    // This flag crosses to the pixel clock through a two-flop synchronizer.
    // It controls only the pixel value (black until ready), never data-enable;
    // dropping data-enable would shorten a 1440-pixel line and make the
    // following 3:4 scaler appear to move the picture horizontally.
    reg cache_prefill_ready;

    // Precomputed source-line range for every output line. Each entry is
    // {minimum source line, maximum source line including y+1 interpolation, slot}.
    function automatic [28:0] window_bounds;
        input [10:0] y;
        begin
            case (y)
                11'd0: window_bounds = {11'd63, 11'd125, 7'd63};
                11'd1: window_bounds = {11'd63, 11'd126, 7'd63};
                11'd2: window_bounds = {11'd64, 11'd127, 7'd64};
                11'd3: window_bounds = {11'd65, 11'd127, 7'd65};
                11'd4: window_bounds = {11'd65, 11'd128, 7'd65};
                11'd5: window_bounds = {11'd66, 11'd129, 7'd0};
                11'd6: window_bounds = {11'd67, 11'd130, 7'd1};
                11'd7: window_bounds = {11'd68, 11'd130, 7'd2};
                11'd8: window_bounds = {11'd68, 11'd131, 7'd2};
                11'd9: window_bounds = {11'd69, 11'd132, 7'd3};
                11'd10: window_bounds = {11'd70, 11'd133, 7'd4};
                11'd11: window_bounds = {11'd70, 11'd133, 7'd4};
                11'd12: window_bounds = {11'd71, 11'd134, 7'd5};
                11'd13: window_bounds = {11'd72, 11'd135, 7'd6};
                11'd14: window_bounds = {11'd72, 11'd136, 7'd6};
                11'd15: window_bounds = {11'd73, 11'd136, 7'd7};
                11'd16: window_bounds = {11'd74, 11'd137, 7'd8};
                11'd17: window_bounds = {11'd75, 11'd138, 7'd9};
                11'd18: window_bounds = {11'd75, 11'd138, 7'd9};
                11'd19: window_bounds = {11'd76, 11'd139, 7'd10};
                11'd20: window_bounds = {11'd77, 11'd140, 7'd11};
                11'd21: window_bounds = {11'd77, 11'd141, 7'd11};
                11'd22: window_bounds = {11'd78, 11'd141, 7'd12};
                11'd23: window_bounds = {11'd79, 11'd142, 7'd13};
                11'd24: window_bounds = {11'd80, 11'd143, 7'd14};
                11'd25: window_bounds = {11'd80, 11'd144, 7'd14};
                11'd26: window_bounds = {11'd81, 11'd144, 7'd15};
                11'd27: window_bounds = {11'd82, 11'd145, 7'd16};
                11'd28: window_bounds = {11'd83, 11'd146, 7'd17};
                11'd29: window_bounds = {11'd83, 11'd146, 7'd17};
                11'd30: window_bounds = {11'd84, 11'd147, 7'd18};
                11'd31: window_bounds = {11'd85, 11'd148, 7'd19};
                11'd32: window_bounds = {11'd85, 11'd149, 7'd19};
                11'd33: window_bounds = {11'd86, 11'd149, 7'd20};
                11'd34: window_bounds = {11'd87, 11'd150, 7'd21};
                11'd35: window_bounds = {11'd88, 11'd151, 7'd22};
                11'd36: window_bounds = {11'd88, 11'd152, 7'd22};
                11'd37: window_bounds = {11'd89, 11'd152, 7'd23};
                11'd38: window_bounds = {11'd90, 11'd153, 7'd24};
                11'd39: window_bounds = {11'd90, 11'd154, 7'd24};
                11'd40: window_bounds = {11'd91, 11'd154, 7'd25};
                11'd41: window_bounds = {11'd92, 11'd155, 7'd26};
                11'd42: window_bounds = {11'd93, 11'd156, 7'd27};
                11'd43: window_bounds = {11'd93, 11'd157, 7'd27};
                11'd44: window_bounds = {11'd94, 11'd157, 7'd28};
                11'd45: window_bounds = {11'd95, 11'd158, 7'd29};
                11'd46: window_bounds = {11'd96, 11'd159, 7'd30};
                11'd47: window_bounds = {11'd96, 11'd160, 7'd30};
                11'd48: window_bounds = {11'd97, 11'd160, 7'd31};
                11'd49: window_bounds = {11'd98, 11'd161, 7'd32};
                11'd50: window_bounds = {11'd99, 11'd162, 7'd33};
                11'd51: window_bounds = {11'd99, 11'd163, 7'd33};
                11'd52: window_bounds = {11'd100, 11'd163, 7'd34};
                11'd53: window_bounds = {11'd101, 11'd164, 7'd35};
                11'd54: window_bounds = {11'd101, 11'd165, 7'd35};
                11'd55: window_bounds = {11'd102, 11'd165, 7'd36};
                11'd56: window_bounds = {11'd103, 11'd166, 7'd37};
                11'd57: window_bounds = {11'd104, 11'd167, 7'd38};
                11'd58: window_bounds = {11'd104, 11'd168, 7'd38};
                11'd59: window_bounds = {11'd105, 11'd168, 7'd39};
                11'd60: window_bounds = {11'd106, 11'd169, 7'd40};
                11'd61: window_bounds = {11'd107, 11'd170, 7'd41};
                11'd62: window_bounds = {11'd107, 11'd171, 7'd41};
                11'd63: window_bounds = {11'd108, 11'd171, 7'd42};
                11'd64: window_bounds = {11'd109, 11'd172, 7'd43};
                11'd65: window_bounds = {11'd110, 11'd173, 7'd44};
                11'd66: window_bounds = {11'd110, 11'd174, 7'd44};
                11'd67: window_bounds = {11'd111, 11'd174, 7'd45};
                11'd68: window_bounds = {11'd112, 11'd175, 7'd46};
                11'd69: window_bounds = {11'd113, 11'd176, 7'd47};
                11'd70: window_bounds = {11'd113, 11'd176, 7'd47};
                11'd71: window_bounds = {11'd114, 11'd177, 7'd48};
                11'd72: window_bounds = {11'd115, 11'd178, 7'd49};
                11'd73: window_bounds = {11'd116, 11'd179, 7'd50};
                11'd74: window_bounds = {11'd116, 11'd179, 7'd50};
                11'd75: window_bounds = {11'd117, 11'd180, 7'd51};
                11'd76: window_bounds = {11'd118, 11'd181, 7'd52};
                11'd77: window_bounds = {11'd119, 11'd182, 7'd53};
                11'd78: window_bounds = {11'd119, 11'd182, 7'd53};
                11'd79: window_bounds = {11'd120, 11'd183, 7'd54};
                11'd80: window_bounds = {11'd121, 11'd184, 7'd55};
                11'd81: window_bounds = {11'd122, 11'd185, 7'd56};
                11'd82: window_bounds = {11'd123, 11'd185, 7'd57};
                11'd83: window_bounds = {11'd123, 11'd186, 7'd57};
                11'd84: window_bounds = {11'd124, 11'd187, 7'd58};
                11'd85: window_bounds = {11'd125, 11'd187, 7'd59};
                11'd86: window_bounds = {11'd126, 11'd188, 7'd60};
                11'd87: window_bounds = {11'd126, 11'd189, 7'd60};
                11'd88: window_bounds = {11'd127, 11'd190, 7'd61};
                11'd89: window_bounds = {11'd128, 11'd190, 7'd62};
                11'd90: window_bounds = {11'd129, 11'd191, 7'd63};
                11'd91: window_bounds = {11'd129, 11'd192, 7'd63};
                11'd92: window_bounds = {11'd130, 11'd193, 7'd64};
                11'd93: window_bounds = {11'd131, 11'd193, 7'd65};
                11'd94: window_bounds = {11'd132, 11'd194, 7'd0};
                11'd95: window_bounds = {11'd133, 11'd195, 7'd1};
                11'd96: window_bounds = {11'd133, 11'd196, 7'd1};
                11'd97: window_bounds = {11'd134, 11'd196, 7'd2};
                11'd98: window_bounds = {11'd135, 11'd197, 7'd3};
                11'd99: window_bounds = {11'd136, 11'd198, 7'd4};
                11'd100: window_bounds = {11'd136, 11'd199, 7'd4};
                11'd101: window_bounds = {11'd137, 11'd199, 7'd5};
                11'd102: window_bounds = {11'd138, 11'd200, 7'd6};
                11'd103: window_bounds = {11'd139, 11'd201, 7'd7};
                11'd104: window_bounds = {11'd140, 11'd201, 7'd8};
                11'd105: window_bounds = {11'd140, 11'd202, 7'd8};
                11'd106: window_bounds = {11'd141, 11'd203, 7'd9};
                11'd107: window_bounds = {11'd142, 11'd204, 7'd10};
                11'd108: window_bounds = {11'd143, 11'd204, 7'd11};
                11'd109: window_bounds = {11'd143, 11'd205, 7'd11};
                11'd110: window_bounds = {11'd144, 11'd206, 7'd12};
                11'd111: window_bounds = {11'd145, 11'd207, 7'd13};
                11'd112: window_bounds = {11'd146, 11'd207, 7'd14};
                11'd113: window_bounds = {11'd147, 11'd208, 7'd15};
                11'd114: window_bounds = {11'd147, 11'd209, 7'd15};
                11'd115: window_bounds = {11'd148, 11'd210, 7'd16};
                11'd116: window_bounds = {11'd149, 11'd210, 7'd17};
                11'd117: window_bounds = {11'd150, 11'd211, 7'd18};
                11'd118: window_bounds = {11'd150, 11'd212, 7'd18};
                11'd119: window_bounds = {11'd151, 11'd213, 7'd19};
                11'd120: window_bounds = {11'd152, 11'd213, 7'd20};
                11'd121: window_bounds = {11'd153, 11'd214, 7'd21};
                11'd122: window_bounds = {11'd154, 11'd215, 7'd22};
                11'd123: window_bounds = {11'd154, 11'd216, 7'd22};
                11'd124: window_bounds = {11'd155, 11'd216, 7'd23};
                11'd125: window_bounds = {11'd156, 11'd217, 7'd24};
                11'd126: window_bounds = {11'd157, 11'd218, 7'd25};
                11'd127: window_bounds = {11'd158, 11'd219, 7'd26};
                11'd128: window_bounds = {11'd158, 11'd219, 7'd26};
                11'd129: window_bounds = {11'd159, 11'd220, 7'd27};
                11'd130: window_bounds = {11'd160, 11'd221, 7'd28};
                11'd131: window_bounds = {11'd161, 11'd222, 7'd29};
                11'd132: window_bounds = {11'd162, 11'd222, 7'd30};
                11'd133: window_bounds = {11'd162, 11'd223, 7'd30};
                11'd134: window_bounds = {11'd163, 11'd224, 7'd31};
                11'd135: window_bounds = {11'd164, 11'd224, 7'd32};
                11'd136: window_bounds = {11'd165, 11'd225, 7'd33};
                11'd137: window_bounds = {11'd166, 11'd226, 7'd34};
                11'd138: window_bounds = {11'd166, 11'd227, 7'd34};
                11'd139: window_bounds = {11'd167, 11'd227, 7'd35};
                11'd140: window_bounds = {11'd168, 11'd228, 7'd36};
                11'd141: window_bounds = {11'd169, 11'd229, 7'd37};
                11'd142: window_bounds = {11'd170, 11'd230, 7'd38};
                11'd143: window_bounds = {11'd170, 11'd230, 7'd38};
                11'd144: window_bounds = {11'd171, 11'd231, 7'd39};
                11'd145: window_bounds = {11'd172, 11'd232, 7'd40};
                11'd146: window_bounds = {11'd173, 11'd233, 7'd41};
                11'd147: window_bounds = {11'd174, 11'd233, 7'd42};
                11'd148: window_bounds = {11'd175, 11'd234, 7'd43};
                11'd149: window_bounds = {11'd175, 11'd235, 7'd43};
                11'd150: window_bounds = {11'd176, 11'd236, 7'd44};
                11'd151: window_bounds = {11'd177, 11'd236, 7'd45};
                11'd152: window_bounds = {11'd178, 11'd237, 7'd46};
                11'd153: window_bounds = {11'd179, 11'd238, 7'd47};
                11'd154: window_bounds = {11'd179, 11'd239, 7'd47};
                11'd155: window_bounds = {11'd180, 11'd239, 7'd48};
                11'd156: window_bounds = {11'd181, 11'd240, 7'd49};
                11'd157: window_bounds = {11'd182, 11'd241, 7'd50};
                11'd158: window_bounds = {11'd183, 11'd242, 7'd51};
                11'd159: window_bounds = {11'd184, 11'd242, 7'd52};
                11'd160: window_bounds = {11'd184, 11'd243, 7'd52};
                11'd161: window_bounds = {11'd185, 11'd244, 7'd53};
                11'd162: window_bounds = {11'd186, 11'd245, 7'd54};
                11'd163: window_bounds = {11'd187, 11'd245, 7'd55};
                11'd164: window_bounds = {11'd188, 11'd246, 7'd56};
                11'd165: window_bounds = {11'd189, 11'd247, 7'd57};
                11'd166: window_bounds = {11'd189, 11'd248, 7'd57};
                11'd167: window_bounds = {11'd190, 11'd248, 7'd58};
                11'd168: window_bounds = {11'd191, 11'd249, 7'd59};
                11'd169: window_bounds = {11'd192, 11'd250, 7'd60};
                11'd170: window_bounds = {11'd193, 11'd251, 7'd61};
                11'd171: window_bounds = {11'd193, 11'd251, 7'd61};
                11'd172: window_bounds = {11'd194, 11'd252, 7'd62};
                11'd173: window_bounds = {11'd195, 11'd253, 7'd63};
                11'd174: window_bounds = {11'd196, 11'd254, 7'd64};
                11'd175: window_bounds = {11'd197, 11'd254, 7'd65};
                11'd176: window_bounds = {11'd198, 11'd255, 7'd0};
                11'd177: window_bounds = {11'd198, 11'd256, 7'd0};
                11'd178: window_bounds = {11'd199, 11'd257, 7'd1};
                11'd179: window_bounds = {11'd200, 11'd257, 7'd2};
                11'd180: window_bounds = {11'd201, 11'd258, 7'd3};
                11'd181: window_bounds = {11'd202, 11'd259, 7'd4};
                11'd182: window_bounds = {11'd203, 11'd260, 7'd5};
                11'd183: window_bounds = {11'd204, 11'd261, 7'd6};
                11'd184: window_bounds = {11'd204, 11'd261, 7'd6};
                11'd185: window_bounds = {11'd205, 11'd262, 7'd7};
                11'd186: window_bounds = {11'd206, 11'd263, 7'd8};
                11'd187: window_bounds = {11'd207, 11'd264, 7'd9};
                11'd188: window_bounds = {11'd208, 11'd264, 7'd10};
                11'd189: window_bounds = {11'd209, 11'd265, 7'd11};
                11'd190: window_bounds = {11'd209, 11'd266, 7'd11};
                11'd191: window_bounds = {11'd210, 11'd267, 7'd12};
                11'd192: window_bounds = {11'd211, 11'd267, 7'd13};
                11'd193: window_bounds = {11'd212, 11'd268, 7'd14};
                11'd194: window_bounds = {11'd213, 11'd269, 7'd15};
                11'd195: window_bounds = {11'd214, 11'd270, 7'd16};
                11'd196: window_bounds = {11'd215, 11'd270, 7'd17};
                11'd197: window_bounds = {11'd215, 11'd271, 7'd17};
                11'd198: window_bounds = {11'd216, 11'd272, 7'd18};
                11'd199: window_bounds = {11'd217, 11'd273, 7'd19};
                11'd200: window_bounds = {11'd218, 11'd273, 7'd20};
                11'd201: window_bounds = {11'd219, 11'd274, 7'd21};
                11'd202: window_bounds = {11'd220, 11'd275, 7'd22};
                11'd203: window_bounds = {11'd220, 11'd276, 7'd22};
                11'd204: window_bounds = {11'd221, 11'd276, 7'd23};
                11'd205: window_bounds = {11'd222, 11'd277, 7'd24};
                11'd206: window_bounds = {11'd223, 11'd278, 7'd25};
                11'd207: window_bounds = {11'd224, 11'd279, 7'd26};
                11'd208: window_bounds = {11'd225, 11'd279, 7'd27};
                11'd209: window_bounds = {11'd226, 11'd280, 7'd28};
                11'd210: window_bounds = {11'd227, 11'd281, 7'd29};
                11'd211: window_bounds = {11'd227, 11'd282, 7'd29};
                11'd212: window_bounds = {11'd228, 11'd282, 7'd30};
                11'd213: window_bounds = {11'd229, 11'd283, 7'd31};
                11'd214: window_bounds = {11'd230, 11'd284, 7'd32};
                11'd215: window_bounds = {11'd231, 11'd285, 7'd33};
                11'd216: window_bounds = {11'd232, 11'd286, 7'd34};
                11'd217: window_bounds = {11'd232, 11'd286, 7'd34};
                11'd218: window_bounds = {11'd233, 11'd287, 7'd35};
                11'd219: window_bounds = {11'd234, 11'd288, 7'd36};
                11'd220: window_bounds = {11'd235, 11'd289, 7'd37};
                11'd221: window_bounds = {11'd236, 11'd289, 7'd38};
                11'd222: window_bounds = {11'd237, 11'd290, 7'd39};
                11'd223: window_bounds = {11'd238, 11'd291, 7'd40};
                11'd224: window_bounds = {11'd239, 11'd292, 7'd41};
                11'd225: window_bounds = {11'd239, 11'd292, 7'd41};
                11'd226: window_bounds = {11'd240, 11'd293, 7'd42};
                11'd227: window_bounds = {11'd241, 11'd294, 7'd43};
                11'd228: window_bounds = {11'd242, 11'd295, 7'd44};
                11'd229: window_bounds = {11'd243, 11'd296, 7'd45};
                11'd230: window_bounds = {11'd244, 11'd296, 7'd46};
                11'd231: window_bounds = {11'd245, 11'd297, 7'd47};
                11'd232: window_bounds = {11'd246, 11'd298, 7'd48};
                11'd233: window_bounds = {11'd246, 11'd299, 7'd48};
                11'd234: window_bounds = {11'd247, 11'd299, 7'd49};
                11'd235: window_bounds = {11'd248, 11'd300, 7'd50};
                11'd236: window_bounds = {11'd249, 11'd301, 7'd51};
                11'd237: window_bounds = {11'd250, 11'd302, 7'd52};
                11'd238: window_bounds = {11'd251, 11'd302, 7'd53};
                11'd239: window_bounds = {11'd252, 11'd303, 7'd54};
                11'd240: window_bounds = {11'd253, 11'd304, 7'd55};
                11'd241: window_bounds = {11'd253, 11'd305, 7'd55};
                11'd242: window_bounds = {11'd254, 11'd306, 7'd56};
                11'd243: window_bounds = {11'd255, 11'd306, 7'd57};
                11'd244: window_bounds = {11'd256, 11'd307, 7'd58};
                11'd245: window_bounds = {11'd257, 11'd308, 7'd59};
                11'd246: window_bounds = {11'd258, 11'd309, 7'd60};
                11'd247: window_bounds = {11'd259, 11'd309, 7'd61};
                11'd248: window_bounds = {11'd260, 11'd310, 7'd62};
                11'd249: window_bounds = {11'd261, 11'd311, 7'd63};
                11'd250: window_bounds = {11'd261, 11'd312, 7'd63};
                11'd251: window_bounds = {11'd262, 11'd312, 7'd64};
                11'd252: window_bounds = {11'd263, 11'd313, 7'd65};
                11'd253: window_bounds = {11'd264, 11'd314, 7'd0};
                11'd254: window_bounds = {11'd265, 11'd315, 7'd1};
                11'd255: window_bounds = {11'd266, 11'd316, 7'd2};
                11'd256: window_bounds = {11'd267, 11'd316, 7'd3};
                11'd257: window_bounds = {11'd268, 11'd317, 7'd4};
                11'd258: window_bounds = {11'd269, 11'd318, 7'd5};
                11'd259: window_bounds = {11'd269, 11'd319, 7'd5};
                11'd260: window_bounds = {11'd270, 11'd319, 7'd6};
                11'd261: window_bounds = {11'd271, 11'd320, 7'd7};
                11'd262: window_bounds = {11'd272, 11'd321, 7'd8};
                11'd263: window_bounds = {11'd273, 11'd322, 7'd9};
                11'd264: window_bounds = {11'd274, 11'd323, 7'd10};
                11'd265: window_bounds = {11'd275, 11'd323, 7'd11};
                11'd266: window_bounds = {11'd276, 11'd324, 7'd12};
                11'd267: window_bounds = {11'd277, 11'd325, 7'd13};
                11'd268: window_bounds = {11'd278, 11'd326, 7'd14};
                11'd269: window_bounds = {11'd278, 11'd326, 7'd14};
                11'd270: window_bounds = {11'd279, 11'd327, 7'd15};
                11'd271: window_bounds = {11'd280, 11'd328, 7'd16};
                11'd272: window_bounds = {11'd281, 11'd329, 7'd17};
                11'd273: window_bounds = {11'd282, 11'd330, 7'd18};
                11'd274: window_bounds = {11'd283, 11'd330, 7'd19};
                11'd275: window_bounds = {11'd284, 11'd331, 7'd20};
                11'd276: window_bounds = {11'd285, 11'd332, 7'd21};
                11'd277: window_bounds = {11'd286, 11'd333, 7'd22};
                11'd278: window_bounds = {11'd287, 11'd333, 7'd23};
                11'd279: window_bounds = {11'd287, 11'd334, 7'd23};
                11'd280: window_bounds = {11'd288, 11'd335, 7'd24};
                11'd281: window_bounds = {11'd289, 11'd336, 7'd25};
                11'd282: window_bounds = {11'd290, 11'd337, 7'd26};
                11'd283: window_bounds = {11'd291, 11'd337, 7'd27};
                11'd284: window_bounds = {11'd292, 11'd338, 7'd28};
                11'd285: window_bounds = {11'd293, 11'd339, 7'd29};
                11'd286: window_bounds = {11'd294, 11'd340, 7'd30};
                11'd287: window_bounds = {11'd295, 11'd340, 7'd31};
                11'd288: window_bounds = {11'd296, 11'd341, 7'd32};
                11'd289: window_bounds = {11'd297, 11'd342, 7'd33};
                11'd290: window_bounds = {11'd297, 11'd343, 7'd33};
                11'd291: window_bounds = {11'd298, 11'd344, 7'd34};
                11'd292: window_bounds = {11'd299, 11'd344, 7'd35};
                11'd293: window_bounds = {11'd300, 11'd345, 7'd36};
                11'd294: window_bounds = {11'd301, 11'd346, 7'd37};
                11'd295: window_bounds = {11'd302, 11'd347, 7'd38};
                11'd296: window_bounds = {11'd303, 11'd347, 7'd39};
                11'd297: window_bounds = {11'd304, 11'd348, 7'd40};
                11'd298: window_bounds = {11'd305, 11'd349, 7'd41};
                11'd299: window_bounds = {11'd306, 11'd350, 7'd42};
                11'd300: window_bounds = {11'd307, 11'd351, 7'd43};
                11'd301: window_bounds = {11'd308, 11'd351, 7'd44};
                11'd302: window_bounds = {11'd308, 11'd352, 7'd44};
                11'd303: window_bounds = {11'd309, 11'd353, 7'd45};
                11'd304: window_bounds = {11'd310, 11'd354, 7'd46};
                11'd305: window_bounds = {11'd311, 11'd355, 7'd47};
                11'd306: window_bounds = {11'd312, 11'd355, 7'd48};
                11'd307: window_bounds = {11'd313, 11'd356, 7'd49};
                11'd308: window_bounds = {11'd314, 11'd357, 7'd50};
                11'd309: window_bounds = {11'd315, 11'd358, 7'd51};
                11'd310: window_bounds = {11'd316, 11'd358, 7'd52};
                11'd311: window_bounds = {11'd317, 11'd359, 7'd53};
                11'd312: window_bounds = {11'd318, 11'd360, 7'd54};
                11'd313: window_bounds = {11'd319, 11'd361, 7'd55};
                11'd314: window_bounds = {11'd320, 11'd362, 7'd56};
                11'd315: window_bounds = {11'd321, 11'd362, 7'd57};
                11'd316: window_bounds = {11'd321, 11'd363, 7'd57};
                11'd317: window_bounds = {11'd322, 11'd364, 7'd58};
                11'd318: window_bounds = {11'd323, 11'd365, 7'd59};
                11'd319: window_bounds = {11'd324, 11'd366, 7'd60};
                11'd320: window_bounds = {11'd325, 11'd366, 7'd61};
                11'd321: window_bounds = {11'd326, 11'd367, 7'd62};
                11'd322: window_bounds = {11'd327, 11'd368, 7'd63};
                11'd323: window_bounds = {11'd328, 11'd369, 7'd64};
                11'd324: window_bounds = {11'd329, 11'd370, 7'd65};
                11'd325: window_bounds = {11'd330, 11'd370, 7'd0};
                11'd326: window_bounds = {11'd331, 11'd371, 7'd1};
                11'd327: window_bounds = {11'd332, 11'd372, 7'd2};
                11'd328: window_bounds = {11'd333, 11'd373, 7'd3};
                11'd329: window_bounds = {11'd334, 11'd373, 7'd4};
                11'd330: window_bounds = {11'd334, 11'd374, 7'd4};
                11'd331: window_bounds = {11'd335, 11'd375, 7'd5};
                11'd332: window_bounds = {11'd336, 11'd376, 7'd6};
                11'd333: window_bounds = {11'd337, 11'd377, 7'd7};
                11'd334: window_bounds = {11'd338, 11'd377, 7'd8};
                11'd335: window_bounds = {11'd339, 11'd378, 7'd9};
                11'd336: window_bounds = {11'd340, 11'd379, 7'd10};
                11'd337: window_bounds = {11'd341, 11'd380, 7'd11};
                11'd338: window_bounds = {11'd342, 11'd381, 7'd12};
                11'd339: window_bounds = {11'd343, 11'd381, 7'd13};
                11'd340: window_bounds = {11'd344, 11'd382, 7'd14};
                11'd341: window_bounds = {11'd345, 11'd383, 7'd15};
                11'd342: window_bounds = {11'd346, 11'd384, 7'd16};
                11'd343: window_bounds = {11'd347, 11'd385, 7'd17};
                11'd344: window_bounds = {11'd348, 11'd385, 7'd18};
                11'd345: window_bounds = {11'd349, 11'd386, 7'd19};
                11'd346: window_bounds = {11'd350, 11'd387, 7'd20};
                11'd347: window_bounds = {11'd350, 11'd388, 7'd20};
                11'd348: window_bounds = {11'd351, 11'd389, 7'd21};
                11'd349: window_bounds = {11'd352, 11'd389, 7'd22};
                11'd350: window_bounds = {11'd353, 11'd390, 7'd23};
                11'd351: window_bounds = {11'd354, 11'd391, 7'd24};
                11'd352: window_bounds = {11'd355, 11'd392, 7'd25};
                11'd353: window_bounds = {11'd356, 11'd393, 7'd26};
                11'd354: window_bounds = {11'd357, 11'd393, 7'd27};
                11'd355: window_bounds = {11'd358, 11'd394, 7'd28};
                11'd356: window_bounds = {11'd359, 11'd395, 7'd29};
                11'd357: window_bounds = {11'd360, 11'd396, 7'd30};
                11'd358: window_bounds = {11'd361, 11'd396, 7'd31};
                11'd359: window_bounds = {11'd362, 11'd397, 7'd32};
                11'd360: window_bounds = {11'd363, 11'd398, 7'd33};
                11'd361: window_bounds = {11'd364, 11'd399, 7'd34};
                11'd362: window_bounds = {11'd365, 11'd400, 7'd35};
                11'd363: window_bounds = {11'd366, 11'd401, 7'd36};
                11'd364: window_bounds = {11'd367, 11'd401, 7'd37};
                11'd365: window_bounds = {11'd368, 11'd402, 7'd38};
                11'd366: window_bounds = {11'd368, 11'd403, 7'd38};
                11'd367: window_bounds = {11'd369, 11'd404, 7'd39};
                11'd368: window_bounds = {11'd370, 11'd404, 7'd40};
                11'd369: window_bounds = {11'd371, 11'd405, 7'd41};
                11'd370: window_bounds = {11'd372, 11'd406, 7'd42};
                11'd371: window_bounds = {11'd373, 11'd407, 7'd43};
                11'd372: window_bounds = {11'd374, 11'd408, 7'd44};
                11'd373: window_bounds = {11'd375, 11'd408, 7'd45};
                11'd374: window_bounds = {11'd376, 11'd409, 7'd46};
                11'd375: window_bounds = {11'd377, 11'd410, 7'd47};
                11'd376: window_bounds = {11'd378, 11'd411, 7'd48};
                11'd377: window_bounds = {11'd379, 11'd412, 7'd49};
                11'd378: window_bounds = {11'd380, 11'd412, 7'd50};
                11'd379: window_bounds = {11'd381, 11'd413, 7'd51};
                11'd380: window_bounds = {11'd382, 11'd414, 7'd52};
                11'd381: window_bounds = {11'd383, 11'd415, 7'd53};
                11'd382: window_bounds = {11'd384, 11'd416, 7'd54};
                11'd383: window_bounds = {11'd385, 11'd416, 7'd55};
                11'd384: window_bounds = {11'd386, 11'd417, 7'd56};
                11'd385: window_bounds = {11'd387, 11'd418, 7'd57};
                11'd386: window_bounds = {11'd388, 11'd419, 7'd58};
                11'd387: window_bounds = {11'd389, 11'd420, 7'd59};
                11'd388: window_bounds = {11'd390, 11'd420, 7'd60};
                11'd389: window_bounds = {11'd391, 11'd421, 7'd61};
                11'd390: window_bounds = {11'd392, 11'd422, 7'd62};
                11'd391: window_bounds = {11'd392, 11'd423, 7'd62};
                11'd392: window_bounds = {11'd393, 11'd424, 7'd63};
                11'd393: window_bounds = {11'd394, 11'd425, 7'd64};
                11'd394: window_bounds = {11'd395, 11'd425, 7'd65};
                11'd395: window_bounds = {11'd396, 11'd426, 7'd0};
                11'd396: window_bounds = {11'd397, 11'd427, 7'd1};
                11'd397: window_bounds = {11'd398, 11'd428, 7'd2};
                11'd398: window_bounds = {11'd399, 11'd429, 7'd3};
                11'd399: window_bounds = {11'd400, 11'd429, 7'd4};
                11'd400: window_bounds = {11'd401, 11'd430, 7'd5};
                11'd401: window_bounds = {11'd402, 11'd431, 7'd6};
                11'd402: window_bounds = {11'd403, 11'd432, 7'd7};
                11'd403: window_bounds = {11'd404, 11'd433, 7'd8};
                11'd404: window_bounds = {11'd405, 11'd433, 7'd9};
                11'd405: window_bounds = {11'd406, 11'd434, 7'd10};
                11'd406: window_bounds = {11'd407, 11'd435, 7'd11};
                11'd407: window_bounds = {11'd408, 11'd436, 7'd12};
                11'd408: window_bounds = {11'd409, 11'd437, 7'd13};
                11'd409: window_bounds = {11'd410, 11'd437, 7'd14};
                11'd410: window_bounds = {11'd411, 11'd438, 7'd15};
                11'd411: window_bounds = {11'd412, 11'd439, 7'd16};
                11'd412: window_bounds = {11'd413, 11'd440, 7'd17};
                11'd413: window_bounds = {11'd414, 11'd441, 7'd18};
                11'd414: window_bounds = {11'd415, 11'd441, 7'd19};
                11'd415: window_bounds = {11'd416, 11'd442, 7'd20};
                11'd416: window_bounds = {11'd417, 11'd443, 7'd21};
                11'd417: window_bounds = {11'd418, 11'd444, 7'd22};
                11'd418: window_bounds = {11'd419, 11'd445, 7'd23};
                11'd419: window_bounds = {11'd420, 11'd445, 7'd24};
                11'd420: window_bounds = {11'd421, 11'd446, 7'd25};
                11'd421: window_bounds = {11'd422, 11'd447, 7'd26};
                11'd422: window_bounds = {11'd423, 11'd448, 7'd27};
                11'd423: window_bounds = {11'd424, 11'd449, 7'd28};
                11'd424: window_bounds = {11'd424, 11'd450, 7'd28};
                11'd425: window_bounds = {11'd426, 11'd450, 7'd30};
                11'd426: window_bounds = {11'd427, 11'd451, 7'd31};
                11'd427: window_bounds = {11'd427, 11'd452, 7'd31};
                11'd428: window_bounds = {11'd428, 11'd453, 7'd32};
                11'd429: window_bounds = {11'd429, 11'd454, 7'd33};
                11'd430: window_bounds = {11'd430, 11'd454, 7'd34};
                11'd431: window_bounds = {11'd431, 11'd455, 7'd35};
                11'd432: window_bounds = {11'd432, 11'd456, 7'd36};
                11'd433: window_bounds = {11'd433, 11'd457, 7'd37};
                11'd434: window_bounds = {11'd434, 11'd458, 7'd38};
                11'd435: window_bounds = {11'd435, 11'd458, 7'd39};
                11'd436: window_bounds = {11'd436, 11'd459, 7'd40};
                11'd437: window_bounds = {11'd437, 11'd460, 7'd41};
                11'd438: window_bounds = {11'd438, 11'd461, 7'd42};
                11'd439: window_bounds = {11'd439, 11'd462, 7'd43};
                11'd440: window_bounds = {11'd440, 11'd462, 7'd44};
                11'd441: window_bounds = {11'd441, 11'd463, 7'd45};
                11'd442: window_bounds = {11'd442, 11'd464, 7'd46};
                11'd443: window_bounds = {11'd443, 11'd465, 7'd47};
                11'd444: window_bounds = {11'd444, 11'd466, 7'd48};
                11'd445: window_bounds = {11'd445, 11'd467, 7'd49};
                11'd446: window_bounds = {11'd446, 11'd467, 7'd50};
                11'd447: window_bounds = {11'd447, 11'd468, 7'd51};
                11'd448: window_bounds = {11'd448, 11'd469, 7'd52};
                11'd449: window_bounds = {11'd449, 11'd470, 7'd53};
                11'd450: window_bounds = {11'd450, 11'd471, 7'd54};
                11'd451: window_bounds = {11'd451, 11'd471, 7'd55};
                11'd452: window_bounds = {11'd452, 11'd472, 7'd56};
                11'd453: window_bounds = {11'd453, 11'd473, 7'd57};
                11'd454: window_bounds = {11'd454, 11'd474, 7'd58};
                11'd455: window_bounds = {11'd455, 11'd475, 7'd59};
                11'd456: window_bounds = {11'd456, 11'd475, 7'd60};
                11'd457: window_bounds = {11'd457, 11'd476, 7'd61};
                11'd458: window_bounds = {11'd458, 11'd477, 7'd62};
                11'd459: window_bounds = {11'd459, 11'd478, 7'd63};
                11'd460: window_bounds = {11'd460, 11'd479, 7'd64};
                11'd461: window_bounds = {11'd461, 11'd480, 7'd65};
                11'd462: window_bounds = {11'd462, 11'd480, 7'd0};
                11'd463: window_bounds = {11'd463, 11'd481, 7'd1};
                11'd464: window_bounds = {11'd464, 11'd482, 7'd2};
                11'd465: window_bounds = {11'd465, 11'd483, 7'd3};
                11'd466: window_bounds = {11'd466, 11'd484, 7'd4};
                11'd467: window_bounds = {11'd467, 11'd484, 7'd5};
                11'd468: window_bounds = {11'd468, 11'd485, 7'd6};
                11'd469: window_bounds = {11'd469, 11'd486, 7'd7};
                11'd470: window_bounds = {11'd470, 11'd487, 7'd8};
                11'd471: window_bounds = {11'd471, 11'd488, 7'd9};
                11'd472: window_bounds = {11'd472, 11'd489, 7'd10};
                11'd473: window_bounds = {11'd473, 11'd489, 7'd11};
                11'd474: window_bounds = {11'd474, 11'd490, 7'd12};
                11'd475: window_bounds = {11'd475, 11'd491, 7'd13};
                11'd476: window_bounds = {11'd476, 11'd492, 7'd14};
                11'd477: window_bounds = {11'd477, 11'd493, 7'd15};
                11'd478: window_bounds = {11'd478, 11'd493, 7'd16};
                11'd479: window_bounds = {11'd479, 11'd494, 7'd17};
                11'd480: window_bounds = {11'd480, 11'd495, 7'd18};
                11'd481: window_bounds = {11'd481, 11'd496, 7'd19};
                11'd482: window_bounds = {11'd482, 11'd497, 7'd20};
                11'd483: window_bounds = {11'd483, 11'd497, 7'd21};
                11'd484: window_bounds = {11'd484, 11'd498, 7'd22};
                11'd485: window_bounds = {11'd485, 11'd499, 7'd23};
                11'd486: window_bounds = {11'd486, 11'd500, 7'd24};
                11'd487: window_bounds = {11'd487, 11'd501, 7'd25};
                11'd488: window_bounds = {11'd488, 11'd502, 7'd26};
                11'd489: window_bounds = {11'd489, 11'd502, 7'd27};
                11'd490: window_bounds = {11'd490, 11'd503, 7'd28};
                11'd491: window_bounds = {11'd491, 11'd504, 7'd29};
                11'd492: window_bounds = {11'd492, 11'd505, 7'd30};
                11'd493: window_bounds = {11'd493, 11'd506, 7'd31};
                11'd494: window_bounds = {11'd494, 11'd506, 7'd32};
                11'd495: window_bounds = {11'd495, 11'd507, 7'd33};
                11'd496: window_bounds = {11'd496, 11'd508, 7'd34};
                11'd497: window_bounds = {11'd497, 11'd509, 7'd35};
                11'd498: window_bounds = {11'd498, 11'd510, 7'd36};
                11'd499: window_bounds = {11'd499, 11'd511, 7'd37};
                11'd500: window_bounds = {11'd500, 11'd511, 7'd38};
                11'd501: window_bounds = {11'd501, 11'd512, 7'd39};
                11'd502: window_bounds = {11'd502, 11'd513, 7'd40};
                11'd503: window_bounds = {11'd503, 11'd514, 7'd41};
                11'd504: window_bounds = {11'd504, 11'd515, 7'd42};
                11'd505: window_bounds = {11'd505, 11'd515, 7'd43};
                11'd506: window_bounds = {11'd506, 11'd516, 7'd44};
                11'd507: window_bounds = {11'd507, 11'd517, 7'd45};
                11'd508: window_bounds = {11'd508, 11'd518, 7'd46};
                11'd509: window_bounds = {11'd509, 11'd519, 7'd47};
                11'd510: window_bounds = {11'd510, 11'd520, 7'd48};
                11'd511: window_bounds = {11'd511, 11'd520, 7'd49};
                11'd512: window_bounds = {11'd512, 11'd521, 7'd50};
                11'd513: window_bounds = {11'd513, 11'd522, 7'd51};
                11'd514: window_bounds = {11'd514, 11'd523, 7'd52};
                11'd515: window_bounds = {11'd514, 11'd524, 7'd52};
                11'd516: window_bounds = {11'd515, 11'd524, 7'd53};
                11'd517: window_bounds = {11'd517, 11'd525, 7'd55};
                11'd518: window_bounds = {11'd518, 11'd526, 7'd56};
                11'd519: window_bounds = {11'd519, 11'd527, 7'd57};
                11'd520: window_bounds = {11'd519, 11'd528, 7'd57};
                11'd521: window_bounds = {11'd520, 11'd529, 7'd58};
                11'd522: window_bounds = {11'd522, 11'd529, 7'd60};
                11'd523: window_bounds = {11'd523, 11'd530, 7'd61};
                11'd524: window_bounds = {11'd524, 11'd531, 7'd62};
                11'd525: window_bounds = {11'd524, 11'd532, 7'd62};
                11'd526: window_bounds = {11'd525, 11'd533, 7'd63};
                11'd527: window_bounds = {11'd527, 11'd534, 7'd65};
                11'd528: window_bounds = {11'd528, 11'd534, 7'd0};
                11'd529: window_bounds = {11'd529, 11'd535, 7'd1};
                11'd530: window_bounds = {11'd530, 11'd536, 7'd2};
                11'd531: window_bounds = {11'd530, 11'd537, 7'd2};
                11'd532: window_bounds = {11'd532, 11'd538, 7'd4};
                11'd533: window_bounds = {11'd533, 11'd538, 7'd5};
                11'd534: window_bounds = {11'd534, 11'd539, 7'd6};
                11'd535: window_bounds = {11'd535, 11'd540, 7'd7};
                11'd536: window_bounds = {11'd535, 11'd541, 7'd7};
                11'd537: window_bounds = {11'd536, 11'd542, 7'd8};
                11'd538: window_bounds = {11'd538, 11'd542, 7'd10};
                11'd539: window_bounds = {11'd539, 11'd543, 7'd11};
                11'd540: window_bounds = {11'd540, 11'd544, 7'd12};
                11'd541: window_bounds = {11'd540, 11'd545, 7'd12};
                11'd542: window_bounds = {11'd541, 11'd546, 7'd13};
                11'd543: window_bounds = {11'd543, 11'd547, 7'd15};
                11'd544: window_bounds = {11'd544, 11'd547, 7'd16};
                11'd545: window_bounds = {11'd545, 11'd548, 7'd17};
                11'd546: window_bounds = {11'd546, 11'd549, 7'd18};
                11'd547: window_bounds = {11'd546, 11'd550, 7'd18};
                11'd548: window_bounds = {11'd548, 11'd551, 7'd20};
                11'd549: window_bounds = {11'd549, 11'd552, 7'd21};
                11'd550: window_bounds = {11'd550, 11'd552, 7'd22};
                11'd551: window_bounds = {11'd551, 11'd553, 7'd23};
                11'd552: window_bounds = {11'd551, 11'd554, 7'd23};
                11'd553: window_bounds = {11'd552, 11'd555, 7'd24};
                11'd554: window_bounds = {11'd554, 11'd556, 7'd26};
                11'd555: window_bounds = {11'd555, 11'd556, 7'd27};
                11'd556: window_bounds = {11'd556, 11'd557, 7'd28};
                11'd557: window_bounds = {11'd556, 11'd558, 7'd28};
                11'd558: window_bounds = {11'd557, 11'd559, 7'd29};
                11'd559: window_bounds = {11'd559, 11'd560, 7'd31};
                11'd560: window_bounds = {11'd560, 11'd561, 7'd32};
                11'd561: window_bounds = {11'd560, 11'd562, 7'd32};
                11'd562: window_bounds = {11'd561, 11'd563, 7'd33};
                11'd563: window_bounds = {11'd562, 11'd563, 7'd34};
                11'd564: window_bounds = {11'd563, 11'd565, 7'd35};
                11'd565: window_bounds = {11'd564, 11'd566, 7'd36};
                11'd566: window_bounds = {11'd564, 11'd567, 7'd36};
                11'd567: window_bounds = {11'd565, 11'd567, 7'd37};
                11'd568: window_bounds = {11'd566, 11'd568, 7'd38};
                11'd569: window_bounds = {11'd567, 11'd569, 7'd39};
                11'd570: window_bounds = {11'd568, 11'd570, 7'd40};
                11'd571: window_bounds = {11'd569, 11'd571, 7'd41};
                11'd572: window_bounds = {11'd569, 11'd572, 7'd41};
                11'd573: window_bounds = {11'd570, 11'd573, 7'd42};
                11'd574: window_bounds = {11'd571, 11'd574, 7'd43};
                11'd575: window_bounds = {11'd572, 11'd575, 7'd44};
                11'd576: window_bounds = {11'd573, 11'd576, 7'd45};
                11'd577: window_bounds = {11'd573, 11'd577, 7'd45};
                11'd578: window_bounds = {11'd574, 11'd578, 7'd46};
                11'd579: window_bounds = {11'd575, 11'd579, 7'd47};
                11'd580: window_bounds = {11'd576, 11'd580, 7'd48};
                11'd581: window_bounds = {11'd577, 11'd581, 7'd49};
                11'd582: window_bounds = {11'd578, 11'd582, 7'd50};
                11'd583: window_bounds = {11'd578, 11'd583, 7'd50};
                11'd584: window_bounds = {11'd579, 11'd584, 7'd51};
                11'd585: window_bounds = {11'd580, 11'd585, 7'd52};
                11'd586: window_bounds = {11'd581, 11'd586, 7'd53};
                11'd587: window_bounds = {11'd582, 11'd587, 7'd54};
                11'd588: window_bounds = {11'd583, 11'd588, 7'd55};
                11'd589: window_bounds = {11'd583, 11'd589, 7'd55};
                11'd590: window_bounds = {11'd584, 11'd590, 7'd56};
                11'd591: window_bounds = {11'd585, 11'd591, 7'd57};
                11'd592: window_bounds = {11'd586, 11'd592, 7'd58};
                11'd593: window_bounds = {11'd587, 11'd593, 7'd59};
                11'd594: window_bounds = {11'd587, 11'd594, 7'd59};
                11'd595: window_bounds = {11'd588, 11'd595, 7'd60};
                11'd596: window_bounds = {11'd589, 11'd596, 7'd61};
                11'd597: window_bounds = {11'd590, 11'd597, 7'd62};
                11'd598: window_bounds = {11'd591, 11'd598, 7'd63};
                11'd599: window_bounds = {11'd592, 11'd599, 7'd64};
                11'd600: window_bounds = {11'd592, 11'd600, 7'd64};
                11'd601: window_bounds = {11'd593, 11'd601, 7'd65};
                11'd602: window_bounds = {11'd594, 11'd602, 7'd0};
                11'd603: window_bounds = {11'd595, 11'd603, 7'd1};
                11'd604: window_bounds = {11'd596, 11'd604, 7'd2};
                11'd605: window_bounds = {11'd596, 11'd605, 7'd2};
                11'd606: window_bounds = {11'd597, 11'd606, 7'd3};
                11'd607: window_bounds = {11'd598, 11'd607, 7'd4};
                11'd608: window_bounds = {11'd599, 11'd608, 7'd5};
                11'd609: window_bounds = {11'd600, 11'd609, 7'd6};
                11'd610: window_bounds = {11'd601, 11'd610, 7'd7};
                11'd611: window_bounds = {11'd601, 11'd611, 7'd7};
                11'd612: window_bounds = {11'd602, 11'd612, 7'd8};
                11'd613: window_bounds = {11'd603, 11'd613, 7'd9};
                11'd614: window_bounds = {11'd604, 11'd614, 7'd10};
                11'd615: window_bounds = {11'd605, 11'd615, 7'd11};
                11'd616: window_bounds = {11'd605, 11'd616, 7'd11};
                11'd617: window_bounds = {11'd606, 11'd617, 7'd12};
                11'd618: window_bounds = {11'd607, 11'd618, 7'd13};
                11'd619: window_bounds = {11'd608, 11'd619, 7'd14};
                11'd620: window_bounds = {11'd609, 11'd620, 7'd15};
                11'd621: window_bounds = {11'd609, 11'd621, 7'd15};
                11'd622: window_bounds = {11'd610, 11'd622, 7'd16};
                11'd623: window_bounds = {11'd611, 11'd623, 7'd17};
                11'd624: window_bounds = {11'd612, 11'd624, 7'd18};
                11'd625: window_bounds = {11'd613, 11'd625, 7'd19};
                11'd626: window_bounds = {11'd614, 11'd626, 7'd20};
                11'd627: window_bounds = {11'd614, 11'd627, 7'd20};
                11'd628: window_bounds = {11'd615, 11'd628, 7'd21};
                11'd629: window_bounds = {11'd616, 11'd629, 7'd22};
                11'd630: window_bounds = {11'd617, 11'd630, 7'd23};
                11'd631: window_bounds = {11'd618, 11'd631, 7'd24};
                11'd632: window_bounds = {11'd618, 11'd632, 7'd24};
                11'd633: window_bounds = {11'd619, 11'd633, 7'd25};
                11'd634: window_bounds = {11'd620, 11'd634, 7'd26};
                11'd635: window_bounds = {11'd621, 11'd635, 7'd27};
                11'd636: window_bounds = {11'd622, 11'd636, 7'd28};
                11'd637: window_bounds = {11'd623, 11'd637, 7'd29};
                11'd638: window_bounds = {11'd623, 11'd638, 7'd29};
                11'd639: window_bounds = {11'd624, 11'd639, 7'd30};
                11'd640: window_bounds = {11'd625, 11'd640, 7'd31};
                11'd641: window_bounds = {11'd626, 11'd641, 7'd32};
                11'd642: window_bounds = {11'd627, 11'd642, 7'd33};
                11'd643: window_bounds = {11'd627, 11'd643, 7'd33};
                11'd644: window_bounds = {11'd628, 11'd644, 7'd34};
                11'd645: window_bounds = {11'd629, 11'd645, 7'd35};
                11'd646: window_bounds = {11'd630, 11'd646, 7'd36};
                11'd647: window_bounds = {11'd631, 11'd647, 7'd37};
                11'd648: window_bounds = {11'd632, 11'd648, 7'd38};
                11'd649: window_bounds = {11'd632, 11'd649, 7'd38};
                11'd650: window_bounds = {11'd633, 11'd650, 7'd39};
                11'd651: window_bounds = {11'd634, 11'd651, 7'd40};
                11'd652: window_bounds = {11'd635, 11'd652, 7'd41};
                11'd653: window_bounds = {11'd636, 11'd653, 7'd42};
                11'd654: window_bounds = {11'd636, 11'd654, 7'd42};
                11'd655: window_bounds = {11'd637, 11'd655, 7'd43};
                11'd656: window_bounds = {11'd638, 11'd656, 7'd44};
                11'd657: window_bounds = {11'd639, 11'd657, 7'd45};
                11'd658: window_bounds = {11'd640, 11'd658, 7'd46};
                11'd659: window_bounds = {11'd641, 11'd659, 7'd47};
                11'd660: window_bounds = {11'd641, 11'd660, 7'd47};
                11'd661: window_bounds = {11'd642, 11'd661, 7'd48};
                11'd662: window_bounds = {11'd643, 11'd662, 7'd49};
                11'd663: window_bounds = {11'd644, 11'd663, 7'd50};
                11'd664: window_bounds = {11'd645, 11'd664, 7'd51};
                11'd665: window_bounds = {11'd645, 11'd665, 7'd51};
                11'd666: window_bounds = {11'd646, 11'd666, 7'd52};
                11'd667: window_bounds = {11'd647, 11'd667, 7'd53};
                11'd668: window_bounds = {11'd648, 11'd668, 7'd54};
                11'd669: window_bounds = {11'd649, 11'd669, 7'd55};
                11'd670: window_bounds = {11'd649, 11'd670, 7'd55};
                11'd671: window_bounds = {11'd650, 11'd671, 7'd56};
                11'd672: window_bounds = {11'd651, 11'd672, 7'd57};
                11'd673: window_bounds = {11'd652, 11'd673, 7'd58};
                11'd674: window_bounds = {11'd653, 11'd674, 7'd59};
                11'd675: window_bounds = {11'd654, 11'd675, 7'd60};
                11'd676: window_bounds = {11'd654, 11'd676, 7'd60};
                11'd677: window_bounds = {11'd655, 11'd677, 7'd61};
                11'd678: window_bounds = {11'd656, 11'd678, 7'd62};
                11'd679: window_bounds = {11'd657, 11'd679, 7'd63};
                11'd680: window_bounds = {11'd658, 11'd680, 7'd64};
                11'd681: window_bounds = {11'd658, 11'd681, 7'd64};
                11'd682: window_bounds = {11'd659, 11'd682, 7'd65};
                11'd683: window_bounds = {11'd660, 11'd683, 7'd0};
                11'd684: window_bounds = {11'd661, 11'd684, 7'd1};
                11'd685: window_bounds = {11'd662, 11'd685, 7'd2};
                11'd686: window_bounds = {11'd662, 11'd686, 7'd2};
                11'd687: window_bounds = {11'd663, 11'd687, 7'd3};
                11'd688: window_bounds = {11'd664, 11'd688, 7'd4};
                11'd689: window_bounds = {11'd665, 11'd689, 7'd5};
                11'd690: window_bounds = {11'd666, 11'd690, 7'd6};
                11'd691: window_bounds = {11'd667, 11'd691, 7'd7};
                11'd692: window_bounds = {11'd667, 11'd692, 7'd7};
                11'd693: window_bounds = {11'd668, 11'd693, 7'd8};
                11'd694: window_bounds = {11'd669, 11'd694, 7'd9};
                11'd695: window_bounds = {11'd670, 11'd694, 7'd10};
                11'd696: window_bounds = {11'd671, 11'd695, 7'd11};
                11'd697: window_bounds = {11'd671, 11'd696, 7'd11};
                11'd698: window_bounds = {11'd672, 11'd697, 7'd12};
                11'd699: window_bounds = {11'd673, 11'd698, 7'd13};
                11'd700: window_bounds = {11'd674, 11'd699, 7'd14};
                11'd701: window_bounds = {11'd675, 11'd700, 7'd15};
                11'd702: window_bounds = {11'd675, 11'd701, 7'd15};
                11'd703: window_bounds = {11'd676, 11'd702, 7'd16};
                11'd704: window_bounds = {11'd677, 11'd703, 7'd17};
                11'd705: window_bounds = {11'd678, 11'd704, 7'd18};
                11'd706: window_bounds = {11'd679, 11'd705, 7'd19};
                11'd707: window_bounds = {11'd679, 11'd706, 7'd19};
                11'd708: window_bounds = {11'd680, 11'd707, 7'd20};
                11'd709: window_bounds = {11'd681, 11'd708, 7'd21};
                11'd710: window_bounds = {11'd682, 11'd709, 7'd22};
                11'd711: window_bounds = {11'd683, 11'd710, 7'd23};
                11'd712: window_bounds = {11'd683, 11'd711, 7'd23};
                11'd713: window_bounds = {11'd684, 11'd712, 7'd24};
                11'd714: window_bounds = {11'd685, 11'd713, 7'd25};
                11'd715: window_bounds = {11'd686, 11'd714, 7'd26};
                11'd716: window_bounds = {11'd687, 11'd715, 7'd27};
                11'd717: window_bounds = {11'd688, 11'd716, 7'd28};
                11'd718: window_bounds = {11'd688, 11'd717, 7'd28};
                11'd719: window_bounds = {11'd689, 11'd718, 7'd29};
                11'd720: window_bounds = {11'd690, 11'd719, 7'd30};
                11'd721: window_bounds = {11'd691, 11'd720, 7'd31};
                11'd722: window_bounds = {11'd692, 11'd721, 7'd32};
                11'd723: window_bounds = {11'd692, 11'd722, 7'd32};
                11'd724: window_bounds = {11'd693, 11'd723, 7'd33};
                11'd725: window_bounds = {11'd694, 11'd724, 7'd34};
                11'd726: window_bounds = {11'd695, 11'd725, 7'd35};
                11'd727: window_bounds = {11'd696, 11'd726, 7'd36};
                11'd728: window_bounds = {11'd696, 11'd727, 7'd36};
                11'd729: window_bounds = {11'd697, 11'd727, 7'd37};
                11'd730: window_bounds = {11'd698, 11'd728, 7'd38};
                11'd731: window_bounds = {11'd699, 11'd729, 7'd39};
                11'd732: window_bounds = {11'd700, 11'd730, 7'd40};
                11'd733: window_bounds = {11'd700, 11'd731, 7'd40};
                11'd734: window_bounds = {11'd701, 11'd732, 7'd41};
                11'd735: window_bounds = {11'd702, 11'd733, 7'd42};
                11'd736: window_bounds = {11'd703, 11'd734, 7'd43};
                11'd737: window_bounds = {11'd704, 11'd735, 7'd44};
                11'd738: window_bounds = {11'd704, 11'd736, 7'd44};
                11'd739: window_bounds = {11'd705, 11'd737, 7'd45};
                11'd740: window_bounds = {11'd706, 11'd738, 7'd46};
                11'd741: window_bounds = {11'd707, 11'd739, 7'd47};
                11'd742: window_bounds = {11'd708, 11'd740, 7'd48};
                11'd743: window_bounds = {11'd708, 11'd741, 7'd48};
                11'd744: window_bounds = {11'd709, 11'd742, 7'd49};
                11'd745: window_bounds = {11'd710, 11'd743, 7'd50};
                11'd746: window_bounds = {11'd711, 11'd744, 7'd51};
                11'd747: window_bounds = {11'd712, 11'd745, 7'd52};
                11'd748: window_bounds = {11'd712, 11'd746, 7'd52};
                11'd749: window_bounds = {11'd713, 11'd747, 7'd53};
                11'd750: window_bounds = {11'd714, 11'd748, 7'd54};
                11'd751: window_bounds = {11'd715, 11'd749, 7'd55};
                11'd752: window_bounds = {11'd716, 11'd750, 7'd56};
                11'd753: window_bounds = {11'd716, 11'd751, 7'd56};
                11'd754: window_bounds = {11'd717, 11'd752, 7'd57};
                11'd755: window_bounds = {11'd718, 11'd752, 7'd58};
                11'd756: window_bounds = {11'd719, 11'd753, 7'd59};
                11'd757: window_bounds = {11'd720, 11'd754, 7'd60};
                11'd758: window_bounds = {11'd720, 11'd755, 7'd60};
                11'd759: window_bounds = {11'd721, 11'd756, 7'd61};
                11'd760: window_bounds = {11'd722, 11'd757, 7'd62};
                11'd761: window_bounds = {11'd723, 11'd758, 7'd63};
                11'd762: window_bounds = {11'd724, 11'd759, 7'd64};
                11'd763: window_bounds = {11'd724, 11'd760, 7'd64};
                11'd764: window_bounds = {11'd725, 11'd761, 7'd65};
                11'd765: window_bounds = {11'd726, 11'd762, 7'd0};
                11'd766: window_bounds = {11'd727, 11'd763, 7'd1};
                11'd767: window_bounds = {11'd728, 11'd764, 7'd2};
                11'd768: window_bounds = {11'd728, 11'd765, 7'd2};
                11'd769: window_bounds = {11'd729, 11'd766, 7'd3};
                11'd770: window_bounds = {11'd730, 11'd767, 7'd4};
                11'd771: window_bounds = {11'd731, 11'd768, 7'd5};
                11'd772: window_bounds = {11'd732, 11'd769, 7'd6};
                11'd773: window_bounds = {11'd732, 11'd770, 7'd6};
                11'd774: window_bounds = {11'd733, 11'd770, 7'd7};
                11'd775: window_bounds = {11'd734, 11'd771, 7'd8};
                11'd776: window_bounds = {11'd735, 11'd772, 7'd9};
                11'd777: window_bounds = {11'd736, 11'd773, 7'd10};
                11'd778: window_bounds = {11'd736, 11'd774, 7'd10};
                11'd779: window_bounds = {11'd737, 11'd775, 7'd11};
                11'd780: window_bounds = {11'd738, 11'd776, 7'd12};
                11'd781: window_bounds = {11'd739, 11'd777, 7'd13};
                11'd782: window_bounds = {11'd740, 11'd778, 7'd14};
                11'd783: window_bounds = {11'd740, 11'd779, 7'd14};
                11'd784: window_bounds = {11'd741, 11'd780, 7'd15};
                11'd785: window_bounds = {11'd742, 11'd781, 7'd16};
                11'd786: window_bounds = {11'd743, 11'd782, 7'd17};
                11'd787: window_bounds = {11'd744, 11'd783, 7'd18};
                11'd788: window_bounds = {11'd744, 11'd784, 7'd18};
                11'd789: window_bounds = {11'd745, 11'd785, 7'd19};
                11'd790: window_bounds = {11'd746, 11'd786, 7'd20};
                11'd791: window_bounds = {11'd747, 11'd786, 7'd21};
                11'd792: window_bounds = {11'd747, 11'd787, 7'd21};
                11'd793: window_bounds = {11'd748, 11'd788, 7'd22};
                11'd794: window_bounds = {11'd749, 11'd789, 7'd23};
                11'd795: window_bounds = {11'd750, 11'd790, 7'd24};
                11'd796: window_bounds = {11'd751, 11'd791, 7'd25};
                11'd797: window_bounds = {11'd751, 11'd792, 7'd25};
                11'd798: window_bounds = {11'd752, 11'd793, 7'd26};
                11'd799: window_bounds = {11'd753, 11'd794, 7'd27};
                11'd800: window_bounds = {11'd754, 11'd795, 7'd28};
                11'd801: window_bounds = {11'd755, 11'd796, 7'd29};
                11'd802: window_bounds = {11'd755, 11'd797, 7'd29};
                11'd803: window_bounds = {11'd756, 11'd798, 7'd30};
                11'd804: window_bounds = {11'd757, 11'd799, 7'd31};
                11'd805: window_bounds = {11'd758, 11'd800, 7'd32};
                11'd806: window_bounds = {11'd759, 11'd800, 7'd33};
                11'd807: window_bounds = {11'd759, 11'd801, 7'd33};
                11'd808: window_bounds = {11'd760, 11'd802, 7'd34};
                11'd809: window_bounds = {11'd761, 11'd803, 7'd35};
                11'd810: window_bounds = {11'd762, 11'd804, 7'd36};
                11'd811: window_bounds = {11'd762, 11'd805, 7'd36};
                11'd812: window_bounds = {11'd763, 11'd806, 7'd37};
                11'd813: window_bounds = {11'd764, 11'd807, 7'd38};
                11'd814: window_bounds = {11'd765, 11'd808, 7'd39};
                11'd815: window_bounds = {11'd766, 11'd809, 7'd40};
                11'd816: window_bounds = {11'd766, 11'd810, 7'd40};
                11'd817: window_bounds = {11'd767, 11'd811, 7'd41};
                11'd818: window_bounds = {11'd768, 11'd812, 7'd42};
                11'd819: window_bounds = {11'd769, 11'd812, 7'd43};
                11'd820: window_bounds = {11'd770, 11'd813, 7'd44};
                11'd821: window_bounds = {11'd770, 11'd814, 7'd44};
                11'd822: window_bounds = {11'd771, 11'd815, 7'd45};
                11'd823: window_bounds = {11'd772, 11'd816, 7'd46};
                11'd824: window_bounds = {11'd773, 11'd817, 7'd47};
                11'd825: window_bounds = {11'd773, 11'd818, 7'd47};
                11'd826: window_bounds = {11'd774, 11'd819, 7'd48};
                11'd827: window_bounds = {11'd775, 11'd820, 7'd49};
                11'd828: window_bounds = {11'd776, 11'd821, 7'd50};
                11'd829: window_bounds = {11'd777, 11'd822, 7'd51};
                11'd830: window_bounds = {11'd777, 11'd823, 7'd51};
                11'd831: window_bounds = {11'd778, 11'd823, 7'd52};
                11'd832: window_bounds = {11'd779, 11'd824, 7'd53};
                11'd833: window_bounds = {11'd780, 11'd825, 7'd54};
                11'd834: window_bounds = {11'd780, 11'd826, 7'd54};
                11'd835: window_bounds = {11'd781, 11'd827, 7'd55};
                11'd836: window_bounds = {11'd782, 11'd828, 7'd56};
                11'd837: window_bounds = {11'd783, 11'd829, 7'd57};
                11'd838: window_bounds = {11'd784, 11'd830, 7'd58};
                11'd839: window_bounds = {11'd784, 11'd831, 7'd58};
                11'd840: window_bounds = {11'd785, 11'd832, 7'd59};
                11'd841: window_bounds = {11'd786, 11'd833, 7'd60};
                11'd842: window_bounds = {11'd787, 11'd833, 7'd61};
                11'd843: window_bounds = {11'd788, 11'd834, 7'd62};
                11'd844: window_bounds = {11'd788, 11'd835, 7'd62};
                11'd845: window_bounds = {11'd789, 11'd836, 7'd63};
                11'd846: window_bounds = {11'd790, 11'd837, 7'd64};
                11'd847: window_bounds = {11'd791, 11'd838, 7'd65};
                11'd848: window_bounds = {11'd791, 11'd839, 7'd65};
                11'd849: window_bounds = {11'd792, 11'd840, 7'd0};
                11'd850: window_bounds = {11'd793, 11'd841, 7'd1};
                11'd851: window_bounds = {11'd794, 11'd842, 7'd2};
                11'd852: window_bounds = {11'd794, 11'd843, 7'd2};
                11'd853: window_bounds = {11'd795, 11'd843, 7'd3};
                11'd854: window_bounds = {11'd796, 11'd844, 7'd4};
                11'd855: window_bounds = {11'd797, 11'd845, 7'd5};
                11'd856: window_bounds = {11'd798, 11'd846, 7'd6};
                11'd857: window_bounds = {11'd798, 11'd847, 7'd6};
                11'd858: window_bounds = {11'd799, 11'd848, 7'd7};
                11'd859: window_bounds = {11'd800, 11'd849, 7'd8};
                11'd860: window_bounds = {11'd801, 11'd850, 7'd9};
                11'd861: window_bounds = {11'd801, 11'd851, 7'd9};
                11'd862: window_bounds = {11'd802, 11'd851, 7'd10};
                11'd863: window_bounds = {11'd803, 11'd852, 7'd11};
                11'd864: window_bounds = {11'd804, 11'd853, 7'd12};
                11'd865: window_bounds = {11'd805, 11'd854, 7'd13};
                11'd866: window_bounds = {11'd805, 11'd855, 7'd13};
                11'd867: window_bounds = {11'd806, 11'd856, 7'd14};
                11'd868: window_bounds = {11'd807, 11'd857, 7'd15};
                11'd869: window_bounds = {11'd808, 11'd858, 7'd16};
                11'd870: window_bounds = {11'd808, 11'd859, 7'd16};
                11'd871: window_bounds = {11'd809, 11'd859, 7'd17};
                11'd872: window_bounds = {11'd810, 11'd860, 7'd18};
                11'd873: window_bounds = {11'd811, 11'd861, 7'd19};
                11'd874: window_bounds = {11'd812, 11'd862, 7'd20};
                11'd875: window_bounds = {11'd812, 11'd863, 7'd20};
                11'd876: window_bounds = {11'd813, 11'd864, 7'd21};
                11'd877: window_bounds = {11'd814, 11'd865, 7'd22};
                11'd878: window_bounds = {11'd815, 11'd866, 7'd23};
                11'd879: window_bounds = {11'd815, 11'd867, 7'd23};
                11'd880: window_bounds = {11'd816, 11'd867, 7'd24};
                11'd881: window_bounds = {11'd817, 11'd868, 7'd25};
                11'd882: window_bounds = {11'd818, 11'd869, 7'd26};
                11'd883: window_bounds = {11'd818, 11'd870, 7'd26};
                11'd884: window_bounds = {11'd819, 11'd871, 7'd27};
                11'd885: window_bounds = {11'd820, 11'd872, 7'd28};
                11'd886: window_bounds = {11'd821, 11'd873, 7'd29};
                11'd887: window_bounds = {11'd822, 11'd874, 7'd30};
                11'd888: window_bounds = {11'd822, 11'd874, 7'd30};
                11'd889: window_bounds = {11'd823, 11'd875, 7'd31};
                11'd890: window_bounds = {11'd824, 11'd876, 7'd32};
                11'd891: window_bounds = {11'd825, 11'd877, 7'd33};
                11'd892: window_bounds = {11'd825, 11'd878, 7'd33};
                11'd893: window_bounds = {11'd826, 11'd879, 7'd34};
                11'd894: window_bounds = {11'd827, 11'd880, 7'd35};
                11'd895: window_bounds = {11'd828, 11'd881, 7'd36};
                11'd896: window_bounds = {11'd828, 11'd881, 7'd36};
                11'd897: window_bounds = {11'd829, 11'd882, 7'd37};
                11'd898: window_bounds = {11'd830, 11'd883, 7'd38};
                11'd899: window_bounds = {11'd831, 11'd884, 7'd39};
                11'd900: window_bounds = {11'd832, 11'd885, 7'd40};
                11'd901: window_bounds = {11'd832, 11'd886, 7'd40};
                11'd902: window_bounds = {11'd833, 11'd887, 7'd41};
                11'd903: window_bounds = {11'd834, 11'd888, 7'd42};
                11'd904: window_bounds = {11'd835, 11'd888, 7'd43};
                11'd905: window_bounds = {11'd835, 11'd889, 7'd43};
                11'd906: window_bounds = {11'd836, 11'd890, 7'd44};
                11'd907: window_bounds = {11'd837, 11'd891, 7'd45};
                11'd908: window_bounds = {11'd838, 11'd892, 7'd46};
                11'd909: window_bounds = {11'd838, 11'd893, 7'd46};
                11'd910: window_bounds = {11'd839, 11'd894, 7'd47};
                11'd911: window_bounds = {11'd840, 11'd894, 7'd48};
                11'd912: window_bounds = {11'd841, 11'd895, 7'd49};
                11'd913: window_bounds = {11'd841, 11'd896, 7'd49};
                11'd914: window_bounds = {11'd842, 11'd897, 7'd50};
                11'd915: window_bounds = {11'd843, 11'd898, 7'd51};
                11'd916: window_bounds = {11'd844, 11'd899, 7'd52};
                11'd917: window_bounds = {11'd845, 11'd900, 7'd53};
                11'd918: window_bounds = {11'd845, 11'd900, 7'd53};
                11'd919: window_bounds = {11'd846, 11'd901, 7'd54};
                11'd920: window_bounds = {11'd847, 11'd902, 7'd55};
                11'd921: window_bounds = {11'd848, 11'd903, 7'd56};
                11'd922: window_bounds = {11'd848, 11'd904, 7'd56};
                11'd923: window_bounds = {11'd849, 11'd905, 7'd57};
                11'd924: window_bounds = {11'd850, 11'd906, 7'd58};
                11'd925: window_bounds = {11'd851, 11'd906, 7'd59};
                11'd926: window_bounds = {11'd851, 11'd907, 7'd59};
                11'd927: window_bounds = {11'd852, 11'd908, 7'd60};
                11'd928: window_bounds = {11'd853, 11'd909, 7'd61};
                11'd929: window_bounds = {11'd854, 11'd910, 7'd62};
                11'd930: window_bounds = {11'd854, 11'd911, 7'd62};
                11'd931: window_bounds = {11'd855, 11'd911, 7'd63};
                11'd932: window_bounds = {11'd856, 11'd912, 7'd64};
                11'd933: window_bounds = {11'd857, 11'd913, 7'd65};
                11'd934: window_bounds = {11'd857, 11'd914, 7'd65};
                11'd935: window_bounds = {11'd858, 11'd915, 7'd0};
                11'd936: window_bounds = {11'd859, 11'd916, 7'd1};
                11'd937: window_bounds = {11'd860, 11'd917, 7'd2};
                11'd938: window_bounds = {11'd860, 11'd917, 7'd2};
                11'd939: window_bounds = {11'd861, 11'd918, 7'd3};
                11'd940: window_bounds = {11'd862, 11'd919, 7'd4};
                11'd941: window_bounds = {11'd863, 11'd920, 7'd5};
                11'd942: window_bounds = {11'd863, 11'd921, 7'd5};
                11'd943: window_bounds = {11'd864, 11'd922, 7'd6};
                11'd944: window_bounds = {11'd865, 11'd922, 7'd7};
                11'd945: window_bounds = {11'd866, 11'd923, 7'd8};
                11'd946: window_bounds = {11'd866, 11'd924, 7'd8};
                11'd947: window_bounds = {11'd867, 11'd925, 7'd9};
                11'd948: window_bounds = {11'd868, 11'd926, 7'd10};
                11'd949: window_bounds = {11'd869, 11'd927, 7'd11};
                11'd950: window_bounds = {11'd869, 11'd927, 7'd11};
                11'd951: window_bounds = {11'd870, 11'd928, 7'd12};
                11'd952: window_bounds = {11'd871, 11'd929, 7'd13};
                11'd953: window_bounds = {11'd872, 11'd930, 7'd14};
                11'd954: window_bounds = {11'd872, 11'd931, 7'd14};
                11'd955: window_bounds = {11'd873, 11'd932, 7'd15};
                11'd956: window_bounds = {11'd874, 11'd932, 7'd16};
                11'd957: window_bounds = {11'd875, 11'd933, 7'd17};
                11'd958: window_bounds = {11'd875, 11'd934, 7'd17};
                11'd959: window_bounds = {11'd876, 11'd935, 7'd18};
                11'd960: window_bounds = {11'd877, 11'd936, 7'd19};
                11'd961: window_bounds = {11'd878, 11'd937, 7'd20};
                11'd962: window_bounds = {11'd878, 11'd937, 7'd20};
                11'd963: window_bounds = {11'd879, 11'd938, 7'd21};
                11'd964: window_bounds = {11'd880, 11'd939, 7'd22};
                11'd965: window_bounds = {11'd881, 11'd940, 7'd23};
                11'd966: window_bounds = {11'd881, 11'd941, 7'd23};
                11'd967: window_bounds = {11'd882, 11'd942, 7'd24};
                11'd968: window_bounds = {11'd883, 11'd942, 7'd25};
                11'd969: window_bounds = {11'd884, 11'd943, 7'd26};
                11'd970: window_bounds = {11'd884, 11'd944, 7'd26};
                11'd971: window_bounds = {11'd885, 11'd945, 7'd27};
                11'd972: window_bounds = {11'd886, 11'd946, 7'd28};
                11'd973: window_bounds = {11'd887, 11'd946, 7'd29};
                11'd974: window_bounds = {11'd887, 11'd947, 7'd29};
                11'd975: window_bounds = {11'd888, 11'd948, 7'd30};
                11'd976: window_bounds = {11'd889, 11'd949, 7'd31};
                11'd977: window_bounds = {11'd890, 11'd950, 7'd32};
                11'd978: window_bounds = {11'd890, 11'd950, 7'd32};
                11'd979: window_bounds = {11'd891, 11'd951, 7'd33};
                11'd980: window_bounds = {11'd892, 11'd952, 7'd34};
                11'd981: window_bounds = {11'd893, 11'd953, 7'd35};
                11'd982: window_bounds = {11'd893, 11'd954, 7'd35};
                11'd983: window_bounds = {11'd894, 11'd954, 7'd36};
                11'd984: window_bounds = {11'd895, 11'd955, 7'd37};
                11'd985: window_bounds = {11'd896, 11'd956, 7'd38};
                11'd986: window_bounds = {11'd896, 11'd957, 7'd38};
                11'd987: window_bounds = {11'd897, 11'd958, 7'd39};
                11'd988: window_bounds = {11'd898, 11'd959, 7'd40};
                11'd989: window_bounds = {11'd899, 11'd959, 7'd41};
                11'd990: window_bounds = {11'd899, 11'd960, 7'd41};
                11'd991: window_bounds = {11'd900, 11'd961, 7'd42};
                11'd992: window_bounds = {11'd901, 11'd962, 7'd43};
                11'd993: window_bounds = {11'd902, 11'd963, 7'd44};
                11'd994: window_bounds = {11'd902, 11'd963, 7'd44};
                11'd995: window_bounds = {11'd903, 11'd964, 7'd45};
                11'd996: window_bounds = {11'd904, 11'd965, 7'd46};
                11'd997: window_bounds = {11'd905, 11'd966, 7'd47};
                11'd998: window_bounds = {11'd905, 11'd966, 7'd47};
                11'd999: window_bounds = {11'd906, 11'd967, 7'd48};
                11'd1000: window_bounds = {11'd907, 11'd968, 7'd49};
                11'd1001: window_bounds = {11'd908, 11'd969, 7'd50};
                11'd1002: window_bounds = {11'd908, 11'd970, 7'd50};
                11'd1003: window_bounds = {11'd909, 11'd970, 7'd51};
                11'd1004: window_bounds = {11'd910, 11'd971, 7'd52};
                11'd1005: window_bounds = {11'd911, 11'd972, 7'd53};
                11'd1006: window_bounds = {11'd911, 11'd973, 7'd53};
                11'd1007: window_bounds = {11'd912, 11'd974, 7'd54};
                11'd1008: window_bounds = {11'd913, 11'd974, 7'd55};
                11'd1009: window_bounds = {11'd914, 11'd975, 7'd56};
                11'd1010: window_bounds = {11'd914, 11'd976, 7'd56};
                11'd1011: window_bounds = {11'd915, 11'd977, 7'd57};
                11'd1012: window_bounds = {11'd916, 11'd977, 7'd58};
                11'd1013: window_bounds = {11'd916, 11'd978, 7'd58};
                11'd1014: window_bounds = {11'd917, 11'd979, 7'd59};
                11'd1015: window_bounds = {11'd918, 11'd980, 7'd60};
                11'd1016: window_bounds = {11'd919, 11'd981, 7'd61};
                11'd1017: window_bounds = {11'd919, 11'd981, 7'd61};
                11'd1018: window_bounds = {11'd920, 11'd982, 7'd62};
                11'd1019: window_bounds = {11'd921, 11'd983, 7'd63};
                11'd1020: window_bounds = {11'd922, 11'd984, 7'd64};
                11'd1021: window_bounds = {11'd922, 11'd985, 7'd64};
                11'd1022: window_bounds = {11'd923, 11'd985, 7'd65};
                11'd1023: window_bounds = {11'd924, 11'd986, 7'd0};
                11'd1024: window_bounds = {11'd925, 11'd987, 7'd1};
                11'd1025: window_bounds = {11'd925, 11'd988, 7'd1};
                11'd1026: window_bounds = {11'd926, 11'd988, 7'd2};
                11'd1027: window_bounds = {11'd927, 11'd989, 7'd3};
                11'd1028: window_bounds = {11'd928, 11'd990, 7'd4};
                11'd1029: window_bounds = {11'd928, 11'd991, 7'd4};
                11'd1030: window_bounds = {11'd929, 11'd992, 7'd5};
                11'd1031: window_bounds = {11'd930, 11'd992, 7'd6};
                11'd1032: window_bounds = {11'd930, 11'd993, 7'd6};
                11'd1033: window_bounds = {11'd931, 11'd994, 7'd7};
                11'd1034: window_bounds = {11'd932, 11'd995, 7'd8};
                11'd1035: window_bounds = {11'd933, 11'd995, 7'd9};
                11'd1036: window_bounds = {11'd933, 11'd996, 7'd9};
                11'd1037: window_bounds = {11'd934, 11'd997, 7'd10};
                11'd1038: window_bounds = {11'd935, 11'd998, 7'd11};
                11'd1039: window_bounds = {11'd936, 11'd998, 7'd12};
                11'd1040: window_bounds = {11'd936, 11'd999, 7'd12};
                11'd1041: window_bounds = {11'd937, 11'd1000, 7'd13};
                11'd1042: window_bounds = {11'd938, 11'd1001, 7'd14};
                11'd1043: window_bounds = {11'd939, 11'd1001, 7'd15};
                11'd1044: window_bounds = {11'd939, 11'd1002, 7'd15};
                11'd1045: window_bounds = {11'd940, 11'd1003, 7'd16};
                11'd1046: window_bounds = {11'd941, 11'd1004, 7'd17};
                11'd1047: window_bounds = {11'd942, 11'd1004, 7'd18};
                11'd1048: window_bounds = {11'd942, 11'd1005, 7'd18};
                11'd1049: window_bounds = {11'd943, 11'd1006, 7'd19};
                11'd1050: window_bounds = {11'd944, 11'd1007, 7'd20};
                11'd1051: window_bounds = {11'd944, 11'd1007, 7'd20};
                11'd1052: window_bounds = {11'd945, 11'd1008, 7'd21};
                11'd1053: window_bounds = {11'd946, 11'd1009, 7'd22};
                11'd1054: window_bounds = {11'd947, 11'd1010, 7'd23};
                11'd1055: window_bounds = {11'd947, 11'd1011, 7'd23};
                11'd1056: window_bounds = {11'd948, 11'd1011, 7'd24};
                11'd1057: window_bounds = {11'd949, 11'd1012, 7'd25};
                11'd1058: window_bounds = {11'd950, 11'd1013, 7'd26};
                11'd1059: window_bounds = {11'd950, 11'd1013, 7'd26};
                11'd1060: window_bounds = {11'd951, 11'd1014, 7'd27};
                11'd1061: window_bounds = {11'd952, 11'd1015, 7'd28};
                11'd1062: window_bounds = {11'd952, 11'd1016, 7'd28};
                11'd1063: window_bounds = {11'd953, 11'd1016, 7'd29};
                11'd1064: window_bounds = {11'd954, 11'd1017, 7'd30};
                11'd1065: window_bounds = {11'd955, 11'd1018, 7'd31};
                11'd1066: window_bounds = {11'd955, 11'd1019, 7'd31};
                11'd1067: window_bounds = {11'd956, 11'd1019, 7'd32};
                11'd1068: window_bounds = {11'd957, 11'd1020, 7'd33};
                11'd1069: window_bounds = {11'd958, 11'd1021, 7'd34};
                11'd1070: window_bounds = {11'd958, 11'd1022, 7'd34};
                11'd1071: window_bounds = {11'd959, 11'd1022, 7'd35};
                11'd1072: window_bounds = {11'd960, 11'd1023, 7'd36};
                11'd1073: window_bounds = {11'd961, 11'd1024, 7'd37};
                11'd1074: window_bounds = {11'd961, 11'd1025, 7'd37};
                11'd1075: window_bounds = {11'd962, 11'd1025, 7'd38};
                11'd1076: window_bounds = {11'd963, 11'd1026, 7'd39};
                11'd1077: window_bounds = {11'd963, 11'd1027, 7'd39};
                11'd1078: window_bounds = {11'd964, 11'd1028, 7'd40};
                11'd1079: window_bounds = {11'd965, 11'd1028, 7'd41};
                default: window_bounds = {11'd0, 11'd1, 7'd0};
            endcase
        end
    endfunction


    // The maximum required source line is monotonic. Store only whether it
    // advances on each output-line transition instead of synthesizing the
    // 1080-entry, 29-bit case table as a large combinational mux. Transition
    // 563->564 is the only two-line advance and is handled separately.
    localparam [1078:0] MAX_Y_STEP_GE1 = 1079'h3BBBBB7BBBBBBDDEF77BDDEFBDEF7DF7DF7DFBEFDFBF7F7F7F7FBFDFEFFDFFBFFBFFDFFFBFFFDFFFFBFFFFFEFFFFFFFFBFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBBFBDF7DEF7DF7BEF7DEFBDEFBDF7BDF7BDEFBDEF7BDF7BDEF77DDEF7BDEEF7BDDEF77BBDDEEF77BBBDDDEEEF77777777BBBBBBBBBBBB77777776EEEEDDDDBBBB7776EEDDDBBBB;
    wire [1:0] next_max_y_step = (output_y == 11'd563)
                                   ? 2'd2
                                   : {1'b0, MAX_Y_STEP_GE1[output_y]};
    wire ddr_rd_active = rd_active_sync[1];
    wire ddr_rd_fsync = rd_fsync_sync[1];
    wire ddr_frame_start = !ddr_rd_fsync_d && ddr_rd_fsync;
    wire [ADDR_WIDTH-1:0] selected_frame_base =
        {{(ADDR_WIDTH-LINE_ADDR_WIDTH-2){1'b0}}, frame_sel,
         {LINE_ADDR_WIDTH{1'b0}}};
    // If input and output frame boundaries land on the same DDR clock edge,
    // frame_sel still contains the old display bank until the nonblocking
    // assignment below takes effect.  Expose the bank being selected during
    // that edge so the writer cannot choose it as its next destination.
    assign display_frame_bank = ddr_frame_start ? completed_frame_bank :
                                (frame_restart_pending ? pending_frame_sel : frame_sel);

    always @(posedge ddr_clk) begin
        if (!ddr_rstn) begin
            req_state <= 0;
            ddr_rreq <= 1'b0;
            ddr_raddr <= 'd0;
            load_y <= 0;
            load_slot <= 0;
            output_y <= 0;
            target_max_y <= 0;
            frame_sel <= 0;
            pending_frame_sel <= 0;
            frame_restart_pending <= 0;
            rd_active_sync <= 2'b00;
            rd_fsync_sync <= 2'b00;
            ddr_rd_active_d <= 0;
            ddr_rd_fsync_d <= 0;
            beat_count <= 0;
            previous_beat <= 0;
            flush_pending <= 0;
            cache_wr_en <= 0;
            cache_wr_line_done <= 0;
            cache_prefill_ready <= 0;
        end else begin
            ddr_rreq <= 1'b0;
            cache_wr_en <= 1'b0;
            cache_wr_line_done <= 1'b0;
            // rd_fsync/rd_active originate in the 148.5 MHz video domain.
            // Synchronize these level signals before edge detection at the
            // 100 MHz DDR clock to prevent metastability and duplicate/missed
            // frame or line transitions.
            rd_active_sync <= {rd_active_sync[0], rd_active};
            rd_fsync_sync <= {rd_fsync_sync[0], rd_fsync};
            ddr_rd_active_d <= ddr_rd_active;
            ddr_rd_fsync_d <= ddr_rd_fsync;

            if (ddr_frame_start) begin
                // Do not abort an in-flight line transaction. The command
                // adapter can report ready after issuing its final AXI burst,
                // before all returned data has reached this module. Abruptly
                // clearing req_state here could count tail data from the old
                // frame as the first line of the new frame.
                pending_frame_sel <= completed_frame_bank;
                frame_restart_pending <= 1'b1;
                cache_prefill_ready <= 1'b0;
            end else if (frame_restart_pending && req_state == 0 &&
                         !flush_pending && !cache_wr_en && !cache_wr_line_done) begin
                // The old DDR transaction and its delayed final cache write
                // are complete. Now switch banks and begin a clean prefetch.
                frame_sel <= pending_frame_sel;
                frame_restart_pending <= 1'b0;
                output_y <= 0;
                load_y <= 11'd63;
                target_max_y <= 11'd125;
                load_slot <= 7'd63;
            end else if (ddr_rd_active_d && !ddr_rd_active && output_y < V_NUM-1) begin
                output_y <= output_y + 1'b1;
                target_max_y <= target_max_y + next_max_y_step;
            end

            if (req_state == 0 && !frame_restart_pending && !ddr_frame_start &&
                init_done && load_y <= target_max_y && ddr_rrdy) begin
                req_state <= 1;
                req_line <= load_y;
                req_slot <= load_slot;
                beat_count <= 0;
                ddr_raddr <= ADDR_OFFSET + selected_frame_base +
                             load_y * LINE_WORDS * 8 + CACHE_X_WORD_FIRST * 8;
                ddr_rreq <= 1'b1;
            end else if (req_state == 1 && ddr_rdone) begin
                req_state <= 0;
                load_y <= load_y + 1'b1;
                load_slot <= (load_slot == CACHE_LINES-1) ? 7'd0 : load_slot + 1'b1;
            end

            if (ddr_rdata_en && req_state == 1) begin
                if (beat_count != 0) begin
                    cache_wr_en <= 1'b1;
                    cache_wr_bank <= req_line[0];
                    cache_wr_half <= req_slot[6] | req_slot[5];
                    cache_wr_slot <= req_slot;
                    cache_wr_line <= req_line;
                    cache_wr_line_done <= 1'b0;
                    cache_wr_addr <= (req_slot[6] ? 5'd16 : {1'b0, req_slot[4:1]}) *
                                     CACHE_LINE_WORDS + beat_count - 1'b1;
                    // The line-buffer RAM maps its lowest write address to
                    // ddr_rdata[15:0], so pixels advance from LSB to MSB in
                    // each DDR beat.  Append the first pixel of the next beat
                    // above the previous beat to provide the x+1 sample at a
                    // 256-bit boundary.
                    cache_wr_data <= {ddr_rdata[15:0], previous_beat};
                end
                previous_beat <= ddr_rdata;
                if (beat_count == CACHE_LINE_WORDS-1) begin
                    flush_pending <= 1'b1;
                    flush_beat <= ddr_rdata;
                    flush_slot <= req_slot;
                    flush_line <= req_line;
                    flush_bank <= req_line[0];
                    flush_half <= req_slot[6] | req_slot[5];
                end else
                    beat_count <= beat_count + 1'b1;
            end else if (flush_pending) begin
                cache_wr_en <= 1'b1;
                cache_wr_bank <= flush_bank;
                cache_wr_half <= flush_half;
                cache_wr_slot <= flush_slot;
                cache_wr_line <= flush_line;
                cache_wr_line_done <= 1'b1;
                cache_wr_addr <= (flush_slot[6] ? 5'd16 : {1'b0, flush_slot[4:1]}) *
                                 CACHE_LINE_WORDS + CACHE_LINE_WORDS-1;
                // The last cached word never needs data beyond the fetched
                // range for this calibration.  Duplicate its last pixel so
                // an accidental boundary interpolation still stays in-range.
                cache_wr_data <= {flush_beat[255:240], flush_beat};
                flush_pending <= 1'b0;
            end

            if (cache_wr_en) begin
                if (cache_wr_bank && cache_wr_half)
                    cache_odd_hi[cache_wr_addr] <= cache_wr_data;
                else if (cache_wr_bank)
                    cache_odd_lo[cache_wr_addr] <= cache_wr_data;
                else if (cache_wr_half)
                    cache_even_hi[cache_wr_addr] <= cache_wr_data;
                else
                    cache_even_lo[cache_wr_addr] <= cache_wr_data;

                if (cache_wr_line_done) begin
                    // Output line zero needs source lines 63 through 125.
                    // Only release the pixel pipeline after line 125 has been
                    // committed, not merely after its DDR request completed.
                    if (cache_wr_line == 11'd125 &&
                        !frame_restart_pending && !ddr_frame_start)
                        cache_prefill_ready <= 1'b1;
                end
            end
        end
    end

    reg [11:0] x_count;
    reg [10:0] y_count;
    reg signed [23:0] xn_acc_q22, yn_acc_q22;
    reg signed [16:0] xn0, yn0, xn1, yn1, xn2, yn2, xn3, yn3, xn4, yn4, xn4a, yn4a;
    reg signed [33:0] x_sq1, y_sq1;
    reg signed [17:0] r20, r2_d3, r40, k1_term4, k2_term4, scale1;
    reg signed [17:0] xdist3, ydist3;
    reg signed [31:0] xsrc2, ysrc2;
    reg [10:0] src_x0, src_y0;
    reg [3:0]  src_x_mod0;
    reg [4:0]  frac_x0, frac_y0;
    reg pix_rd_active_d, pix_rd_fsync_d;
    reg v0, v1, v2, v3, v4, v4a, v5, v6, v7, v7a, v7b, v8, v9, v10, v11, v12, v13;
    reg [6:0] cache_slot0;
    reg [10:0] cache_src_x0;
    reg [10:0] cache_src_y0;
    reg [3:0] cache_src_x_mod0;
    reg [4:0] cache_frac_x0, cache_frac_y0;
    reg [10:0] cache_even_addr, cache_odd_addr;
    reg        addr_even_hi, addr_odd_hi, addr_y_odd;
    reg [3:0]  addr_x_mod;
    reg [4:0]  addr_fx, addr_fy;
    reg [CACHE_WORD_WIDTH-1:0] even_lo_word, even_hi_word;
    reg [CACHE_WORD_WIDTH-1:0] odd_lo_word, odd_hi_word;
    reg [CACHE_WORD_WIDTH-1:0] even_word, odd_word;
    reg [3:0] read_x_mod;
    reg [4:0] read_fx, read_fy;
    reg       read_y_odd;
    reg       read_even_hi, read_odd_hi;
    reg [3:0] select_x_mod;
    reg [4:0] select_fx, select_fy;
    reg       select_y_odd;
    reg [15:0] p00, p01, p10, p11;
    reg [4:0] interp_fx, interp_fy, interp_fy_d;
    reg [6:0] hr0, hg0, hb0, hr1, hg1, hb1;
    reg [4:0] nearest_r0, nearest_r1, nearest_b0, nearest_b1;
    reg [5:0] nearest_g0, nearest_g1;
    reg [12:0] vr0_prod, vr1_prod, vg0_prod, vg1_prod, vb0_prod, vb1_prod;
    reg [6:0] vr, vg, vb;
    reg frame_cache_valid;

    // init_done is generated in the DDR clock domain. Reset assertion may be
    // asynchronous, but both readiness signals are released through these
    // two pixel-clocked stages before the output pipeline starts.
    reg [1:0] vout_ready_sync;
    reg [1:0] cache_ready_sync;
    always @(posedge vout_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            vout_ready_sync <= 2'b00;
            cache_ready_sync <= 2'b00;
        end else begin
            vout_ready_sync <= {vout_ready_sync[0], init_done};
            cache_ready_sync <= {cache_ready_sync[0], cache_prefill_ready};
        end
    end
    // Cache readiness is deliberately not part of the pipeline reset. It is
    // cleared once per frame while the first source rows are fetched. If a
    // prefetch ever runs late, resetting the x/y accumulators in active video
    // would restart the mapping in the middle of a physical line.
    wire vout_pipeline_ready = vout_ready_sync[1];

    wire [5:0] inv_interp_fx = 6'd32 - {1'b0, interp_fx};
    wire [5:0] inv_interp_fy = 6'd32 - {1'b0, interp_fy_d};

    // Verilog multiplication otherwise inherits the operand width. Preserve
    // the complete product before the Q14 shift; truncating it here changes
    // the distortion curve rather than merely reducing precision.
    function automatic signed [33:0] mul17x17;
        input signed [16:0] a;
        input signed [16:0] b;
        reg signed [33:0] a_wide;
        begin
            a_wide = a;
            mul17x17 = a_wide * b;
        end
    endfunction

    function automatic signed [35:0] mul18x18;
        input signed [17:0] a;
        input signed [17:0] b;
        reg signed [35:0] a_wide;
        begin
            a_wide = a;
            mul18x18 = a_wide * b;
        end
    endfunction

    function automatic signed [35:0] mul17x18;
        input signed [16:0] a;
        input signed [17:0] b;
        reg signed [35:0] a_wide;
        begin
            a_wide = a;
            mul17x18 = a_wide * b;
        end
    endfunction

    // Eleven bits hold the largest weighted RGB565 channel sum
    // (63 * 32 = 2016). Explicitly widening each color operand prevents the
    // bilinear products from being evaluated at only 6 or 7 bits.
    wire [10:0] h_r0_sum = {6'd0, p00[15:11]} * inv_interp_fx +
                           {6'd0, p01[15:11]} * {1'b0, interp_fx};
    wire [10:0] h_g0_sum = {5'd0, p00[10:5]}  * inv_interp_fx +
                           {5'd0, p01[10:5]}  * {1'b0, interp_fx};
    wire [10:0] h_b0_sum = {6'd0, p00[4:0]}   * inv_interp_fx +
                           {6'd0, p01[4:0]}   * {1'b0, interp_fx};
    wire [10:0] h_r1_sum = {6'd0, p10[15:11]} * inv_interp_fx +
                           {6'd0, p11[15:11]} * {1'b0, interp_fx};
    wire [10:0] h_g1_sum = {5'd0, p10[10:5]}  * inv_interp_fx +
                           {5'd0, p11[10:5]}  * {1'b0, interp_fx};
    wire [10:0] h_b1_sum = {6'd0, p10[4:0]}   * inv_interp_fx +
                           {6'd0, p11[4:0]}   * {1'b0, interp_fx};
    // Register both vertical products before adding them.  Without this
    // boundary PDS cascades two APM multipliers and an adder in one 6.734 ns
    // pixel-clock period, which fails timing at 148.5 MHz.
    wire [13:0] v_r_sum = {1'b0, vr0_prod} + {1'b0, vr1_prod};
    wire [13:0] v_g_sum = {1'b0, vg0_prod} + {1'b0, vg1_prod};
    wire [13:0] v_b_sum = {1'b0, vb0_prod} + {1'b0, vb1_prod};

    function automatic signed [31:0] scale_fx;
        input signed [31:0] value;
        begin
            scale_fx = (value <<< 9) + (value <<< 8) + (value <<< 5) +
                       (value <<< 4) + (value <<< 3) + (value <<< 1);
        end
    endfunction

    function automatic signed [31:0] scale_fy;
        input signed [31:0] value;
        begin
            scale_fy = (value <<< 9) + (value <<< 8) + (value <<< 5) +
                       (value <<< 4) + (value <<< 3) + (value <<< 1) + value;
        end
    endfunction

    // For 0 <= y < 1080, floor(y/66) = (y*993)>>16 exactly.
    wire [20:0] slot_product = src_y0 * 10'd993;
    wire [4:0] slot_quotient = slot_product[20:16];
    wire [10:0] slot_remainder = src_y0 - (slot_quotient << 6) - (slot_quotient << 1);
    wire [6:0] next_cache_slot = (cache_slot0 == CACHE_LINES-1) ? 7'd0 : cache_slot0 + 1'b1;
    wire [6:0] cache_x_word = (cache_src_x0 >> 4) - CACHE_X_WORD_FIRST;
    wire [6:0] even_read_slot = cache_slot0[0] ? next_cache_slot : cache_slot0;
    wire [6:0] odd_read_slot  = cache_slot0[0] ? cache_slot0 : next_cache_slot;
    wire [4:0] even_local_row = even_read_slot[6] ? 5'd16 : {1'b0, even_read_slot[4:1]};
    wire [4:0] odd_local_row  = odd_read_slot[6] ? 5'd16 : {1'b0, odd_read_slot[4:1]};
    wire [10:0] even_read_addr = even_local_row * CACHE_LINE_WORDS + cache_x_word;
    wire [10:0] odd_read_addr  = odd_local_row * CACHE_LINE_WORDS + cache_x_word;

    always @(posedge vout_clk) begin
        if (!vout_pipeline_ready) begin
            x_count <= 0; y_count <= 0; pix_rd_active_d <= 0; pix_rd_fsync_d <= 0;
            frame_cache_valid <= 1'b0;
            xn_acc_q22 <= XN_START_Q22;
            yn_acc_q22 <= YN_START_Q22;
            v0 <= 0; v1 <= 0; v2 <= 0; v3 <= 0; v4 <= 0; v4a <= 0; v5 <= 0;
            v6 <= 0; v7 <= 0; v7a <= 0; v7b <= 0; v8 <= 0; v9 <= 0; v10 <= 0; v11 <= 0; v12 <= 0; v13 <= 0;
            vout_de <= 0; vout_data <= 0;
        end else begin
            pix_rd_active_d <= rd_active;
            pix_rd_fsync_d <= rd_fsync;
            if (rd_fsync && !pix_rd_fsync_d) begin
                x_count <= 0;
                y_count <= 0;
                xn_acc_q22 <= XN_START_Q22;
                yn_acc_q22 <= YN_START_Q22;
            end else if (rd_en) begin
                if (x_count < H_NUM-1) begin
                    x_count <= x_count + 1'b1;
                    xn_acc_q22 <= xn_acc_q22 + XN_STEP_Q22;
                end else begin
                    x_count <= 0;
                    xn_acc_q22 <= XN_START_Q22;
                end
            end else if (pix_rd_active_d && !rd_active) begin
                if (y_count < V_NUM-1) begin
                    y_count <= y_count + 1'b1;
                    yn_acc_q22 <= yn_acc_q22 + YN_STEP_Q22;
                end
            end

            // Commit the first complete cache before enabling pixels. Once a
            // valid frame has been displayed, keep it during a late prefetch
            // instead of inserting a black frame at every output VSYNC. The
            // cache writer still advances only on complete source-line writes.
            if (!frame_cache_valid && rd_active && !pix_rd_active_d && y_count == 0)
                frame_cache_valid <= cache_ready_sync[1];

            v0 <= rd_en;
            xn0 <= xn_acc_q22 >>> 8;
            yn0 <= yn_acc_q22 >>> 8;
            v1 <= v0;
            xn1 <= xn0;
            yn1 <= yn0;
            x_sq1 <= mul17x17(xn0, xn0);
            y_sq1 <= mul17x17(yn0, yn0);

            v2 <= v1;
            xn2 <= xn1;
            yn2 <= yn1;
            r20 <= (x_sq1 + y_sq1) >>> FRAC_BITS;

            v3 <= v2;
            xn3 <= xn2;
            yn3 <= yn2;
            r2_d3 <= r20;
            r40 <= mul18x18(r20, r20) >>> FRAC_BITS;

            v4 <= v3;
            xn4 <= xn3;
            yn4 <= yn3;
            k1_term4 <= mul18x18(K1_Q14, r2_d3) >>> FRAC_BITS;
            k2_term4 <= mul18x18(K2_Q14, r40) >>> FRAC_BITS;

            v4a <= v4;
            xn4a <= xn4;
            yn4a <= yn4;
            scale1 <= (1 <<< FRAC_BITS) + k1_term4 + k2_term4;

            v5 <= v4a;
            xdist3 <= mul17x18(xn4a, scale1) >>> FRAC_BITS;
            ydist3 <= mul17x18(yn4a, scale1) >>> FRAC_BITS;

            v6 <= v5;
            xsrc2 <= scale_fx(xdist3) + CX_Q14;
            ysrc2 <= scale_fy(ydist3) + CY_Q14;

            v7 <= v6;
            if ((xsrc2 >>> FRAC_BITS) <= 1) begin src_x0 <= 0; src_x_mod0 <= 0; frac_x0 <= 0; end
            else if ((xsrc2 >>> FRAC_BITS) >= H_NUM) begin src_x0 <= H_NUM-1; src_x_mod0 <= (H_NUM-1) & 4'hf; frac_x0 <= 0; end
            else begin src_x0 <= (xsrc2 >>> FRAC_BITS) - 1; src_x_mod0 <= ((xsrc2 >>> FRAC_BITS) - 1) & 4'hf; frac_x0 <= xsrc2[FRAC_BITS-1 -: 5]; end
            if ((ysrc2 >>> FRAC_BITS) <= 1) begin src_y0 <= 0; frac_y0 <= 0; end
            else if ((ysrc2 >>> FRAC_BITS) >= V_NUM) begin src_y0 <= V_NUM-1; frac_y0 <= 0; end
            else begin src_y0 <= (ysrc2 >>> FRAC_BITS) - 1; frac_y0 <= ysrc2[FRAC_BITS-1 -: 5]; end

            v7a <= v7;
            cache_slot0 <= slot_remainder[6:0];
            cache_src_x0 <= src_x0;
            cache_src_y0 <= src_y0;
            cache_src_x_mod0 <= src_x_mod0;
            cache_frac_x0 <= frac_x0;
            cache_frac_y0 <= frac_y0;

            // Register the complete RAM addresses. This separates modulo-66
            // wrap/high-half selection from the DRM18K address input path.
            v7b <= v7a;
            cache_even_addr <= even_read_addr;
            cache_odd_addr <= odd_read_addr;
            addr_even_hi <= even_read_slot[6] | even_read_slot[5];
            addr_odd_hi <= odd_read_slot[6] | odd_read_slot[5];
            addr_y_odd <= cache_slot0[0];
            addr_x_mod <= cache_src_x_mod0;
            addr_fx <= cache_frac_x0;
            addr_fy <= cache_frac_y0;

            even_lo_word <= cache_even_lo[cache_even_addr];
            even_hi_word <= cache_even_hi[cache_even_addr];
            odd_lo_word <= cache_odd_lo[cache_odd_addr];
            odd_hi_word <= cache_odd_hi[cache_odd_addr];
            read_even_hi <= addr_even_hi;
            read_odd_hi <= addr_odd_hi;
            read_y_odd <= addr_y_odd;
            read_x_mod <= addr_x_mod;
            read_fx <= addr_fx;
            read_fy <= addr_fy;
            // Every rd_en must produce exactly one output-valid pulse. The
            // scaler treats each pulse as the next x coordinate, so dropping
            // one would shift every following pixel to the right.
            v8 <= v7b;

            v9 <= v8;
            even_word <= read_even_hi ? even_hi_word : even_lo_word;
            odd_word <= read_odd_hi ? odd_hi_word : odd_lo_word;
            select_y_odd <= read_y_odd;
            select_x_mod <= read_x_mod;
            select_fx <= read_fx;
            select_fy <= read_fy;

            v10 <= v9;
            interp_fx <= select_fx;
            interp_fy <= select_fy;
            if (select_y_odd) begin
                p00 <= pixel_at(odd_word, {1'b0, select_x_mod});
                p01 <= pixel_at(odd_word, {1'b0, select_x_mod} + 1'b1);
                p10 <= pixel_at(even_word, {1'b0, select_x_mod});
                p11 <= pixel_at(even_word, {1'b0, select_x_mod} + 1'b1);
            end else begin
                p00 <= pixel_at(even_word, {1'b0, select_x_mod});
                p01 <= pixel_at(even_word, {1'b0, select_x_mod} + 1'b1);
                p10 <= pixel_at(odd_word, {1'b0, select_x_mod});
                p11 <= pixel_at(odd_word, {1'b0, select_x_mod} + 1'b1);
            end

            v11 <= v10;
            interp_fy_d <= interp_fy;
            hr0 <= h_r0_sum >> 5;
            hg0 <= h_g0_sum >> 5;
            hb0 <= h_b0_sum >> 5;
            hr1 <= h_r1_sum >> 5;
            hg1 <= h_g1_sum >> 5;
            hb1 <= h_b1_sum >> 5;
            // Nearest-neighbor uses the closest source sample instead of
            // averaging four taps. Keep it in the same pipeline stage so
            // DE/HS/VS latency does not change when comparing modes.
            if (interp_fx < 5'd16) begin
                nearest_r0 <= p00[15:11];
                nearest_g0 <= p00[10:5];
                nearest_b0 <= p00[4:0];
                nearest_r1 <= p10[15:11];
                nearest_g1 <= p10[10:5];
                nearest_b1 <= p10[4:0];
            end else begin
                nearest_r0 <= p01[15:11];
                nearest_g0 <= p01[10:5];
                nearest_b0 <= p01[4:0];
                nearest_r1 <= p11[15:11];
                nearest_g1 <= p11[10:5];
                nearest_b1 <= p11[4:0];
            end

            v12 <= v11;
            if (INTERPOLATION_MODE == 0) begin
                vr0_prod <= {6'd0, hr0} * inv_interp_fy;
                vr1_prod <= {6'd0, hr1} * {1'b0, interp_fy_d};
                vg0_prod <= {6'd0, hg0} * inv_interp_fy;
                vg1_prod <= {6'd0, hg1} * {1'b0, interp_fy_d};
                vb0_prod <= {6'd0, hb0} * inv_interp_fy;
                vb1_prod <= {6'd0, hb1} * {1'b0, interp_fy_d};
            end else if (interp_fy_d < 5'd16) begin
                vr0_prod <= {nearest_r0, 5'd0};
                vr1_prod <= 13'd0;
                vg0_prod <= {nearest_g0, 5'd0};
                vg1_prod <= 13'd0;
                vb0_prod <= {nearest_b0, 5'd0};
                vb1_prod <= 13'd0;
            end else begin
                vr0_prod <= {nearest_r1, 5'd0};
                vr1_prod <= 13'd0;
                vg0_prod <= {nearest_g1, 5'd0};
                vg1_prod <= 13'd0;
                vb0_prod <= {nearest_b1, 5'd0};
                vb1_prod <= 13'd0;
            end

            v13 <= v12;
            vr <= v_r_sum >> 5;
            vg <= v_g_sum >> 5;
            vb <= v_b_sum >> 5;

            vout_de <= v13;
            // A late prefetch produces deterministic black pixels while line
            // length and coordinate phase remain intact. Normally this flag
            // becomes true during vertical blanking, before active video.
            vout_data <= frame_cache_valid
                       ? {vr[4:0], vg[5:0], vb[4:0]}
                       : 16'h0000;
        end
    end

    function automatic [15:0] pixel_at;
        input [CACHE_WORD_WIDTH-1:0] word;
        input [4:0] index;
        begin
            pixel_at = word[index*16 +: 16];
        end
    endfunction

    assign ddr_rd_len = CACHE_LINE_WORDS;

endmodule

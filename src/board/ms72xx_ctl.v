`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:Meyesemi 
// Engineer: Will
// 
// Create Date: 2023-01-29 20:31  
// Design Name:  
// Module Name: 
// Project Name: 
// Target Devices: Pango
// Tool Versions: 
// Description: 
//      
// Dependencies: 
// 
// Revision:
// Revision 1.0 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
// ============================================================================
// ms72xx_ctl.v：MS7200（接收端）和 MS7210（发送端）配置总控
// 两个芯片分别由各自的控制器产生寄存器访问请求，再连接到独立的 iic_dir。
// 本模块还负责将外部复位同步到 cfg_clk 域，并把 SDA 实现为开漏三态接口。
// init_over 取自 MS7210 控制器，用于指示发送端初始化结束。
// ============================================================================
`define UD #1
module ms72xx_ctl(
    input       clk,
    input       rst_n,
    
    output      init_over,
    output      iic_tx_scl,
    inout       iic_tx_sda,
    output      iic_scl,
    inout       iic_sda
);
    // 复位同步寄存器，避免异步复位释放造成亚稳态
    reg rstn_temp1,rstn_temp2;
    reg rstn;
    always @(posedge clk or negedge rst_n)
    begin
    	if(!rst_n)
    	    rstn_temp1 <= 1'b0;
    	else
    	    rstn_temp1 <= rst_n;
    end
    
    always @(posedge clk)
    begin
    	rstn_temp2 <= rstn_temp1;
    	rstn <= rstn_temp2;
    end
    
    wire         init_over_rx;
    wire   [7:0] device_id_rx;
    wire         iic_trig_rx ;
    wire         w_r_rx      ;
    wire  [15:0] addr_rx     /*synthesis PAP_MARK_DEBUG="true"*/;
    wire  [ 7:0] data_in_rx  ;
    wire         busy_rx     ;
    wire  [ 7:0] data_out_rx ;
    wire         byte_over_rx;
    
    wire   [7:0] device_id_tx;
    wire         iic_trig_tx ;
    wire         w_r_tx      ;
    wire  [15:0] addr_tx     /*synthesis PAP_MARK_DEBUG="true"*/;
    wire  [ 7:0] data_in_tx  ;
    wire         busy_tx     ;
    wire  [ 7:0] data_out_tx ;
    wire         byte_over_tx;
    
//    wire   [7:0] device_id   ;
//    wire         iic_trig    ;
//    wire         w_r         ;
//    wire  [15:0] addr        /*synthesis PAP_MARK_DEBUG="true"*/;
//    wire  [ 7:0] data_in     ;
//    wire         busy        ;
//    wire  [ 7:0] data_out    /*synthesis PAP_MARK_DEBUG="true"*/;
//    wire         byte_over   /*synthesis PAP_MARK_DEBUG="true"*/;

    // MS7200 接收芯片的寄存器配置控制器
    ms7200_ctl ms7200_ctl(
        .clk             (  clk           ),//input               
        .rstn            (  rstn          ),//input               
                              
        .init_over       (  init_over_rx  ),//output reg          
        .device_id       (  device_id_rx  ),//output        [7:0] 
        .iic_trig        (  iic_trig_rx   ),//output reg          
        .w_r             (  w_r_rx        ),//output reg          
        .addr            (  addr_rx       ),//output reg   [15:0] 
        .data_in         (  data_in_rx    ),//output reg   [ 7:0] 
        .busy            (  busy_rx       ),//input               
        .data_out        (  data_out_rx   ),//input        [ 7:0] 
        .byte_over       (  byte_over_rx  ) //input               
    );
    
    // MS7210 发送芯片的寄存器配置控制器
    ms7210_ctl ms7210_ctl(
        .clk             (  clk           ),//input              
        // Match the proven 06_hdmi_loop startup sequence: configure the
        // receiver first, then release the transmitter configuration state
        // machine.  Starting both I2C tables in parallel can leave the TX
        // configured before a valid input format is available.
        .rstn            (  init_over_rx  ),//input    rstn
                              
        .init_over       (  init_over     ),//output reg          
        .device_id       (  device_id_tx  ),//output        [7:0] 
        .iic_trig        (  iic_trig_tx   ),//output reg          
        .w_r             (  w_r_tx        ),//output reg          
        .addr            (  addr_tx       ),//output reg   [15:0] 
        .data_in         (  data_in_tx    ),//output reg   [ 7:0] 
        .busy            (  busy_tx       ),//input               
        .data_out        (  data_out_tx   ),//input        [ 7:0] 
        .byte_over       (  byte_over_tx  ) //input               
    );
    
//    assign device_id = (init_over_rx == 1'b1 && init_over == 1'b0) ? device_id_tx : device_id_rx;
//    assign iic_trig = (init_over_rx == 1'b1 && init_over == 1'b0) ? iic_trig_tx : iic_trig_rx;
//    assign w_r = (init_over_rx == 1'b1 && init_over == 1'b0) ? w_r_tx : w_r_rx;
//    assign addr = (init_over_rx == 1'b1 && init_over == 1'b0) ? addr_tx : addr_rx;
//    assign data_in = (init_over_rx == 1'b1 && init_over == 1'b0) ? data_in_tx : data_in_rx;
//    assign busy_tx = (init_over_rx == 1'b1 && init_over == 1'b0) ? busy : 0;
//    assign data_out_tx = (init_over_rx == 1'b1 && init_over == 1'b0) ? data_out : 0;
//    assign byte_over_tx = (init_over_rx == 1'b1 && init_over == 1'b0) ? byte_over : 0;
//    
//    assign busy_rx = (init_over_rx == 1'b0 || init_over == 1'b1) ? busy : 0;
//    assign data_out_rx = (init_over_rx == 1'b0 || init_over == 1'b1) ? data_out : 0;
//    assign byte_over_rx = (init_over_rx == 1'b0 || init_over == 1'b1) ? byte_over : 0;

    wire         sda_in/*synthesis PAP_MARK_DEBUG="true"*/;
    wire         sda_out/*synthesis PAP_MARK_DEBUG="true"*/;
    wire         sda_out_en/*synthesis PAP_MARK_DEBUG="true"*/;  
    // 接收端 I2C 主机。MS7200 使用 16 位内部寄存器地址，每次访问 1 字节。
    // device_id_rx=8'h56 是“7 位地址+写位”的旧式写法；新驱动会取 [7:1]
    // 作为真正的 7 位从机地址，并在内部自动补读写位。
    iic_dir #(
        .MAIN_CLOCK     (  10_000_000     ), // 本模块输入 clk 为 10 MHz
        .IIC_CLOCK      (  400_000        ), // I2C Fast-mode，400 kHz
        .TIME_WAIT_WIRTE(  1              ), // 写事务完成后等待 1 ms
        .ADDR_BYTE      (  2              ), // MS7200 寄存器地址为 16 位
        .ADDR_LSB_FIRST (  1              ), // 与 06_hdmi_loop 一致：寄存器地址低字节先发送
        .LEN_WIDTH      (  3              ), // byte_len 端口宽度
        .DATA_WIDTH     (  8              )
    ) iic_dir_rx(
        .clk            (  clk             ),//input                clk,
        .rstn           (  rstn            ),//input                rstn,
        .device_id      (  device_id_rx    ),//input                device_id,
        .pluse          (  iic_trig_rx     ),//input                pluse,                     //I2C transmit trigger
        .w_r            (  w_r_rx          ),//input                w_r,                       //I2C transmit direction 1:send  0:receive
        .byte_len       (  3'd1            ),//input  [LEN_WIDTH-1:0] byte_len,                //每次读写 1 字节
                   
        .addr           (  addr_rx         ),//input  [7:0]         addr,                      //I2C transmit addr
        .data_in        (  data_in_rx      ),//input  [7:0]         data_in,                   //I2C send data
                     
        .busy           (  busy_rx         ),//output reg           busy=0,                    //I2C bus status
        
        .byte_over      (  byte_over_rx    ),//output reg           byte_over=0,               //I2C byte transmit over flag               
        .data_out       (  data_out_rx     ),//output reg[7:0]      data_out,                  //I2C receive data
                                           
        .scl            (  iic_scl         ),//output               scl,
        .sda_in         (  sda_in          ),//input                sda_in,
        .sda_out        (  sda_out         ),//output   reg         sda_out=1'b1,
        .sda_out_en     (  sda_out_en      ) //output               sda_out_en
    );
    
    // 开漏 SDA：发送时驱动，读取 ACK/数据时释放总线
    assign iic_sda = sda_out_en ? sda_out : 1'bz;
    assign sda_in = iic_sda;
    
    wire         sda_tx_in/*synthesis PAP_MARK_DEBUG="true"*/;
    wire         sda_tx_out/*synthesis PAP_MARK_DEBUG="true"*/;
    wire         sda_tx_out_en/*synthesis PAP_MARK_DEBUG="true"*/;  
    // 发送端 I2C 主机。MS7210 同样使用 16 位内部寄存器地址。
    // device_id_tx=8'hB2 会被新驱动解释为 7 位地址 7'h59。
    iic_dir #(
        .MAIN_CLOCK     (  10_000_000     ),
        .IIC_CLOCK      (  400_000        ),
        .TIME_WAIT_WIRTE(  1              ),
        .ADDR_BYTE      (  2              ),
        .ADDR_LSB_FIRST (  1              ), // MS7210 原驱动同样采用低字节优先
        .LEN_WIDTH      (  3              ),
        .DATA_WIDTH     (  8              )
    ) iic_dir_tx(
        .clk            (  clk             ),//input                clk,
        .rstn           (  rstn            ),//input                rstn,
        .device_id      (  device_id_tx    ),//input                device_id,
        .pluse          (  iic_trig_tx     ),//input                pluse,                     //I2C transmit trigger
        .w_r            (  w_r_tx          ),//input                w_r,                       //I2C transmit direction 1:send  0:receive
        .byte_len       (  3'd1            ),//input  [LEN_WIDTH-1:0] byte_len,                //每次读写 1 字节
                   
        .addr           (  addr_tx         ),//input  [7:0]         addr,                      //I2C transmit addr
        .data_in        (  data_in_tx      ),//input  [7:0]         data_in,                   //I2C send data
                     
        .busy           (  busy_tx         ),//output reg           busy=0,                    //I2C bus status
        
        .byte_over      (  byte_over_tx    ),//output reg           byte_over=0,               //I2C byte transmit over flag               
        .data_out       (  data_out_tx     ),//output reg[7:0]      data_out,                  //I2C receive data
                                           
        .scl            (  iic_tx_scl      ),//output               scl,
        .sda_in         (  sda_tx_in       ),//input                sda_in,
        .sda_out        (  sda_tx_out      ),//output   reg         sda_out=1'b1,
        .sda_out_en     (  sda_tx_out_en   ) //output               sda_out_en
    );
    
    // 发送端 SDA 开漏连接
    assign iic_tx_sda = sda_tx_out_en ? sda_tx_out : 1'bz;
    assign sda_tx_in = iic_tx_sda;
//    GTP_IOBUF #(
//        .IOSTANDARD     (  "DEFAULT"      ),
//        .SLEW_RATE      (  "SLOW"         ),
//        .DRIVE_STRENGTH (  "8"            ),
//        .TERM_DDR       (  "ON"           )
//    ) GTP_IOBUF         (                 
//        .IO             (  iic_sda        ),// INOUT  
//        .O              (  sda_in         ), // OUTPUT  
//        .I              (  sda_out        ), // INPUT  
//        .T              (  sda_out_en     )  // INPUT  
//    );
    
endmodule

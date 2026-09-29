// Attitude FIFO reader, protocol packer and CP2102 UART transmitter.
module cp2102 #(
    parameter SYS_CLK_FREQ=50_000_000,
    parameter UART_CLK_FREQ=14_743_589,
    parameter BAUD_RATE=921600,
    parameter DATA_BITS=8,
    parameter PARITY="NONE",
    parameter STOP_BITS=1
) (
    input wire sys_clk_50mhz,
    input wire uart_clk,
    input wire sys_rst_n,
    input wire uart_rst_n,
    input wire [47:0] attitude_data,
    input wire attitude_empty,
    output wire attitude_rd_en,
    output wire sys_uart_tx,
    output reg tx_activity_toggle
);
    localparam [1:0] XFER_IDLE=0,
    XFER_READ=1,
    XFER_WAIT=2,
    XFER_WRITE=3;
    localparam [2:0] TX_IDLE=0,TX_FIFO_READ=1,TX_FIFO_WAIT=2,TX_SEND=3,TX_WAIT_BUSY=4,TX_WAIT_DONE=5;
    reg [1:0] xfer_current_state,xfer_next_state; reg [47:0] xfer_data;
    wire [47:0] tx_fifo_rd_data; wire tx_fifo_wr_full,tx_fifo_rd_empty,tx_fifo_almost_full,tx_fifo_almost_empty;
    wire tx_fifo_wr_en,tx_fifo_rd_en; reg [2:0] tx_current_state,tx_next_state; reg [47:0] frame_payload; reg [3:0] byte_index; reg [7:0] frame_checksum;
    wire [7:0] uart_data_tx;
     wire uart_data_valid_tx;
     wire uart_busy;
    assign attitude_rd_en=(xfer_current_state==XFER_READ); assign tx_fifo_wr_en=(xfer_current_state==XFER_WRITE)&&!tx_fifo_wr_full;
     assign tx_fifo_rd_en=(tx_current_state==TX_FIFO_READ);

    cp2102_tx_fifo u_cp2102_tx_fifo (
        .wr_clk(sys_clk_50mhz),
        .wr_rst(~sys_rst_n),
        .wr_en(tx_fifo_wr_en),
        .wr_data(xfer_data),
        .wr_full(tx_fifo_wr_full),
        .rd_clk(uart_clk),
        .rd_rst(~uart_rst_n),
        .rd_en(tx_fifo_rd_en),
        .rd_data(tx_fifo_rd_data),
        .almost_full(tx_fifo_almost_full),
        .rd_empty(tx_fifo_rd_empty),
        .almost_empty(tx_fifo_almost_empty));

    uart_tx #(
        .SYS_CLK_FREQ(SYS_CLK_FREQ),
    .UART_CLK_FREQ(UART_CLK_FREQ),
    .BAUD_RATE(BAUD_RATE),
    .DATA_BITS(DATA_BITS),
    .PARITY(PARITY),
    .STOP_BITS(STOP_BITS))
     u_uart_tx (
        .sys_clk_50mhz(sys_clk_50mhz),
        .uart_clk(uart_clk),
        .sys_rst_n(uart_rst_n),
        .sys_uart_tx(sys_uart_tx),
        .uart_data_tx(uart_data_tx),
        .uart_data_valid_tx(uart_data_valid_tx),
        .uart_busy(uart_busy));
    // Three-stage FSM: system-domain state register.
    always @(posedge sys_clk_50mhz or negedge sys_rst_n) begin if (!sys_rst_n)
    xfer_current_state<=XFER_IDLE;
    else xfer_current_state<=xfer_next_state;
    end
    // Three-stage FSM: system-domain next-state logic.
    always @(*) begin
        xfer_next_state=xfer_current_state;
        case (xfer_current_state)
            XFER_IDLE: if (!attitude_empty&&!tx_fifo_wr_full) xfer_next_state=XFER_READ;
            XFER_READ: xfer_next_state=XFER_WAIT;
            XFER_WAIT: xfer_next_state=XFER_WRITE;
            XFER_WRITE: if (!tx_fifo_wr_full) xfer_next_state=XFER_IDLE;
            default: xfer_next_state=XFER_IDLE;
        endcase
    end
    // Three-stage FSM: system-domain data register.
    always @(posedge sys_clk_50mhz or negedge sys_rst_n) begin if (!sys_rst_n) xfer_data<=0; else if (xfer_current_state==XFER_WAIT) xfer_data<=attitude_data; end
    // Three-stage FSM: UART-domain state register.
    always @(posedge uart_clk or negedge uart_rst_n) begin if (!uart_rst_n) tx_current_state<=TX_IDLE; else tx_current_state<=tx_next_state; end
    // Three-stage FSM: UART-domain next-state logic.
    always @(*) begin
        tx_next_state=tx_current_state;
        case (tx_current_state)
            TX_IDLE: if (!tx_fifo_rd_empty) tx_next_state=TX_FIFO_READ;
            TX_FIFO_READ: tx_next_state=TX_FIFO_WAIT;
            TX_FIFO_WAIT: tx_next_state=TX_SEND;
            TX_SEND: tx_next_state=TX_WAIT_BUSY;
            TX_WAIT_BUSY: if (uart_busy) tx_next_state=TX_WAIT_DONE;
            TX_WAIT_DONE: if (!uart_busy) begin if (byte_index==9) tx_next_state=TX_IDLE; else tx_next_state=TX_SEND; end
            default: tx_next_state=TX_IDLE;
        endcase
    end

    // Three-stage FSM: packet data and byte index registers.
    always @(posedge uart_clk or negedge uart_rst_n) begin
        if (!uart_rst_n) begin frame_payload<=0; frame_checksum<=0; byte_index<=0; tx_activity_toggle<=0; end
        else begin
        case (tx_current_state)
            TX_IDLE: byte_index<=0;
            TX_FIFO_WAIT: begin
                frame_payload<=tx_fifo_rd_data;
                frame_checksum<=tx_fifo_rd_data[7:0]+tx_fifo_rd_data[15:8]+tx_fifo_rd_data[23:16]+tx_fifo_rd_data[31:24]+tx_fifo_rd_data[39:32]+tx_fifo_rd_data[47:40];
                byte_index<=0; tx_activity_toggle<=~tx_activity_toggle;
            end
            TX_WAIT_DONE: if (!uart_busy && byte_index<9) byte_index<=byte_index+1'b1;
            default: byte_index<=byte_index;
        endcase
        end
    end
    assign uart_data_valid_tx=(tx_current_state==TX_SEND);
    assign uart_data_tx=(byte_index==0)?8'h55:(byte_index==1)?8'hAA:(byte_index==2)?frame_payload[7:0]:(byte_index==3)?frame_payload[15:8]:(byte_index==4)?frame_payload[23:16]:(byte_index==5)?frame_payload[31:24]:(byte_index==6)?frame_payload[39:32]:(byte_index==7)?frame_payload[47:40]:(byte_index==8)?frame_checksum:8'h0D;
    wire unused_fifo_flags=tx_fifo_almost_full|tx_fifo_almost_empty;
endmodule

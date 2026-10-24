`timescale 1ns/1ps
// PC UART protocol v1: A5 5A version type sequence length payload XOR.
// XOR covers version through payload. One host request may be outstanding.
// Responses have priority over rate-limited, coherent gamma frame snapshots.
module cp2102_control #(
    parameter integer CLK_HZ=50000000, BAUD=115200, REPORT_HZ=10,
    parameter [2:0] AVAILABLE_MASK=3'b111
) (
    input clk,rstn,rx,
    output tx,
    input control_busy,
    input [2:0] requested_mask,applied_mask,
    output reg control_valid,
    output reg [2:0] control_mask,
    input sample_valid,
    input [223:0] sample_data,
    output reg stream_enabled,
    output reg [31:0] receive_errors
);
    wire [7:0] rx_byte;
    wire rx_valid,tx_ready;
    reg [7:0] packet[0:34];
    reg [5:0] tx_index,tx_length;
    reg sending;
    imu_uart_rx_50m #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_rx (
        .clk(clk),.rstn(rstn),.rx(rx),.data(rx_byte),.data_valid(rx_valid));
    uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_tx (
        .clk(clk),.rstn(rstn),.valid(sending),.data(packet[tx_index]),
        .ready(tx_ready),.tx(tx));

    reg [2:0] phase;
    reg [7:0] command,sequence_id,payload_length,value,check;
    reg [31:0] timeout_count,report_count;
    reg reply_pending,telemetry_due,snapshot_seen;
    reg [7:0] reply_sequence,telemetry_sequence;
    reg [63:0] reply_payload;
    reg [223:0] latest_sample;
    integer i;
    reg [7:0] checksum;
    reg [7:0] result_code;
    reg [2:0] reply_requested;
    reg reply_busy,reply_stream;

    task handle_command;
        input [7:0] received_value;
        begin
            if(!reply_pending) begin
                result_code=0;reply_requested=requested_mask;
                reply_busy=control_busy;reply_stream=stream_enabled;
                case(command)
                    8'h10: begin
                        if(payload_length!=1) result_code=2;
                        else if(received_value[7:3]!=0) result_code=3;
                        else if((received_value[2:0] & ~AVAILABLE_MASK)!=0) result_code=5;
                        else if(control_busy || control_valid) result_code=4;
                        else begin
                            control_mask<=received_value[2:0];control_valid<=1;
                            reply_requested=received_value[2:0];reply_busy=1;
                        end
                    end
                    8'h11: if(payload_length!=0) result_code=2;
                    8'h12: begin
                        if(payload_length!=1) result_code=2;
                        else if(received_value>1) result_code=3;
                        else begin stream_enabled<=received_value[0];reply_stream=received_value[0];end
                    end
                    8'h13: begin
                        if(payload_length!=0) result_code=2;
                        else if(!snapshot_seen) result_code=6;
                        else telemetry_due<=1;
                    end
                    default: result_code=1;
                endcase
                reply_sequence<=sequence_id;reply_pending<=1;
                reply_payload<={receive_errors[7:0],{7'd0,snapshot_seen},
                    {7'd0,reply_stream},{5'd0,AVAILABLE_MASK},{7'd0,reply_busy},
                    {5'd0,applied_mask},{5'd0,reply_requested},result_code};
            end else receive_errors<=receive_errors+1'b1;
        end
    endtask

    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            phase<=0;command<=0;sequence_id<=0;payload_length<=0;value<=0;check<=0;
            timeout_count<=0;report_count<=0;control_valid<=0;control_mask<=0;
            reply_pending<=0;telemetry_due<=0;snapshot_seen<=0;reply_payload<=0;
            reply_sequence<=0;telemetry_sequence<=0;latest_sample<=0;
            stream_enabled<=1;receive_errors<=0;
            sending<=0;tx_index<=0;tx_length<=0;
            for(i=0;i<35;i=i+1) packet[i]<=0;
        end else begin
            control_valid<=0;
            if(sample_valid) begin latest_sample<=sample_data;snapshot_seen<=1;end
            if(report_count==CLK_HZ/REPORT_HZ-1) begin
                report_count<=0;
                if(stream_enabled && snapshot_seen) telemetry_due<=1;
            end else report_count<=report_count+1'b1;

            if(phase!=0) begin
                if(timeout_count==CLK_HZ/50-1) begin
                    phase<=0;timeout_count<=0;receive_errors<=receive_errors+1'b1;
                end else timeout_count<=timeout_count+1'b1;
            end else timeout_count<=0;
            if(rx_valid) begin
                timeout_count<=0;
                case(phase)
                    0: if(rx_byte==8'ha5) phase<=1;
                    1: if(rx_byte==8'h5a) phase<=2;
                       else phase<=(rx_byte==8'ha5) ? 1 : 0;
                    2: if(rx_byte==1) begin check<=rx_byte;phase<=3;end
                       else begin phase<=0;receive_errors<=receive_errors+1'b1;end
                    3: begin command<=rx_byte;check<=check^rx_byte;phase<=4;end
                    4: begin sequence_id<=rx_byte;check<=check^rx_byte;phase<=5;end
                    5: if(rx_byte<=1) begin payload_length<=rx_byte;check<=check^rx_byte;phase<=6;end
                       else begin phase<=0;receive_errors<=receive_errors+1'b1;end
                    6: if(payload_length==1) begin value<=rx_byte;check<=check^rx_byte;phase<=7;end
                       else begin
                           phase<=0;
                           if(rx_byte==check) handle_command(0);
                           else receive_errors<=receive_errors+1'b1;
                       end
                    7: begin
                        phase<=0;
                        if(rx_byte==check) handle_command(value);
                        else receive_errors<=receive_errors+1'b1;
                    end
                endcase
            end

            if(!sending) begin
                if(reply_pending) begin
                    packet[0]<=8'ha5;packet[1]<=8'h5a;packet[2]<=1;packet[3]<=8'h80;
                    packet[4]<=reply_sequence;packet[5]<=8;
                    checksum=8'h01^8'h80^reply_sequence^8'd8;
                    for(i=0;i<8;i=i+1) begin
                        packet[i+6]<=reply_payload[i*8+:8];checksum=checksum^reply_payload[i*8+:8];
                    end
                    packet[14]<=checksum;tx_length<=15;tx_index<=0;sending<=1;reply_pending<=0;
                end else if(telemetry_due && snapshot_seen) begin
                    packet[0]<=8'ha5;packet[1]<=8'h5a;packet[2]<=1;packet[3]<=8'h81;
                    packet[4]<=telemetry_sequence;packet[5]<=28;
                    checksum=8'h01^8'h81^telemetry_sequence^8'd28;
                    for(i=0;i<28;i=i+1) begin
                        packet[i+6]<=latest_sample[i*8+:8];checksum=checksum^latest_sample[i*8+:8];
                    end
                    packet[34]<=checksum;tx_length<=35;tx_index<=0;sending<=1;
                    telemetry_due<=0;telemetry_sequence<=telemetry_sequence+1'b1;
                end
            end else if(tx_ready) begin
                if(tx_index==tx_length-1) sending<=0;
                else tx_index<=tx_index+1'b1;
            end
        end
    end
endmodule

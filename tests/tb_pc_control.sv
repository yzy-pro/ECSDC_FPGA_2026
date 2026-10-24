`timescale 1ns/1ps
module tb_pc_control;
    parameter CLK_HZ=1843200;
    localparam BIT_CYCLES=(CLK_HZ+115200/2)/115200;
    reg clk=0,vin_clk=0,rstn=0,rx=1,frame_start=0;
    always #10 clk=~clk;
    always #7 vin_clk=~vin_clk;
    wire tx,control_busy,control_valid,stream_enabled;
    wire [2:0] control_mask,requested_mask,applied_mask,source_mask;
    wire [31:0] receive_errors;
    reg sample_valid=0;
    reg [223:0] sample_data=0;
    cp2102_control #(.CLK_HZ(CLK_HZ),.REPORT_HZ(10)) dut (
        .clk(clk),.rstn(rstn),.rx(rx),.tx(tx),.control_busy(control_busy),
        .requested_mask(requested_mask),.applied_mask(applied_mask),
        .control_valid(control_valid),.control_mask(control_mask),
        .sample_valid(sample_valid),.sample_data(sample_data),
        .stream_enabled(stream_enabled),.receive_errors(receive_errors));
    video_control_cdc controls (
        .sys_clk(clk),.vin_clk(vin_clk),.rstn(rstn),.frame_start(frame_start),
        .command_valid(control_valid),.command_mask(control_mask),.busy(control_busy),
        .requested_mask(requested_mask),.applied_mask_sys(applied_mask),.applied_mask_vin(source_mask));
    wire [7:0] received;
    wire received_valid;
    imu_uart_rx_50m #(.CLK_HZ(CLK_HZ),.BAUD(115200)) monitor (
        .clk(clk),.rstn(rstn),.rx(tx),.data(received),.data_valid(received_valid));
    integer position=0,status_count=0,telemetry_count=0,changes=0;
    reg [7:0] bytes[0:40];
    reg [7:0] sum=0,last_result,last_sequence;
    reg [63:0] status_payload;
    reg [223:0] observed_sample;
    integer k;
    always @(posedge clk) if(rstn) begin
        if(control_valid) changes=changes+1;
        if(received_valid) begin
            bytes[position]=received;
            if(position==0 && received!=8'ha5) $fatal(1,"TX sync A5");
            if(position==1 && received!=8'h5a) $fatal(1,"TX sync 5A");
            if(position==2) sum=received;
            else if(position>=3 && (position<=5 || position<6+bytes[5])) sum=sum^received;
            if(position>=6 && position==6+bytes[5]) begin
                if(received!==sum) $fatal(1,"TX checksum");
                if(bytes[3]==8'h80) begin
                    for(k=0;k<8;k=k+1) status_payload[k*8+:8]=bytes[k+6];
                    last_sequence=bytes[4];last_result=bytes[6];status_count=status_count+1;
                end else if(bytes[3]==8'h81) begin
                    for(k=0;k<28;k=k+1) observed_sample[k*8+:8]=bytes[k+6];
                    telemetry_count=telemetry_count+1;
                end else $fatal(1,"unknown TX packet");
                position=0;
            end else position=position+1;
        end
    end
    task send_byte(input [7:0] b);
        integer j;
        begin
            rx=0;repeat(BIT_CYCLES) @(negedge clk);
            for(j=0;j<8;j=j+1) begin rx=b[j];repeat(BIT_CYCLES) @(negedge clk);end
            rx=1;repeat(BIT_CYCLES) @(negedge clk);
        end
    endtask
    integer sequence_number=0;
    task command(input [7:0] kind,len,val,expected_code,input bit corrupt=0);
        integer before_count;
        reg [7:0] check;
        begin
            before_count=status_count;sequence_number=sequence_number+1;
            check=8'd1^kind^sequence_number[7:0]^len^(len!=0 ? val : 8'd0);
            send_byte(8'ha5);send_byte(8'h5a);send_byte(1);send_byte(kind);
            send_byte(sequence_number);send_byte(len);
            if(len!=0) send_byte(val);
            send_byte(check^(corrupt ? 8'h01 : 8'h00));
            if(!corrupt) begin
                wait(status_count>before_count);
                if(last_result!=expected_code || last_sequence!=sequence_number)
                    $fatal(1,"status code/sequence got=%0d expected=%0d",last_result,expected_code);
            end else begin
                repeat(400) @(negedge clk);
                if(status_count!=before_count) $fatal(1,"bad checksum replied");
            end
        end
    endtask
    task apply_frame(input [2:0] expected_mask);
        begin
            repeat(15) @(negedge vin_clk);
            if(source_mask===expected_mask && applied_mask!==expected_mask)
                $fatal(1,"unexpected control snapshot");
            frame_start=1;@(negedge vin_clk);frame_start=0;
            wait(!control_busy);repeat(3) @(negedge clk);
            if(applied_mask!==expected_mask || source_mask!==expected_mask) $fatal(1,"SOF control apply");
        end
    endtask
    integer m;
    initial begin
        repeat(8) @(negedge clk);rstn=1;
        command(8'h12,1,0,0); // Keep telemetry deterministic until queried.
        command(8'h11,0,0,0);
        if(status_payload[23:16]!=7 || status_payload[39:32]!=7) $fatal(1,"defaults/capabilities");
        command(8'h10,1,0,0);
        if(!control_busy || applied_mask!=7 || requested_mask!=0) $fatal(1,"changed before SOF");
        command(8'h10,1,1,4); // A pending command must not be overwritten.
        apply_frame(0);
        for(m=1;m<8;m=m+1) begin command(8'h10,1,m,0);apply_frame(m);end
        command(8'h10,1,8,3);command(8'h10,0,0,2);command(8'h99,0,0,1);
        command(8'h12,1,2,3);
        command(8'h10,1,0,0,1);
        if(requested_mask!=7 || changes!=8) $fatal(1,"invalid packet changed config");
        send_byte(8'ha5);send_byte(8'h5a);send_byte(1);
        repeat(CLK_HZ/50+100) @(negedge clk); // Incomplete packet timeout.
        command(8'h11,0,0,0);
        if(receive_errors<2) $fatal(1,"checksum/timeout counters");
        command(8'h13,0,0,6);
        @(negedge clk);sample_data=224'h07010203000102030405060708090a0b0c0d0e0f1011121314151617;
        sample_valid=1;@(negedge clk);sample_valid=0;
        command(8'h13,0,0,0);wait(telemetry_count==1);
        if(observed_sample!==sample_data) $fatal(1,"telemetry packing/snapshot");
        command(8'h12,1,1,0);wait(telemetry_count==2);
        $display("PASS PC UART: all masks, SOF commit, busy, checksum, timeout, status, telemetry, streaming");
        $finish;
    end
    initial begin #300000000;$fatal(1,"PC UART timeout");end
endmodule

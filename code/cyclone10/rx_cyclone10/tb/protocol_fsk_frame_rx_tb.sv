`timescale 1ns/1ps

`include "fsk_sync_word.vh"

module protocol_fsk_frame_rx_tb;
    localparam integer TIMEOUT_CYCLES = 20;

    reg clk;
    reg rst_n;
    reg bit_valid;
    reg bit_value;
    reg lock_lost;

    wire       busy;
    wire       sync_found;
    wire       frame_valid;
    wire       good_frame;
    wire [7:0] frame_version_type;
    wire [7:0] frame_sequence;
    wire [7:0] frame_payload_length;
    wire       frame_payload_valid;
    wire [7:0] frame_payload_data;
    wire       frame_payload_last;
    wire       header_error;
    wire       length_error;
    wire       crc_error;
    wire       timeout_error;

    reg [7:0] tx_payload [0:64];
    reg [7:0] captured_payload [0:63];
    integer captured_count;
    integer sync_count;
    integer good_count;
    integer header_error_count;
    integer length_error_count;
    integer crc_error_count;
    integer timeout_error_count;
    integer index;

    fsk_frame_rx #(
        .SYNC_WORD(`FSK_SYNC_WORD),
        .BIT_TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .bit_valid            (bit_valid),
        .bit_value            (bit_value),
        .lock_lost            (lock_lost),
        .busy                 (busy),
        .sync_found           (sync_found),
        .frame_valid          (frame_valid),
        .good_frame           (good_frame),
        .frame_version_type   (frame_version_type),
        .frame_sequence       (frame_sequence),
        .frame_payload_length (frame_payload_length),
        .frame_payload_valid  (frame_payload_valid),
        .frame_payload_data   (frame_payload_data),
        .frame_payload_last   (frame_payload_last),
        .header_error         (header_error),
        .length_error         (length_error),
        .crc_error            (crc_error),
        .timeout_error        (timeout_error)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (sync_found)
            sync_count = sync_count + 1;
        if (good_frame) begin
            if (!frame_valid)
                $fatal(1, "good_frame and frame_valid diverged");
            good_count = good_count + 1;
        end
        if (header_error)
            header_error_count = header_error_count + 1;
        if (length_error)
            length_error_count = length_error_count + 1;
        if (crc_error)
            crc_error_count = crc_error_count + 1;
        if (timeout_error)
            timeout_error_count = timeout_error_count + 1;
        if (frame_payload_valid) begin
            if (captured_count >= 64)
                $fatal(1, "payload output exceeded 64 bytes");
            captured_payload[captured_count] = frame_payload_data;
            captured_count = captured_count + 1;
            if (frame_payload_last !== (captured_count == frame_payload_length))
                $fatal(1, "payload_last asserted at the wrong byte");
        end
    end

    function [7:0] crc8_next;
        input [7:0] crc_value;
        input [7:0] data_value;
        integer bit_index;
        reg [7:0] value;
        begin
            value = crc_value ^ data_value;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (value[7])
                    value = {value[6:0], 1'b0} ^ 8'h07;
                else
                    value = {value[6:0], 1'b0};
            end
            crc8_next = value;
        end
    endfunction

    function [15:0] crc16_next;
        input [15:0] crc_value;
        input [7:0] data_value;
        integer bit_index;
        reg [15:0] value;
        begin
            value = crc_value ^ {data_value, 8'h00};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (value[15])
                    value = {value[14:0], 1'b0} ^ 16'h1021;
                else
                    value = {value[14:0], 1'b0};
            end
            crc16_next = value;
        end
    endfunction

    task drive_bit;
        input value;
        begin
            @(negedge clk);
            bit_valid = 1'b1;
            bit_value = value;
        end
    endtask

    task stop_bits;
        begin
            @(negedge clk);
            bit_valid = 1'b0;
            bit_value = 1'b0;
        end
    endtask

    task send_byte;
        input [7:0] value;
        integer bit_index;
        begin
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1)
                drive_bit(value[bit_index]);
        end
    endtask

    task send_sync;
        input [15:0] error_mask;
        integer bit_index;
        reg [15:0] transmitted;
        begin
            transmitted = `FSK_SYNC_WORD ^ error_mask;
            for (bit_index = 15; bit_index >= 0; bit_index = bit_index - 1)
                drive_bit(transmitted[bit_index]);
        end
    endtask

    task send_frame;
        input [7:0] length;
        input [15:0] sync_error_mask;
        input bad_header_crc;
        input corrupt_payload;
        input bad_frame_crc;
        reg [7:0] header0;
        reg [7:0] header1;
        reg [7:0] header_crc;
        reg [15:0] frame_crc;
        reg [7:0] transmitted_byte;
        integer payload_index;
        begin
            header0 = 8'h11;
            header1 = 8'h5A;
            header_crc = crc8_next(crc8_next(crc8_next(8'h00, header0), header1), length);
            frame_crc = crc16_next(16'hFFFF, header0);
            frame_crc = crc16_next(frame_crc, header1);
            frame_crc = crc16_next(frame_crc, length);
            frame_crc = crc16_next(frame_crc, header_crc);
            for (payload_index = 0; payload_index < length; payload_index = payload_index + 1)
                frame_crc = crc16_next(frame_crc, tx_payload[payload_index]);

            send_sync(sync_error_mask);
            send_byte(header0);
            send_byte(header1);
            send_byte(length);
            if (length <= 8'd64) begin
                send_byte(header_crc ^ (bad_header_crc ? 8'h01 : 8'h00));
                for (payload_index = 0; payload_index < length; payload_index = payload_index + 1) begin
                    transmitted_byte = tx_payload[payload_index];
                    if (corrupt_payload && (payload_index == 0))
                        transmitted_byte = transmitted_byte ^ 8'h01;
                    send_byte(transmitted_byte);
                end
                send_byte(frame_crc[15:8]);
                send_byte(frame_crc[7:0] ^ (bad_frame_crc ? 8'h01 : 8'h00));
            end
            stop_bits();
        end
    endtask

    task reset_dut;
        begin
            bit_valid = 1'b0;
            bit_value = 1'b0;
            lock_lost = 1'b0;
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            captured_count = 0;
        end
    endtask

    task expect_good_frame;
        input integer expected_length;
        input integer good_before;
        integer wait_cycles;
        begin
            for (wait_cycles = 0; wait_cycles < 80; wait_cycles = wait_cycles + 1)
                @(posedge clk);
            #1;
            if (good_count != good_before + 1)
                $fatal(1, "expected one good frame of length %0d", expected_length);
            if (captured_count != expected_length)
                $fatal(1, "length %0d emitted %0d bytes", expected_length, captured_count);
            if (frame_payload_length !== expected_length[7:0])
                $fatal(1, "reported payload length mismatch");
            for (index = 0; index < expected_length; index = index + 1) begin
                if (captured_payload[index] !== tx_payload[index])
                    $fatal(1, "payload mismatch at byte %0d", index);
            end
        end
    endtask

    integer before_count;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        bit_valid = 1'b0;
        bit_value = 1'b0;
        lock_lost = 1'b0;
        captured_count = 0;
        sync_count = 0;
        good_count = 0;
        header_error_count = 0;
        length_error_count = 0;
        crc_error_count = 0;
        timeout_error_count = 0;
        for (index = 0; index < 65; index = index + 1)
            tx_payload[index] = (index * 8'h3D) ^ 8'hA7;

        reset_dut();
        before_count = good_count;
        send_frame(8'd0, 16'h0000, 1'b0, 1'b0, 1'b0);
        expect_good_frame(0, before_count);

        reset_dut();
        before_count = good_count;
        send_frame(8'd1, 16'h0001, 1'b0, 1'b0, 1'b0);
        expect_good_frame(1, before_count);

        reset_dut();
        before_count = good_count;
        send_frame(8'd64, 16'h0000, 1'b0, 1'b0, 1'b0);
        expect_good_frame(64, before_count);

        reset_dut();
        before_count = length_error_count;
        send_frame(8'd65, 16'h0000, 1'b0, 1'b0, 1'b0);
        repeat (4) @(posedge clk);
        if (length_error_count != before_count + 1 || good_frame)
            $fatal(1, "65-byte length was not rejected immediately");

        reset_dut();
        before_count = header_error_count;
        send_frame(8'd1, 16'h0000, 1'b1, 1'b0, 1'b0);
        repeat (8) @(posedge clk);
        if (header_error_count != before_count + 1)
            $fatal(1, "bad header CRC was not rejected");

        reset_dut();
        before_count = crc_error_count;
        send_frame(8'd1, 16'h0000, 1'b0, 1'b1, 1'b0);
        repeat (8) @(posedge clk);
        if (crc_error_count != before_count + 1 || good_frame)
            $fatal(1, "payload bit error did not cause CRC16 rejection");

        reset_dut();
        before_count = crc_error_count;
        send_frame(8'd1, 16'h0000, 1'b0, 1'b0, 1'b1);
        repeat (8) @(posedge clk);
        if (crc_error_count != before_count + 1)
            $fatal(1, "bad received CRC16 was not rejected");

        reset_dut();
        before_count = sync_count;
        send_sync(16'h0003);
        stop_bits();
        repeat (4) @(posedge clk);
        if (sync_count != before_count || busy)
            $fatal(1, "two-bit sync error was accepted");

        reset_dut();
        before_count = timeout_error_count;
        send_sync(16'h0000);
        send_byte(8'h11);
        drive_bit(1'b0);
        stop_bits();
        repeat (TIMEOUT_CYCLES + 4) @(posedge clk);
        if (timeout_error_count != before_count + 1 || busy)
            $fatal(1, "partial frame timeout was not reported");

        $display("protocol_fsk_frame_rx_tb: PASS");
        $finish;
    end
endmodule

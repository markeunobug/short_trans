`timescale 1ns/1ps
`include "fsk_sync_word.vh"

module integration_fsk_reacquisition_tb;
    reg clk = 0, reset_n = 0;
    reg metric_valid = 0, carrier = 0, hard_bit = 0;
    reg [7:0] confidence = 0;
    wire [1:0] sync_state;
    wire locked, lock_lost, search_timeout, bit_valid, bit_value;
    wire sync_found, frame_valid, payload_valid, payload_last;
    wire header_error, length_error, crc_error, frame_timeout;
    wire time_valid, time_base;
    wire [7:0] length, sequence_id, payload;
    wire [31:0] timestamp;
    wire frame_end = header_error || length_error || crc_error || frame_timeout ||
                     payload_last || (frame_valid && length == 0);

    integer good_count = 0, header_errors = 0, crc_errors = 0;
    integer lost_count = 0, search_timeouts = 0, output_bits = 0;
    integer payload_count = 0, metrics_in_rearm = 0, last_rearm_metrics = 0;
    integer quiet_metrics = 0, last_quiet_metrics = 0;
    integer expected_length = 0;
    reg [7:0] expected_sequence = 0;
    reg [31:0] expected_timestamp = 0;
    reg [1:0] previous_state = 0;

    fsk_symbol_sync #(.LOCK_TIMEOUT_SYMBOLS(640)) symbol_sync (
        .clk(clk), .reset_n(reset_n), .metric_valid(metric_valid),
        .hard_bit(hard_bit), .total_energy(33'd2000), .confidence(confidence),
        .carrier_present(carrier), .preamble_confidence_threshold(8'd140),
        .frame_sync_found(sync_found), .frame_end(frame_end),
        .debug_state(sync_state), .sync_locked(locked), .lock_lost(lock_lost),
        .search_timeout(search_timeout), .bit_valid(bit_valid), .bit_value(bit_value),
        .carrier_active(), .preamble_detected(), .symbol_energy(), .symbol_confidence(),
        .selected_phase(), .timing_adjust()
    );

    fsk_frame_rx frame_rx (
        .clk(clk), .rst_n(reset_n), .bit_valid(bit_valid), .bit_value(bit_value),
        .lock_lost(lock_lost), .sync_found(sync_found), .frame_valid(frame_valid),
        .frame_sequence(sequence_id), .frame_payload_length(length),
        .frame_timestamp(timestamp), .frame_timestamp_valid(time_valid),
        .frame_is_time_base(time_base), .frame_payload_valid(payload_valid),
        .frame_payload_data(payload), .frame_payload_last(payload_last),
        .header_error(header_error), .length_error(length_error),
        .crc_error(crc_error), .timeout_error(frame_timeout),
        .busy(), .good_frame(), .frame_version_type(), .debug_state(), .debug_payload_bytes()
    );

    always #5 clk = ~clk;

    always @(posedge clk) if (reset_n) begin
        if (bit_valid) output_bits = output_bits + 1;
        if (lock_lost) lost_count = lost_count + 1;
        if (search_timeout) search_timeouts = search_timeouts + 1;
        if (header_error) header_errors = header_errors + 1;
        if (crc_error) crc_errors = crc_errors + 1;
        if (length_error || frame_timeout) $fatal(1, "unexpected parser error");
        if (sync_state == 3 && metric_valid) begin
            metrics_in_rearm = metrics_in_rearm + 1;
            quiet_metrics = carrier ? 0 : quiet_metrics + 1;
        end
        if (previous_state == 3 && sync_state != 3) begin
            last_rearm_metrics = metrics_in_rearm;
            last_quiet_metrics = quiet_metrics;
            metrics_in_rearm = 0;
            quiet_metrics = 0;
        end
        previous_state = sync_state;
        if (frame_valid) begin
            good_count = good_count + 1;
            payload_count = 0;
            if (sequence_id !== expected_sequence || length != expected_length ||
                timestamp !== expected_timestamp || !time_valid || time_base != (expected_length == 0))
                $fatal(1, "unexpected metadata seq=%0d len=%0d time=%h valid=%b base=%b",
                       sequence_id, length, timestamp, time_valid, time_base);
        end
        if (payload_valid) begin
            if (payload !== 8'(expected_sequence + payload_count) ||
                payload_last != (payload_count == expected_length - 1))
                $fatal(1, "payload mismatch at byte %0d", payload_count);
            payload_count = payload_count + 1;
        end
    end

    task automatic metric(input bit value, input bit present, input [7:0] quality);
        @(negedge clk);
        hard_bit = value;
        carrier = present;
        confidence = quality;
        metric_valid = 1;
        @(negedge clk);
        metric_valid = 0;
        repeat (12) @(negedge clk);
    endtask

    task automatic send_preamble;
        localparam [15:0] PREAMBLE = 16'haaaa;
        integer symbol_index, distance;
        repeat (4) metric(1, 1, 180);
        for (integer tick = 0; tick < 160; tick = tick + 1) begin
            symbol_index = (tick + 1) / 10;
            distance = ((tick + 1) % 10) - 5;
            if (distance < 0) distance = -distance;
            metric(symbol_index < 16 ? PREAMBLE[15-symbol_index] : 1'b0,
                   1, 8'(230 - distance * 14));
        end
        if (!locked) $fatal(1, "preamble did not lock");
    endtask

    task automatic send_byte(input [7:0] value);
        for (integer i = 7; i >= 0; i = i - 1)
            repeat (10) metric(value[i], 1, 180);
    endtask

    function automatic [7:0] crc8(input [7:0] current, input [7:0] data);
        reg [7:0] value;
        value = current ^ data;
        repeat (8) value = (value << 1) ^ (value[7] ? 8'h07 : 8'h00);
        return value;
    endfunction

    function automatic [15:0] crc16(input [15:0] current, input [7:0] data);
        reg [15:0] value;
        value = current ^ {data, 8'd0};
        repeat (8) value = (value << 1) ^ (value[15] ? 16'h1021 : 16'h0000);
        return value;
    endfunction

    task automatic send_frame(input integer size, input [7:0] seq,
                              input bit corrupt_header, input bit corrupt_crc);
        localparam [15:0] SYNC = `FSK_SYNC_WORD;
        reg [7:0] body [0:71];
        reg [15:0] check;
        integer body_size;
        body[0] = size == 0 ? 8'h21 : 8'h20;
        body[1] = seq;
        body[2] = 8'(size);
        body[3] = crc8(crc8(crc8(0, body[0]), body[1]), body[2]) ^ {7'd0, corrupt_header};
        body[4] = 8'h12;
        body[5] = 8'h34;
        body[6] = 8'h56;
        body[7] = 8'h78;
        body_size = size == 0 ? 8 : 7 + size;
        for (integer i = 0; i < size; i = i + 1) body[7+i] = 8'(seq + i);
        expected_length = size;
        expected_sequence = seq;
        expected_timestamp = size == 0 ? 32'h12345678 : 32'h00123456;
        check = 16'hffff;
        send_preamble();
        send_byte(SYNC[15:8]);
        send_byte(SYNC[7:0]);
        for (integer i = 0; i < body_size; i = i + 1) begin
            send_byte(body[i]);
            check = crc16(check, body[i]);
            if (corrupt_header && i == 3 && (locked || header_errors != 1))
                $fatal(1, "bad header did not release lock before the remaining body");
        end
        send_byte(check[15:8]);
        send_byte(check[7:0] ^ {7'd0, corrupt_crc});
    endtask

    task automatic gap;
        // The TX adds 100 ms after one frame and 100 ms before the next.
        repeat (200) metric(0, 0, 0);
        if (sync_state != 0) $fatal(1, "receiver not ready after normal quiet gap");
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset_n = 1;
        send_frame(0, 1, 0, 0);
        gap();
        if (good_count != 1 || last_quiet_metrics != 10 || lost_count != 0)
            $fatal(1, "TIME_BASE completion or quiet rearm failed");

        output_bits = 0;
        send_preamble();
        repeat (255) metric(0, 1, 180);
        if (locked || output_bits != 24 || search_timeouts != 1 || lost_count != 1)
            $fatal(1, "false preamble did not expire after 24 emitted bits");
        repeat (40) metric(0, 1, 180);
        if (last_rearm_metrics != 32) $fatal(1, "high carrier exceeded rearm bound");
        gap();
        send_frame(1, 2, 0, 0);
        gap();
        if (good_count != 2 || payload_count != 1) $fatal(1, "recovery after false preamble");

        send_frame(1, 3, 1, 0);
        gap();
        send_frame(1, 4, 0, 0);
        gap();
        if (good_count != 3 || header_errors != 1) $fatal(1, "recovery after bad header");

        send_frame(1, 5, 0, 1);
        if (locked || crc_errors != 1 || good_count != 3) $fatal(1, "bad CRC did not release lock");
        gap();
        send_frame(64, 6, 0, 0);
        gap();
        if (good_count != 4 || payload_count != 64) $fatal(1, "recovery after bad CRC or max length lost");

        $display("PASS: fake preamble, bounded rearm, bad header, bad CRC, TIME_BASE and DATA64");
        $finish;
    end
endmodule

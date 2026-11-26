`timescale 1ns/1ps

`include "fsk_sync_word.vh"

// Real sample-domain integration test:
// signed 20-bit samples -> demodulator -> symbol synchronizer -> frame parser.
module integration_rx_chain_tb;
    localparam integer MAX_FRAME_BYTES = 74;

    reg clk;
    reg reset_n;
    reg sample_valid;
    reg signed [19:0] sample_data;

    wire metric_valid;
    wire hard_bit;
    wire signed [32:0] soft_metric;
    wire [32:0] total_energy;
    wire [7:0] confidence;
    wire confidence_ok;
    wire [31:0] energy_f0;
    wire [31:0] energy_f1;
    wire [32:0] noise_energy;
    wire [32:0] carrier_threshold;
    wire energy_above_threshold;
    wire noise_ready;
    wire noise_update;

    wire carrier_active;
    wire sync_locked;
    wire preamble_detected;
    wire lock_lost;
    wire search_timeout;
    wire bit_valid;
    wire bit_value;
    wire [32:0] symbol_energy;
    wire [7:0] symbol_confidence;
    wire [3:0] selected_phase;
    wire signed [1:0] timing_adjust;

    wire frame_busy;
    wire sync_found;
    wire frame_valid;
    wire good_frame;
    wire [7:0] frame_version_type;
    wire [7:0] frame_sequence;
    wire [7:0] frame_payload_length;
    wire frame_payload_valid;
    wire [7:0] frame_payload_data;
    wire frame_payload_last;
    wire header_error;
    wire length_error;
    wire crc_error;
    wire timeout_error;

    reg [8*512-1:0] sample_file;
    reg [8*512-1:0] frame_file;
    reg [7:0] expected_frame [0:MAX_FRAME_BYTES-1];
    reg [31:0] file_value;
    integer expected_sample_count;
    integer expected_frame_byte_count;
    integer expected_sync_word;
    integer expected_payload_length;
    integer descriptor;
    integer status;
    integer index;

    integer metric_count;
    integer preamble_count;
    integer recovered_bit_count;
    integer sync_count;
    integer frame_count;
    integer payload_count;
    integer error_count;

    fsk_demod_core demod (
        .clk                    (clk),
        .reset_n                (reset_n),
        .sample_valid           (sample_valid),
        .sample_data            (sample_data),
        .noise_track_enable     (1'b1),
        .carrier_active         (carrier_active),
        .noise_multiplier_q4_4  (8'h40),
        .noise_offset           (33'd1),
        .confidence_threshold   (8'd128),
        .metric_valid           (metric_valid),
        .hard_bit               (hard_bit),
        .soft_metric            (soft_metric),
        .total_energy           (total_energy),
        .confidence             (confidence),
        .confidence_ok          (confidence_ok),
        .energy_f0              (energy_f0),
        .energy_f1              (energy_f1),
        .noise_energy           (noise_energy),
        .carrier_threshold      (carrier_threshold),
        .energy_above_threshold (energy_above_threshold),
        .noise_ready            (noise_ready),
        .noise_update           (noise_update)
    );

    // Match the production top's bounded maximum-frame lock budget.
    // The synchronizer's unit-test default is only 100 symbols.
    fsk_symbol_sync #(.LOCK_TIMEOUT_SYMBOLS(640)) symbol_sync (
        .clk                           (clk),
        .reset_n                       (reset_n),
        .metric_valid                  (metric_valid),
        .hard_bit                      (hard_bit),
        .total_energy                  (total_energy),
        .confidence                    (confidence),
        .carrier_present               (energy_above_threshold),
        .preamble_confidence_threshold (8'd140),
        .carrier_active                (carrier_active),
        .sync_locked                   (sync_locked),
        .preamble_detected             (preamble_detected),
        .lock_lost                     (lock_lost),
        .search_timeout                (search_timeout),
        .bit_valid                     (bit_valid),
        .bit_value                     (bit_value),
        .symbol_energy                 (symbol_energy),
        .symbol_confidence             (symbol_confidence),
        .selected_phase                (selected_phase),
        .timing_adjust                 (timing_adjust)
    );

    fsk_frame_rx frame_rx (
        .clk                  (clk),
        .rst_n                (reset_n),
        .bit_valid            (bit_valid),
        .bit_value            (bit_value),
        .lock_lost            (lock_lost),
        .busy                 (frame_busy),
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
        if (reset_n) begin
            if (metric_valid)
                metric_count = metric_count + 1;
            if (preamble_detected)
                preamble_count = preamble_count + 1;
            if (bit_valid)
                recovered_bit_count = recovered_bit_count + 1;
            if (sync_found)
                sync_count = sync_count + 1;
            if (frame_valid) begin
                if (!good_frame)
                    $fatal(1, "FAIL: frame_valid and good_frame diverged");
                frame_count = frame_count + 1;
            end
            if (header_error || length_error || crc_error || timeout_error)
                error_count = error_count + 1;

            if (frame_payload_valid) begin
                if (payload_count >= expected_payload_length)
                    $fatal(1, "FAIL: payload output exceeded expected length %0d",
                           expected_payload_length);
                if (frame_payload_data !== expected_frame[8 + payload_count])
                    $fatal(1,
                           "FAIL: payload byte %0d expected=%02h actual=%02h",
                           payload_count, expected_frame[8 + payload_count],
                           frame_payload_data);
                if (frame_payload_last !==
                    (payload_count == expected_payload_length - 1))
                    $fatal(1, "FAIL: payload_last is wrong at byte %0d",
                           payload_count);
                payload_count = payload_count + 1;
            end
        end
    end

    initial begin
        clk = 1'b0;
        reset_n = 1'b0;
        sample_valid = 1'b0;
        sample_data = 20'sd0;
        metric_count = 0;
        preamble_count = 0;
        recovered_bit_count = 0;
        sync_count = 0;
        frame_count = 0;
        payload_count = 0;
        error_count = 0;

        if (!$value$plusargs("SAMPLE_FILE=%s", sample_file) ||
            !$value$plusargs("FRAME_FILE=%s", frame_file) ||
            !$value$plusargs("SAMPLE_COUNT=%d", expected_sample_count) ||
            !$value$plusargs("FRAME_BYTE_COUNT=%d", expected_frame_byte_count) ||
            !$value$plusargs("SYNC_WORD=%h", expected_sync_word))
            $fatal(1, "FAIL: RX-chain vector plusargs are incomplete");

        if (expected_frame_byte_count > MAX_FRAME_BYTES)
            $fatal(1, "FAIL: frame vector exceeds testbench capacity");

        descriptor = $fopen(frame_file, "r");
        if (descriptor == 0)
            $fatal(1, "FAIL: cannot open frame vector %0s", frame_file);
        for (index = 0; index < expected_frame_byte_count; index = index + 1) begin
            status = $fscanf(descriptor, "%h\n", file_value);
            if (status != 1)
                $fatal(1, "FAIL: frame vector ended at byte %0d", index);
            expected_frame[index] = file_value[7:0];
        end
        status = $fscanf(descriptor, "%h\n", file_value);
        if (status == 1)
            $fatal(1, "FAIL: frame vector has more than %0d bytes",
                   expected_frame_byte_count);
        $fclose(descriptor);

        expected_payload_length = expected_frame[6];
        if (expected_payload_length <= 0 || expected_payload_length > 64)
            $fatal(1, "FAIL: integration vector needs a 1..64 byte payload");
        if (expected_frame_byte_count != expected_payload_length + 10)
            $fatal(1, "FAIL: frame byte count is inconsistent with payload length");
        if (expected_frame[0] != 8'hAA || expected_frame[1] != 8'hAA ||
            expected_frame[2] != expected_sync_word[15:8] ||
            expected_frame[3] != expected_sync_word[7:0] ||
            expected_sync_word[15:0] != `FSK_SYNC_WORD)
            $fatal(1, "FAIL: preamble/sync does not match RTL protocol constants");

        descriptor = $fopen(sample_file, "r");
        if (descriptor == 0)
            $fatal(1, "FAIL: cannot open sample vector %0s", sample_file);

        repeat (8) @(posedge clk);
        @(negedge clk);
        reset_n = 1'b1;

        for (index = 0; index < expected_sample_count; index = index + 1) begin
            status = $fscanf(descriptor, "%h\n", file_value);
            if (status != 1)
                $fatal(1, "FAIL: sample vector ended at sample %0d", index);
            @(negedge clk);
            sample_valid = 1'b1;
            sample_data = file_value[19:0];
        end
        status = $fscanf(descriptor, "%h\n", file_value);
        if (status == 1)
            $fatal(1, "FAIL: sample vector has more than %0d samples",
                   expected_sample_count);
        $fclose(descriptor);

        @(negedge clk);
        sample_valid = 1'b0;
        sample_data = 20'sd0;
        repeat (32) @(posedge clk);
        #1;

        $display("RX chain diagnostics: metrics=%0d preambles=%0d bits=%0d sync=%0d frames=%0d payload=%0d phase=%0d errors=%0d",
                 metric_count, preamble_count, recovered_bit_count, sync_count,
                 frame_count, payload_count, selected_phase, error_count);

        if (!noise_ready)
            $fatal(1, "FAIL: idle noise tracker never initialized");
        if (preamble_count != 1)
            $fatal(1, "FAIL: expected one preamble lock, observed %0d",
                   preamble_count);
        if (sync_count != 1)
            $fatal(1, "FAIL: expected one protocol sync, observed %0d", sync_count);
        if (frame_count != 1)
            $fatal(1, "FAIL: expected one CRC-valid frame, observed %0d",
                   frame_count);
        if (error_count != 0)
            $fatal(1, "FAIL: protocol error pulses observed: %0d",
                   error_count);
        if (frame_version_type !== expected_frame[4] ||
            frame_sequence !== expected_frame[5] ||
            frame_payload_length !== expected_payload_length[7:0])
            $fatal(1, "FAIL: recovered frame header does not match vector");
        if (payload_count != expected_payload_length)
            $fatal(1, "FAIL: expected %0d payload bytes, observed %0d",
                   expected_payload_length, payload_count);

        $display("integration_rx_chain_tb: PASS - recovered %0d-byte payload from %0d signed 20-bit samples",
                 payload_count, expected_sample_count);
        $finish;
    end
endmodule

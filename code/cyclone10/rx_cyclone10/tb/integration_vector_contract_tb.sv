`timescale 1ns/1ps

// Vector-file contract test only.  No RX RTL is instantiated here.
module integration_vector_contract_tb;
    reg [8*512-1:0] sample_file;
    reg [8*512-1:0] bit_file;
    reg [8*512-1:0] frame_file;
    integer expected_sample_count;
    integer expected_bit_count;
    integer expected_frame_byte_count;
    integer expected_sync_word;
    integer descriptor;
    integer status;
    integer value;
    integer count;
    integer nonzero_samples;
    integer changed_samples;
    integer previous_sample;
    integer first_frame_byte;
    integer second_frame_byte;
    integer third_frame_byte;
    integer fourth_frame_byte;

    initial begin
        if (!$value$plusargs("SAMPLE_FILE=%s", sample_file) ||
            !$value$plusargs("BIT_FILE=%s", bit_file) ||
            !$value$plusargs("FRAME_FILE=%s", frame_file) ||
            !$value$plusargs("SAMPLE_COUNT=%d", expected_sample_count) ||
            !$value$plusargs("BIT_COUNT=%d", expected_bit_count) ||
            !$value$plusargs("FRAME_BYTE_COUNT=%d", expected_frame_byte_count) ||
            !$value$plusargs("SYNC_WORD=%h", expected_sync_word))
            $fatal(1, "FAIL: vector contract plusargs are incomplete");

        descriptor = $fopen(sample_file, "r");
        if (descriptor == 0)
            $fatal(1, "FAIL: cannot open sample vector %0s", sample_file);
        count = 0;
        nonzero_samples = 0;
        changed_samples = 0;
        previous_sample = 0;
        while (!$feof(descriptor)) begin
            status = $fscanf(descriptor, "%h\n", value);
            if (status == 1) begin
                if ((value & ~20'hfffff) != 0)
                    $fatal(1, "FAIL: sample %0d exceeds 20 bits", count);
                if ((value & 20'hfffff) != 0)
                    nonzero_samples = nonzero_samples + 1;
                if (count != 0 && (value & 20'hfffff) != previous_sample)
                    changed_samples = changed_samples + 1;
                previous_sample = value & 20'hfffff;
                count = count + 1;
            end
        end
        $fclose(descriptor);
        if (count != expected_sample_count)
            $fatal(1, "FAIL: sample count expected=%0d actual=%0d", expected_sample_count, count);
        if (nonzero_samples == 0 || changed_samples == 0)
            $fatal(1, "FAIL: sample vector contains no active waveform");

        descriptor = $fopen(bit_file, "r");
        if (descriptor == 0)
            $fatal(1, "FAIL: cannot open bit vector %0s", bit_file);
        count = 0;
        while (!$feof(descriptor)) begin
            status = $fscanf(descriptor, "%h\n", value);
            if (status == 1) begin
                if (value != 0 && value != 1)
                    $fatal(1, "FAIL: bit %0d is not binary", count);
                count = count + 1;
            end
        end
        $fclose(descriptor);
        if (count != expected_bit_count)
            $fatal(1, "FAIL: bit count expected=%0d actual=%0d", expected_bit_count, count);

        descriptor = $fopen(frame_file, "r");
        if (descriptor == 0)
            $fatal(1, "FAIL: cannot open frame vector %0s", frame_file);
        count = 0;
        first_frame_byte = -1;
        second_frame_byte = -1;
        third_frame_byte = -1;
        fourth_frame_byte = -1;
        while (!$feof(descriptor)) begin
            status = $fscanf(descriptor, "%h\n", value);
            if (status == 1) begin
                if ((value & ~8'hff) != 0)
                    $fatal(1, "FAIL: frame byte %0d exceeds 8 bits", count);
                if (count == 0) first_frame_byte = value;
                if (count == 1) second_frame_byte = value;
                if (count == 2) third_frame_byte = value;
                if (count == 3) fourth_frame_byte = value;
                count = count + 1;
            end
        end
        $fclose(descriptor);
        if (count != expected_frame_byte_count)
            $fatal(1, "FAIL: frame byte count expected=%0d actual=%0d", expected_frame_byte_count, count);
        if (first_frame_byte != 8'haa || second_frame_byte != 8'haa ||
            third_frame_byte != ((expected_sync_word >> 8) & 8'hff) ||
            fourth_frame_byte != (expected_sync_word & 8'hff))
            $fatal(1, "FAIL: frame preamble/sync prefix is incorrect");

        $display("PASS: deterministic vector file contract; END_TO_END_RTL_NOT_RUN");
        $finish;
    end
endmodule

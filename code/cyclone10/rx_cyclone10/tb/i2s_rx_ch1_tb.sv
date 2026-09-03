`timescale 1ns/1ps

module i2s_rx_ch1_tb;

    logic              clk_i2s = 1'b0;
    logic              rst_i2s_n = 1'b0;
    logic              i2s_fsync = 1'b1;
    logic              i2s_sdout = 1'b0;
    logic              clear_errors = 1'b0;
    wire signed [31:0] sample_data;
    wire               sample_valid;
    wire               format_error;
    wire [15:0]        format_error_count;

    integer errors = 0;
    integer observed_samples = 0;

    always #5 clk_i2s = ~clk_i2s;

    i2s_rx_ch1 dut (
        .clk_i2s(clk_i2s),
        .rst_i2s_n(rst_i2s_n),
        .i2s_fsync(i2s_fsync),
        .i2s_sdout(i2s_sdout),
        .clear_errors(clear_errors),
        .sample_data(sample_data),
        .sample_valid(sample_valid),
        .format_error(format_error),
        .format_error_count(format_error_count)
    );

    always @(posedge clk_i2s) begin
        #1;
        if (sample_valid)
            observed_samples = observed_samples + 1;
    end

    task automatic send_stereo(input logic [31:0] left_word,
                               input logic [31:0] right_word);
        integer bit_index;
        begin
            // Entry condition: WS is already low and the next bit is CH1 MSB.
            for (bit_index = 31; bit_index >= 0; bit_index = bit_index - 1) begin
                @(negedge clk_i2s);
                i2s_sdout = left_word[bit_index];
                if (bit_index == 0)
                    i2s_fsync = 1'b1;
            end
            for (bit_index = 31; bit_index >= 0; bit_index = bit_index - 1) begin
                @(negedge clk_i2s);
                i2s_sdout = right_word[bit_index];
                if (bit_index == 0)
                    i2s_fsync = 1'b0;
            end
        end
    endtask

    task automatic expect_sample(input logic [31:0] expected_word);
        begin : wait_for_sample
            forever begin
                @(posedge clk_i2s);
                #1;
                if (sample_valid) begin
                    if (sample_data !== expected_word) begin
                        $display("ERROR: expected sample %08x, got %08x",
                                 expected_word, sample_data);
                        errors = errors + 1;
                    end
                    disable wait_for_sample;
                end
            end
        end
    endtask

    task automatic send_early_ch1_transition;
        integer bit_index;
        begin
            // Ten CH1 bit times instead of 32, followed by a valid CH2 slot.
            for (bit_index = 31; bit_index >= 22; bit_index = bit_index - 1) begin
                @(negedge clk_i2s);
                i2s_sdout = bit_index[0];
                if (bit_index == 22)
                    i2s_fsync = 1'b1;
            end
            for (bit_index = 31; bit_index >= 0; bit_index = bit_index - 1) begin
                @(negedge clk_i2s);
                i2s_sdout = 1'b0;
                if (bit_index == 0)
                    i2s_fsync = 1'b0;
            end
        end
    endtask

    task automatic send_late_ch1_transition;
        integer bit_index;
        begin
            // Keep WS low through all 32 CH1 bits; transition one BCLK late.
            for (bit_index = 31; bit_index >= 0; bit_index = bit_index - 1) begin
                @(negedge clk_i2s);
                i2s_sdout = bit_index[0];
            end
            @(negedge clk_i2s);
            i2s_sdout = 1'b0;
            i2s_fsync = 1'b1;
            for (bit_index = 31; bit_index >= 0; bit_index = bit_index - 1) begin
                @(negedge clk_i2s);
                i2s_sdout = 1'b0;
                if (bit_index == 0)
                    i2s_fsync = 1'b0;
            end
        end
    endtask

    task automatic hold_fsync_for_two_slots;
        integer bit_index;
        begin
            // Simulate a lost/stuck WS signal for two complete slot periods.
            for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1) begin
                @(negedge clk_i2s);
                i2s_sdout = bit_index[0];
                i2s_fsync = 1'b0;
            end
            // Re-establish a CH2 boundary, then send one valid CH2 slot so the
            // receiver returns to the normal CH1 boundary.
            @(negedge clk_i2s);
            i2s_sdout = 1'b0;
            i2s_fsync = 1'b1;
            for (bit_index = 31; bit_index >= 0; bit_index = bit_index - 1) begin
                @(negedge clk_i2s);
                i2s_sdout = 1'b0;
                if (bit_index == 0)
                    i2s_fsync = 1'b0;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk_i2s);
        @(negedge clk_i2s);
        rst_i2s_n = 1'b1;
        repeat (3) @(posedge clk_i2s);

        // Establish the I2S one-bit-delay boundary. This bit is the previous
        // channel's LSB; CH1 MSB follows on the next BCLK.
        @(negedge clk_i2s);
        i2s_fsync = 1'b0;
        i2s_sdout = 1'b0;
        @(posedge clk_i2s);

        fork
            begin
                send_stereo(32'h12345678, 32'hdeadbeef);
                send_stereo(32'h80000000, 32'h13579bdf);
                send_stereo(32'h7fffffff, 32'h2468ace0);
            end
            begin
                expect_sample(32'h12345678);
                expect_sample(32'h80000000);
                expect_sample(32'h7fffffff);
            end
        join
        @(posedge clk_i2s);
        #1;

        if (format_error || format_error_count != 16'd0) begin
            $display("ERROR: valid I2S stream raised format error count=%0d",
                     format_error_count);
            errors = errors + 1;
        end
        if (observed_samples != 3) begin
            $display("ERROR: CH2 leaked or CH1 missing, count=%0d",
                     observed_samples);
            errors = errors + 1;
        end

        send_early_ch1_transition();
        @(posedge clk_i2s);
        #1;
        if (!format_error || format_error_count != 16'd1) begin
            $display("ERROR: early WS edge not counted exactly once, count=%0d",
                     format_error_count);
            errors = errors + 1;
        end
        if (observed_samples != 3) begin
            $display("ERROR: malformed CH1 produced sample_valid");
            errors = errors + 1;
        end

        send_late_ch1_transition();
        @(posedge clk_i2s);
        #1;
        if (format_error_count != 16'd2) begin
            $display("ERROR: late WS edge not counted exactly once, count=%0d",
                     format_error_count);
            errors = errors + 1;
        end

        hold_fsync_for_two_slots();
        @(posedge clk_i2s);
        #1;
        if (format_error_count != 16'd4) begin
            $display("ERROR: stuck WS did not count two lost slots, count=%0d",
                     format_error_count);
            errors = errors + 1;
        end

        @(negedge clk_i2s);
        clear_errors = 1'b1;
        @(negedge clk_i2s);
        clear_errors = 1'b0;
        @(posedge clk_i2s);
        #1;
        if (format_error || format_error_count != 16'd0) begin
            $display("ERROR: clear_errors failed");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: I2S CH1 words, sign bits, channel select and WS errors verified");
        else
            $fatal(1, "FAIL: %0d I2S checks failed", errors);
        $finish;
    end

endmodule

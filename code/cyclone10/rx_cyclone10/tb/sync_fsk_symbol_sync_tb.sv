`timescale 1ns/1ps

module sync_fsk_symbol_sync_tb;

    localparam int ENERGY_WIDTH = 16;
    localparam int CONFIDENCE_WIDTH = 8;

    logic clk = 1'b0;
    logic reset_n = 1'b0;
    logic metric_valid = 1'b0;
    logic hard_bit = 1'b0;
    logic [ENERGY_WIDTH-1:0] total_energy = '0;
    logic [CONFIDENCE_WIDTH-1:0] confidence = '0;
    logic carrier_present = 1'b0;
    logic [CONFIDENCE_WIDTH-1:0] preamble_confidence_threshold = 8'd140;

    wire carrier_active;
    wire sync_locked;
    wire preamble_detected;
    wire lock_lost;
    wire search_timeout;
    wire bit_valid;
    wire bit_value;
    wire [ENERGY_WIDTH-1:0] symbol_energy;
    wire [CONFIDENCE_WIDTH-1:0] symbol_confidence;
    wire [3:0] selected_phase;
    wire signed [1:0] timing_adjust;

    integer errors = 0;
    integer lock_count = 0;
    integer lost_count = 0;
    integer timeout_count = 0;
    integer metric_number = 0;
    integer output_count = 0;
    integer adjust_late_count = 0;
    integer adjust_early_count = 0;

    fsk_symbol_sync #(
        .ENERGY_WIDTH(ENERGY_WIDTH),
        .CONFIDENCE_WIDTH(CONFIDENCE_WIDTH),
        .LOCK_TIMEOUT_SYMBOLS(80),
        .TIMING_HYSTERESIS(8'd4)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .metric_valid(metric_valid),
        .hard_bit(hard_bit),
        .total_energy(total_energy),
        .confidence(confidence),
        .carrier_present(carrier_present),
        .preamble_confidence_threshold(preamble_confidence_threshold),
        .carrier_active(carrier_active),
        .sync_locked(sync_locked),
        .preamble_detected(preamble_detected),
        .lock_lost(lock_lost),
        .search_timeout(search_timeout),
        .bit_valid(bit_valid),
        .bit_value(bit_value),
        .symbol_energy(symbol_energy),
        .symbol_confidence(symbol_confidence),
        .selected_phase(selected_phase),
        .timing_adjust(timing_adjust)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (preamble_detected)
            lock_count = lock_count + 1;
        if (lock_lost)
            lost_count = lost_count + 1;
        if (search_timeout)
            timeout_count = timeout_count + 1;
        if (bit_valid)
            output_count = output_count + 1;
        if (timing_adjust == 2'sd1)
            adjust_late_count = adjust_late_count + 1;
        if (timing_adjust == -2'sd1)
            adjust_early_count = adjust_early_count + 1;
    end

    function automatic bit preamble_bit(input integer symbol_index,
                                          input integer error_count);
        bit value;
        begin
            value = ((symbol_index & 1) == 0);
            if ((error_count >= 1 && symbol_index == 3) ||
                (error_count >= 2 && symbol_index == 9) ||
                (error_count >= 3 && symbol_index == 13))
                value = ~value;
            preamble_bit = value;
        end
    endfunction

    function automatic [7:0] phase_confidence(input integer tick,
                                               input integer offset);
        integer phase_position;
        integer distance;
        begin
            phase_position = (tick + 10 - offset) % 10;
            distance = (phase_position > 5) ? (phase_position - 5) : (5 - phase_position);
            phase_confidence = 8'(230 - (distance * 14));
        end
    endfunction

    task automatic drive_metric(input bit value,
                                input bit present,
                                input [7:0] quality,
                                input [ENERGY_WIDTH-1:0] energy);
        begin
            @(negedge clk);
            hard_bit = value;
            carrier_present = present;
            confidence = quality;
            total_energy = energy;
            metric_valid = 1'b1;
            metric_number = metric_number + 1;
            @(posedge clk);
            #1;
            @(negedge clk);
            metric_valid = 1'b0;
        end
    endtask

    task automatic apply_reset;
        begin
            @(negedge clk);
            reset_n = 1'b0;
            metric_valid = 1'b0;
            carrier_present = 1'b0;
            hard_bit = 1'b0;
            confidence = '0;
            total_energy = '0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset_n = 1'b1;
            repeat (2) @(posedge clk);
            lock_count = 0;
            lost_count = 0;
            timeout_count = 0;
            output_count = 0;
            adjust_late_count = 0;
            adjust_early_count = 0;
            metric_number = 0;
        end
    endtask

    task automatic send_preamble(input integer offset,
                                 input integer error_count);
        integer tick;
        integer symbol_index;
        bit value;
        begin
            // The fifth carrier metric is also phase candidate zero.
            for (tick = 0; tick < 4; tick = tick + 1)
                drive_metric(1'b1, 1'b1, 8'd180, 16'd1200);

            for (tick = 0; tick < 160; tick = tick + 1) begin
                symbol_index = (tick + 10 - offset) / 10;
                if (symbol_index < 16)
                    value = preamble_bit(symbol_index, error_count);
                else
                    value = 1'b0;
                drive_metric(value, 1'b1, phase_confidence(tick, offset), 16'd2000);
            end
            // The hardware evaluates one of ten candidate phases per clock.
            repeat (14) @(posedge clk);
        end
    endtask

    task automatic expect_lock(input integer offset,
                               input integer error_count,
                               input string label_text);
        begin
            apply_reset();
            send_preamble(offset, error_count);
            if (!sync_locked || lock_count != 1) begin
                $error("%s: expected lock, locked=%0b lock_count=%0d", label_text,
                       sync_locked, lock_count);
                errors = errors + 1;
            end
            if (selected_phase > 9) begin
                $error("%s: selected phase out of range: %0d", label_text, selected_phase);
                errors = errors + 1;
            end
        end
    endtask

    task automatic test_three_error_rejection;
        begin
            apply_reset();
            send_preamble(9, 3);
            if (sync_locked || lock_count != 0 || timeout_count != 1) begin
                $error("three-error preamble was not rejected: lock=%0b locks=%0d timeouts=%0d",
                       sync_locked, lock_count, timeout_count);
                errors = errors + 1;
            end
            if (carrier_active) begin
                $error("carrier feedback remained active after search timeout");
                errors = errors + 1;
            end
        end
    endtask

    task automatic test_timing_correction;
        integer first_tick;
        integer second_tick;
        integer third_tick;
        begin
            expect_lock(7, 0, "timing-acquisition");

            // The first post-preamble bit changes 0 -> 1. A stronger late
            // metric requests a one-millisecond later next sample.
            while (!bit_valid)
                drive_metric(1'b1, 1'b1, 8'd100, 16'd2100);
            first_tick = metric_number;
            drive_metric(1'b1, 1'b1, 8'd240, 16'd2100);
            repeat (2) @(posedge clk);
            if (adjust_late_count != 1) begin
                $error("late correction was not generated");
                errors = errors + 1;
            end

            // Change to zero and make the early metric stronger than late.
            while (!bit_valid)
                drive_metric(1'b0, 1'b1, 8'd240, 16'd2100);
            second_tick = metric_number;
            if ((second_tick - first_tick) != 11) begin
                $error("late correction interval=%0d, expected 11",
                       second_tick - first_tick);
                errors = errors + 1;
            end
            drive_metric(1'b0, 1'b1, 8'd80, 16'd2100);
            repeat (2) @(posedge clk);
            if (adjust_early_count != 1) begin
                $error("early correction was not generated");
                errors = errors + 1;
            end

            while (!bit_valid)
                drive_metric(1'b1, 1'b1, 8'd180, 16'd2100);
            third_tick = metric_number;
            if ((third_tick - second_tick) != 9) begin
                $error("early correction interval=%0d, expected 9",
                       third_tick - second_tick);
                errors = errors + 1;
            end
        end
    endtask

    task automatic test_low_energy_loss;
        integer metrics_sent;
        integer outputs_before;
        begin
            expect_lock(5, 0, "low-energy-acquisition");
            metrics_sent = 0;
            outputs_before = output_count;

            while (sync_locked && metrics_sent < 40) begin
                drive_metric(1'b1, 1'b0, 8'd20, 16'd10);
                metrics_sent = metrics_sent + 1;
                if ((output_count - outputs_before) <= 2 && !sync_locked && !lock_lost) begin
                    $error("lock disappeared without a loss pulse");
                    errors = errors + 1;
                end
            end

            repeat (2) @(posedge clk);
            if (sync_locked || lost_count != 1) begin
                $error("three low-energy symbols did not lose lock: locked=%0b lost=%0d",
                       sync_locked, lost_count);
                errors = errors + 1;
            end
            if ((output_count - outputs_before) != 2) begin
                $error("low-energy path emitted %0d bits, expected first two only",
                       output_count - outputs_before);
                errors = errors + 1;
            end
            if (metrics_sent < 20) begin
                $error("lock was lost before two complete low-energy symbols");
                errors = errors + 1;
            end
        end
    endtask

    task automatic test_low_confidence_holds_lock;
        integer metric_index;
        integer outputs_before;
        begin
            expect_lock(5, 0, "low-confidence-hold");
            outputs_before = output_count;

            // Confidence describes bit-decision quality, not whether signal
            // energy is present.  Sustained low confidence must therefore
            // keep symbol lock while carrier_present remains asserted.
            for (metric_index = 0; metric_index < 40; metric_index = metric_index + 1)
                drive_metric(1'b1, 1'b1, 8'd0, 16'd2100);

            repeat (2) @(posedge clk);
            if (!sync_locked || lost_count != 0) begin
                $error("low confidence incorrectly caused carrier loss: locked=%0b lost=%0d",
                       sync_locked, lost_count);
                errors = errors + 1;
            end
            if ((output_count - outputs_before) < 3) begin
                $error("low-confidence hold emitted only %0d bits, expected at least 3",
                       output_count - outputs_before);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        expect_lock(2, 0, "random-start-offset-2");
        expect_lock(7, 2, "two-error-preamble");
        expect_lock(9, 0, "random-start-offset-9");
        test_three_error_rejection();
        test_timing_correction();
        test_low_confidence_holds_lock();
        test_low_energy_loss();

        if (errors == 0) begin
            $display("PASS: random phase, preamble errors, timing tracking, low-confidence hold, and low-energy loss verified");
            $finish;
        end else begin
            $fatal(1, "FAIL: %0d symbol synchronizer checks failed", errors);
        end
    end

    initial begin
        #2000000;
        $fatal(1, "FAIL: simulation timeout");
    end

endmodule

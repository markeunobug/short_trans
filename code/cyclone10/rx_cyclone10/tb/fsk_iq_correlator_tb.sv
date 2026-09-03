`timescale 1ns/1ps

module fsk_iq_correlator_tb;
    localparam integer SAMPLE_COUNT = 5376;
    localparam integer METRIC_COUNT = 103;

    logic clk;
    logic reset_n;
    logic sample_valid;
    logic signed [19:0] sample_data;
    logic [7:0] confidence_threshold;

    wire metric_valid;
    wire hard_bit;
    wire signed [32:0] soft_metric;
    wire [32:0] total_energy;
    wire [7:0] confidence;
    wire confidence_ok;
    wire [31:0] energy_f0;
    wire [31:0] energy_f1;

    logic signed [19:0] sample_vectors [0:SAMPLE_COUNT-1];
    logic [138:0] expected_metrics [0:METRIC_COUNT-1];
    logic [138:0] expected_current;

    integer vector_index;
    integer accepted_samples;
    integer metric_sample;
    integer metric_index;
    integer last_metric_sample;
    integer errors;
    integer stable_checks;

    fsk_iq_correlator dut (
        .clk                  (clk),
        .reset_n              (reset_n),
        .sample_valid         (sample_valid),
        .sample_data          (sample_data),
        .confidence_threshold (confidence_threshold),
        .metric_valid         (metric_valid),
        .hard_bit             (hard_bit),
        .soft_metric          (soft_metric),
        .total_energy         (total_energy),
        .confidence           (confidence),
        .confidence_ok        (confidence_ok),
        .energy_f0            (energy_f0),
        .energy_f1            (energy_f1)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (reset_n && sample_valid)
            accepted_samples = accepted_samples + 1;

        #1;
        if (reset_n && metric_valid) begin
            // Metric arithmetic is multi-cycle; associate each ordered result
            // with the accepted-sample boundary that launched it.
            metric_sample = 480 + (metric_index * 48);
            if (metric_index >= METRIC_COUNT) begin
                $error("unexpected metric after expected vector exhausted");
                errors = errors + 1;
            end else begin
                expected_current = expected_metrics[metric_index];

                if (energy_f0 !== expected_current[31:0]) begin
                    $error("metric %0d E0 got %0d expected %0d",
                           metric_index, energy_f0, expected_current[31:0]);
                    errors = errors + 1;
                end
                if (energy_f1 !== expected_current[63:32]) begin
                    $error("metric %0d E1 got %0d expected %0d",
                           metric_index, energy_f1, expected_current[63:32]);
                    errors = errors + 1;
                end
                if (soft_metric !== $signed(expected_current[96:64])) begin
                    $error("metric %0d soft got %0d expected %0d",
                           metric_index,
                           $signed(soft_metric),
                           $signed(expected_current[96:64]));
                    errors = errors + 1;
                end
                if (total_energy !== expected_current[129:97]) begin
                    $error("metric %0d total got %0d expected %0d",
                           metric_index,
                           total_energy,
                           expected_current[129:97]);
                    errors = errors + 1;
                end
                if (confidence !== expected_current[137:130]) begin
                    $error("metric %0d confidence got %0d expected %0d",
                           metric_index,
                           confidence,
                           expected_current[137:130]);
                    errors = errors + 1;
                end
                if (hard_bit !== expected_current[138]) begin
                    $error("metric %0d hard bit got %0b expected %0b",
                           metric_index, hard_bit, expected_current[138]);
                    errors = errors + 1;
                end
                if (total_energy !== ({1'b0, energy_f0} + {1'b0, energy_f1})) begin
                    $error("metric %0d total energy identity failed", metric_index);
                    errors = errors + 1;
                end
                if (confidence_ok !== (confidence >= 8'd128)) begin
                    $error("metric %0d confidence threshold mismatch", metric_index);
                    errors = errors + 1;
                end

                // Explicit stable-window checks supplement bit-exact vectors.
                if ((metric_sample >= 1056 && metric_sample <= 1536) ||
                    (metric_sample >= 2976 && metric_sample <= 3456) ||
                    (metric_sample >= 4896 && metric_sample <= 5376)) begin
                    stable_checks = stable_checks + 1;
                    if (hard_bit !== 1'b0 || soft_metric >= 0) begin
                        $error("stable f0 decision failed at sample %0d",
                               metric_sample);
                        errors = errors + 1;
                    end
                end
                if ((metric_sample >= 2016 && metric_sample <= 2496) ||
                    (metric_sample >= 3936 && metric_sample <= 4416)) begin
                    stable_checks = stable_checks + 1;
                    if (hard_bit !== 1'b1 || soft_metric <= 0) begin
                        $error("stable f1 decision failed at sample %0d",
                               metric_sample);
                        errors = errors + 1;
                    end
                end

                last_metric_sample = metric_sample;
                metric_index = metric_index + 1;
            end
        end
    end

    initial begin
        $readmemh(
            "tb/fsk_correlator_samples.mem",
            sample_vectors
        );
        $readmemh(
            "tb/fsk_correlator_expected.mem",
            expected_metrics
        );

        reset_n = 1'b0;
        sample_valid = 1'b0;
        sample_data = 20'sd0;
        confidence_threshold = 8'd128;
        accepted_samples = 0;
        metric_index = 0;
        last_metric_sample = 0;
        errors = 0;
        stable_checks = 0;

        repeat (5) @(negedge clk);
        reset_n = 1'b1;

        for (vector_index = 0;
             vector_index < SAMPLE_COUNT;
             vector_index = vector_index + 1) begin
            @(negedge clk);
            sample_data = sample_vectors[vector_index];
            sample_valid = 1'b1;
            if ((vector_index % 17) == 16) begin
                @(negedge clk);
                sample_valid = 1'b0;
            end
        end

        @(negedge clk);
        sample_valid = 1'b0;
        repeat (16) @(negedge clk);

        if (accepted_samples != SAMPLE_COUNT) begin
            $error("accepted %0d samples, expected %0d",
                   accepted_samples, SAMPLE_COUNT);
            errors = errors + 1;
        end
        if (metric_index != METRIC_COUNT) begin
            $error("observed %0d metrics, expected %0d",
                   metric_index, METRIC_COUNT);
            errors = errors + 1;
        end
        if (stable_checks < 40) begin
            $error("only %0d stable-window checks ran", stable_checks);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: %0d bit-exact metrics, %0d stable decisions",
                     metric_index, stable_checks);
        else
            $fatal(1, "FAIL: %0d correlator errors", errors);
        $finish;
    end
endmodule

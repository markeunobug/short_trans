`timescale 1ns/1ps

module fsk_noise_tracker_tb;
    logic clk;
    logic reset_n;
    logic metric_valid;
    logic [32:0] total_energy;
    logic noise_track_enable;
    logic carrier_active;
    logic [7:0] noise_multiplier_q4_4;
    logic [32:0] noise_offset;

    wire [32:0] noise_energy;
    wire [32:0] carrier_threshold;
    wire energy_above_threshold;
    wire noise_ready;
    wire noise_update;

    integer errors;
    integer update_index;
    logic [32:0] frozen_noise;

    fsk_noise_tracker dut (
        .clk                    (clk),
        .reset_n                (reset_n),
        .metric_valid           (metric_valid),
        .total_energy           (total_energy),
        .noise_track_enable     (noise_track_enable),
        .carrier_active         (carrier_active),
        .noise_multiplier_q4_4  (noise_multiplier_q4_4),
        .noise_offset           (noise_offset),
        .noise_energy           (noise_energy),
        .carrier_threshold      (carrier_threshold),
        .energy_above_threshold (energy_above_threshold),
        .noise_ready            (noise_ready),
        .noise_update           (noise_update)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task send_metric;
        input [32:0] value;
        input expected_update;
        begin
            @(negedge clk);
            total_energy = value;
            metric_valid = 1'b1;
            @(posedge clk);
            #1;
            if (noise_update !== expected_update) begin
                $error("noise_update got %0b expected %0b for energy %0d",
                       noise_update, expected_update, value);
                errors = errors + 1;
            end
            @(negedge clk);
            metric_valid = 1'b0;
            @(posedge clk);
            #1;
            if (noise_update !== 1'b0) begin
                $error("noise_update was not a one-cycle pulse");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        reset_n = 1'b0;
        metric_valid = 1'b0;
        total_energy = 33'd0;
        noise_track_enable = 1'b1;
        carrier_active = 1'b0;
        noise_multiplier_q4_4 = 8'h40;
        noise_offset = 33'd200;
        errors = 0;

        repeat (4) @(negedge clk);
        reset_n = 1'b1;

        total_energy = 33'd80;
        #1;
        if (energy_above_threshold !== 1'b0) begin
            $error("startup noise was reported as a carrier before noise_ready");
            errors = errors + 1;
        end
        send_metric(33'd80, 1'b1);
        if (!noise_ready || noise_energy != 33'd80) begin
            $error("first idle metric did not seed noise estimate");
            errors = errors + 1;
        end
        if (carrier_threshold != 33'd520) begin
            $error("threshold got %0d expected 520", carrier_threshold);
            errors = errors + 1;
        end

        for (update_index = 0; update_index < 32; update_index = update_index + 1)
            send_metric(33'd112, 1'b1);
        if (noise_energy <= 33'd80 || noise_energy >= 33'd112) begin
            $error("EWMA failed to move toward idle energy: %0d", noise_energy);
            errors = errors + 1;
        end

        frozen_noise = noise_energy;
        total_energy = carrier_threshold + 33'd1000;
        #1;
        if (!energy_above_threshold) begin
            $error("carrier candidate did not cross threshold");
            errors = errors + 1;
        end
        send_metric(carrier_threshold + 33'd1000, 1'b0);
        if (noise_energy != frozen_noise) begin
            $error("candidate carrier was learned into noise");
            errors = errors + 1;
        end

        carrier_active = 1'b1;
        send_metric(33'd20, 1'b0);
        if (noise_energy != frozen_noise) begin
            $error("carrier_active did not freeze noise estimate");
            errors = errors + 1;
        end

        carrier_active = 1'b0;
        noise_track_enable = 1'b0;
        send_metric(33'd20, 1'b0);
        if (noise_energy != frozen_noise) begin
            $error("noise_track_enable did not gate updates");
            errors = errors + 1;
        end

        noise_track_enable = 1'b1;
        send_metric(33'd20, 1'b1);
        if (noise_energy >= frozen_noise) begin
            $error("downward EWMA update failed");
            errors = errors + 1;
        end

        noise_offset = {33{1'b1}};
        #1;
        if (carrier_threshold != {33{1'b1}}) begin
            $error("threshold saturation failed");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: EWMA, threshold, freeze, gate, and saturation");
        else
            $fatal(1, "FAIL: %0d noise tracker errors", errors);
        $finish;
    end
endmodule

`timescale 1ns/1ps

// Integration wrapper for Task 4. carrier_active is fed back by Task 5 after
// carrier confirmation/lock; energy_above_threshold is the 1 ms candidate.
module fsk_demod_core (
    input  wire                  clk,
    input  wire                  reset_n,
    input  wire                  sample_valid,
    input  wire signed [19:0]    sample_data,
    input  wire                  noise_track_enable,
    input  wire                  carrier_active,
    input  wire [7:0]            noise_multiplier_q4_4,
    input  wire [15:0]           noise_offset,
    input  wire [7:0]            confidence_threshold,
    output wire                  metric_valid,
    output wire                  hard_bit,
    output wire signed [32:0]    soft_metric,
    output wire [32:0]           total_energy,
    output wire [7:0]            confidence,
    output wire                  confidence_ok,
    output wire [31:0]           energy_f0,
    output wire [31:0]           energy_f1,
    output wire [32:0]           noise_energy,
    output wire [32:0]           carrier_threshold,
    output wire                  energy_above_threshold,
    output wire                  noise_ready,
    output wire                  noise_update
);

    fsk_iq_correlator correlator (
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

    fsk_noise_tracker noise_tracker (
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

endmodule


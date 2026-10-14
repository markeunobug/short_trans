`timescale 1ns/1ps

// Idle-time EWMA estimator for the scaled correlator total-energy domain.
// noise_multiplier_q4_4 uses unsigned Q4.4 format; 8'h40 means 4.0x.
module fsk_noise_tracker #(
    parameter integer ENERGY_WIDTH = 33,
    parameter integer EWMA_SHIFT   = 5
) (
    input  wire                         clk,
    input  wire                         reset_n,
    input  wire                         metric_valid,
    input  wire [ENERGY_WIDTH-1:0]      total_energy,
    input  wire                         noise_track_enable,
    input  wire                         carrier_active,
    input  wire [7:0]                   noise_multiplier_q4_4,
    input  wire [ENERGY_WIDTH-1:0]      noise_offset,
    output reg  [ENERGY_WIDTH-1:0]      noise_energy,
    output wire [ENERGY_WIDTH-1:0]      carrier_threshold,
    output wire                         energy_above_threshold,
    output reg                          noise_ready,
    output reg                          noise_update
);

    wire [ENERGY_WIDTH+7:0] multiplied_noise =
        noise_energy * noise_multiplier_q4_4;
    wire [ENERGY_WIDTH+7:0] rounded_multiplied_noise =
        multiplied_noise + {{(ENERGY_WIDTH+4){1'b0}}, 4'd8};
    wire [ENERGY_WIDTH+7:0] scaled_noise =
        rounded_multiplied_noise >> 4;
    wire [ENERGY_WIDTH+8:0] threshold_sum =
        {1'b0, scaled_noise} + {{9{1'b0}}, noise_offset};

    assign carrier_threshold =
        (|(threshold_sum[ENERGY_WIDTH+8:ENERGY_WIDTH])) ?
        {ENERGY_WIDTH{1'b1}} :
        threshold_sum[ENERGY_WIDTH-1:0];

    // Do not call positive startup noise a carrier while the baseline is
    // still uninitialized. Without this gate, noise_energy=0 makes the
    // threshold zero and prevents the idle estimator from ever bootstrapping.
    assign energy_above_threshold = noise_ready &&
                                    (total_energy > carrier_threshold);

    wire [ENERGY_WIDTH-1:0] upward_difference =
        total_energy - noise_energy;
    wire [ENERGY_WIDTH-1:0] downward_difference =
        noise_energy - total_energy;
    wire [ENERGY_WIDTH-1:0] ewma_rounding =
        {{(ENERGY_WIDTH-EWMA_SHIFT){1'b0}},
         1'b1,
         {(EWMA_SHIFT-1){1'b0}}};
    wire [ENERGY_WIDTH:0] upward_step_wide =
        {1'b0, upward_difference} + {1'b0, ewma_rounding};
    wire [ENERGY_WIDTH:0] downward_step_wide =
        {1'b0, downward_difference} + {1'b0, ewma_rounding};
    wire [ENERGY_WIDTH-1:0] upward_step =
        {{(EWMA_SHIFT-1){1'b0}},
         upward_step_wide[ENERGY_WIDTH:EWMA_SHIFT]};
    wire [ENERGY_WIDTH-1:0] downward_step =
        {{(EWMA_SHIFT-1){1'b0}},
         downward_step_wide[ENERGY_WIDTH:EWMA_SHIFT]};

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            noise_energy <= {ENERGY_WIDTH{1'b0}};
            noise_ready  <= 1'b0;
            noise_update <= 1'b0;
        end else begin
            noise_update <= 1'b0;
            if (metric_valid &&
                noise_track_enable &&
                !carrier_active &&
                !energy_above_threshold) begin
                noise_update <= 1'b1;
                if (!noise_ready) begin
                    noise_energy <= total_energy;
                    noise_ready  <= 1'b1;
                end else if (total_energy >= noise_energy) begin
                    noise_energy <= noise_energy + upward_step;
                end else begin
                    noise_energy <= noise_energy - downward_step;
                end
            end
        end
    end

endmodule

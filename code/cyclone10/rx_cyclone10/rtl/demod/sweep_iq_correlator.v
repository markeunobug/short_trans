`timescale 1ns/1ps
`default_nettype none

// Single-tone non-coherent measurement path used only by sweep diagnostics.
// Each configured window produces E = I^2 + Q^2. Multiple window energies
// are accumulated here; software divides energy_sum by result_window_count.
module sweep_iq_correlator #(
    parameter integer INPUT_WIDTH       = 20,
    parameter integer COEFFICIENT_WIDTH = 16,
    parameter integer PRODUCT_WIDTH     = 36,
    parameter integer ACCUMULATOR_WIDTH = 52,
    parameter integer CORRELATOR_SHIFT  = 24,
    parameter integer CORRELATOR_WIDTH  = 24,
    parameter integer ENERGY_SHIFT      = 16,
    parameter integer ENERGY_WIDTH      = 32
) (
    input  wire                              clk,
    input  wire                              reset_n,
    input  wire                              start_pulse,
    input  wire                              abort_pulse,
    input  wire [31:0]                       phase_increment,
    input  wire [15:0]                       settle_samples,
    input  wire [15:0]                       window_samples,
    input  wire [7:0]                        average_count,
    input  wire                              sample_valid,
    input  wire signed [INPUT_WIDTH-1:0]     sample_data,
    input  wire                              sample_clipped,

    output reg                               active,
    output reg                               busy,
    output reg                               done,
    output reg                               error,
    output reg [63:0]                        result_energy_sum,
    output reg [ENERGY_WIDTH-1:0]            result_energy_min,
    output reg [ENERGY_WIDTH-1:0]            result_energy_max,
    output reg [31:0]                        result_clip_count,
    output reg [7:0]                         result_window_count
);

    localparam [1:0] STATE_IDLE    = 2'd0;
    localparam [1:0] STATE_SETTLE  = 2'd1;
    localparam [1:0] STATE_MEASURE = 2'd2;
    localparam [1:0] STATE_WAIT    = 2'd3;

    reg [1:0] state;
    reg [31:0] phase_accumulator;
    wire [7:0] sine_phase = phase_accumulator[31:24];
    wire [7:0] cosine_phase = sine_phase + 8'd64;
    wire signed [COEFFICIENT_WIDTH-1:0] sine_coefficient;
    wire signed [COEFFICIENT_WIDTH-1:0] cosine_coefficient;

    sweep_sine_lut u_sine_lut (
        .phase(sine_phase),
        .sine(sine_coefficient)
    );
    sweep_sine_lut u_cosine_lut (
        .phase(cosine_phase),
        .sine(cosine_coefficient)
    );

    wire signed [PRODUCT_WIDTH-1:0] product_i = sample_data * cosine_coefficient;
    wire signed [PRODUCT_WIDTH-1:0] product_q = sample_data * sine_coefficient;

    reg signed [ACCUMULATOR_WIDTH-1:0] accumulator_i;
    reg signed [ACCUMULATOR_WIDTH-1:0] accumulator_q;
    wire signed [ACCUMULATOR_WIDTH-1:0] product_i_extended =
        {{(ACCUMULATOR_WIDTH-PRODUCT_WIDTH){product_i[PRODUCT_WIDTH-1]}}, product_i};
    wire signed [ACCUMULATOR_WIDTH-1:0] product_q_extended =
        {{(ACCUMULATOR_WIDTH-PRODUCT_WIDTH){product_q[PRODUCT_WIDTH-1]}}, product_q};
    wire signed [ACCUMULATOR_WIDTH-1:0] next_i = accumulator_i + product_i_extended;
    wire signed [ACCUMULATOR_WIDTH-1:0] next_q = accumulator_q + product_q_extended;

    reg [15:0] settle_count;
    reg [15:0] window_sample_count;
    reg [7:0] windows_started;
    reg [7:0] windows_completed;
    reg [31:0] clip_count;
    reg [63:0] energy_sum;
    reg [ENERGY_WIDTH-1:0] energy_min;
    reg [ENERGY_WIDTH-1:0] energy_max;

    reg signed [CORRELATOR_WIDTH-1:0] metric_i;
    reg signed [CORRELATOR_WIDTH-1:0] metric_q;
    reg metric_pending;
    reg metric_last;

    function signed [CORRELATOR_WIDTH-1:0] scale_correlator;
        input signed [ACCUMULATOR_WIDTH-1:0] value;
        reg [ACCUMULATOR_WIDTH:0] magnitude;
        reg [ACCUMULATOR_WIDTH:0] shifted;
        reg [ACCUMULATOR_WIDTH:0] rounded;
        begin
            magnitude = value[ACCUMULATOR_WIDTH-1]
                            ? ({1'b0, ~value} + 1'b1)
                            : {1'b0, value};
            rounded = magnitude +
                ({{ACCUMULATOR_WIDTH{1'b0}}, 1'b1} << (CORRELATOR_SHIFT-1));
            shifted = rounded >> CORRELATOR_SHIFT;
            if (|shifted[ACCUMULATOR_WIDTH:CORRELATOR_WIDTH-1]) begin
                scale_correlator = value[ACCUMULATOR_WIDTH-1]
                    ? {1'b1, {(CORRELATOR_WIDTH-1){1'b0}}}
                    : {1'b0, {(CORRELATOR_WIDTH-1){1'b1}}};
            end else if (value[ACCUMULATOR_WIDTH-1]) begin
                scale_correlator = -$signed(shifted[CORRELATOR_WIDTH-1:0]);
            end else begin
                scale_correlator = $signed(shifted[CORRELATOR_WIDTH-1:0]);
            end
        end
    endfunction

    wire signed [(2*CORRELATOR_WIDTH)-1:0] square_i_signed = metric_i * metric_i;
    wire signed [(2*CORRELATOR_WIDTH)-1:0] square_q_signed = metric_q * metric_q;
    wire [(2*CORRELATOR_WIDTH):0] energy_raw =
        {1'b0, square_i_signed} + {1'b0, square_q_signed};

    function [ENERGY_WIDTH-1:0] scale_energy;
        input [(2*CORRELATOR_WIDTH):0] value;
        reg [(2*CORRELATOR_WIDTH):0] rounded;
        reg [(2*CORRELATOR_WIDTH):0] shifted;
        begin
            rounded = value +
                ({{(2*CORRELATOR_WIDTH){1'b0}}, 1'b1} << (ENERGY_SHIFT-1));
            shifted = rounded >> ENERGY_SHIFT;
            if (|shifted[(2*CORRELATOR_WIDTH):ENERGY_WIDTH])
                scale_energy = {ENERGY_WIDTH{1'b1}};
            else
                scale_energy = shifted[ENERGY_WIDTH-1:0];
        end
    endfunction

    wire [ENERGY_WIDTH-1:0] metric_energy = scale_energy(energy_raw);
    wire [63:0] next_energy_sum = energy_sum + metric_energy;
    wire [ENERGY_WIDTH-1:0] next_energy_min =
        (windows_completed == 0 || metric_energy < energy_min) ? metric_energy : energy_min;
    wire [ENERGY_WIDTH-1:0] next_energy_max =
        (windows_completed == 0 || metric_energy > energy_max) ? metric_energy : energy_max;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= STATE_IDLE;
            active <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            phase_accumulator <= 32'd0;
            settle_count <= 16'd0;
            window_sample_count <= 16'd0;
            windows_started <= 8'd0;
            windows_completed <= 8'd0;
            accumulator_i <= {ACCUMULATOR_WIDTH{1'b0}};
            accumulator_q <= {ACCUMULATOR_WIDTH{1'b0}};
            clip_count <= 32'd0;
            energy_sum <= 64'd0;
            energy_min <= {ENERGY_WIDTH{1'b1}};
            energy_max <= {ENERGY_WIDTH{1'b0}};
            metric_i <= {CORRELATOR_WIDTH{1'b0}};
            metric_q <= {CORRELATOR_WIDTH{1'b0}};
            metric_pending <= 1'b0;
            metric_last <= 1'b0;
            result_energy_sum <= 64'd0;
            result_energy_min <= {ENERGY_WIDTH{1'b0}};
            result_energy_max <= {ENERGY_WIDTH{1'b0}};
            result_clip_count <= 32'd0;
            result_window_count <= 8'd0;
        end else if (abort_pulse) begin
            state <= STATE_IDLE;
            active <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            metric_pending <= 1'b0;
        end else if (start_pulse) begin
            phase_accumulator <= 32'd0;
            settle_count <= 16'd0;
            window_sample_count <= 16'd0;
            windows_started <= 8'd0;
            windows_completed <= 8'd0;
            accumulator_i <= {ACCUMULATOR_WIDTH{1'b0}};
            accumulator_q <= {ACCUMULATOR_WIDTH{1'b0}};
            clip_count <= 32'd0;
            energy_sum <= 64'd0;
            energy_min <= {ENERGY_WIDTH{1'b1}};
            energy_max <= {ENERGY_WIDTH{1'b0}};
            metric_pending <= 1'b0;
            metric_last <= 1'b0;
            result_energy_sum <= 64'd0;
            result_energy_min <= {ENERGY_WIDTH{1'b0}};
            result_energy_max <= {ENERGY_WIDTH{1'b0}};
            result_clip_count <= 32'd0;
            result_window_count <= 8'd0;
            done <= 1'b0;
            if ((phase_increment == 0) || (window_samples == 0) ||
                (average_count == 0)) begin
                state <= STATE_IDLE;
                active <= 1'b0;
                busy <= 1'b0;
                error <= 1'b1;
                done <= 1'b1;
            end else begin
                state <= (settle_samples == 0) ? STATE_MEASURE : STATE_SETTLE;
                active <= 1'b1;
                busy <= 1'b1;
                error <= 1'b0;
            end
        end else begin
            if (metric_pending) begin
                metric_pending <= 1'b0;
                energy_sum <= next_energy_sum;
                energy_min <= next_energy_min;
                energy_max <= next_energy_max;
                windows_completed <= windows_completed + 1'b1;
                if (metric_last) begin
                    state <= STATE_IDLE;
                    busy <= 1'b0;
                    done <= 1'b1;
                    result_energy_sum <= next_energy_sum;
                    result_energy_min <= next_energy_min;
                    result_energy_max <= next_energy_max;
                    result_clip_count <= clip_count;
                    result_window_count <= windows_completed + 1'b1;
                end
            end

            if (sample_valid && busy) begin
                phase_accumulator <= phase_accumulator + phase_increment;
                if (state == STATE_SETTLE) begin
                    if (settle_count == (settle_samples - 1'b1)) begin
                        settle_count <= 16'd0;
                        state <= STATE_MEASURE;
                    end else begin
                        settle_count <= settle_count + 1'b1;
                    end
                end else if (state == STATE_MEASURE) begin
                    accumulator_i <= next_i;
                    accumulator_q <= next_q;
                    if (sample_clipped)
                        clip_count <= clip_count + 1'b1;

                    if (window_sample_count == (window_samples - 1'b1)) begin
                        metric_i <= scale_correlator(next_i);
                        metric_q <= scale_correlator(next_q);
                        metric_pending <= 1'b1;
                        metric_last <= ((windows_started + 1'b1) >= average_count);
                        windows_started <= windows_started + 1'b1;
                        window_sample_count <= 16'd0;
                        accumulator_i <= {ACCUMULATOR_WIDTH{1'b0}};
                        accumulator_q <= {ACCUMULATOR_WIDTH{1'b0}};
                        if ((windows_started + 1'b1) >= average_count)
                            state <= STATE_WAIT;
                    end else begin
                        window_sample_count <= window_sample_count + 1'b1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire

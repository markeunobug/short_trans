`timescale 1ns/1ps

// Non-coherent dual-tone correlator for 48 kSPS, 1.6/2.0 kHz 2FSK.
// The history RAM contains the four products, so a true 480-sample sliding
// window is updated with one add and one subtract for every accepted sample.
module fsk_iq_correlator #(
    parameter integer INPUT_WIDTH         = 20,
    parameter integer COEFFICIENT_WIDTH   = 16,
    parameter integer PRODUCT_WIDTH       = 36,
    parameter integer WINDOW_SAMPLES      = 480,
    parameter integer METRIC_STEP_SAMPLES = 48,
    parameter integer ACCUMULATOR_WIDTH   = 45,
    parameter integer CORRELATOR_SHIFT    = 20,
    parameter integer CORRELATOR_WIDTH    = 24,
    parameter integer ENERGY_SHIFT        = 16,
    parameter integer ENERGY_WIDTH        = 32,
    parameter integer CONFIDENCE_WIDTH    = 8
) (
    input  wire                                  clk,
    input  wire                                  reset_n,
    input  wire                                  sample_valid,
    input  wire signed [INPUT_WIDTH-1:0]         sample_data,
    input  wire        [CONFIDENCE_WIDTH-1:0]    confidence_threshold,

    output reg                                   metric_valid,
    output reg                                   hard_bit,
    output reg  signed [ENERGY_WIDTH:0]          soft_metric,
    output reg         [ENERGY_WIDTH:0]          total_energy,
    output reg         [CONFIDENCE_WIDTH-1:0]    confidence,
    output reg                                   confidence_ok,
    output reg         [ENERGY_WIDTH-1:0]        energy_f0,
    output reg         [ENERGY_WIDTH-1:0]        energy_f1
);

    wire signed [COEFFICIENT_WIDTH-1:0] cos_f0;
    wire signed [COEFFICIENT_WIDTH-1:0] sin_f0;
    wire signed [COEFFICIENT_WIDTH-1:0] cos_f1;
    wire signed [COEFFICIENT_WIDTH-1:0] sin_f1;

    reg [6:0] phase_index;

    fsk_tone_rom tone_rom (
        .phase_index (phase_index),
        .cos_f0      (cos_f0),
        .sin_f0      (sin_f0),
        .cos_f1      (cos_f1),
        .sin_f1      (sin_f1)
    );

    wire signed [PRODUCT_WIDTH-1:0] product_i0_w = sample_data * cos_f0;
    wire signed [PRODUCT_WIDTH-1:0] product_q0_w = sample_data * sin_f0;
    wire signed [PRODUCT_WIDTH-1:0] product_i1_w = sample_data * cos_f1;
    wire signed [PRODUCT_WIDTH-1:0] product_q1_w = sample_data * sin_f1;

    // Synchronous read-before-write arrays are intended to infer M9K blocks.
    // Runtime reset deliberately does not clear RAM: fill_count prevents stale
    // locations from being subtracted until every address has been rewritten.
    (* ramstyle = "M9K" *) reg signed [PRODUCT_WIDTH-1:0] history_i0 [0:WINDOW_SAMPLES-1];
    (* ramstyle = "M9K" *) reg signed [PRODUCT_WIDTH-1:0] history_q0 [0:WINDOW_SAMPLES-1];
    (* ramstyle = "M9K" *) reg signed [PRODUCT_WIDTH-1:0] history_i1 [0:WINDOW_SAMPLES-1];
    (* ramstyle = "M9K" *) reg signed [PRODUCT_WIDTH-1:0] history_q1 [0:WINDOW_SAMPLES-1];

    reg [8:0] window_pointer;
    reg [8:0] fill_count;
    reg       window_full;
    reg [5:0] metric_step_count;

    reg signed [PRODUCT_WIDTH-1:0] new_i0_pipe;
    reg signed [PRODUCT_WIDTH-1:0] new_q0_pipe;
    reg signed [PRODUCT_WIDTH-1:0] new_i1_pipe;
    reg signed [PRODUCT_WIDTH-1:0] new_q1_pipe;
    reg signed [PRODUCT_WIDTH-1:0] old_i0_pipe;
    reg signed [PRODUCT_WIDTH-1:0] old_q0_pipe;
    reg signed [PRODUCT_WIDTH-1:0] old_i1_pipe;
    reg signed [PRODUCT_WIDTH-1:0] old_q1_pipe;
    reg                            subtract_old_pipe;
    reg                            metric_due_pipe;
    reg                            sample_pending;
    reg [8:0]                      write_pointer_pipe;

    reg signed [ACCUMULATOR_WIDTH-1:0] accumulator_i0;
    reg signed [ACCUMULATOR_WIDTH-1:0] accumulator_q0;
    reg signed [ACCUMULATOR_WIDTH-1:0] accumulator_i1;
    reg signed [ACCUMULATOR_WIDTH-1:0] accumulator_q1;

    // Metric calculations are pipelined because they are needed only once
    // per 48 accepted samples. Stage 1 captures scaled correlators, stage 2
    // captures energies, and an 8-cycle restoring divider forms confidence.
    reg signed [CORRELATOR_WIDTH-1:0] metric_scaled_i0;
    reg signed [CORRELATOR_WIDTH-1:0] metric_scaled_q0;
    reg signed [CORRELATOR_WIDTH-1:0] metric_scaled_i1;
    reg signed [CORRELATOR_WIDTH-1:0] metric_scaled_q1;
    reg metric_scale_valid;
    reg [ENERGY_WIDTH-1:0] metric_energy_f0;
    reg [ENERGY_WIDTH-1:0] metric_energy_f1;
    reg [ENERGY_WIDTH:0] metric_total_energy;
    reg signed [ENERGY_WIDTH:0] metric_soft_energy;
    reg [ENERGY_WIDTH:0] metric_difference;
    reg metric_hard_bit;
    reg [CONFIDENCE_WIDTH-1:0] metric_confidence_threshold;
    reg [ENERGY_WIDTH+1:0] divide_remainder;
    reg [ENERGY_WIDTH:0] divide_denominator;
    reg [CONFIDENCE_WIDTH-1:0] divide_result;
    reg [2:0] divide_count;
    reg divide_busy;

    wire signed [ACCUMULATOR_WIDTH-1:0] new_i0_extended =
        {{(ACCUMULATOR_WIDTH-PRODUCT_WIDTH){new_i0_pipe[PRODUCT_WIDTH-1]}}, new_i0_pipe};
    wire signed [ACCUMULATOR_WIDTH-1:0] new_q0_extended =
        {{(ACCUMULATOR_WIDTH-PRODUCT_WIDTH){new_q0_pipe[PRODUCT_WIDTH-1]}}, new_q0_pipe};
    wire signed [ACCUMULATOR_WIDTH-1:0] new_i1_extended =
        {{(ACCUMULATOR_WIDTH-PRODUCT_WIDTH){new_i1_pipe[PRODUCT_WIDTH-1]}}, new_i1_pipe};
    wire signed [ACCUMULATOR_WIDTH-1:0] new_q1_extended =
        {{(ACCUMULATOR_WIDTH-PRODUCT_WIDTH){new_q1_pipe[PRODUCT_WIDTH-1]}}, new_q1_pipe};

    wire signed [ACCUMULATOR_WIDTH-1:0] old_i0_extended =
        {{(ACCUMULATOR_WIDTH-PRODUCT_WIDTH){old_i0_pipe[PRODUCT_WIDTH-1]}}, old_i0_pipe};
    wire signed [ACCUMULATOR_WIDTH-1:0] old_q0_extended =
        {{(ACCUMULATOR_WIDTH-PRODUCT_WIDTH){old_q0_pipe[PRODUCT_WIDTH-1]}}, old_q0_pipe};
    wire signed [ACCUMULATOR_WIDTH-1:0] old_i1_extended =
        {{(ACCUMULATOR_WIDTH-PRODUCT_WIDTH){old_i1_pipe[PRODUCT_WIDTH-1]}}, old_i1_pipe};
    wire signed [ACCUMULATOR_WIDTH-1:0] old_q1_extended =
        {{(ACCUMULATOR_WIDTH-PRODUCT_WIDTH){old_q1_pipe[PRODUCT_WIDTH-1]}}, old_q1_pipe};

    wire signed [ACCUMULATOR_WIDTH-1:0] next_i0 =
        accumulator_i0 + new_i0_extended -
        (subtract_old_pipe ? old_i0_extended : {ACCUMULATOR_WIDTH{1'b0}});
    wire signed [ACCUMULATOR_WIDTH-1:0] next_q0 =
        accumulator_q0 + new_q0_extended -
        (subtract_old_pipe ? old_q0_extended : {ACCUMULATOR_WIDTH{1'b0}});
    wire signed [ACCUMULATOR_WIDTH-1:0] next_i1 =
        accumulator_i1 + new_i1_extended -
        (subtract_old_pipe ? old_i1_extended : {ACCUMULATOR_WIDTH{1'b0}});
    wire signed [ACCUMULATOR_WIDTH-1:0] next_q1 =
        accumulator_q1 + new_q1_extended -
        (subtract_old_pipe ? old_q1_extended : {ACCUMULATOR_WIDTH{1'b0}});

    // Symmetric round-to-nearest followed by saturation.
    function signed [CORRELATOR_WIDTH-1:0] scale_correlator;
        input signed [ACCUMULATOR_WIDTH-1:0] value;
        reg [ACCUMULATOR_WIDTH:0] magnitude;
        reg [ACCUMULATOR_WIDTH:0] rounded_magnitude;
        reg [ACCUMULATOR_WIDTH:0] shifted_magnitude;
        reg [ACCUMULATOR_WIDTH:0] maximum_positive;
        reg [ACCUMULATOR_WIDTH:0] maximum_negative_magnitude;
        begin
            if (value[ACCUMULATOR_WIDTH-1])
                magnitude = {1'b0, (~value)} + 1'b1;
            else
                magnitude = {1'b0, value};

            rounded_magnitude = magnitude +
                ({{ACCUMULATOR_WIDTH{1'b0}}, 1'b1} << (CORRELATOR_SHIFT-1));
            shifted_magnitude = rounded_magnitude >> CORRELATOR_SHIFT;

            maximum_positive = {(ACCUMULATOR_WIDTH+1){1'b0}};
            maximum_positive[CORRELATOR_WIDTH-2:0] =
                {(CORRELATOR_WIDTH-1){1'b1}};
            maximum_negative_magnitude = {(ACCUMULATOR_WIDTH+1){1'b0}};
            maximum_negative_magnitude[CORRELATOR_WIDTH-1] = 1'b1;

            if (value[ACCUMULATOR_WIDTH-1]) begin
                if (shifted_magnitude >= maximum_negative_magnitude)
                    scale_correlator = {1'b1, {(CORRELATOR_WIDTH-1){1'b0}}};
                else
                    scale_correlator =
                        -$signed(shifted_magnitude[CORRELATOR_WIDTH-1:0]);
            end else begin
                if (shifted_magnitude > maximum_positive)
                    scale_correlator = {1'b0, {(CORRELATOR_WIDTH-1){1'b1}}};
                else
                    scale_correlator =
                        $signed(shifted_magnitude[CORRELATOR_WIDTH-1:0]);
            end
        end
    endfunction

    wire signed [CORRELATOR_WIDTH-1:0] scaled_i0 = scale_correlator(next_i0);
    wire signed [CORRELATOR_WIDTH-1:0] scaled_q0 = scale_correlator(next_q0);
    wire signed [CORRELATOR_WIDTH-1:0] scaled_i1 = scale_correlator(next_i1);
    wire signed [CORRELATOR_WIDTH-1:0] scaled_q1 = scale_correlator(next_q1);

    wire signed [(2*CORRELATOR_WIDTH)-1:0] square_i0_signed =
        metric_scaled_i0 * metric_scaled_i0;
    wire signed [(2*CORRELATOR_WIDTH)-1:0] square_q0_signed =
        metric_scaled_q0 * metric_scaled_q0;
    wire signed [(2*CORRELATOR_WIDTH)-1:0] square_i1_signed =
        metric_scaled_i1 * metric_scaled_i1;
    wire signed [(2*CORRELATOR_WIDTH)-1:0] square_q1_signed =
        metric_scaled_q1 * metric_scaled_q1;

    wire [(2*CORRELATOR_WIDTH):0] energy_f0_raw =
        {1'b0, square_i0_signed} + {1'b0, square_q0_signed};
    wire [(2*CORRELATOR_WIDTH):0] energy_f1_raw =
        {1'b0, square_i1_signed} + {1'b0, square_q1_signed};

    function [ENERGY_WIDTH-1:0] scale_energy;
        input [(2*CORRELATOR_WIDTH):0] value;
        reg [(2*CORRELATOR_WIDTH):0] rounded_value;
        reg [(2*CORRELATOR_WIDTH):0] shifted_value;
        begin
            rounded_value = value +
                ({{(2*CORRELATOR_WIDTH){1'b0}}, 1'b1} << (ENERGY_SHIFT-1));
            shifted_value = rounded_value >> ENERGY_SHIFT;
            if (|(shifted_value[(2*CORRELATOR_WIDTH):ENERGY_WIDTH]))
                scale_energy = {ENERGY_WIDTH{1'b1}};
            else
                scale_energy = shifted_value[ENERGY_WIDTH-1:0];
        end
    endfunction

    wire [ENERGY_WIDTH-1:0] energy_f0_scaled = scale_energy(energy_f0_raw);
    wire [ENERGY_WIDTH-1:0] energy_f1_scaled = scale_energy(energy_f1_raw);
    wire [ENERGY_WIDTH:0] energy_total_w =
        {1'b0, energy_f0_scaled} + {1'b0, energy_f1_scaled};
    wire signed [ENERGY_WIDTH:0] energy_soft_w =
        $signed({1'b0, energy_f1_scaled}) - $signed({1'b0, energy_f0_scaled});
    wire [ENERGY_WIDTH:0] energy_difference_w =
        (energy_f1_scaled >= energy_f0_scaled) ?
        ({1'b0, energy_f1_scaled} - {1'b0, energy_f0_scaled}) :
        ({1'b0, energy_f0_scaled} - {1'b0, energy_f1_scaled});

    wire [ENERGY_WIDTH+1:0] divide_shifted = divide_remainder << 1;
    wire divide_take =
        (divide_denominator != {(ENERGY_WIDTH+1){1'b0}}) &&
        (divide_shifted >= {1'b0, divide_denominator});
    wire [ENERGY_WIDTH+1:0] divide_remainder_next = divide_take ?
        (divide_shifted - {1'b0, divide_denominator}) : divide_shifted;
    reg [CONFIDENCE_WIDTH-1:0] divide_result_next;
    always @(*) begin
        divide_result_next = divide_result;
        if (divide_take) begin
            case (divide_count)
                3'd0: divide_result_next[7] = 1'b1;
                3'd1: divide_result_next[6] = 1'b1;
                3'd2: divide_result_next[5] = 1'b1;
                3'd3: divide_result_next[4] = 1'b1;
                3'd4: divide_result_next[3] = 1'b1;
                3'd5: divide_result_next[2] = 1'b1;
                3'd6: divide_result_next[1] = 1'b1;
                default: divide_result_next[0] = 1'b1;
            endcase
        end
    end

    wire [ENERGY_WIDTH+CONFIDENCE_WIDTH:0] confidence_left_w =
        {metric_difference, {CONFIDENCE_WIDTH{1'b0}}};
    wire [ENERGY_WIDTH+CONFIDENCE_WIDTH:0] confidence_right_w =
        metric_total_energy * metric_confidence_threshold;
    wire confidence_ok_w =
        (metric_total_energy != {(ENERGY_WIDTH+1){1'b0}}) &&
        (confidence_left_w >= confidence_right_w);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            phase_index        <= 7'd0;
            window_pointer     <= 9'd0;
            fill_count         <= 9'd0;
            window_full        <= 1'b0;
            metric_step_count  <= 6'd0;
            sample_pending     <= 1'b0;
            subtract_old_pipe  <= 1'b0;
            metric_due_pipe    <= 1'b0;
            write_pointer_pipe <= 9'd0;
            new_i0_pipe        <= {PRODUCT_WIDTH{1'b0}};
            new_q0_pipe        <= {PRODUCT_WIDTH{1'b0}};
            new_i1_pipe        <= {PRODUCT_WIDTH{1'b0}};
            new_q1_pipe        <= {PRODUCT_WIDTH{1'b0}};
            old_i0_pipe        <= {PRODUCT_WIDTH{1'b0}};
            old_q0_pipe        <= {PRODUCT_WIDTH{1'b0}};
            old_i1_pipe        <= {PRODUCT_WIDTH{1'b0}};
            old_q1_pipe        <= {PRODUCT_WIDTH{1'b0}};
            accumulator_i0     <= {ACCUMULATOR_WIDTH{1'b0}};
            accumulator_q0     <= {ACCUMULATOR_WIDTH{1'b0}};
            accumulator_i1     <= {ACCUMULATOR_WIDTH{1'b0}};
            accumulator_q1     <= {ACCUMULATOR_WIDTH{1'b0}};
            metric_scaled_i0   <= {CORRELATOR_WIDTH{1'b0}};
            metric_scaled_q0   <= {CORRELATOR_WIDTH{1'b0}};
            metric_scaled_i1   <= {CORRELATOR_WIDTH{1'b0}};
            metric_scaled_q1   <= {CORRELATOR_WIDTH{1'b0}};
            metric_scale_valid <= 1'b0;
            metric_energy_f0   <= {ENERGY_WIDTH{1'b0}};
            metric_energy_f1   <= {ENERGY_WIDTH{1'b0}};
            metric_total_energy <= {(ENERGY_WIDTH+1){1'b0}};
            metric_soft_energy <= {(ENERGY_WIDTH+1){1'b0}};
            metric_difference  <= {(ENERGY_WIDTH+1){1'b0}};
            metric_hard_bit    <= 1'b0;
            metric_confidence_threshold <= {CONFIDENCE_WIDTH{1'b0}};
            divide_remainder   <= {(ENERGY_WIDTH+2){1'b0}};
            divide_denominator <= {(ENERGY_WIDTH+1){1'b0}};
            divide_result      <= {CONFIDENCE_WIDTH{1'b0}};
            divide_count       <= 3'd0;
            divide_busy        <= 1'b0;
            metric_valid       <= 1'b0;
            hard_bit           <= 1'b0;
            soft_metric        <= {(ENERGY_WIDTH+1){1'b0}};
            total_energy       <= {(ENERGY_WIDTH+1){1'b0}};
            confidence         <= {CONFIDENCE_WIDTH{1'b0}};
            confidence_ok      <= 1'b0;
            energy_f0          <= {ENERGY_WIDTH{1'b0}};
            energy_f1          <= {ENERGY_WIDTH{1'b0}};
        end else begin
            metric_valid <= 1'b0;
            metric_scale_valid <= 1'b0;
            sample_pending <= sample_valid;

            if (metric_scale_valid) begin
                metric_energy_f0 <= energy_f0_scaled;
                metric_energy_f1 <= energy_f1_scaled;
                metric_total_energy <= energy_total_w;
                metric_soft_energy <= energy_soft_w;
                metric_difference <= energy_difference_w;
                metric_hard_bit <= (energy_f1_scaled > energy_f0_scaled);
                metric_confidence_threshold <= confidence_threshold;
                divide_remainder <= {1'b0, energy_difference_w};
                divide_denominator <= energy_total_w;
                divide_result <= {CONFIDENCE_WIDTH{1'b0}};
                divide_count <= 3'd0;
                divide_busy <= 1'b1;
            end else if (divide_busy) begin
                divide_remainder <= divide_remainder_next;
                divide_result <= divide_result_next;
                if (divide_count == 3'd7) begin
                    divide_busy <= 1'b0;
                    metric_valid <= 1'b1;
                    energy_f0 <= metric_energy_f0;
                    energy_f1 <= metric_energy_f1;
                    hard_bit <= metric_hard_bit;
                    soft_metric <= metric_soft_energy;
                    total_energy <= metric_total_energy;
                    confidence <= divide_result_next;
                    confidence_ok <= confidence_ok_w;
                end else begin
                    divide_count <= divide_count + 1'b1;
                end
            end

            if (sample_pending) begin
                // Write the previous sample while the read port may fetch the
                // current pointer. Consecutive samples always use adjacent
                // addresses, including across the circular wrap.
                history_i0[write_pointer_pipe] <= new_i0_pipe;
                history_q0[write_pointer_pipe] <= new_q0_pipe;
                history_i1[write_pointer_pipe] <= new_i1_pipe;
                history_q1[write_pointer_pipe] <= new_q1_pipe;

                accumulator_i0 <= next_i0;
                accumulator_q0 <= next_q0;
                accumulator_i1 <= next_i1;
                accumulator_q1 <= next_q1;

                if (metric_due_pipe) begin
                    metric_scaled_i0 <= scaled_i0;
                    metric_scaled_q0 <= scaled_q0;
                    metric_scaled_i1 <= scaled_i1;
                    metric_scaled_q1 <= scaled_q1;
                    metric_scale_valid <= 1'b1;
                end
            end

            if (sample_valid) begin
                new_i0_pipe <= product_i0_w;
                new_q0_pipe <= product_q0_w;
                new_i1_pipe <= product_i1_w;
                new_q1_pipe <= product_q1_w;

                old_i0_pipe <= history_i0[window_pointer];
                old_q0_pipe <= history_q0[window_pointer];
                old_i1_pipe <= history_i1[window_pointer];
                old_q1_pipe <= history_q1[window_pointer];

                subtract_old_pipe <= window_full;
                write_pointer_pipe <= window_pointer;
                metric_due_pipe <=
                    (metric_step_count == (METRIC_STEP_SAMPLES-1)) &&
                    (window_full || (fill_count == (WINDOW_SAMPLES-1)));

                if (phase_index == 7'd119)
                    phase_index <= 7'd0;
                else
                    phase_index <= phase_index + 7'd1;

                if (window_pointer == (WINDOW_SAMPLES-1))
                    window_pointer <= 9'd0;
                else
                    window_pointer <= window_pointer + 9'd1;

                if (!window_full) begin
                    if (fill_count == (WINDOW_SAMPLES-1))
                        window_full <= 1'b1;
                    else
                        fill_count <= fill_count + 9'd1;
                end

                if (metric_step_count == (METRIC_STEP_SAMPLES-1))
                    metric_step_count <= 6'd0;
                else
                    metric_step_count <= metric_step_count + 6'd1;
            end
        end
    end

endmodule

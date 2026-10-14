`timescale 1ns/1ps

// Finds the 100 bit/s symbol phase from 1 ms demodulator metrics. The module
// consumes the preamble and emits only bits which follow it.
module fsk_symbol_sync #(
    parameter integer ENERGY_WIDTH = 33,
    parameter integer CONFIDENCE_WIDTH = 8,
    parameter integer PHASE_COUNT = 10,
    parameter integer PREAMBLE_BITS = 16,
    parameter [PREAMBLE_BITS-1:0] PREAMBLE_PATTERN = 16'hAAAA,
    parameter integer PREAMBLE_MIN_MATCHES = 14,
    parameter integer PREAMBLE_MIN_CARRIER_HITS = 14,
    parameter [CONFIDENCE_WIDTH-1:0] TIMING_HYSTERESIS = 8'd4,
    parameter integer LOCK_TIMEOUT_SYMBOLS = 100
) (
    input  wire                              clk,
    input  wire                              reset_n,
    input  wire                              metric_valid,
    input  wire                              hard_bit,
    input  wire [ENERGY_WIDTH-1:0]           total_energy,
    input  wire [CONFIDENCE_WIDTH-1:0]       confidence,
    input  wire                              carrier_present,
    input  wire [CONFIDENCE_WIDTH-1:0]       preamble_confidence_threshold,

    output wire                              carrier_active,
    output wire                              sync_locked,
    output reg                               preamble_detected,
    output reg                               lock_lost,
    output reg                               search_timeout,
    output reg                               bit_valid,
    output reg                               bit_value,
    output reg  [ENERGY_WIDTH-1:0]           symbol_energy,
    output reg  [CONFIDENCE_WIDTH-1:0]       symbol_confidence,
    output reg  [3:0]                        selected_phase,
    output reg  signed [1:0]                 timing_adjust
);

    function integer clog2;
        input integer value;
        integer work;
        begin
            work = value - 1;
            clog2 = 0;
            while (work > 0) begin
                clog2 = clog2 + 1;
                work = work >> 1;
            end
        end
    endfunction

    localparam integer PHASE_WIDTH_RAW = clog2(PHASE_COUNT);
    localparam integer PHASE_WIDTH = (PHASE_WIDTH_RAW < 1) ? 1 : PHASE_WIDTH_RAW;
    localparam integer SAMPLE_COUNT_WIDTH_RAW = clog2(PREAMBLE_BITS + 1);
    localparam integer SAMPLE_COUNT_WIDTH =
        (SAMPLE_COUNT_WIDTH_RAW < 1) ? 1 : SAMPLE_COUNT_WIDTH_RAW;
    localparam integer SEARCH_COUNT_WIDTH_RAW = clog2(PHASE_COUNT * PREAMBLE_BITS + 1);
    localparam integer SEARCH_COUNT_WIDTH =
        (SEARCH_COUNT_WIDTH_RAW < 1) ? 1 : SEARCH_COUNT_WIDTH_RAW;
    localparam integer COUNTDOWN_WIDTH_RAW = clog2(PHASE_COUNT + 2);
    localparam integer COUNTDOWN_WIDTH =
        (COUNTDOWN_WIDTH_RAW < 1) ? 1 : COUNTDOWN_WIDTH_RAW;
    localparam integer LOCK_COUNT_WIDTH_RAW = clog2(LOCK_TIMEOUT_SYMBOLS + 1);
    localparam integer LOCK_COUNT_WIDTH =
        (LOCK_COUNT_WIDTH_RAW < 1) ? 1 : LOCK_COUNT_WIDTH_RAW;
    localparam integer CONFIDENCE_SUM_WIDTH = CONFIDENCE_WIDTH + 4;
    localparam integer ENERGY_SUM_WIDTH = ENERGY_WIDTH + 4;
    localparam integer TOTAL_SEARCH_METRICS = PHASE_COUNT * PREAMBLE_BITS;

    localparam [1:0] ST_CARRIER = 2'd0;
    localparam [1:0] ST_SEARCH  = 2'd1;
    localparam [1:0] ST_LOCKED  = 2'd2;

    reg [1:0] state;
    reg [2:0] carrier_run;

    reg [PREAMBLE_BITS-1:0] phase_bits [0:PHASE_COUNT-1];
    reg [PREAMBLE_BITS-1:0] phase_carrier [0:PHASE_COUNT-1];
    reg [CONFIDENCE_SUM_WIDTH-1:0] phase_confidence_sum [0:PHASE_COUNT-1];
    reg [ENERGY_SUM_WIDTH-1:0] phase_energy_sum [0:PHASE_COUNT-1];
    reg [SAMPLE_COUNT_WIDTH-1:0] phase_sample_count [0:PHASE_COUNT-1];

    reg [PHASE_WIDTH-1:0] search_phase;
    reg [SEARCH_COUNT_WIDTH-1:0] search_metric_count;
    reg evaluation_pending;
    reg evaluation_finalize;
    reg [PHASE_WIDTH-1:0] evaluation_phase;
    reg best_found;
    reg [PHASE_WIDTH-1:0] best_phase;
    reg [SAMPLE_COUNT_WIDTH-1:0] best_matches;
    reg [CONFIDENCE_SUM_WIDTH-1:0] best_confidence_sum;
    reg [ENERGY_SUM_WIDTH-1:0] best_energy_sum;
    reg [PHASE_WIDTH-1:0] last_metric_phase;
    reg [CONFIDENCE_WIDTH-1:0] last_metric_confidence;

    reg [COUNTDOWN_WIDTH-1:0] symbol_countdown;
    reg awaiting_late_metric;
    reg transition_pending;
    reg previous_bit;
    reg [CONFIDENCE_WIDTH-1:0] early_confidence;
    reg early_confidence_valid;
    reg [1:0] low_energy_symbols;
    reg [LOCK_COUNT_WIDTH-1:0] locked_symbol_count;

    integer reset_index;
    function [SAMPLE_COUNT_WIDTH-1:0] count_matches;
        input [PREAMBLE_BITS-1:0] value;
        integer bit_index;
        begin
            count_matches = {SAMPLE_COUNT_WIDTH{1'b0}};
            for (bit_index = 0; bit_index < PREAMBLE_BITS; bit_index = bit_index + 1)
                if (value[bit_index] == PREAMBLE_PATTERN[bit_index])
                    count_matches = count_matches + 1'b1;
        end
    endfunction

    function [SAMPLE_COUNT_WIDTH-1:0] count_carrier_hits;
        input [PREAMBLE_BITS-1:0] value;
        integer bit_index;
        begin
            count_carrier_hits = {SAMPLE_COUNT_WIDTH{1'b0}};
            for (bit_index = 0; bit_index < PREAMBLE_BITS; bit_index = bit_index + 1)
                if (value[bit_index])
                    count_carrier_hits = count_carrier_hits + 1'b1;
        end
    endfunction

    wire [SAMPLE_COUNT_WIDTH-1:0] evaluation_matches =
        count_matches(phase_bits[evaluation_phase]);
    wire [SAMPLE_COUNT_WIDTH-1:0] evaluation_carrier_hits =
        count_carrier_hits(phase_carrier[evaluation_phase]);
    wire evaluation_candidate =
        (phase_sample_count[evaluation_phase] == PREAMBLE_BITS) &&
        (evaluation_matches >= PREAMBLE_MIN_MATCHES) &&
        (evaluation_carrier_hits >= PREAMBLE_MIN_CARRIER_HITS) &&
        (phase_confidence_sum[evaluation_phase] >=
            {preamble_confidence_threshold, 4'b0000});
    wire evaluation_better = !best_found ||
        (evaluation_matches > best_matches) ||
        ((evaluation_matches == best_matches) &&
         (phase_confidence_sum[evaluation_phase] > best_confidence_sum)) ||
        ((evaluation_matches == best_matches) &&
         (phase_confidence_sum[evaluation_phase] == best_confidence_sum) &&
         (phase_energy_sum[evaluation_phase] > best_energy_sum));
    wire [COUNTDOWN_WIDTH-1:0] lock_distance =
        (best_phase > last_metric_phase) ?
        (best_phase - last_metric_phase) :
        (PHASE_COUNT - last_metric_phase + best_phase);

    assign carrier_active = (state != ST_CARRIER);
    assign sync_locked = (state == ST_LOCKED);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state                         <= ST_CARRIER;
            carrier_run                   <= 3'd0;
            search_phase                  <= {PHASE_WIDTH{1'b0}};
            search_metric_count           <= {SEARCH_COUNT_WIDTH{1'b0}};
            evaluation_pending            <= 1'b0;
            evaluation_finalize           <= 1'b0;
            evaluation_phase              <= {PHASE_WIDTH{1'b0}};
            best_found                    <= 1'b0;
            best_phase                    <= {PHASE_WIDTH{1'b0}};
            best_matches                  <= {SAMPLE_COUNT_WIDTH{1'b0}};
            best_confidence_sum           <= {CONFIDENCE_SUM_WIDTH{1'b0}};
            best_energy_sum               <= {ENERGY_SUM_WIDTH{1'b0}};
            last_metric_phase             <= {PHASE_WIDTH{1'b0}};
            last_metric_confidence        <= {CONFIDENCE_WIDTH{1'b0}};
            symbol_countdown              <= {COUNTDOWN_WIDTH{1'b0}};
            awaiting_late_metric          <= 1'b0;
            transition_pending            <= 1'b0;
            previous_bit                  <= 1'b0;
            early_confidence              <= {CONFIDENCE_WIDTH{1'b0}};
            early_confidence_valid        <= 1'b0;
            low_energy_symbols            <= 2'd0;
            locked_symbol_count           <= {LOCK_COUNT_WIDTH{1'b0}};
            preamble_detected             <= 1'b0;
            lock_lost                     <= 1'b0;
            search_timeout                <= 1'b0;
            bit_valid                     <= 1'b0;
            bit_value                     <= 1'b0;
            symbol_energy                 <= {ENERGY_WIDTH{1'b0}};
            symbol_confidence             <= {CONFIDENCE_WIDTH{1'b0}};
            selected_phase                <= 4'd0;
            timing_adjust                 <= 2'sd0;

            for (reset_index = 0; reset_index < PHASE_COUNT; reset_index = reset_index + 1) begin
                phase_bits[reset_index]          <= {PREAMBLE_BITS{1'b0}};
                phase_carrier[reset_index]       <= {PREAMBLE_BITS{1'b0}};
                phase_confidence_sum[reset_index] <= {CONFIDENCE_SUM_WIDTH{1'b0}};
                phase_energy_sum[reset_index]    <= {ENERGY_SUM_WIDTH{1'b0}};
                phase_sample_count[reset_index]  <= {SAMPLE_COUNT_WIDTH{1'b0}};
            end
        end else begin
            preamble_detected <= 1'b0;
            lock_lost         <= 1'b0;
            search_timeout    <= 1'b0;
            bit_valid         <= 1'b0;
            timing_adjust     <= 2'sd0;

            case (state)
                ST_CARRIER: begin
                    evaluation_pending   <= 1'b0;
                    evaluation_finalize  <= 1'b0;
                    awaiting_late_metric <= 1'b0;

                    if (metric_valid) begin
                        if (carrier_present) begin
                            if (carrier_run == 3'd4) begin
                                state               <= ST_SEARCH;
                                carrier_run         <= 3'd0;
                                search_phase        <= {{(PHASE_WIDTH-1){1'b0}}, 1'b1};
                                search_metric_count <= {{(SEARCH_COUNT_WIDTH-1){1'b0}}, 1'b1};
                                last_metric_phase   <= {PHASE_WIDTH{1'b0}};
                                last_metric_confidence <= confidence;

                                for (reset_index = 0; reset_index < PHASE_COUNT; reset_index = reset_index + 1) begin
                                    phase_bits[reset_index]           <= {PREAMBLE_BITS{1'b0}};
                                    phase_carrier[reset_index]        <= {PREAMBLE_BITS{1'b0}};
                                    phase_confidence_sum[reset_index] <= {CONFIDENCE_SUM_WIDTH{1'b0}};
                                    phase_energy_sum[reset_index]     <= {ENERGY_SUM_WIDTH{1'b0}};
                                    phase_sample_count[reset_index]   <= {SAMPLE_COUNT_WIDTH{1'b0}};
                                end

                                phase_bits[0] <= {{(PREAMBLE_BITS-1){1'b0}}, hard_bit};
                                phase_carrier[0] <= {{(PREAMBLE_BITS-1){1'b0}}, 1'b1};
                                phase_confidence_sum[0] <=
                                    {{4{1'b0}}, confidence};
                                phase_energy_sum[0] <= {{4{1'b0}}, total_energy};
                                phase_sample_count[0] <=
                                    {{(SAMPLE_COUNT_WIDTH-1){1'b0}}, 1'b1};
                            end else begin
                                carrier_run <= carrier_run + 1'b1;
                            end
                        end else begin
                            carrier_run <= 3'd0;
                        end
                    end
                end

                ST_SEARCH: begin
                    if (evaluation_pending) begin
                        if (evaluation_candidate && evaluation_better) begin
                            best_found <= 1'b1;
                            best_phase <= evaluation_phase;
                            best_matches <= evaluation_matches;
                            best_confidence_sum <=
                                phase_confidence_sum[evaluation_phase];
                            best_energy_sum <= phase_energy_sum[evaluation_phase];
                        end

                        if (evaluation_phase == PHASE_COUNT - 1) begin
                            evaluation_pending <= 1'b0;
                            evaluation_finalize <= 1'b1;
                        end else begin
                            evaluation_phase <= evaluation_phase + 1'b1;
                        end
                    end else if (evaluation_finalize) begin
                        evaluation_finalize <= 1'b0;
                        if (best_found) begin
                            state                    <= ST_LOCKED;
                            preamble_detected        <= 1'b1;
                            selected_phase           <= best_phase;
                            symbol_countdown         <= lock_distance;
                            previous_bit             <= phase_bits[best_phase][0];
                            low_energy_symbols       <= 2'd0;
                            locked_symbol_count      <= {LOCK_COUNT_WIDTH{1'b0}};
                            awaiting_late_metric     <= 1'b0;
                            transition_pending       <= 1'b0;
                            early_confidence         <= last_metric_confidence;
                            early_confidence_valid   <= (lock_distance == 1);
                        end else begin
                            state          <= ST_CARRIER;
                            carrier_run    <= 3'd0;
                            search_timeout <= 1'b1;
                        end
                    end else if (metric_valid) begin
                        phase_bits[search_phase] <=
                            {phase_bits[search_phase][PREAMBLE_BITS-2:0], hard_bit};
                        phase_carrier[search_phase] <=
                            {phase_carrier[search_phase][PREAMBLE_BITS-2:0], carrier_present};
                        phase_confidence_sum[search_phase] <=
                            phase_confidence_sum[search_phase] + {{4{1'b0}}, confidence};
                        phase_energy_sum[search_phase] <=
                            phase_energy_sum[search_phase] + {{4{1'b0}}, total_energy};
                        phase_sample_count[search_phase] <=
                            phase_sample_count[search_phase] + 1'b1;
                        last_metric_phase      <= search_phase;
                        last_metric_confidence <= confidence;

                        if (search_phase == PHASE_COUNT - 1)
                            search_phase <= {PHASE_WIDTH{1'b0}};
                        else
                            search_phase <= search_phase + 1'b1;

                        if (search_metric_count == TOTAL_SEARCH_METRICS - 1) begin
                            evaluation_pending <= 1'b1;
                            evaluation_phase <= {PHASE_WIDTH{1'b0}};
                            best_found <= 1'b0;
                            best_phase <= {PHASE_WIDTH{1'b0}};
                            best_matches <= {SAMPLE_COUNT_WIDTH{1'b0}};
                            best_confidence_sum <= {CONFIDENCE_SUM_WIDTH{1'b0}};
                            best_energy_sum <= {ENERGY_SUM_WIDTH{1'b0}};
                        end else begin
                            search_metric_count <= search_metric_count + 1'b1;
                        end
                    end
                end

                ST_LOCKED: begin
                    if (metric_valid) begin
                        if (awaiting_late_metric) begin
                            awaiting_late_metric <= 1'b0;
                            transition_pending   <= 1'b0;
                            early_confidence_valid <= 1'b0;

                            if (transition_pending && early_confidence_valid &&
                                (confidence > early_confidence) &&
                                ((confidence - early_confidence) > TIMING_HYSTERESIS)) begin
                                symbol_countdown <= PHASE_COUNT;
                                timing_adjust    <= 2'sd1;
                            end else if (transition_pending && early_confidence_valid &&
                                         (early_confidence > confidence) &&
                                         ((early_confidence - confidence) > TIMING_HYSTERESIS)) begin
                                symbol_countdown <= PHASE_COUNT - 2;
                                timing_adjust    <= -2'sd1;
                            end else begin
                                symbol_countdown <= PHASE_COUNT - 1;
                            end
                        end else begin
                            if (symbol_countdown == 2) begin
                                early_confidence       <= confidence;
                                early_confidence_valid <= 1'b1;
                            end

                            if (symbol_countdown <= 1) begin
                                symbol_energy     <= total_energy;
                                symbol_confidence <= confidence;

                                if (!carrier_present && (low_energy_symbols == 2)) begin
                                    state                   <= ST_CARRIER;
                                    carrier_run             <= 3'd0;
                                    lock_lost               <= 1'b1;
                                    awaiting_late_metric    <= 1'b0;
                                    transition_pending      <= 1'b0;
                                    early_confidence_valid  <= 1'b0;
                                end else begin
                                    bit_valid          <= 1'b1;
                                    bit_value          <= hard_bit;
                                    transition_pending <= (hard_bit != previous_bit);
                                    previous_bit       <= hard_bit;
                                    awaiting_late_metric <= 1'b1;

                                    if (carrier_present)
                                        low_energy_symbols <= 2'd0;
                                    else
                                        low_energy_symbols <= low_energy_symbols + 1'b1;

                                    if (locked_symbol_count == LOCK_TIMEOUT_SYMBOLS - 1) begin
                                        state                <= ST_CARRIER;
                                        carrier_run          <= 3'd0;
                                        lock_lost            <= 1'b1;
                                        search_timeout       <= 1'b1;
                                        awaiting_late_metric <= 1'b0;
                                    end else begin
                                        locked_symbol_count <= locked_symbol_count + 1'b1;
                                    end
                                end
                            end else begin
                                symbol_countdown <= symbol_countdown - 1'b1;
                            end
                        end
                    end
                end

                default: begin
                    state       <= ST_CARRIER;
                    carrier_run <= 3'd0;
                end
            endcase
        end
    end

endmodule

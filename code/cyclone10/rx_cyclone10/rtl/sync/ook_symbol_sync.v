`timescale 1ns/1ps
`default_nettype none

// Fixed-threshold 100 bps OOK synchronizer. Metrics arrive at 1 ms; each
// candidate phase sees one bit every ten metrics (480 samples). No adaptive
// threshold or preamble calibration is used. A strict AAAA06B7 match selects
// the midpoint of the longest viable interval across ten candidate phases.
// The 06B7 sync is then replayed at clk rate before the next body bit.
module ook_symbol_sync (
    input wire clk, input wire reset_n,
    input wire metric_valid, input wire [31:0] energy,
    input wire [31:0] low_threshold, input wire [31:0] high_threshold,
    input wire parser_busy,
    output reg hard_bit, output reg bit_valid, output reg bit_value,
    output wire symbol_locked, output reg candidate_active, output reg preamble_detected, output reg lock_lost,
    output reg [3:0] selected_phase
);
    localparam [1:0] SEARCH=0, COLLECT=1, REPLAY=2, RECEIVE=3;
    localparam [31:0] SYNC_PATTERN = 32'hAAAA06B7;
    localparam [15:0] SYNC_WORD = 16'h06B7;
    localparam integer FRAME_WATCHDOG_BITS = 1024;
    reg [1:0] state;
    reg [3:0] metric_phase;
    reg [31:0] history [0:9];
    reg [5:0] history_count [0:9];
    reg [4:0] replay_index;
    reg [3:0] collect_count;
    reg [3:0] collect_origin_phase;
    reg [3:0] run_start, run_length, best_run_start, best_run_length;
    reg [9:0] valid_phase_mask;
    reg [10:0] receive_bits;
    reg [7:0] candidate_watchdog;
    reg [19:0] metric_gap_count;
    integer k;
    assign symbol_locked = (state != SEARCH);
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state<=SEARCH; metric_phase<=0; hard_bit<=0; bit_valid<=0; bit_value<=0;
            candidate_active<=0; preamble_detected<=0; lock_lost<=0; selected_phase<=0; replay_index<=0; collect_count<=0; collect_origin_phase<=0; run_start<=0; run_length<=0; best_run_start<=0; best_run_length<=0; valid_phase_mask<=0; receive_bits<=0; candidate_watchdog<=0; metric_gap_count<=0;
            for(k=0;k<10;k=k+1) begin history[k]<=0; history_count[k]<=0; end
        end else begin
            bit_valid<=0; preamble_detected<=0; lock_lost<=0;
            // SYNC is injected in sixteen consecutive system clocks. This
            // finishes hundreds of microseconds before the next 10 ms symbol,
            // avoiding the 160 ms delay that would otherwise lose short-gap frames.
            if (state == REPLAY) begin
                bit_valid <= 1'b1;
                bit_value <= SYNC_WORD[15-replay_index];
                if (replay_index == 15) begin state <= RECEIVE; receive_bits <= 0; end
                else replay_index <= replay_index + 1'b1;
            end
            // 20 ms metric watchdog releases a stalled candidate/frame but
            // never treats valid low-energy (OOK zero) symbols as loss.
            if (((state != SEARCH) || candidate_active) && !metric_valid) begin
                if (metric_gap_count == 20'd599999) begin
                    state <= SEARCH; lock_lost <= (state != SEARCH); candidate_active <= 1'b0;
                    metric_gap_count <= 0;
                    for (k=0;k<10;k=k+1) begin history[k] <= 0; history_count[k] <= 0; end
                end else metric_gap_count <= metric_gap_count + 1'b1;
            end else if (metric_valid) begin
                metric_gap_count <= 0;
            end
            if (metric_valid && state != REPLAY) begin
                if (candidate_active && state == SEARCH) begin
                    if (candidate_watchdog == 8'd199) begin candidate_active <= 1'b0; candidate_watchdog <= 0; end
                    else candidate_watchdog <= candidate_watchdog + 1'b1;
                end
                if (energy >= high_threshold) hard_bit <= 1'b1;
                else if (energy <= low_threshold) hard_bit <= 1'b0;
                // retain within hysteresis band
                case (state)
                    SEARCH: begin
                        history[metric_phase] <= {history[metric_phase][30:0],
                                                  (energy >= high_threshold) ? 1'b1 :
                                                  (energy <= low_threshold) ? 1'b0 : hard_bit};
                        if (history_count[metric_phase] < 32) history_count[metric_phase] <= history_count[metric_phase] + 1'b1;
                        if (!candidate_active &&
                            ({history[metric_phase][14:0], (energy >= high_threshold) ? 1'b1 :
                             (energy <= low_threshold) ? 1'b0 : hard_bit} == 16'hAAAA)) begin
                            candidate_active <= 1'b1; candidate_watchdog <= 0;
                        end
                        if ((history_count[metric_phase] >= 31) &&
                            ({history[metric_phase][30:0], (energy >= high_threshold) ? 1'b1 :
                              (energy <= low_threshold) ? 1'b0 : hard_bit} == SYNC_PATTERN)) begin
                            // Evaluate all ten 1 ms phases before choosing the
                            // middle viable window.  This avoids threshold-edge
                            // phases while still leaving almost 10 ms for replay.
                            state <= COLLECT; collect_count <= 0;
                            collect_origin_phase <= metric_phase;
                            run_start <= 0; run_length <= 1;
                            best_run_start <= 0; best_run_length <= 1;
                            valid_phase_mask <= 10'b0000000001;
                            candidate_active <= 1'b1; candidate_watchdog <= 0;
                        end
                    end
                    COLLECT: begin
                        history[metric_phase] <= {history[metric_phase][30:0],
                                                  (energy >= high_threshold) ? 1'b1 :
                                                  (energy <= low_threshold) ? 1'b0 : hard_bit};
                        if (history_count[metric_phase] < 32) history_count[metric_phase] <= history_count[metric_phase] + 1'b1;
                        // collection offset is 1..9. Find the longest
                        // contiguous viable interval and select its midpoint;
                        // ties retain the earlier interval for deterministic
                        // phase choice. The final offset is included here.
                        if ((history_count[metric_phase] >= 31) &&
                            ({history[metric_phase][30:0], (energy >= high_threshold) ? 1'b1 :
                              (energy <= low_threshold) ? 1'b0 : hard_bit} == SYNC_PATTERN)) begin
                            valid_phase_mask[collect_count + 1'b1] <= 1'b1;
                            if ((run_length + 1'b1) > best_run_length) begin
                                best_run_start <= run_start;
                                best_run_length <= run_length + 1'b1;
                            end
                            run_length <= run_length + 1'b1;
                        end else begin
                            run_start <= collect_count + 4'd2;
                            run_length <= 0;
                        end
                        if (collect_count == 4'd8) begin
                            state <= REPLAY;
                            // Use the just-observed run if it improves best.
                            if ((history_count[metric_phase] >= 31) &&
                                ({history[metric_phase][30:0], (energy >= high_threshold) ? 1'b1 :
                                  (energy <= low_threshold) ? 1'b0 : hard_bit} == SYNC_PATTERN) &&
                                ((run_length + 1'b1) > best_run_length)) begin
                                selected_phase <= ((collect_origin_phase + run_start +
                                    ((run_length) >> 1)) >= 10) ?
                                    (collect_origin_phase + run_start + ((run_length) >> 1) - 10) :
                                    (collect_origin_phase + run_start + ((run_length) >> 1));
                            end else begin
                                selected_phase <= ((collect_origin_phase + best_run_start +
                                    ((best_run_length - 1'b1) >> 1)) >= 10) ?
                                    (collect_origin_phase + best_run_start + ((best_run_length - 1'b1) >> 1) - 10) :
                                    (collect_origin_phase + best_run_start + ((best_run_length - 1'b1) >> 1));
                            end
                            replay_index <= 0; receive_bits <= 0;
                            candidate_active <= 1'b0; preamble_detected <= 1'b1;
                        end else collect_count <= collect_count + 1'b1;
                    end
                    REPLAY: begin
                        // Handled above at clk rate; no metric-domain action.
                    end
                    RECEIVE: if (metric_phase == selected_phase) begin
                        if (!parser_busy) begin
                            state <= SEARCH;
                            for (k=0;k<10;k=k+1) begin history[k] <= 0; history_count[k] <= 0; end
                        end else begin
                            bit_valid <= 1'b1;
                            bit_value <= (energy >= high_threshold) ? 1'b1 :
                                         (energy <= low_threshold) ? 1'b0 : hard_bit;
                            if (receive_bits == FRAME_WATCHDOG_BITS-1) begin
                                state <= SEARCH; lock_lost <= 1'b1;
                                for (k=0;k<10;k=k+1) begin history[k] <= 0; history_count[k] <= 0; end
                            end else receive_bits <= receive_bits + 1'b1;
                        end
                    end
                    default: state<=SEARCH;
                endcase
                metric_phase <= (metric_phase == 9) ? 0 : metric_phase + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire

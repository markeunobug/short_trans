`timescale 1ns/1ps
`default_nettype none

module rx_cyclone10 (
    input  wire FPGA_CLK,
    input  wire ACLK_FPGA,

    input  wire ADC_FSYNC,
    input  wire ADC_BCLK,
    input  wire ADC_SDOUT,

    output wire ADC_SCL,
    inout  wire ADC_SDA,

    input  wire SPI1_MOSI,
    output wire SPI1_MISO,
    input  wire SPI1_SCK,
    input  wire SPI1_NSS,

    input  wire SPI3_MOSI,
    output wire SPI3_MISO,
    input  wire SPI3_SCK,
    input  wire SPI3_NSS
);

    wire clk_sys = FPGA_CLK;

    // The board has no FPGA reset pin. Cyclone 10 LP configuration clears
    // logic registers; this counter holds all domains reset for 256 sys clocks.
    (* preserve *) reg [7:0] power_on_count;
    always @(posedge FPGA_CLK) begin
        if (!(&power_on_count))
            power_on_count <= power_on_count + 1'b1;
    end
    wire async_reset_n = &power_on_count;

    wire rst_sys_n;
    wire rst_i2s_n;
    wire rst_mclk_n;
    reset_sync u_reset_sys (
        .clk(FPGA_CLK),
        .arst_n(async_reset_n),
        .srst_n(rst_sys_n),
        .srst()
    );
    reset_sync u_reset_i2s (
        .clk(ADC_BCLK),
        .arst_n(async_reset_n),
        .srst_n(rst_i2s_n),
        .srst()
    );
    reset_sync u_reset_mclk (
        .clk(ACLK_FPGA),
        .arst_n(async_reset_n),
        .srst_n(rst_mclk_n),
        .srst()
    );

    // Watch the external 24.576 MHz clock without transferring a counter bus.
    reg mclk_toggle;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg mclk_sync_ff1;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg mclk_sync_ff2;
    reg mclk_sync_d;
    reg [15:0] mclk_watchdog;
    (* keep *) reg mclk_present;

    always @(posedge ACLK_FPGA or negedge rst_mclk_n) begin
        if (!rst_mclk_n)
            mclk_toggle <= 1'b0;
        else
            mclk_toggle <= ~mclk_toggle;
    end

    always @(posedge FPGA_CLK or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            mclk_sync_ff1 <= 1'b0;
            mclk_sync_ff2 <= 1'b0;
            mclk_sync_d   <= 1'b0;
            mclk_watchdog <= 16'd0;
            mclk_present  <= 1'b0;
        end else begin
            mclk_sync_ff1 <= mclk_toggle;
            mclk_sync_ff2 <= mclk_sync_ff1;
            mclk_sync_d   <= mclk_sync_ff2;
            if (mclk_sync_ff2 != mclk_sync_d) begin
                mclk_watchdog <= 16'd0;
                mclk_present  <= 1'b1;
            end else if (mclk_watchdog < 16'd30000) begin
                mclk_watchdog <= mclk_watchdog + 1'b1;
            end else begin
                mclk_present <= 1'b0;
            end
        end
    end

    // Fixed TLV320ADC6120 configuration and open-drain I2C pins.
    wire adc_scl_drive_low;
    wire adc_sda_drive_low;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg adc_sda_sync_ff1;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg adc_sda_sync_ff2;
    wire adc_init_busy;
    wire adc_init_done;
    wire adc_init_error;
    (* keep *) wire adc_config_valid;
    wire [1:0] adc_init_attempt;
    wire [2:0] adc_last_error;
    wire [5:0] adc_last_failed_entry;
    wire [7:0] adc_last_read_data;
    wire [3:0] adc_init_state;
    wire adc_reinit_pulse;

    assign ADC_SCL = adc_scl_drive_low ? 1'b0 : 1'bz;
    assign ADC_SDA = adc_sda_drive_low ? 1'b0 : 1'bz;

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            adc_sda_sync_ff1 <= 1'b1;
            adc_sda_sync_ff2 <= 1'b1;
        end else begin
            adc_sda_sync_ff1 <= ADC_SDA;
            adc_sda_sync_ff2 <= adc_sda_sync_ff1;
        end
    end

    tlv320_init_ctrl u_adc_init (
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n),
        .reinit(adc_reinit_pulse),
        .i2c_sda_in(adc_sda_sync_ff2),
        .i2c_scl_drive_low(adc_scl_drive_low),
        .i2c_sda_drive_low(adc_sda_drive_low),
        .init_busy(adc_init_busy),
        .init_done(adc_init_done),
        .init_error(adc_init_error),
        .adc_data_valid(adc_config_valid),
        .attempt_count(adc_init_attempt),
        .last_error_code(adc_last_error),
        .last_failed_entry(adc_last_failed_entry),
        .last_read_data(adc_last_read_data),
        .state_debug(adc_init_state)
    );

    wire clear_errors_pulse;
    wire clear_i2s_errors;
    cdc_pulse u_clear_i2s_errors (
        .src_clk(clk_sys),
        .src_rst_n(rst_sys_n),
        .src_pulse(clear_errors_pulse),
        .dst_clk(ADC_BCLK),
        .dst_rst_n(rst_i2s_n),
        .dst_pulse(clear_i2s_errors)
    );

    // Keep the named I2S outputs available as stable pre-synthesis SignalTap
    // taps during receiver bring-up. These attributes do not alter behavior.
    (* keep *) wire signed [31:0] i2s_sample_data;
    (* keep *) wire i2s_sample_valid;
    (* keep *) wire i2s_format_error;
    wire [15:0] i2s_format_error_count;
    i2s_rx_ch1 u_i2s_rx (
        .clk_i2s(ADC_BCLK),
        .rst_i2s_n(rst_i2s_n),
        .i2s_fsync(ADC_FSYNC),
        .i2s_sdout(ADC_SDOUT),
        .clear_errors(clear_i2s_errors),
        .sample_data(i2s_sample_data),
        .sample_valid(i2s_sample_valid),
        .format_error(i2s_format_error),
        .format_error_count(i2s_format_error_count)
    );

    wire sample_fifo_full;
    wire sample_fifo_empty;
    wire sample_fifo_read;
    (* keep *) wire sample_fifo_rd_valid;
    (* keep *) wire [31:0] sample_fifo_rd_data;
    wire [4:0] sample_fifo_wr_level;
    wire [4:0] sample_fifo_rd_level;
    (* keep *) reg sample_fifo_overflow_i2s;

    always @(posedge ADC_BCLK or negedge rst_i2s_n) begin
        if (!rst_i2s_n)
            sample_fifo_overflow_i2s <= 1'b0;
        else if (clear_i2s_errors)
            sample_fifo_overflow_i2s <= 1'b0;
        else if (i2s_sample_valid && sample_fifo_full)
            sample_fifo_overflow_i2s <= 1'b1;
    end

    assign sample_fifo_read = !sample_fifo_empty;
    async_fifo #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(4)
    ) u_sample_fifo (
        .wr_clk(ADC_BCLK),
        .wr_rst_n(rst_i2s_n),
        .wr_en(i2s_sample_valid),
        .wr_data(i2s_sample_data),
        .wr_full(sample_fifo_full),
        .wr_accept(),
        .wr_level(sample_fifo_wr_level),
        .rd_clk(clk_sys),
        .rd_rst_n(rst_sys_n),
        .rd_en(sample_fifo_read),
        .rd_data(sample_fifo_rd_data),
        .rd_empty(sample_fifo_empty),
        .rd_accept(),
        .rd_valid(sample_fifo_rd_valid),
        .rd_level(sample_fifo_rd_level)
    );

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg sample_overflow_sync_ff1;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    (* keep *) reg sample_overflow_sync_ff2;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg i2s_error_sync_ff1;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    (* keep *) reg i2s_error_sync_ff2;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            sample_overflow_sync_ff1 <= 1'b0;
            sample_overflow_sync_ff2 <= 1'b0;
            i2s_error_sync_ff1 <= 1'b0;
            i2s_error_sync_ff2 <= 1'b0;
        end else begin
            sample_overflow_sync_ff1 <= sample_fifo_overflow_i2s;
            sample_overflow_sync_ff2 <= sample_overflow_sync_ff1;
            i2s_error_sync_ff1 <= i2s_format_error;
            i2s_error_sync_ff2 <= i2s_error_sync_ff1;
        end
    end

    (* keep *) wire [4:0] sample_shift;
    (* keep *) wire signed [19:0] demod_sample_data;
    (* keep *) wire sample_clipped_positive;
    (* keep *) wire sample_clipped_negative;
    (* keep *) wire adc_near_full_scale =
        (sample_fifo_rd_data[31:24] == 8'h7f) ||
        (sample_fifo_rd_data[31:24] == 8'h80);
    sample_preprocess u_sample_preprocess (
        .sample_in(sample_fifo_rd_data),
        .shift_amount(sample_shift),
        .sample_out(demod_sample_data),
        .clipped_positive(sample_clipped_positive),
        .clipped_negative(sample_clipped_negative)
    );

    wire snapshot_start_pulse;
    wire snapshot_read_next;
    wire [31:0] snapshot_read_data;
    wire snapshot_read_valid;
    wire snapshot_busy;
    wire snapshot_ready;
    wire [10:0] snapshot_samples_remaining;
    adc_snapshot u_snapshot (
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n),
        .sample_data(sample_fifo_rd_data),
        .sample_valid(sample_fifo_rd_valid),
        .snapshot_trigger(snapshot_start_pulse),
        .read_next(snapshot_read_next),
        .read_data(snapshot_read_data),
        .read_valid(snapshot_read_valid),
        .snapshot_busy(snapshot_busy),
        .snapshot_ready(snapshot_ready),
        .samples_remaining(snapshot_samples_remaining)
    );

    (* keep *) wire adc_stream_valid = adc_config_valid && mclk_present;
    (* keep *) wire demod_sample_valid = sample_fifo_rd_valid && adc_stream_valid;
    wire rst_chain_n;
    reset_sync u_reset_chain (
        .clk(clk_sys),
        .arst_n(async_reset_n && adc_stream_valid),
        .srst_n(rst_chain_n),
        .srst()
    );
    wire sweep_start_pulse;
    wire sweep_abort_pulse;
    wire [31:0] sweep_phase_increment;
    wire [15:0] sweep_settle_samples;
    wire [15:0] sweep_window_samples;
    wire [7:0] sweep_average_count;
    (* keep *) wire sweep_active;
    wire sweep_busy;
    wire sweep_done;
    wire sweep_error;
    wire [63:0] sweep_energy_sum;
    wire [31:0] sweep_energy_min;
    wire [31:0] sweep_energy_max;
    wire [31:0] sweep_clip_count;
    wire [7:0] sweep_window_count;

    sweep_iq_correlator u_sweep_correlator (
        .clk(clk_sys),
        .reset_n(rst_chain_n),
        .start_pulse(sweep_start_pulse),
        .abort_pulse(sweep_abort_pulse),
        .phase_increment(sweep_phase_increment),
        .settle_samples(sweep_settle_samples),
        .window_samples(sweep_window_samples),
        .average_count(sweep_average_count),
        .sample_valid(demod_sample_valid),
        .sample_data(demod_sample_data),
        .sample_clipped(adc_near_full_scale || sample_clipped_positive ||
                        sample_clipped_negative),
        .active(sweep_active),
        .busy(sweep_busy),
        .done(sweep_done),
        .error(sweep_error),
        .result_energy_sum(sweep_energy_sum),
        .result_energy_min(sweep_energy_min),
        .result_energy_max(sweep_energy_max),
        .result_clip_count(sweep_clip_count),
        .result_window_count(sweep_window_count)
    );

    // Sweep owns the ADC stream while active. The selected production path is
    // otherwise independent; config_apply_pulse resets only demod/symbol state.
    wire [1:0] rx_mode_active;
    wire [31:0] ask_low_active;
    wire [31:0] ask_high_active;
    wire config_apply_pulse;
    (* keep *) wire rst_fsk_n = rst_chain_n && !sweep_active &&
                                (rx_mode_active == 2'd1) && !config_apply_pulse;
    (* keep *) wire rst_ook_n = rst_chain_n && !sweep_active &&
                                (rx_mode_active == 2'd2) && !config_apply_pulse;

    wire [7:0] energy_margin;
    wire [15:0] noise_offset;
    wire [7:0] confidence_threshold;
    wire fsk_metric_valid;
    wire fsk_hard_bit;
    wire signed [32:0] soft_metric;
    wire [32:0] total_energy;
    wire [7:0] confidence;
    wire confidence_ok;
    wire [31:0] energy_f0;
    wire [31:0] energy_f1;
    wire [32:0] noise_energy;
    wire [32:0] carrier_threshold;
    wire energy_above_threshold;
    wire noise_ready;
    wire noise_update;
    (* keep *) wire fsk_carrier_active;

    fsk_demod_core u_demod (
        .clk(clk_sys), .reset_n(rst_fsk_n), .sample_valid(demod_sample_valid),
        .sample_data(demod_sample_data), .noise_track_enable(!fsk_carrier_active),
        .carrier_active(fsk_carrier_active), .noise_multiplier_q4_4(energy_margin),
        .noise_offset(noise_offset), .confidence_threshold(confidence_threshold),
        .metric_valid(fsk_metric_valid), .hard_bit(fsk_hard_bit), .soft_metric(soft_metric),
        .total_energy(total_energy), .confidence(confidence), .confidence_ok(confidence_ok),
        .energy_f0(energy_f0), .energy_f1(energy_f1), .noise_energy(noise_energy),
        .carrier_threshold(carrier_threshold), .energy_above_threshold(energy_above_threshold),
        .noise_ready(noise_ready), .noise_update(noise_update)
    );

    wire [1:0] observer_symbol_state;
    wire [3:0] observer_parser_state;
    wire [6:0] observer_payload_bytes;
    wire fsk_symbol_locked, fsk_preamble_detected, fsk_symbol_lock_lost;
    wire fsk_symbol_search_timeout, fsk_bit_valid, fsk_bit_value;
    wire [32:0] fsk_symbol_energy;
    wire [7:0] fsk_symbol_confidence;
    wire [3:0] fsk_selected_phase;
    wire signed [1:0] fsk_timing_adjust;
    wire fsk_frame_sync_found, fsk_frame_end;
    // The default 100-symbol guard fits TIME_BASE (16+80) but truncates DATA.
    // V2 DATA64 needs 16 sync + 8*(4 header+3 time+64 payload+2 CRC)=600.
    // Keep a bounded 40-symbol margin; carrier-loss release is unchanged.
    fsk_symbol_sync #(.LOCK_TIMEOUT_SYMBOLS(640)) u_symbol_sync (
        .debug_state(observer_symbol_state),
        .clk(clk_sys), .reset_n(rst_fsk_n), .metric_valid(fsk_metric_valid),
        .hard_bit(fsk_hard_bit), .total_energy(total_energy), .confidence(confidence),
        .carrier_present(energy_above_threshold), .preamble_confidence_threshold(confidence_threshold),
        .frame_sync_found(fsk_frame_sync_found), .frame_end(fsk_frame_end),
        .carrier_active(fsk_carrier_active), .sync_locked(fsk_symbol_locked),
        .preamble_detected(fsk_preamble_detected), .lock_lost(fsk_symbol_lock_lost),
        .search_timeout(fsk_symbol_search_timeout), .bit_valid(fsk_bit_valid),
        .bit_value(fsk_bit_value), .symbol_energy(fsk_symbol_energy),
        .symbol_confidence(fsk_symbol_confidence), .selected_phase(fsk_selected_phase),
        .timing_adjust(fsk_timing_adjust)
    );

    (* keep *) wire ook_metric_valid;
    (* keep *) wire [31:0] ook_energy;
    (* keep *) wire ook_energy_ready;
    ook_iq_correlator u_ook_correlator (
        .clk(clk_sys), .reset_n(rst_ook_n), .sample_valid(demod_sample_valid),
        .sample_data(demod_sample_data), .metric_valid(ook_metric_valid),
        .energy(ook_energy), .energy_ready(ook_energy_ready)
    );
    wire ook_hard_bit, ook_bit_valid, ook_bit_value, ook_symbol_locked, ook_candidate_active;
    wire ook_preamble_detected, ook_lock_lost;
    wire [3:0] ook_selected_phase;
    // Parser remains outside the per-mode reset so TIME_BASE and committed
    // FIFO contents survive a safe configuration apply and sweep suspension.
    wire parser_busy_for_ook;
    ook_symbol_sync u_ook_symbol_sync (
        .clk(clk_sys), .reset_n(rst_ook_n), .metric_valid(ook_metric_valid),
        .energy(ook_energy), .low_threshold(ask_low_active), .high_threshold(ask_high_active),
        .parser_busy(parser_busy_for_ook), .hard_bit(ook_hard_bit), .bit_valid(ook_bit_valid),
        .bit_value(ook_bit_value), .symbol_locked(ook_symbol_locked), .candidate_active(ook_candidate_active),
        .preamble_detected(ook_preamble_detected), .lock_lost(ook_lock_lost),
        .selected_phase(ook_selected_phase)
    );

    (* keep *) wire metric_valid = (rx_mode_active == 2'd2) ? ook_metric_valid : fsk_metric_valid;
    (* keep *) wire hard_bit = (rx_mode_active == 2'd2) ? ook_hard_bit : fsk_hard_bit;
    // Expose carrier only after the preamble has passed phase/match validation.
    // Keep fsk_carrier_active internal so noise learning remains frozen in search.
    (* keep *) wire carrier_active = (rx_mode_active == 2'd2) ? ook_symbol_locked : fsk_symbol_locked;
    (* keep *) wire symbol_locked = (rx_mode_active == 2'd2) ? ook_symbol_locked : fsk_symbol_locked;
    (* keep *) wire preamble_detected = (rx_mode_active == 2'd2) ? ook_preamble_detected : fsk_preamble_detected;
    (* keep *) wire symbol_lock_lost = (rx_mode_active == 2'd2) ? ook_lock_lost : fsk_symbol_lock_lost;
    (* keep *) wire symbol_search_timeout = (rx_mode_active == 2'd2) ? 1'b0 : fsk_symbol_search_timeout;
    (* keep *) wire bit_valid = !sweep_active && ((rx_mode_active == 2'd2) ? ook_bit_valid : fsk_bit_valid);
    (* keep *) wire bit_value = (rx_mode_active == 2'd2) ? ook_bit_value : fsk_bit_value;
    (* keep *) wire [32:0] symbol_energy = (rx_mode_active == 2'd2) ? {1'b0, ook_energy} : fsk_symbol_energy;
    (* keep *) wire [7:0] symbol_confidence = (rx_mode_active == 2'd2) ? 8'd0 : fsk_symbol_confidence;
    (* keep *) wire [3:0] selected_phase = (rx_mode_active == 2'd2) ? ook_selected_phase : fsk_selected_phase;
    (* keep *) wire signed [1:0] timing_adjust = (rx_mode_active == 2'd2) ? 2'sd0 : fsk_timing_adjust;

    (* keep *) wire frame_parser_busy;
    assign parser_busy_for_ook = frame_parser_busy;

    // Register one complete symbol result for SignalTap. The valid flag is
    // delayed by one clock so the stored bus is stable when it qualifies the
    // analyzer write and trigger.
    (* noprune, preserve *) reg [50:0] signaltap_symbol_debug;
    (* noprune, preserve *) reg signaltap_symbol_valid;
    always @(posedge clk_sys or negedge rst_fsk_n) begin
        if (!rst_fsk_n) begin
            signaltap_symbol_debug <= 51'd0;
            signaltap_symbol_valid <= 1'b0;
        end else begin
            signaltap_symbol_valid <= bit_valid;
            if (bit_valid) begin
                signaltap_symbol_debug <= {
                    frame_parser_busy,             // [50]
                    carrier_active,                // [49]
                    symbol_locked,                 // [48]
                    timing_adjust,                 // [47:46]
                    selected_phase,                // [45:42]
                    symbol_confidence,             // [41:34]
                    symbol_energy,                 // [33:1]
                    bit_value                      // [0]
                };
            end
        end
    end

    (* keep *) wire sync_found;
    (* keep *) wire frame_valid;
    (* keep *) wire good_frame;
    wire [7:0] frame_version_type;
    wire [7:0] frame_sequence;
    (* keep *) wire [7:0] frame_payload_length;
    (* keep *) wire [31:0] frame_timestamp;
    (* keep *) wire frame_timestamp_valid;
    (* keep *) wire frame_is_time_base;
    (* keep *) wire frame_payload_valid;
    (* keep *) wire [7:0] frame_payload_data;
    (* keep *) wire frame_payload_last;
    (* keep *) wire header_error;
    (* keep *) wire length_error;
    (* keep *) wire crc_error;
    (* keep *) wire frame_timeout_error;

    // Compact, stable SignalTap bus for the complete demodulation path.
    // Configure SignalTap to sample this bus with clk_sys; the bit allocation
    // is documented here so captures remain unambiguous across builds.
    (* keep *) wire [63:0] signaltap_demod_debug;
    assign signaltap_demod_debug = {
        noise_ready,                         // [63]
        sample_clipped_negative,             // [62]
        sample_clipped_positive,             // [61]
        adc_stream_valid,                    // [60]
        demod_sample_valid,                  // [59]
        symbol_confidence,                   // [58:51]
        confidence,                          // [50:43]
        timing_adjust,                       // [42:41]
        selected_phase,                      // [40:37]
        frame_payload_data,                  // [36:29]
        frame_payload_length,                // [28:21]
        frame_timeout_error,                 // [20]
        crc_error,                           // [19]
        length_error,                        // [18]
        header_error,                        // [17]
        frame_payload_last,                  // [16]
        frame_payload_valid,                 // [15]
        good_frame,                          // [14]
        frame_valid,                         // [13]
        frame_parser_busy,                   // [12]
        sync_found,                          // [11]
        symbol_search_timeout,               // [10]
        symbol_lock_lost,                    // [9]
        preamble_detected,                   // [8]
        symbol_locked,                       // [7]
        bit_value,                           // [6]
        bit_valid,                           // [5]
        hard_bit,                            // [4]
        confidence_ok,                       // [3]
        energy_above_threshold,              // [2]
        carrier_active,                      // [1]
        metric_valid                         // [0]
    };
    // A safe config apply or sweep transition abandons only a partial parser
    // candidate/frame through lock_lost; fsk_frame_rx retains TIME_BASE and
    // the committed SPI FIFO because rst_chain_n remains asserted.
    wire parser_lock_lost = symbol_lock_lost || config_apply_pulse ||
                            sweep_start_pulse || sweep_abort_pulse;
    assign fsk_frame_sync_found = (rx_mode_active == 2'd1) && sync_found;
    // Empty frames finish at CRC; non-empty frames finish with the last byte.
    assign fsk_frame_end = (rx_mode_active == 2'd1) &&
                           (header_error || length_error || crc_error || frame_timeout_error ||
                            frame_payload_last || (frame_valid && (frame_payload_length == 8'd0)));
    fsk_frame_rx u_frame_rx (
        .debug_state(observer_parser_state), .debug_payload_bytes(observer_payload_bytes),
        .clk(clk_sys),
        .rst_n(rst_chain_n),
        .bit_valid(bit_valid),
        .bit_value(bit_value),
        .lock_lost(parser_lock_lost),
        .busy(frame_parser_busy),
        .sync_found(sync_found),
        .frame_valid(frame_valid),
        .good_frame(good_frame),
        .frame_version_type(frame_version_type),
        .frame_sequence(frame_sequence),
        .frame_payload_length(frame_payload_length),
        .frame_timestamp(frame_timestamp),
        .frame_timestamp_valid(frame_timestamp_valid),
        .frame_is_time_base(frame_is_time_base),
        .frame_payload_valid(frame_payload_valid),
        .frame_payload_data(frame_payload_data),
        .frame_payload_last(frame_payload_last),
        .header_error(header_error),
        .length_error(length_error),
        .crc_error(crc_error),
        .timeout_error(frame_timeout_error)
    );

    reg [15:0] crc_error_count;
    reg [15:0] last_soft_metric;
    reg [7:0] last_energy_f0;
    reg [7:0] last_energy_f1;
    reg [7:0] last_confidence;

    function [7:0] compress_energy;
        input [31:0] value;
        begin
            compress_energy = (|value[31:8]) ? 8'hff : value[7:0];
        end
    endfunction

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            crc_error_count <= 16'd0;
            last_soft_metric <= 16'd0;
            last_energy_f0 <= 8'd0;
            last_energy_f1 <= 8'd0;
            last_confidence <= 8'd0;
        end else begin
            if (clear_errors_pulse)
                crc_error_count <= 16'd0;
            else if (crc_error && crc_error_count != 16'hffff)
                crc_error_count <= crc_error_count + 1'b1;

            if (metric_valid) begin
                last_soft_metric <= soft_metric[15:0];
                last_energy_f0 <= compress_energy(energy_f0);
                last_energy_f1 <= compress_energy(energy_f1);
                last_confidence <= confidence;
            end
        end
    end

    wire [6:0] spi_bus_address;
    wire spi_bus_read_preload;
    wire spi_bus_read_strobe;
    wire [7:0] spi_bus_read_data;
    wire [7:0] register_read_data, trace_read_data;
    wire trace_selected = ((spi_bus_address >= 7'h32) && (spi_bus_address <= 7'h3f)) ||
                          (spi_bus_address == 7'h42);
    wire [7:0] ber_read_data;
    wire ber_selected = (spi_bus_address >= 7'h49) && (spi_bus_address <= 7'h4f);
    assign spi_bus_read_data = ber_selected ? ber_read_data :
                              trace_selected ? trace_read_data : register_read_data;
    wire spi_bus_write_strobe;
    wire [7:0] spi_bus_write_data;
    wire spi_protocol_error;
    wire [111:0] trace_config = {ask_high_active, ask_low_active, noise_offset,
        confidence_threshold, energy_margin, 3'd0, sample_shift, 6'd0, rx_mode_active};
    wire [32:0] ook_midpoint = ({1'b0, ask_low_active} + {1'b0, ask_high_active}) >> 1;
    wire signed [32:0] trace_soft = (rx_mode_active == 2) ?
        $signed({1'b0, ook_energy}) - $signed(ook_midpoint) : soft_metric;
    // Keep the trace carrier/tone state distinct from symbol lock.
    wire trace_carrier = (rx_mode_active == 2'd2) ?
        (ook_energy_ready && ook_hard_bit) : fsk_carrier_active;
    wire [31:0] trace_state = {13'd0, ((rx_mode_active == 1) && confidence_ok), 1'b0,
        ((rx_mode_active == 2) ? (ook_energy >= ask_high_active) : energy_above_threshold),
        ((rx_mode_active == 2) ? ook_energy_ready : noise_ready), 10'd0,
        bit_value, 1'b0, symbol_locked, trace_carrier, hard_bit};
    wire [31:0] trace_events = {17'd0,
        (demod_sample_valid && (adc_near_full_scale || sample_clipped_positive || sample_clipped_negative)),
        symbol_search_timeout, frame_timeout_error, length_error, header_error,
        crc_error, good_frame, sync_found, symbol_lock_lost, preamble_detected, 5'd0};
    demod_trace u_demod_trace (
        .clk(clk_sys), .reset_n(rst_sys_n), .sample_valid(demod_sample_valid),
        .metric_valid(metric_valid), .energy0((rx_mode_active == 2) ? ook_energy : energy_f0),
        .energy1((rx_mode_active == 2) ? 32'd0 : energy_f1),
        .noise((rx_mode_active == 2) ? 33'd0 : noise_energy),
        .threshold((rx_mode_active == 2) ? {1'b0, ask_high_active} : carrier_threshold),
        .soft(trace_soft), .confidence((rx_mode_active == 2) ? 8'd0 : confidence),
        .state_flags(trace_state), .event_flags(trace_events), .bit_valid(bit_valid),
        .phase(selected_phase), .timing_adjust(timing_adjust), .config_data(trace_config),
        .chain_available(rst_chain_n && !sweep_active && !config_apply_pulse),
        .bus_address(spi_bus_address), .bus_read_strobe(spi_bus_read_strobe),
        .bus_write_strobe(spi_bus_write_strobe), .bus_write_data(spi_bus_write_data),
        .bus_read_data(trace_read_data)
    );
    // Observation only: no BER output feeds back into the production chain.
    wire [7:0] observer_read_data, observer_read_offset;
    ber_observer u_ber_observer (
        .clk(clk_sys), .reset_n(rst_sys_n),
        .sample_valid(demod_sample_valid), .metric_valid(fsk_metric_valid),
        .bit_valid(fsk_bit_valid),
        .chain_available(rst_chain_n && rx_mode_active == 2'd1 && !sweep_active && !config_apply_pulse),
        .carrier(fsk_carrier_active), .locked(fsk_symbol_locked),
        .parser_busy(frame_parser_busy), .preamble(fsk_preamble_detected),
        .parser_state(observer_parser_state), .symbol_state(observer_symbol_state),
        .payload_bytes(observer_payload_bytes), .hard_bit(fsk_hard_bit),
        .sync_found(sync_found), .header_error(header_error), .length_error(length_error),
        .crc_error(crc_error), .good_frame(good_frame), .lock_lost(parser_lock_lost),
        .frame_timeout(frame_timeout_error), .search_timeout(fsk_symbol_search_timeout),
        .i2s_error(i2s_error_sync_ff2), .cdc_error(sample_overflow_sync_ff2),
        .clipped(adc_near_full_scale || sample_clipped_positive || sample_clipped_negative),
        .energy_above(energy_above_threshold), .energy(total_energy), .threshold(carrier_threshold),
        .confidence(confidence), .phase(fsk_selected_phase), .timing_adjust(fsk_timing_adjust),
        .bus_address(spi_bus_address), .bus_read_strobe(spi_bus_read_strobe),
        .bus_write_strobe(spi_bus_write_strobe), .bus_write_data(spi_bus_write_data),
        .read_offset(observer_read_offset), .bus_read_data(observer_read_data)
    );
    ber_capture u_ber_capture (
        .clk(clk_sys), .reset_n(rst_sys_n), .sample_valid(sample_fifo_rd_valid),
        .observer_read_data(observer_read_data), .observer_read_offset(observer_read_offset),
        .chain_available(rst_chain_n && rx_mode_active == 2'd1 && !sweep_active &&
                         !config_apply_pulse),
        .sync_found(sync_found), .bit_valid(bit_valid), .bit_value(bit_value),
        .lock_lost(parser_lock_lost), .bus_address(spi_bus_address),
        .bus_read_strobe(spi_bus_read_strobe), .bus_write_strobe(spi_bus_write_strobe),
        .bus_write_data(spi_bus_write_data), .bus_read_data(ber_read_data)
    );

    spi1_slave u_spi1 (
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n),
        .spi_sck(SPI1_SCK),
        .spi_nss(SPI1_NSS),
        .spi_mosi(SPI1_MOSI),
        .spi_miso(SPI1_MISO),
        .bus_address(spi_bus_address),
        .bus_read_preload(spi_bus_read_preload),
        .bus_read_strobe(spi_bus_read_strobe),
        .bus_read_data(spi_bus_read_data),
        .bus_write_strobe(spi_bus_write_strobe),
        .bus_write_data(spi_bus_write_data),
        .spi_protocol_error(spi_protocol_error)
    );

    // Waiting for the next preamble is normal between physical frames.  A
    // symbol-search timeout is therefore a diagnostic event, not a malformed
    // frame/protocol error, and must not set ERROR_FLAGS[3].
    wire protocol_error = header_error || length_error || crc_error ||
                          frame_timeout_error;
    spi_register_bank u_register_bank (
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n),
        .bus_address(spi_bus_address),
        .bus_read_preload(spi_bus_read_preload),
        .bus_read_strobe(spi_bus_read_strobe),
        .bus_read_data(register_read_data),
        .bus_write_strobe(spi_bus_write_strobe),
        .bus_write_data(spi_bus_write_data),
        .spi_protocol_error(spi_protocol_error),
        .adc_init_done(adc_stream_valid),
        .adc_init_error(adc_init_error || !mclk_present),
        .carrier_detected(carrier_active),
        .symbol_locked(symbol_locked),
        .i2c_error(adc_init_error),
        .i2s_error(i2s_error_sync_ff2),
        .cdc_error(sample_overflow_sync_ff2),
        .protocol_error(protocol_error),
        .crc_error_count(crc_error_count),
        .last_soft_metric(last_soft_metric),
        .last_energy_f0(last_energy_f0),
        .last_energy_f1(last_energy_f1),
        .last_confidence(last_confidence),
        .rx_busy(frame_parser_busy || fsk_carrier_active ||
                 ((rx_mode_active == 2'd2) && ook_candidate_active)),
        .ook_energy(ook_energy),
        .ook_hard_bit(ook_hard_bit),
        .ook_symbol_locked(ook_symbol_locked),
        .ook_energy_ready(ook_energy_ready),
        .sweep_active(sweep_active),
        .sweep_busy(sweep_busy),
        .sweep_done(sweep_done),
        .sweep_error(sweep_error),
        .sweep_energy_sum(sweep_energy_sum),
        .sweep_energy_min(sweep_energy_min),
        .sweep_energy_max(sweep_energy_max),
        .sweep_clip_count(sweep_clip_count),
        .sweep_window_count(sweep_window_count),
        .frame_valid(frame_valid),
        .frame_version_type(frame_version_type),
        .frame_sequence(frame_sequence),
        .frame_payload_length(frame_payload_length),
        .frame_timestamp(frame_timestamp),
        .frame_timestamp_valid(frame_timestamp_valid),
        .frame_is_time_base(frame_is_time_base),
        .frame_payload_valid(frame_payload_valid),
        .frame_payload_data(frame_payload_data),
        .frame_payload_last(frame_payload_last),
        .snapshot_busy(snapshot_busy),
        .snapshot_ready(snapshot_ready),
        .snapshot_samples_remaining(snapshot_samples_remaining),
        .snapshot_read_data(snapshot_read_data),
        .snapshot_read_valid(snapshot_read_valid),
        .snapshot_read_next(snapshot_read_next),
        .clear_errors_pulse(clear_errors_pulse),
        .adc_reinit_pulse(adc_reinit_pulse),
        .snapshot_start_pulse(snapshot_start_pulse),
        .sweep_start_pulse(sweep_start_pulse),
        .sweep_abort_pulse(sweep_abort_pulse),
        .sample_shift(sample_shift),
        .energy_margin(energy_margin),
        .noise_offset(noise_offset),
        .confidence_threshold(confidence_threshold),
        .sweep_phase_increment(sweep_phase_increment),
        .sweep_settle_samples(sweep_settle_samples),
        .sweep_window_samples(sweep_window_samples),
        .sweep_average_count(sweep_average_count),
        .rx_mode_active(rx_mode_active),
        .ask_low_active(ask_low_active),
        .ask_high_active(ask_high_active),
        .config_apply_pulse(config_apply_pulse)
    );

    // SPI3 is reserved for a later revision and must never drive the bus.
    assign SPI3_MISO = 1'bz;

    wire unused_inputs = SPI3_MOSI ^ SPI3_SCK ^ SPI3_NSS ^
                         adc_init_busy ^ adc_init_attempt[0] ^
                         adc_last_error[0] ^ adc_last_failed_entry[0] ^
                         adc_last_read_data[0] ^ adc_init_state[0] ^
                         i2s_format_error_count[0] ^ sample_fifo_wr_level[0] ^
                         sample_fifo_rd_level[0] ^ sample_clipped_positive ^
                         sample_clipped_negative ^ noise_ready ^ noise_update ^
                         noise_energy[0] ^ carrier_threshold[0] ^
                         preamble_detected ^ symbol_energy[0] ^
                         symbol_confidence[0] ^ selected_phase[0] ^
                          timing_adjust[0] ^ frame_parser_busy ^ sync_found ^
                          good_frame ^ sweep_done ^ sweep_error ^
                          sweep_energy_sum[0] ^ sweep_energy_min[0] ^
                          sweep_energy_max[0] ^ sweep_clip_count[0] ^
                          sweep_window_count[0];

endmodule

`default_nettype wire

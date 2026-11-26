`timescale 1ns/1ps
`default_nettype none

// SPI-visible register map and packet/snapshot data ports.
// All ports are in clk_sys. spi1_slave performs the asynchronous pin sampling
// and presents byte strobes here.
module spi_register_bank (
    input  wire        clk_sys,
    input  wire        rst_sys_n,

    input  wire [6:0]  bus_address,
    input  wire        bus_read_preload,
    input  wire        bus_read_strobe,
    output reg  [7:0]  bus_read_data,
    input  wire        bus_write_strobe,
    input  wire [7:0]  bus_write_data,
    input  wire        spi_protocol_error,

    input  wire        adc_init_done,
    input  wire        adc_init_error,
    input  wire        carrier_detected,
    input  wire        symbol_locked,
    input  wire        i2c_error,
    input  wire        i2s_error,
    input  wire        cdc_error,
    input  wire        protocol_error,
    input  wire [15:0] crc_error_count,

    input  wire [15:0] last_soft_metric,
    input  wire [7:0]  last_energy_f0,
    input  wire [7:0]  last_energy_f1,
    input  wire [7:0]  last_confidence,

    // Mode-2 fixed OOK transaction interface.
    input  wire        rx_busy,
    input  wire [31:0] ook_energy,
    input  wire        ook_hard_bit,
    input  wire        ook_symbol_locked,
    input  wire        ook_energy_ready,

    input  wire        sweep_active,
    input  wire        sweep_busy,
    input  wire        sweep_done,
    input  wire        sweep_error,
    input  wire [63:0] sweep_energy_sum,
    input  wire [31:0] sweep_energy_min,
    input  wire [31:0] sweep_energy_max,
    input  wire [31:0] sweep_clip_count,
    input  wire [7:0]  sweep_window_count,

    input  wire        frame_valid,
    input  wire [7:0]  frame_version_type,
    input  wire [7:0]  frame_sequence,
    input  wire [7:0]  frame_payload_length,
    input  wire [31:0] frame_timestamp,
    input  wire        frame_timestamp_valid,
    input  wire        frame_is_time_base,
    input  wire        frame_payload_valid,
    input  wire [7:0]  frame_payload_data,
    input  wire        frame_payload_last,

    input  wire        snapshot_busy,
    input  wire        snapshot_ready,
    input  wire [10:0] snapshot_samples_remaining,
    input  wire [31:0] snapshot_read_data,
    input  wire        snapshot_read_valid,
    output reg         snapshot_read_next,

    output reg         clear_errors_pulse,
    output reg         adc_reinit_pulse,
    output reg         snapshot_start_pulse,
    output reg         sweep_start_pulse,
    output reg         sweep_abort_pulse,
    output reg  [4:0]  sample_shift,
    output reg  [7:0]  energy_margin,
    output reg  [15:0] noise_offset,
    output reg  [7:0]  confidence_threshold,
    output reg  [31:0] sweep_phase_increment,
    output reg  [15:0] sweep_settle_samples,
    output reg  [15:0] sweep_window_samples,
    output reg  [7:0]  sweep_average_count,
    output reg  [1:0]  rx_mode_active,
    output reg  [31:0] ask_low_active,
    output reg  [31:0] ask_high_active,
    output reg         config_apply_pulse
);

    localparam [7:0] DEVICE_ID_VALUE  = 8'hA7;
    localparam [7:0] FW_VERSION_VALUE = 8'h14;

    localparam [6:0] ADDR_DEVICE_ID         = 7'h00;
    localparam [6:0] ADDR_FW_VERSION        = 7'h01;
    localparam [6:0] ADDR_STATUS0           = 7'h02;
    localparam [6:0] ADDR_ERROR_FLAGS       = 7'h03;
    localparam [6:0] ADDR_FRAME_COUNT       = 7'h04;
    localparam [6:0] ADDR_HEAD_VERSION_TYPE = 7'h05;
    localparam [6:0] ADDR_HEAD_SEQUENCE     = 7'h06;
    localparam [6:0] ADDR_HEAD_LENGTH       = 7'h07;
    localparam [6:0] ADDR_RX_LEVEL_L        = 7'h08;
    localparam [6:0] ADDR_RX_LEVEL_H        = 7'h09;
    localparam [6:0] ADDR_GOOD_COUNT_L      = 7'h0A;
    localparam [6:0] ADDR_GOOD_COUNT_H      = 7'h0B;
    localparam [6:0] ADDR_CRC_ERROR_L       = 7'h0C;
    localparam [6:0] ADDR_CRC_ERROR_H       = 7'h0D;
    localparam [6:0] ADDR_CONTROL           = 7'h10;
    localparam [6:0] ADDR_SAMPLE_SHIFT      = 7'h11;
    localparam [6:0] ADDR_ENERGY_MARGIN     = 7'h12;
    localparam [6:0] ADDR_CONF_THRESHOLD    = 7'h13;
    localparam [6:0] ADDR_NOISE_OFFSET_L    = 7'h14;
    localparam [6:0] ADDR_NOISE_OFFSET_H    = 7'h15;
    localparam [6:0] ADDR_HEAD_TIME_FLAGS   = 7'h16;
    localparam [6:0] ADDR_HEAD_TIMESTAMP_B3 = 7'h17;
    localparam [6:0] ADDR_HEAD_TIMESTAMP_B2 = 7'h18;
    localparam [6:0] ADDR_HEAD_TIMESTAMP_B1 = 7'h19;
    localparam [6:0] ADDR_HEAD_TIMESTAMP_B0 = 7'h1A;
    localparam [6:0] ADDR_LAST_SOFT_L       = 7'h20;
    localparam [6:0] ADDR_LAST_SOFT_H       = 7'h21;
    localparam [6:0] ADDR_LAST_ENERGY_0     = 7'h22;
    localparam [6:0] ADDR_LAST_ENERGY_1     = 7'h23;
    localparam [6:0] ADDR_LAST_CONFIDENCE   = 7'h24;
    localparam [6:0] ADDR_SWEEP_PHASE_0     = 7'h25;
    localparam [6:0] ADDR_SWEEP_PHASE_1     = 7'h26;
    localparam [6:0] ADDR_SWEEP_PHASE_2     = 7'h27;
    localparam [6:0] ADDR_SWEEP_PHASE_3     = 7'h28;
    localparam [6:0] ADDR_SWEEP_SETTLE_L    = 7'h29;
    localparam [6:0] ADDR_SWEEP_SETTLE_H    = 7'h2A;
    localparam [6:0] ADDR_SWEEP_WINDOW_L    = 7'h2B;
    localparam [6:0] ADDR_SWEEP_WINDOW_H    = 7'h2C;
    localparam [6:0] ADDR_SWEEP_AVERAGE     = 7'h2D;
    localparam [6:0] ADDR_SWEEP_CONTROL     = 7'h2E;
    localparam [6:0] ADDR_SWEEP_STATUS      = 7'h2F;
    localparam [6:0] ADDR_SNAPSHOT_COUNT_L  = 7'h30;
    localparam [6:0] ADDR_SNAPSHOT_COUNT_H  = 7'h31;
    localparam [6:0] ADDR_RX_DATA            = 7'h40;
    localparam [6:0] ADDR_SNAPSHOT_DATA      = 7'h41;
    localparam [6:0] ADDR_SWEEP_SUM_0        = 7'h50;
    localparam [6:0] ADDR_SWEEP_SUM_1        = 7'h51;
    localparam [6:0] ADDR_SWEEP_SUM_2        = 7'h52;
    localparam [6:0] ADDR_SWEEP_SUM_3        = 7'h53;
    localparam [6:0] ADDR_SWEEP_SUM_4        = 7'h54;
    localparam [6:0] ADDR_SWEEP_SUM_5        = 7'h55;
    localparam [6:0] ADDR_SWEEP_SUM_6        = 7'h56;
    localparam [6:0] ADDR_SWEEP_SUM_7        = 7'h57;
    localparam [6:0] ADDR_SWEEP_MIN_0        = 7'h58;
    localparam [6:0] ADDR_SWEEP_MIN_1        = 7'h59;
    localparam [6:0] ADDR_SWEEP_MIN_2        = 7'h5A;
    localparam [6:0] ADDR_SWEEP_MIN_3        = 7'h5B;
    localparam [6:0] ADDR_SWEEP_MAX_0        = 7'h5C;
    localparam [6:0] ADDR_SWEEP_MAX_1        = 7'h5D;
    localparam [6:0] ADDR_SWEEP_MAX_2        = 7'h5E;
    localparam [6:0] ADDR_SWEEP_MAX_3        = 7'h5F;
    localparam [6:0] ADDR_SWEEP_CLIP_0       = 7'h60;
    localparam [6:0] ADDR_SWEEP_CLIP_1       = 7'h61;
    localparam [6:0] ADDR_SWEEP_CLIP_2       = 7'h62;
    localparam [6:0] ADDR_SWEEP_CLIP_3       = 7'h63;
    localparam [6:0] ADDR_SWEEP_COUNT        = 7'h64;
    localparam [6:0] ADDR_RX_MODE_SHADOW     = 7'h65;
    localparam [6:0] ADDR_ASK_LOW_0          = 7'h66;
    localparam [6:0] ADDR_ASK_LOW_1          = 7'h67;
    localparam [6:0] ADDR_ASK_LOW_2          = 7'h68;
    localparam [6:0] ADDR_ASK_LOW_3          = 7'h69;
    localparam [6:0] ADDR_ASK_HIGH_0         = 7'h6A;
    localparam [6:0] ADDR_ASK_HIGH_1         = 7'h6B;
    localparam [6:0] ADDR_ASK_HIGH_2         = 7'h6C;
    localparam [6:0] ADDR_ASK_HIGH_3         = 7'h6D;
    localparam [6:0] ADDR_ASK_CONFIG_CONTROL = 7'h6E;
    localparam [6:0] ADDR_ASK_CONFIG_STATUS  = 7'h6F;
    localparam [6:0] ADDR_ASK_LOW_ACTIVE_0   = 7'h70;
    localparam [6:0] ADDR_ASK_LOW_ACTIVE_1   = 7'h71;
    localparam [6:0] ADDR_ASK_LOW_ACTIVE_2   = 7'h72;
    localparam [6:0] ADDR_ASK_LOW_ACTIVE_3   = 7'h73;
    localparam [6:0] ADDR_ASK_HIGH_ACTIVE_0  = 7'h74;
    localparam [6:0] ADDR_ASK_HIGH_ACTIVE_1  = 7'h75;
    localparam [6:0] ADDR_ASK_HIGH_ACTIVE_2  = 7'h76;
    localparam [6:0] ADDR_ASK_HIGH_ACTIVE_3  = 7'h77;
    localparam [6:0] ADDR_ASK_ENERGY_0       = 7'h78;
    localparam [6:0] ADDR_ASK_ENERGY_1       = 7'h79;
    localparam [6:0] ADDR_ASK_ENERGY_2       = 7'h7A;
    localparam [6:0] ADDR_ASK_ENERGY_3       = 7'h7B;
    localparam [6:0] ADDR_RX_MODE_ACTIVE     = 7'h7C;
    localparam [6:0] ADDR_ASK_FLAGS          = 7'h7D;
    localparam [6:0] ADDR_CONFIG_GENERATION  = 7'h7E;
    localparam [6:0] ADDR_FSK_MARGIN_SHADOW  = 7'h43;
    localparam [6:0] ADDR_FSK_OFFSET_L_SHADOW = 7'h44;
    localparam [6:0] ADDR_FSK_OFFSET_H_SHADOW = 7'h45;
    localparam [6:0] ADDR_FSK_CONFIG_CONTROL = 7'h46;
    localparam [6:0] ADDR_FSK_CONFIG_STATUS  = 7'h47;
    localparam [6:0] ADDR_FSK_CONFIG_GENERATION = 7'h48;

    wire [7:0] fifo_head_version_type;
    wire [7:0] fifo_head_sequence;
    wire [7:0] fifo_head_length;
    wire [7:0] fifo_head_payload_data;
    wire [7:0] fifo_head_remaining;
    wire [31:0] fifo_head_timestamp;
    wire fifo_head_timestamp_valid;
    wire fifo_head_is_time_base;
    wire [8:0] fifo_payload_level;
    wire [3:0] fifo_frame_count;
    wire [15:0] fifo_good_frame_count;
    wire fifo_overflow_sticky;
    wire fifo_protocol_error_sticky;
    wire fifo_ingress_busy;

    reg fifo_rx_data_pop;
    reg fifo_pop_frame;
    reg fifo_drop_frame;

    reg [31:0] snapshot_word0;
    reg [31:0] snapshot_word1;
    reg [1:0]  snapshot_word_count;
    reg [1:0]  snapshot_byte_index;
    reg        snapshot_read_pending;
    reg        snapshot_underflow_sticky;
    reg        spi_error_sticky;
    reg        external_protocol_sticky;
    reg [7:0]  rx_mode_shadow;
    reg [31:0] ask_low_shadow, ask_high_shadow;
    reg        config_pending, config_error_sticky;
    reg [1:0]  pending_mode;
    reg [31:0] pending_low, pending_high;
    reg [7:0]  config_generation;
    reg [7:0]  fsk_margin_shadow;
    reg [15:0] fsk_offset_shadow;
    reg [7:0]  fsk_pending_margin;
    reg [15:0] fsk_pending_offset;
    reg        fsk_config_pending;
    reg        fsk_config_error;
    reg [7:0]  fsk_config_generation;
    reg [31:0] energy_latch;

    wire snapshot_data_read;
    wire snapshot_word_pop;
    wire snapshot_queue_push;
    wire [11:0] snapshot_total_count_wide;
    wire [10:0] snapshot_total_count;
    wire snapshot_stream_available;
    wire [7:0] status0_value;
    wire [7:0] error_flags_value;

    assign snapshot_data_read = bus_read_strobe &&
                                (bus_address == ADDR_SNAPSHOT_DATA);
    assign snapshot_word_pop = snapshot_data_read &&
                               (snapshot_word_count != 0) &&
                               (snapshot_byte_index == 2'd3);
    assign snapshot_queue_push = snapshot_read_valid && snapshot_read_pending;
    assign snapshot_total_count_wide = {1'b0, snapshot_samples_remaining} +
                                       snapshot_word_count;
    assign snapshot_total_count = snapshot_total_count_wide[10:0];
    assign snapshot_stream_available = (snapshot_total_count != 0);

    assign status0_value = {
        adc_init_done,
        adc_init_error,
        carrier_detected,
        symbol_locked,
        (fifo_frame_count != 0),
        snapshot_stream_available,
        snapshot_busy,
        fifo_ingress_busy
    };

    assign error_flags_value = {
        i2c_error,
        i2s_error,
        cdc_error,
        fifo_overflow_sticky,
        (protocol_error || external_protocol_sticky ||
         fifo_protocol_error_sticky),
        spi_error_sticky,
        snapshot_underflow_sticky,
        1'b0
    };

    rx_frame_fifo u_rx_frame_fifo (
        .clk                    (clk_sys),
        .rst_n                  (rst_sys_n),
        .frame_valid            (frame_valid),
        .frame_version_type     (frame_version_type),
        .frame_sequence         (frame_sequence),
        .frame_payload_length   (frame_payload_length),
        .frame_timestamp        (frame_timestamp),
        .frame_timestamp_valid  (frame_timestamp_valid),
        .frame_is_time_base     (frame_is_time_base),
        .frame_payload_valid    (frame_payload_valid),
        .frame_payload_data     (frame_payload_data),
        .frame_payload_last     (frame_payload_last),
        .rx_data_pop            (fifo_rx_data_pop),
        .pop_frame              (fifo_pop_frame),
        .drop_frame             (fifo_drop_frame),
        .clear_errors           (clear_errors_pulse),
        .head_version_type      (fifo_head_version_type),
        .head_sequence          (fifo_head_sequence),
        .head_length            (fifo_head_length),
        .head_payload_data      (fifo_head_payload_data),
        .head_timestamp         (fifo_head_timestamp),
        .head_timestamp_valid   (fifo_head_timestamp_valid),
        .head_is_time_base      (fifo_head_is_time_base),
        .head_remaining         (fifo_head_remaining),
        .payload_level          (fifo_payload_level),
        .frame_count            (fifo_frame_count),
        .good_frame_count       (fifo_good_frame_count),
        .fifo_overflow_sticky   (fifo_overflow_sticky),
        .protocol_error_sticky  (fifo_protocol_error_sticky),
        .ingress_busy           (fifo_ingress_busy)
    );

    always @(*) begin
        case (bus_address)
            ADDR_DEVICE_ID:         bus_read_data = DEVICE_ID_VALUE;
            ADDR_FW_VERSION:        bus_read_data = FW_VERSION_VALUE;
            ADDR_STATUS0:           bus_read_data = status0_value;
            ADDR_ERROR_FLAGS:       bus_read_data = error_flags_value;
            ADDR_FRAME_COUNT:       bus_read_data = {4'd0, fifo_frame_count};
            ADDR_HEAD_VERSION_TYPE: bus_read_data = fifo_head_version_type;
            ADDR_HEAD_SEQUENCE:     bus_read_data = fifo_head_sequence;
            ADDR_HEAD_LENGTH:       bus_read_data = fifo_head_length;
            ADDR_RX_LEVEL_L:        bus_read_data = fifo_payload_level[7:0];
            ADDR_RX_LEVEL_H:        bus_read_data = {7'd0, fifo_payload_level[8]};
            ADDR_GOOD_COUNT_L:      bus_read_data = fifo_good_frame_count[7:0];
            ADDR_GOOD_COUNT_H:      bus_read_data = fifo_good_frame_count[15:8];
            ADDR_CRC_ERROR_L:       bus_read_data = crc_error_count[7:0];
            ADDR_CRC_ERROR_H:       bus_read_data = crc_error_count[15:8];
            ADDR_SAMPLE_SHIFT:      bus_read_data = {3'd0, sample_shift};
            ADDR_ENERGY_MARGIN:     bus_read_data = energy_margin;
            ADDR_CONF_THRESHOLD:    bus_read_data = confidence_threshold;
            ADDR_NOISE_OFFSET_L:    bus_read_data = noise_offset[7:0];
            ADDR_NOISE_OFFSET_H:    bus_read_data = noise_offset[15:8];
            ADDR_HEAD_TIME_FLAGS:   bus_read_data = {6'd0, fifo_head_is_time_base, fifo_head_timestamp_valid};
            ADDR_HEAD_TIMESTAMP_B3: bus_read_data = fifo_head_timestamp[31:24];
            ADDR_HEAD_TIMESTAMP_B2: bus_read_data = fifo_head_timestamp[23:16];
            ADDR_HEAD_TIMESTAMP_B1: bus_read_data = fifo_head_timestamp[15:8];
            ADDR_HEAD_TIMESTAMP_B0: bus_read_data = fifo_head_timestamp[7:0];
            ADDR_LAST_SOFT_L:       bus_read_data = last_soft_metric[7:0];
            ADDR_LAST_SOFT_H:       bus_read_data = last_soft_metric[15:8];
            ADDR_LAST_ENERGY_0:     bus_read_data = last_energy_f0;
            ADDR_LAST_ENERGY_1:     bus_read_data = last_energy_f1;
            ADDR_LAST_CONFIDENCE:   bus_read_data = last_confidence;
            ADDR_SWEEP_PHASE_0:     bus_read_data = sweep_phase_increment[7:0];
            ADDR_SWEEP_PHASE_1:     bus_read_data = sweep_phase_increment[15:8];
            ADDR_SWEEP_PHASE_2:     bus_read_data = sweep_phase_increment[23:16];
            ADDR_SWEEP_PHASE_3:     bus_read_data = sweep_phase_increment[31:24];
            ADDR_SWEEP_SETTLE_L:    bus_read_data = sweep_settle_samples[7:0];
            ADDR_SWEEP_SETTLE_H:    bus_read_data = sweep_settle_samples[15:8];
            ADDR_SWEEP_WINDOW_L:    bus_read_data = sweep_window_samples[7:0];
            ADDR_SWEEP_WINDOW_H:    bus_read_data = sweep_window_samples[15:8];
            ADDR_SWEEP_AVERAGE:     bus_read_data = sweep_average_count;
            ADDR_SWEEP_STATUS:      bus_read_data = {4'd0, sweep_error, sweep_done,
                                                     sweep_busy, sweep_active};
            ADDR_SNAPSHOT_COUNT_L:  bus_read_data = snapshot_total_count[7:0];
            ADDR_SNAPSHOT_COUNT_H:  bus_read_data = {5'd0, snapshot_total_count[10:8]};
            ADDR_RX_DATA:           bus_read_data = fifo_head_payload_data;
            ADDR_SNAPSHOT_DATA: begin
                case (snapshot_byte_index)
                    2'd0: bus_read_data = snapshot_word0[31:24];
                    2'd1: bus_read_data = snapshot_word0[23:16];
                    2'd2: bus_read_data = snapshot_word0[15:8];
                    default: bus_read_data = snapshot_word0[7:0];
                endcase
                if (snapshot_word_count == 0)
                    bus_read_data = 8'd0;
            end
            ADDR_SWEEP_SUM_0:       bus_read_data = sweep_energy_sum[7:0];
            ADDR_SWEEP_SUM_1:       bus_read_data = sweep_energy_sum[15:8];
            ADDR_SWEEP_SUM_2:       bus_read_data = sweep_energy_sum[23:16];
            ADDR_SWEEP_SUM_3:       bus_read_data = sweep_energy_sum[31:24];
            ADDR_SWEEP_SUM_4:       bus_read_data = sweep_energy_sum[39:32];
            ADDR_SWEEP_SUM_5:       bus_read_data = sweep_energy_sum[47:40];
            ADDR_SWEEP_SUM_6:       bus_read_data = sweep_energy_sum[55:48];
            ADDR_SWEEP_SUM_7:       bus_read_data = sweep_energy_sum[63:56];
            ADDR_SWEEP_MIN_0:       bus_read_data = sweep_energy_min[7:0];
            ADDR_SWEEP_MIN_1:       bus_read_data = sweep_energy_min[15:8];
            ADDR_SWEEP_MIN_2:       bus_read_data = sweep_energy_min[23:16];
            ADDR_SWEEP_MIN_3:       bus_read_data = sweep_energy_min[31:24];
            ADDR_SWEEP_MAX_0:       bus_read_data = sweep_energy_max[7:0];
            ADDR_SWEEP_MAX_1:       bus_read_data = sweep_energy_max[15:8];
            ADDR_SWEEP_MAX_2:       bus_read_data = sweep_energy_max[23:16];
            ADDR_SWEEP_MAX_3:       bus_read_data = sweep_energy_max[31:24];
            ADDR_SWEEP_CLIP_0:      bus_read_data = sweep_clip_count[7:0];
            ADDR_SWEEP_CLIP_1:      bus_read_data = sweep_clip_count[15:8];
            ADDR_SWEEP_CLIP_2:      bus_read_data = sweep_clip_count[23:16];
            ADDR_SWEEP_CLIP_3:      bus_read_data = sweep_clip_count[31:24];
            ADDR_SWEEP_COUNT:       bus_read_data = sweep_window_count;
            ADDR_RX_MODE_SHADOW:    bus_read_data = rx_mode_shadow;
            ADDR_ASK_LOW_0:         bus_read_data = ask_low_shadow[7:0];
            ADDR_ASK_LOW_1:         bus_read_data = ask_low_shadow[15:8];
            ADDR_ASK_LOW_2:         bus_read_data = ask_low_shadow[23:16];
            ADDR_ASK_LOW_3:         bus_read_data = ask_low_shadow[31:24];
            ADDR_ASK_HIGH_0:        bus_read_data = ask_high_shadow[7:0];
            ADDR_ASK_HIGH_1:        bus_read_data = ask_high_shadow[15:8];
            ADDR_ASK_HIGH_2:        bus_read_data = ask_high_shadow[23:16];
            ADDR_ASK_HIGH_3:        bus_read_data = ask_high_shadow[31:24];
            ADDR_ASK_CONFIG_STATUS: bus_read_data = {4'd0, sweep_active, rx_busy, config_error_sticky, config_pending};
            ADDR_ASK_LOW_ACTIVE_0:  bus_read_data = ask_low_active[7:0];
            ADDR_ASK_LOW_ACTIVE_1:  bus_read_data = ask_low_active[15:8];
            ADDR_ASK_LOW_ACTIVE_2:  bus_read_data = ask_low_active[23:16];
            ADDR_ASK_LOW_ACTIVE_3:  bus_read_data = ask_low_active[31:24];
            ADDR_ASK_HIGH_ACTIVE_0: bus_read_data = ask_high_active[7:0];
            ADDR_ASK_HIGH_ACTIVE_1: bus_read_data = ask_high_active[15:8];
            ADDR_ASK_HIGH_ACTIVE_2: bus_read_data = ask_high_active[23:16];
            ADDR_ASK_HIGH_ACTIVE_3: bus_read_data = ask_high_active[31:24];
            ADDR_ASK_ENERGY_0:      bus_read_data = bus_read_preload ? ook_energy[7:0] : energy_latch[7:0];
            ADDR_ASK_ENERGY_1:      bus_read_data = energy_latch[15:8];
            ADDR_ASK_ENERGY_2:      bus_read_data = energy_latch[23:16];
            ADDR_ASK_ENERGY_3:      bus_read_data = energy_latch[31:24];
            ADDR_RX_MODE_ACTIVE:    bus_read_data = {6'd0, rx_mode_active};
            ADDR_ASK_FLAGS:         bus_read_data = {5'd0, ook_energy_ready, ook_symbol_locked, ook_hard_bit};
            ADDR_CONFIG_GENERATION: bus_read_data = config_generation;
            ADDR_FSK_MARGIN_SHADOW: bus_read_data = fsk_margin_shadow;
            ADDR_FSK_OFFSET_L_SHADOW: bus_read_data = fsk_offset_shadow[7:0];
            ADDR_FSK_OFFSET_H_SHADOW: bus_read_data = fsk_offset_shadow[15:8];
            ADDR_FSK_CONFIG_STATUS: bus_read_data = {4'd0, sweep_active, rx_busy, fsk_config_error, fsk_config_pending};
            ADDR_FSK_CONFIG_GENERATION: bus_read_data = fsk_config_generation;
            default: bus_read_data = 8'd0;
        endcase
    end

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            clear_errors_pulse       <= 1'b0;
            adc_reinit_pulse          <= 1'b0;
            snapshot_start_pulse      <= 1'b0;
            sweep_start_pulse         <= 1'b0;
            sweep_abort_pulse         <= 1'b0;
            fifo_rx_data_pop          <= 1'b0;
            fifo_pop_frame            <= 1'b0;
            fifo_drop_frame           <= 1'b0;
            sample_shift              <= 5'd12;
            energy_margin             <= 8'h20;
            noise_offset              <= 16'd200;
            confidence_threshold      <= 8'h20;
            sweep_phase_increment     <= 32'h08000000;
            sweep_settle_samples      <= 16'd960;
            sweep_window_samples      <= 16'd4800;
            sweep_average_count       <= 8'd3;
            snapshot_word0            <= 32'd0;
            snapshot_word1            <= 32'd0;
            snapshot_word_count       <= 2'd0;
            snapshot_byte_index       <= 2'd0;
            snapshot_read_pending     <= 1'b0;
            snapshot_read_next        <= 1'b0;
            snapshot_underflow_sticky <= 1'b0;
            spi_error_sticky           <= 1'b0;
            external_protocol_sticky   <= 1'b0;
            rx_mode_shadow <= 8'd1;
            ask_low_shadow <= 32'd400;
            ask_high_shadow <= 32'd600;
            rx_mode_active <= 2'd1;
            ask_low_active <= 32'd400;
            ask_high_active <= 32'd600;
            config_pending <= 1'b0;
            config_error_sticky <= 1'b0;
            pending_mode <= 2'd1;
            pending_low <= 32'd400;
            pending_high <= 32'd600;
            config_generation <= 8'd0;
            fsk_margin_shadow <= 8'h20;
            fsk_offset_shadow <= 16'd200;
            fsk_pending_margin <= 8'h20;
            fsk_pending_offset <= 16'd200;
            fsk_config_pending <= 1'b0;
            fsk_config_error <= 1'b0;
            fsk_config_generation <= 8'd0;
            energy_latch <= 32'd0;
            config_apply_pulse <= 1'b0;
        end else begin
            clear_errors_pulse  <= 1'b0;
            adc_reinit_pulse     <= 1'b0;
            snapshot_start_pulse <= 1'b0;
            sweep_start_pulse    <= 1'b0;
            sweep_abort_pulse    <= 1'b0;
            fifo_rx_data_pop     <= 1'b0;
            fifo_pop_frame       <= 1'b0;
            fifo_drop_frame      <= 1'b0;
            snapshot_read_next   <= 1'b0;
            config_apply_pulse   <= 1'b0;
            if (bus_read_preload && bus_address == ADDR_ASK_ENERGY_0)
                energy_latch <= ook_energy;
            if (config_pending && !rx_busy && !sweep_active) begin
                rx_mode_active <= pending_mode;
                ask_low_active <= pending_low;
                ask_high_active <= pending_high;
                config_pending <= 1'b0;
                config_generation <= config_generation + 1'b1;
                config_apply_pulse <= 1'b1;
            end

            if (fsk_config_pending && !config_pending &&
                (rx_mode_active == 2'd1) && !rx_busy && !sweep_active) begin
                energy_margin <= fsk_pending_margin;
                noise_offset <= fsk_pending_offset;
                fsk_config_pending <= 1'b0;
                fsk_config_generation <= fsk_config_generation + 1'b1;
                config_apply_pulse <= 1'b1;
            end
            if (spi_protocol_error)
                spi_error_sticky <= 1'b1;
            if (protocol_error)
                external_protocol_sticky <= 1'b1;

            if (!snapshot_read_pending && snapshot_ready &&
                (snapshot_word_count < 2)) begin
                snapshot_read_next    <= 1'b1;
                snapshot_read_pending <= 1'b1;
            end

            if (snapshot_queue_push)
                snapshot_read_pending <= 1'b0;

            case ({snapshot_queue_push, snapshot_word_pop})
                2'b10: begin
                    if (snapshot_word_count == 0)
                        snapshot_word0 <= snapshot_read_data;
                    else
                        snapshot_word1 <= snapshot_read_data;
                    snapshot_word_count <= snapshot_word_count + 1'b1;
                end
                2'b01: begin
                    if (snapshot_word_count == 2)
                        snapshot_word0 <= snapshot_word1;
                    snapshot_word_count <= snapshot_word_count - 1'b1;
                end
                2'b11: begin
                    if (snapshot_word_count == 1) begin
                        snapshot_word0 <= snapshot_read_data;
                        snapshot_word_count <= 2'd1;
                    end else begin
                        snapshot_word0 <= snapshot_word1;
                        snapshot_word1 <= snapshot_read_data;
                        snapshot_word_count <= snapshot_word_count;
                    end
                end
                default: snapshot_word_count <= snapshot_word_count;
            endcase

            if (snapshot_data_read) begin
                if (snapshot_word_count == 0) begin
                    snapshot_underflow_sticky <= 1'b1;
                end else if (snapshot_byte_index == 2'd3) begin
                    snapshot_byte_index <= 2'd0;
                end else begin
                    snapshot_byte_index <= snapshot_byte_index + 1'b1;
                end
            end

            if (bus_read_strobe && bus_address == ADDR_RX_DATA)
                fifo_rx_data_pop <= 1'b1;

            if (bus_write_strobe) begin
                case (bus_address)
                    ADDR_CONTROL: begin
                        clear_errors_pulse  <= bus_write_data[0];
                        adc_reinit_pulse     <= bus_write_data[1];
                        snapshot_start_pulse <= bus_write_data[2];
                        fifo_pop_frame       <= bus_write_data[3];
                        fifo_drop_frame      <= bus_write_data[4];
                        if (bus_write_data[0]) begin
                            snapshot_underflow_sticky <= 1'b0;
                            spi_error_sticky           <= 1'b0;
                            external_protocol_sticky   <= 1'b0;
                        end
                    end
                    ADDR_SAMPLE_SHIFT:
                        sample_shift <= bus_write_data[4:0];
                    ADDR_ENERGY_MARGIN:
                        energy_margin <= bus_write_data;
                    ADDR_CONF_THRESHOLD:
                        confidence_threshold <= bus_write_data;
                    ADDR_NOISE_OFFSET_L:
                        noise_offset[7:0] <= bus_write_data;
                    ADDR_NOISE_OFFSET_H:
                        noise_offset[15:8] <= bus_write_data;
                    ADDR_SWEEP_PHASE_0:
                        sweep_phase_increment[7:0] <= bus_write_data;
                    ADDR_SWEEP_PHASE_1:
                        sweep_phase_increment[15:8] <= bus_write_data;
                    ADDR_SWEEP_PHASE_2:
                        sweep_phase_increment[23:16] <= bus_write_data;
                    ADDR_SWEEP_PHASE_3:
                        sweep_phase_increment[31:24] <= bus_write_data;
                    ADDR_SWEEP_SETTLE_L:
                        sweep_settle_samples[7:0] <= bus_write_data;
                    ADDR_SWEEP_SETTLE_H:
                        sweep_settle_samples[15:8] <= bus_write_data;
                    ADDR_SWEEP_WINDOW_L:
                        sweep_window_samples[7:0] <= bus_write_data;
                    ADDR_SWEEP_WINDOW_H:
                        sweep_window_samples[15:8] <= bus_write_data;
                    ADDR_SWEEP_AVERAGE:
                        sweep_average_count <= bus_write_data;
                    ADDR_SWEEP_CONTROL: begin
                        sweep_start_pulse <= bus_write_data[0];
                        sweep_abort_pulse <= bus_write_data[1];
                    end
                    ADDR_RX_MODE_SHADOW:
                        rx_mode_shadow <= bus_write_data;
                    ADDR_ASK_LOW_0: ask_low_shadow[7:0] <= bus_write_data;
                    ADDR_ASK_LOW_1: ask_low_shadow[15:8] <= bus_write_data;
                    ADDR_ASK_LOW_2: ask_low_shadow[23:16] <= bus_write_data;
                    ADDR_ASK_LOW_3: ask_low_shadow[31:24] <= bus_write_data;
                    ADDR_ASK_HIGH_0: ask_high_shadow[7:0] <= bus_write_data;
                    ADDR_ASK_HIGH_1: ask_high_shadow[15:8] <= bus_write_data;
                    ADDR_ASK_HIGH_2: ask_high_shadow[23:16] <= bus_write_data;
                    ADDR_ASK_HIGH_3: ask_high_shadow[31:24] <= bus_write_data;
                    ADDR_ASK_CONFIG_CONTROL: begin
                        if (bus_write_data[1]) config_error_sticky <= 1'b0;
                        if (bus_write_data[0]) begin
                            if (config_pending || fsk_config_pending) config_error_sticky <= 1'b1;
                            else if (((rx_mode_shadow == 8'd1) || (rx_mode_shadow == 8'd2)) &&
                                     (ask_low_shadow < ask_high_shadow)) begin
                                pending_mode <= rx_mode_shadow[1:0];
                                pending_low <= ask_low_shadow;
                                pending_high <= ask_high_shadow;
                                config_pending <= 1'b1;
                            end else config_error_sticky <= 1'b1;
                        end
                    end
                    ADDR_FSK_MARGIN_SHADOW:
                        fsk_margin_shadow <= bus_write_data;
                    ADDR_FSK_OFFSET_L_SHADOW:
                        fsk_offset_shadow[7:0] <= bus_write_data;
                    ADDR_FSK_OFFSET_H_SHADOW:
                        fsk_offset_shadow[15:8] <= bus_write_data;
                    ADDR_FSK_CONFIG_CONTROL: begin
                        if (bus_write_data[1]) fsk_config_error <= 1'b0;
                        if (bus_write_data[0]) begin
                            if (fsk_config_pending || config_pending ||
                                (rx_mode_active != 2'd1) ||
                                (fsk_margin_shadow == 8'd0)) begin
                                fsk_config_error <= 1'b1;
                            end else begin
                                fsk_pending_margin <= fsk_margin_shadow;
                                fsk_pending_offset <= fsk_offset_shadow;
                                fsk_config_pending <= 1'b1;
                            end
                        end
                    end
                    default: begin
                    end
                endcase
            end
        end
    end

endmodule

`default_nettype wire

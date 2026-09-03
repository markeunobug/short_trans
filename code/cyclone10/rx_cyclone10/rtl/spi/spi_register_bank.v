`timescale 1ns/1ps
`default_nettype none

// SPI-visible register map and packet/snapshot data ports.
// All ports are in clk_sys. spi1_slave performs the asynchronous pin sampling
// and presents byte strobes here.
module spi_register_bank (
    input  wire        clk_sys,
    input  wire        rst_sys_n,

    input  wire [6:0]  bus_address,
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

    input  wire        frame_valid,
    input  wire [7:0]  frame_version_type,
    input  wire [7:0]  frame_sequence,
    input  wire [7:0]  frame_payload_length,
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
    output reg  [4:0]  sample_shift,
    output reg  [7:0]  energy_margin,
    output reg  [15:0] noise_offset,
    output reg  [7:0]  confidence_threshold
);

    localparam [7:0] DEVICE_ID_VALUE  = 8'hA7;
    localparam [7:0] FW_VERSION_VALUE = 8'h10;

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
    localparam [6:0] ADDR_LAST_SOFT_L       = 7'h20;
    localparam [6:0] ADDR_LAST_SOFT_H       = 7'h21;
    localparam [6:0] ADDR_LAST_ENERGY_0     = 7'h22;
    localparam [6:0] ADDR_LAST_ENERGY_1     = 7'h23;
    localparam [6:0] ADDR_LAST_CONFIDENCE   = 7'h24;
    localparam [6:0] ADDR_SNAPSHOT_COUNT_L  = 7'h30;
    localparam [6:0] ADDR_SNAPSHOT_COUNT_H  = 7'h31;
    localparam [6:0] ADDR_RX_DATA            = 7'h40;
    localparam [6:0] ADDR_SNAPSHOT_DATA      = 7'h41;

    wire [7:0] fifo_head_version_type;
    wire [7:0] fifo_head_sequence;
    wire [7:0] fifo_head_length;
    wire [7:0] fifo_head_payload_data;
    wire [7:0] fifo_head_remaining;
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
            ADDR_LAST_SOFT_L:       bus_read_data = last_soft_metric[7:0];
            ADDR_LAST_SOFT_H:       bus_read_data = last_soft_metric[15:8];
            ADDR_LAST_ENERGY_0:     bus_read_data = last_energy_f0;
            ADDR_LAST_ENERGY_1:     bus_read_data = last_energy_f1;
            ADDR_LAST_CONFIDENCE:   bus_read_data = last_confidence;
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
            default: bus_read_data = 8'd0;
        endcase
    end

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            clear_errors_pulse       <= 1'b0;
            adc_reinit_pulse          <= 1'b0;
            snapshot_start_pulse      <= 1'b0;
            fifo_rx_data_pop          <= 1'b0;
            fifo_pop_frame            <= 1'b0;
            fifo_drop_frame           <= 1'b0;
            sample_shift              <= 5'd12;
            energy_margin             <= 8'h40;
            noise_offset              <= 16'd200;
            confidence_threshold      <= 8'h20;
            snapshot_word0            <= 32'd0;
            snapshot_word1            <= 32'd0;
            snapshot_word_count       <= 2'd0;
            snapshot_byte_index       <= 2'd0;
            snapshot_read_pending     <= 1'b0;
            snapshot_read_next        <= 1'b0;
            snapshot_underflow_sticky <= 1'b0;
            spi_error_sticky           <= 1'b0;
            external_protocol_sticky   <= 1'b0;
        end else begin
            clear_errors_pulse  <= 1'b0;
            adc_reinit_pulse     <= 1'b0;
            snapshot_start_pulse <= 1'b0;
            fifo_rx_data_pop     <= 1'b0;
            fifo_pop_frame       <= 1'b0;
            fifo_drop_frame      <= 1'b0;
            snapshot_read_next   <= 1'b0;

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
                    default: begin
                    end
                endcase
            end
        end
    end

endmodule

`default_nettype wire

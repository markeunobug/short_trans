`timescale 1ns/1ps
`default_nettype none

`include "fsk_sync_word.vh"

// Searches for the shared 16-bit sync word, then validates and buffers one
// physical frame.  The upstream symbol synchronizer owns the 0xAAAA preamble;
// this module consumes the first bit after that preamble through bit_valid.
module fsk_frame_rx #(
    parameter [15:0] SYNC_WORD = `FSK_SYNC_WORD,
    parameter integer BIT_TIMEOUT_CYCLES = 600000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bit_valid,
    input  wire        bit_value,
    input  wire        lock_lost,

    output wire [3:0]  debug_state,
    output wire [6:0]  debug_payload_bytes,
    output wire        busy,
    output reg         sync_found,
    output reg         frame_valid,
    output wire        good_frame,
    output reg  [7:0]  frame_version_type,
    output reg  [7:0]  frame_sequence,
    output reg  [7:0]  frame_payload_length,
    output reg  [31:0] frame_timestamp,
    output reg         frame_timestamp_valid,
    output reg         frame_is_time_base,
    output reg         frame_payload_valid,
    output reg  [7:0]  frame_payload_data,
    output reg         frame_payload_last,
    output reg         header_error,
    output reg         length_error,
    output reg         crc_error,
    output reg         timeout_error
);

    localparam [3:0] ST_SEARCH_SYNC = 4'd0;
    localparam [3:0] ST_HEADER      = 4'd1;
    localparam [3:0] ST_PAYLOAD     = 4'd2;
    localparam [3:0] ST_CRC_HIGH    = 4'd3;
    localparam [3:0] ST_CRC_LOW     = 4'd4;
    localparam [3:0] ST_EMIT        = 4'd5;
    localparam [3:0] ST_TIME        = 4'd6;

    localparam [3:0] PROTOCOL_VERSION_TIME = 4'd2;
    localparam [3:0] FRAME_TYPE_DATA      = 4'd0;
    localparam [3:0] FRAME_TYPE_TIME_BASE = 4'd1;

    reg [3:0] state;
    reg [15:0] sync_shift;
    reg [4:0] sync_bit_count;
    reg [7:0] rx_byte_shift;
    reg [3:0] rx_bit_count;
    reg [2:0] header_index;
    reg       invalid_length;
    reg [7:0] crc8_state;
    reg [15:0] crc16_state;
    reg [15:0] crc_received_high;
    reg [6:0] payload_byte_index;
    reg [6:0] emit_index;
    reg [31:0] timeout_count;
    reg [7:0] payload_mem [0:63];
    reg [2:0] time_byte_index;
    reg [2:0] time_byte_count;
    reg [31:0] time_shift;
    reg time_base_valid;

    reg [15:0] next_sync;
    reg [7:0] next_byte;

    assign debug_state = state;
    assign debug_payload_bytes = payload_byte_index;
    assign busy       = (state != ST_SEARCH_SYNC);
    assign good_frame = frame_valid;

    function [4:0] hamming16;
        input [15:0] a;
        input [15:0] b;
        integer index;
        reg [15:0] difference;
        begin
            difference = a ^ b;
            hamming16 = 5'd0;
            for (index = 0; index < 16; index = index + 1)
                hamming16 = hamming16 + difference[index];
        end
    endfunction

    function [7:0] crc8_byte;
        input [7:0] crc_value;
        input [7:0] data_value;
        integer index;
        reg [7:0] value;
        begin
            value = crc_value ^ data_value;
            for (index = 0; index < 8; index = index + 1) begin
                if (value[7])
                    value = {value[6:0], 1'b0} ^ 8'h07;
                else
                    value = {value[6:0], 1'b0};
            end
            crc8_byte = value;
        end
    endfunction

    function [15:0] crc16_byte;
        input [15:0] crc_value;
        input [7:0] data_value;
        integer index;
        reg [15:0] value;
        begin
            value = crc_value ^ {data_value, 8'h00};
            for (index = 0; index < 8; index = index + 1) begin
                if (value[15])
                    value = {value[14:0], 1'b0} ^ 16'h1021;
                else
                    value = {value[14:0], 1'b0};
            end
            crc16_byte = value;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= ST_SEARCH_SYNC;
            sync_shift           <= 16'd0;
            sync_bit_count       <= 5'd0;
            rx_byte_shift        <= 8'd0;
            rx_bit_count         <= 4'd0;
            header_index          <= 3'd0;
            invalid_length        <= 1'b0;
            crc8_state            <= 8'd0;
            crc16_state           <= 16'hFFFF;
            crc_received_high     <= 16'd0;
            payload_byte_index    <= 7'd0;
            emit_index            <= 7'd0;
            timeout_count         <= 32'd0;
            sync_found            <= 1'b0;
            frame_valid           <= 1'b0;
            frame_version_type    <= 8'd0;
            frame_sequence        <= 8'd0;
            frame_payload_length  <= 8'd0;
            frame_timestamp       <= 32'd0;
            frame_timestamp_valid <= 1'b0;
            frame_is_time_base    <= 1'b0;
            time_base_valid       <= 1'b0;
            frame_payload_valid   <= 1'b0;
            frame_payload_data    <= 8'd0;
            frame_payload_last    <= 1'b0;
            header_error          <= 1'b0;
            length_error          <= 1'b0;
            crc_error             <= 1'b0;
            timeout_error         <= 1'b0;
        end else begin
            sync_found          <= 1'b0;
            frame_valid         <= 1'b0;
            frame_payload_valid <= 1'b0;
            frame_payload_last  <= 1'b0;
            header_error        <= 1'b0;
            length_error        <= 1'b0;
            crc_error           <= 1'b0;
            timeout_error       <= 1'b0;

            if (lock_lost && (state != ST_EMIT)) begin
                state             <= ST_SEARCH_SYNC;
                sync_shift        <= 16'd0;
                sync_bit_count    <= 5'd0;
                rx_bit_count      <= 4'd0;
                header_index      <= 3'd0;
                payload_byte_index <= 7'd0;
                timeout_count     <= 32'd0;
            end else if ((state != ST_SEARCH_SYNC) &&
                         !bit_valid &&
                         (timeout_count >= BIT_TIMEOUT_CYCLES - 1)) begin
                state             <= ST_SEARCH_SYNC;
                sync_shift        <= 16'd0;
                sync_bit_count    <= 5'd0;
                rx_bit_count      <= 4'd0;
                header_index      <= 3'd0;
                payload_byte_index <= 7'd0;
                timeout_count     <= 32'd0;
                timeout_error     <= 1'b1;
            end else begin
                if (state == ST_SEARCH_SYNC || state == ST_EMIT || bit_valid)
                    timeout_count <= 32'd0;
                else if (timeout_count < BIT_TIMEOUT_CYCLES)
                    timeout_count <= timeout_count + 1'b1;

                case (state)
                    ST_SEARCH_SYNC: begin
                        if (bit_valid) begin
                            next_sync = {sync_shift[14:0], bit_value};
                            if (sync_bit_count == 5'd15) begin
                                if (hamming16(next_sync, SYNC_WORD) <= 5'd1) begin
                                    state             <= ST_HEADER;
                                    sync_found        <= 1'b1;
                                    rx_byte_shift     <= 8'd0;
                                    rx_bit_count      <= 4'd0;
                                    header_index      <= 3'd0;
                                    invalid_length    <= 1'b0;
                                    crc8_state        <= 8'd0;
                                    crc16_state       <= 16'hFFFF;
                                    time_byte_index   <= 3'd0;
                                    time_byte_count   <= 3'd0;
                                    time_shift        <= 32'd0;
                                    frame_timestamp   <= 32'd0;
                                    frame_timestamp_valid <= 1'b0;
                                    frame_is_time_base <= 1'b0;
                                end else begin
                                    sync_shift <= next_sync;
                                end
                            end else begin
                                sync_shift     <= next_sync;
                                sync_bit_count <= sync_bit_count + 1'b1;
                            end
                        end
                    end

                    ST_HEADER: begin
                        if (bit_valid) begin
                            next_byte = {rx_byte_shift[6:0], bit_value};
                            if (rx_bit_count == 4'd7) begin
                                rx_byte_shift <= 8'd0;
                                rx_bit_count  <= 4'd0;
                                crc16_state   <= crc16_byte(crc16_state, next_byte);
                                case (header_index)
                                    3'd0: begin
                                        frame_version_type <= next_byte;
                                        crc8_state         <= crc8_byte(crc8_state, next_byte);
                                        header_index       <= 3'd1;
                                    end
                                    3'd1: begin
                                        frame_sequence <= next_byte;
                                        crc8_state     <= crc8_byte(crc8_state, next_byte);
                                        header_index   <= 3'd2;
                                    end
                                    3'd2: begin
                                        frame_payload_length <= next_byte;
                                        if (next_byte > 8'd64) begin
                                            invalid_length  <= 1'b1;
                                            length_error    <= 1'b1;
                                            state           <= ST_SEARCH_SYNC;
                                            sync_shift      <= 16'd0;
                                            sync_bit_count  <= 5'd0;
                                        end else begin
                                            invalid_length <= 1'b0;
                                            crc8_state     <= crc8_byte(crc8_state, next_byte);
                                            header_index   <= 3'd3;
                                        end
                                    end
                                    default: begin
                                        if (next_byte != crc8_state) begin
                                            header_error <= 1'b1;
                                            state        <= ST_SEARCH_SYNC;
                                            sync_shift   <= 16'd0;
                                            sync_bit_count <= 5'd0;
                                        end else if (invalid_length ||
                                                     (frame_payload_length > 8'd64)) begin
                                            length_error <= 1'b1;
                                            state        <= ST_SEARCH_SYNC;
                                            sync_shift   <= 16'd0;
                                            sync_bit_count <= 5'd0;
                                        end else begin
                                            if ((frame_version_type[7:4] == PROTOCOL_VERSION_TIME) &&
                                                ((frame_version_type[3:0] == FRAME_TYPE_DATA) ||
                                                 (frame_version_type[3:0] == FRAME_TYPE_TIME_BASE))) begin
                                                time_byte_count <= (frame_version_type[3:0] == FRAME_TYPE_TIME_BASE) ? 3'd4 : 3'd3;
                                                time_byte_index <= 3'd0;
                                                time_shift      <= 32'd0;
                                                state           <= ST_TIME;
                                            end else if (frame_payload_length == 8'd0) begin
                                                state <= ST_CRC_HIGH;
                                            end else begin
                                                payload_byte_index <= 7'd0;
                                                state              <= ST_PAYLOAD;
                                            end
                                        end
                                    end
                                endcase
                            end else begin
                                rx_byte_shift <= next_byte;
                                rx_bit_count  <= rx_bit_count + 1'b1;
                            end
                        end
                    end

                    ST_TIME: begin
                        if (bit_valid) begin
                            next_byte = {rx_byte_shift[6:0], bit_value};
                            if (rx_bit_count == 4'd7) begin
                                rx_byte_shift <= 8'd0;
                                rx_bit_count  <= 4'd0;
                                crc16_state   <= crc16_byte(crc16_state, next_byte);
                                time_shift    <= {time_shift[23:0], next_byte};
                                if ((time_byte_index + 1'b1) >= time_byte_count) begin
                                    frame_timestamp <= {time_shift[23:0], next_byte};
                                    frame_is_time_base <= (frame_version_type[3:0] == FRAME_TYPE_TIME_BASE);
                                    frame_timestamp_valid <= (frame_version_type[3:0] == FRAME_TYPE_TIME_BASE) ? 1'b1 : time_base_valid;
                                    if (frame_payload_length == 8'd0)
                                        state <= ST_CRC_HIGH;
                                    else begin
                                        payload_byte_index <= 7'd0;
                                        state <= ST_PAYLOAD;
                                    end
                                end else begin
                                    time_byte_index <= time_byte_index + 1'b1;
                                end
                            end else begin
                                rx_byte_shift <= next_byte;
                                rx_bit_count  <= rx_bit_count + 1'b1;
                            end
                        end
                    end

                    ST_PAYLOAD: begin
                        if (bit_valid) begin
                            next_byte = {rx_byte_shift[6:0], bit_value};
                            if (rx_bit_count == 4'd7) begin
                                rx_byte_shift <= 8'd0;
                                rx_bit_count  <= 4'd0;
                                payload_mem[payload_byte_index] <= next_byte;
                                crc16_state <= crc16_byte(crc16_state, next_byte);
                                if ((payload_byte_index + 1'b1) >= frame_payload_length) begin
                                    state <= ST_CRC_HIGH;
                                end else begin
                                    payload_byte_index <= payload_byte_index + 1'b1;
                                end
                            end else begin
                                rx_byte_shift <= next_byte;
                                rx_bit_count  <= rx_bit_count + 1'b1;
                            end
                        end
                    end

                    ST_CRC_HIGH: begin
                        if (bit_valid) begin
                            next_byte = {rx_byte_shift[6:0], bit_value};
                            if (rx_bit_count == 4'd7) begin
                                rx_byte_shift    <= 8'd0;
                                rx_bit_count     <= 4'd0;
                                crc_received_high <= {8'd0, next_byte};
                                state             <= ST_CRC_LOW;
                            end else begin
                                rx_byte_shift <= next_byte;
                                rx_bit_count  <= rx_bit_count + 1'b1;
                            end
                        end
                    end

                    ST_CRC_LOW: begin
                        if (bit_valid) begin
                            next_byte = {rx_byte_shift[6:0], bit_value};
                            if (rx_bit_count == 4'd7) begin
                                rx_byte_shift <= 8'd0;
                                rx_bit_count  <= 4'd0;
                                if ({crc_received_high[7:0], next_byte} == crc16_state) begin
                                    frame_valid <= 1'b1;
                                    if ((frame_version_type[7:4] == PROTOCOL_VERSION_TIME) &&
                                        (frame_version_type[3:0] == FRAME_TYPE_TIME_BASE))
                                        time_base_valid <= 1'b1;
                                    if (frame_payload_length == 8'd0) begin
                                        state <= ST_SEARCH_SYNC;
                                        sync_shift <= 16'd0;
                                        sync_bit_count <= 5'd0;
                                    end else begin
                                        emit_index <= 7'd0;
                                        state <= ST_EMIT;
                                    end
                                end else begin
                                    crc_error <= 1'b1;
                                    state <= ST_SEARCH_SYNC;
                                    sync_shift <= 16'd0;
                                    sync_bit_count <= 5'd0;
                                end
                            end else begin
                                rx_byte_shift <= next_byte;
                                rx_bit_count  <= rx_bit_count + 1'b1;
                            end
                        end
                    end

                    ST_EMIT: begin
                        frame_payload_valid <= 1'b1;
                        frame_payload_data  <= payload_mem[emit_index];
                        frame_payload_last  <= ((emit_index + 1'b1) >= frame_payload_length);
                        if ((emit_index + 1'b1) >= frame_payload_length) begin
                            state <= ST_SEARCH_SYNC;
                            sync_shift <= 16'd0;
                            sync_bit_count <= 5'd0;
                        end else begin
                            emit_index <= emit_index + 1'b1;
                        end
                    end

                    default: begin
                        state <= ST_SEARCH_SYNC;
                        sync_shift <= 16'd0;
                        sync_bit_count <= 5'd0;
                    end
                endcase
            end
        end
    end

endmodule

`default_nettype wire

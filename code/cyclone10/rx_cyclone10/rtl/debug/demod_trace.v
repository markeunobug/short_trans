`timescale 1ns/1ps
`default_nettype none

// Passive metric recorder. Frozen captures are seekable for block retries.
module demod_trace #(parameter integer ADDR_BITS = 9) (
    input wire clk, reset_n, sample_valid, metric_valid,
    input wire [31:0] energy0, energy1,
    input wire [32:0] noise, threshold,
    input wire signed [32:0] soft,
    input wire [7:0] confidence,
    input wire [31:0] state_flags, event_flags,
    input wire bit_valid, input wire [3:0] phase,
    input wire [1:0] timing_adjust,
    input wire [111:0] config_data,
    input wire chain_available,
    input wire [6:0] bus_address,
    input wire bus_read_strobe, bus_write_strobe,
    input wire [7:0] bus_write_data,
    output reg [7:0] bus_read_data
);
    localparam integer DEPTH = (1 << ADDR_BITS);
    (* ramstyle = "M9K" *) reg [383:0] memory [0:DEPTH-1];
    reg [383:0] ram_read;
    reg [ADDR_BITS-1:0] write_ptr, first_ptr, trigger_ptr;
    reg [15:0] count, capture_id, trigger_index;
    reg armed, triggered, ready, invalid;
    reg [7:0] trigger_mask, active_mask;
    reg [15:0] post_count, active_post, post_left;
    reg manual_pending, event_pending;
    reg [111:0] captured_config;
    reg [31:0] sample_count;
    reg [287:0] metric_record;
    reg [7:0] metric_confidence;
    reg [31:0] metric_flags;
    reg [31:0] events;
    reg [7:0] bit_count;
    reg [6:0] delay_count;
    reg [31:0] previous_state;
    reg [15:0] read_offset;
    reg [511:0] header;
    wire [15:0] relative_offset = read_offset - 16'd64;
    wire [15:0] record_index = relative_offset / 16'd48;
    wire [5:0] record_byte = relative_offset % 16'd48;
    wire [ADDR_BITS-1:0] read_ptr = first_ptr + record_index[ADDR_BITS-1:0];
    wire [ADDR_BITS-1:0] next_write_ptr = write_ptr + 1'b1;
    wire control = bus_write_strobe && bus_address == 7'h33;
    wire arm = control && bus_write_data[0];
    wire abort_capture = control && bus_write_data[2];
    wire hit = (active_mask[0] && manual_pending) ||
               (active_mask[1] && state_flags[1] && !previous_state[1]) ||
               (active_mask[2] && state_flags[2] && !previous_state[2]) ||
               (active_mask[3] && event_flags[6]) ||
               (active_mask[4] && event_flags[9]) ||
               (active_mask[5] && event_flags[8]) ||
               (active_mask[6] && event_flags[7]);
    wire [7:0] status = {4'd0, invalid, ready, triggered, armed};
    wire [31:0] combined_events = events | event_flags;
    wire [7:0] combined_bits = (bit_valid && bit_count != 8'hff) ? bit_count + 1'b1 : bit_count;
    // Noise tracking updates on metric_valid. Retain the threshold-decision
    // flags from that edge, not the updated estimator 64 clocks later.
    wire [31:0] record_flags = (state_flags & ~32'h58000) | metric_flags | combined_events |
                               ((combined_bits != 0) ? 32'h8 : 0) |
                               ((combined_bits > 1) ? 32'h20000 : 0);
    wire [383:0] completed_record = {
        captured_config[7:0], captured_config[15:8], captured_config[23:16],
        captured_config[31:24], combined_bits, {6'd0,timing_adjust},
        {4'd0,phase}, metric_confidence, record_flags, metric_record
    };

    // Synchronous block RAM read settles before the next 1 MHz SPI byte.
    always @(posedge clk) begin
        ram_read <= memory[read_ptr];
        if (armed && delay_count == 1 && !arm && !abort_capture &&
            chain_available && captured_config == config_data)
            memory[write_ptr] <= completed_record;
    end

    always @(*) begin
        header = 512'd0;
        header[31:0] = 32'h31525444;
        header[39:32] = 8'd1;
        header[47:40] = 8'h14;
        header[159:48] = captured_config;
        header[191:160] = 32'd48000;
        header[207:192] = 16'd48;
        header[223:208] = 16'd48;
        header[239:224] = count;
        header[255:240] = trigger_index;
        header[271:256] = capture_id;
        header[279:272] = active_mask;
        header[303:288] = active_post;
        header[311:304] = status;
        header[335:320] = 16'd1700;
        header[351:336] = 16'd1900;
        header[367:352] = 16'd1800;
        header[383:368] = (captured_config[7:0] == 2) ? 16'd80 : 16'd480;
        case (bus_address)
            7'h32: bus_read_data = 8'hD1;
            7'h34: bus_read_data = trigger_mask;
            7'h35: bus_read_data = post_count[7:0];
            7'h36: bus_read_data = post_count[15:8];
            7'h37: bus_read_data = status;
            7'h38: bus_read_data = ready ? count[7:0] : 0;
            7'h39: bus_read_data = ready ? count[15:8] : 0;
            7'h3a: bus_read_data = read_offset[7:0];
            7'h3b: bus_read_data = read_offset[15:8];
            7'h3c: bus_read_data = capture_id[7:0];
            7'h3d: bus_read_data = capture_id[15:8];
            7'h3e: bus_read_data = trigger_index[7:0];
            7'h3f: bus_read_data = trigger_index[15:8];
            7'h42: bus_read_data = !ready ? 0 :
                (read_offset < 64) ? header[read_offset*8 +: 8] :
                (record_index < count) ? ram_read[record_byte*8 +: 8] : 0;
            default: bus_read_data = 0;
        endcase
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            write_ptr <= 0; first_ptr <= 0; trigger_ptr <= 0;
            count <= 0; capture_id <= 0; trigger_index <= 16'hffff;
            armed <= 0; triggered <= 0; ready <= 0; invalid <= 0;
            trigger_mask <= 1; active_mask <= 1;
            post_count <= 128; active_post <= 128; post_left <= 0;
            manual_pending <= 0; event_pending <= 0; captured_config <= 0;
            sample_count <= 0; metric_record <= 0; metric_confidence <= 0; metric_flags <= 0;
            events <= 0; bit_count <= 0; delay_count <= 0;
            previous_state <= 0; read_offset <= 0;
        end else begin
            if (sample_valid) sample_count <= sample_count + 1'b1;
            previous_state <= state_flags;
            if (bus_write_strobe) begin
                case (bus_address)
                    7'h34: trigger_mask <= bus_write_data;
                    7'h35: post_count[7:0] <= bus_write_data;
                    7'h36: post_count[15:8] <= bus_write_data;
                    7'h3a: read_offset[7:0] <= bus_write_data;
                    7'h3b: read_offset[15:8] <= bus_write_data;
                    default: begin end
                endcase
            end
            if (bus_read_strobe && bus_address == 7'h42 && ready &&
                read_offset < 64 + count * 48) read_offset <= read_offset + 1'b1;
            if (control && bus_write_data[1] && armed) manual_pending <= 1;
            if (arm) begin
                armed <= chain_available && post_count < DEPTH && trigger_mask != 0 && !trigger_mask[7];
                invalid <= !chain_available || post_count >= DEPTH || trigger_mask == 0 || trigger_mask[7];
                triggered <= 0; ready <= 0; count <= 0; write_ptr <= 0; first_ptr <= 0;
                capture_id <= capture_id + 1'b1; trigger_index <= 16'hffff;
                captured_config <= config_data; active_mask <= trigger_mask; active_post <= post_count;
                manual_pending <= 0; event_pending <= 0; delay_count <= 0; events <= 0; bit_count <= 0;
                read_offset <= 0;
            end else if (armed) begin
                events <= combined_events;
                bit_count <= combined_bits;
                if (hit) event_pending <= 1;
                if (abort_capture || !chain_available || captured_config != config_data) begin
                    armed <= 0; ready <= 1; invalid <= 1; delay_count <= 0;
                    first_ptr <= (count == DEPTH) ? write_ptr : 0;
                    trigger_index <= triggered ? ((trigger_ptr - ((count == DEPTH) ? write_ptr : 0)) & (DEPTH-1)) : 16'hffff;
                end else begin
                    if (metric_valid) begin
                        metric_record <= {{31{soft[32]}}, soft, 31'd0, threshold, 31'd0, noise, energy1, energy0, sample_count};
                        metric_confidence <= confidence;
                        metric_flags <= state_flags & 32'h58000;
                        delay_count <= 64;
                    end else if (delay_count != 0) delay_count <= delay_count - 1'b1;
                    if (delay_count == 1) begin
                        write_ptr <= next_write_ptr;
                        if (count < DEPTH) count <= count + 1'b1;
                        events <= 0; bit_count <= 0;
                        if (!triggered && (event_pending || hit)) begin
                            triggered <= 1; trigger_ptr <= write_ptr; post_left <= active_post;
                            if (active_post == 0) begin
                                armed <= 0; ready <= 1;
                                first_ptr <= (count >= DEPTH-1) ? next_write_ptr : 0;
                                trigger_index <= (count >= DEPTH-1) ? DEPTH-1 : count;
                            end
                        end else if (triggered) begin
                            post_left <= post_left - 1'b1;
                            if (post_left == 1) begin
                                armed <= 0; ready <= 1;
                                first_ptr <= (count >= DEPTH-1) ? next_write_ptr : 0;
                                trigger_index <= (trigger_ptr - ((count >= DEPTH-1) ? next_write_ptr : 0)) & (DEPTH-1);
                            end
                        end
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire

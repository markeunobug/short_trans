`timescale 1ns/1ps
`default_nettype none

// Passive, fixed-32-byte V2 DATA observer. Never drives the receive chain.
// Accepted sync is an observation boundary; no claim is made for uncaptured bits.
module ber_capture #(
    parameter integer BIT_TIMEOUT_CYCLES = 600000
) (
    input wire clk, reset_n, sample_valid, chain_available,
    input wire sync_found, bit_valid, bit_value, lock_lost,
    input wire [7:0] observer_read_data,
    output wire [7:0] observer_read_offset,
    input wire [6:0] bus_address,
    input wire bus_read_strobe, bus_write_strobe,
    input wire [7:0] bus_write_data,
    output reg [7:0] bus_read_data
);
    localparam integer DEPTH = 8;
    localparam integer RAW_BYTES = 41;
    (* ramstyle = "M9K" *) reg [7:0] memory [0:511];
    reg [7:0] ram_read;
    reg [2:0] write_ptr, read_ptr;
    reg [3:0] count;
    reg enabled, capturing, publishing;
    reg [5:0] publish_index;
    reg [7:0] read_offset;
    reg [255:0] status_snapshot;
    reg [327:0] raw_data;
    reg [127:0] record_header;
    reg [15:0] bit_count;
    reg [7:0] byte_shift, capture_flags, crc8_state, crc_high;
    reg [15:0] crc16_state;
    reg version_good, length_good;
    reg [31:0] idle_cycles, sample_index, capture_sample, capture_id;
    reg [31:0] started, dropped, committed, protocol_errors, popped, missed_sync;
    assign observer_read_offset = read_offset;
    wire control = bus_write_strobe && bus_address == 7'h4a;
    wire do_pop = control && bus_write_data == 8'h08 && count != 0;
    wire do_commit = publishing && publish_index == 6'd63;
    wire [7:0] state_flags = {3'd0, chain_available, (count == DEPTH),
                              (count != 0), (capturing || publishing), enabled};
    wire [255:0] live_status = {missed_sync, popped, protocol_errors, committed,
                               dropped, started, 8'd64, 8'd8, {4'd0,count},
                               state_flags, 32'h31305342}; // BS01
    wire [7:0] assembled_byte = {byte_shift[6:0], bit_value};
    wire [5:0] byte_index = bit_count[8:3];
    reg [7:0] publish_byte;

    function [31:0] inc_sat;
        input [31:0] value;
        begin inc_sat = (&value) ? value : value + 1'b1; end
    endfunction
    function [7:0] crc8_byte;
        input [7:0] old_crc, data;
        integer j; reg [7:0] v;
        begin
            v = old_crc ^ data;
            for (j=0;j<8;j=j+1) v = v[7] ? (v << 1)^8'h07 : v << 1;
            crc8_byte = v;
        end
    endfunction
    function [15:0] crc16_byte;
        input [15:0] old_crc; input [7:0] data;
        integer j; reg [15:0] v;
        begin
            v = old_crc ^ {data,8'd0};
            for (j=0;j<8;j=j+1) v = v[15] ? (v << 1)^16'h1021 : v << 1;
            crc16_byte = v;
        end
    endfunction

    // No reader can see a slot until all 64 bytes have been published.
    always @(*) begin
        if (publish_index < 16)
            publish_byte = record_header[publish_index*8 +: 8];
        else if (publish_index < 57)
            publish_byte = raw_data[(publish_index-16)*8 +: 8];
        else publish_byte = 0;
    end
    always @(posedge clk) begin
        ram_read <= memory[{read_ptr,read_offset[5:0]}];
        if (publishing) memory[{write_ptr,publish_index}] <= publish_byte;
    end
    always @(*) begin
        case (bus_address)
            7'h49: bus_read_data = 8'hb1;
            7'h4b: bus_read_data = state_flags;
            7'h4c: bus_read_data = {4'd0,count};
            7'h4d: bus_read_data = read_offset;
            7'h4e: bus_read_data = (read_offset >= 8'h80 && read_offset < 8'ha0) ?
                status_snapshot[(read_offset-8'h80)*8 +: 8] :
                ((read_offset < 64 && count != 0) ? ram_read :
                 ((read_offset >= 8'ha0 || (read_offset >= 8'h40 && read_offset < 8'h80)) ? observer_read_data : 8'd0));
            7'h4f: bus_read_data = 8'd2;
            default: bus_read_data = 8'd0;
        endcase
    end

    task finish_capture;
        input [15:0] bits_received;
        input [7:0] flags;
        begin
            capturing <= 0;
            if (count == DEPTH && !do_pop) dropped <= inc_sat(dropped);
            else begin
                record_header <= {capture_sample, 8'd0, flags, bits_received, capture_id, 32'h31305242};
                // Explicit byte assignment avoids unsized expression width.
                record_header[95:88] <= (bits_received+16'd7) >> 3;
                publishing <= 1;
                publish_index <= 0;
            end
        end
    endtask

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            write_ptr <= 0; read_ptr <= 0; count <= 0;
            enabled <= 0; capturing <= 0; publishing <= 0; publish_index <= 0;
            read_offset <= 0; status_snapshot <= 0; raw_data <= 0;
            record_header <= 0; bit_count <= 0; byte_shift <= 0;
            capture_flags <= 0; crc8_state <= 0; crc16_state <= 16'hffff;
            crc_high <= 0; version_good <= 0; length_good <= 0;
            idle_cycles <= 0; sample_index <= 0; capture_sample <= 0;
            capture_id <= 0; started <= 0; dropped <= 0; committed <= 0;
            protocol_errors <= 0; popped <= 0; missed_sync <= 0;
        end else begin
            if (sample_valid) sample_index <= sample_index + 1'b1;
            if (enabled && chain_available && sync_found && (capturing || publishing))
                missed_sync <= inc_sat(missed_sync);
            case ({do_commit,do_pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: ;
            endcase
            if (do_pop) begin
                read_ptr <= read_ptr + 1'b1; popped <= inc_sat(popped);
                read_offset <= 0;
            end
            if (publishing) begin
                if (do_commit) begin
                    publishing <= 0; write_ptr <= write_ptr + 1'b1;
                    committed <= inc_sat(committed);
                end else publish_index <= publish_index + 1'b1;
            end
            if (bus_write_strobe && bus_address == 7'h4d) begin
                read_offset <= bus_write_data;
                if (bus_write_data == 8'h80) status_snapshot <= live_status;
            end
            if (bus_read_strobe && bus_address == 7'h4e) begin
                if ((read_offset < 63 && count != 0) ||
                    (read_offset >= 8'h40 && read_offset < 8'h7f) ||
                    (read_offset >= 8'ha0 && read_offset < 8'hff) ||
                    (read_offset >= 8'h80 && read_offset < 8'h9f))
                    read_offset <= read_offset + 1'b1;
                else if (!((read_offset == 63 && count != 0) || read_offset == 8'h9f ||
                             read_offset == 8'h7f || read_offset == 8'hff))
                    protocol_errors <= inc_sat(protocol_errors);
            end

            if (control) begin
                case (bus_write_data)
                    8'h01: begin
                        if (!enabled && !capturing && !publishing && count == 0 && chain_available) begin
                            enabled <= 1; started <= 0; dropped <= 0;
                            committed <= 0; protocol_errors <= 0; popped <= 0;
                            missed_sync <= 0;
                            read_offset <= 0;
                        end else protocol_errors <= inc_sat(protocol_errors);
                    end
                    8'h02: begin
                        enabled <= 0;
                        if (capturing) finish_capture(bit_count, capture_flags | 8'h08);
                    end
                    8'h04: begin
                        if (!enabled && !capturing && !publishing) begin
                            count <= 0; write_ptr <= 0; read_ptr <= 0;
                            started <= 0; dropped <= 0; committed <= 0;
                            protocol_errors <= 0; popped <= 0; read_offset <= 0;
                            missed_sync <= 0;
                        end else protocol_errors <= inc_sat(protocol_errors);
                    end
                    8'h08: if (!do_pop) protocol_errors <= inc_sat(protocol_errors);
                    default: if (!(bus_write_data == 8'h10 || bus_write_data == 8'h20 ||
                                  (bus_write_data >= 8'h80 && bus_write_data <= 8'h8f)))
                        protocol_errors <= inc_sat(protocol_errors);
                endcase
            end

            // STOP wins over a simultaneous sample. Other controls never gate RX.
            if (!(control && bus_write_data == 8'h02)) begin
                if (capturing) begin
                    if (lock_lost || !chain_available)
                        finish_capture(bit_count, capture_flags | 8'h04);
                    else if (bit_valid) begin
                        idle_cycles <= 0;
                        bit_count <= bit_count + 1'b1;
                        byte_shift <= assembled_byte;
                        // Partial last bytes are zero-padded on the right.
                        raw_data[byte_index*8 +: 8] <= assembled_byte << (7-bit_count[2:0]);
                        if (bit_count[2:0] == 7) begin
                            byte_shift <= 0;
                            if (byte_index < 3) crc8_state <= crc8_byte(crc8_state,assembled_byte);
                            if (byte_index == 0) version_good <= assembled_byte == 8'h20;
                            if (byte_index == 2) length_good <= assembled_byte == 8'd32;
                            if (byte_index == 3 && assembled_byte == crc8_state)
                                capture_flags <= capture_flags | 8'h10;
                            if (byte_index < 39) crc16_state <= crc16_byte(crc16_state,assembled_byte);
                            if (byte_index == 39) crc_high <= assembled_byte;
                            if (byte_index == 40)
                                finish_capture(bit_count+16'd1, capture_flags | 8'h01 |
                                    (({crc_high,assembled_byte} == crc16_state) ? 8'h20 : 8'd0) |
                                    ((version_good && length_good) ? 8'h40 : 8'd0));
                        end
                    end else if (idle_cycles >= BIT_TIMEOUT_CYCLES-1)
                        finish_capture(bit_count, capture_flags | 8'h02);
                    else idle_cycles <= idle_cycles + 1'b1;
                end else if (enabled && !publishing && chain_available && sync_found && !lock_lost) begin
                    capturing <= 1; bit_count <= 0; byte_shift <= 0;
                    raw_data <= 0; capture_flags <= 0; crc8_state <= 0;
                    crc16_state <= 16'hffff; crc_high <= 0;
                    version_good <= 0; length_good <= 0; idle_cycles <= 0;
                    capture_id <= started + 1'b1; started <= inc_sat(started);
                    capture_sample <= sample_index;
                    // Registered parser sync can coincide with Header bit 7.
                    if (bit_valid) begin
                        bit_count <= 1;
                        byte_shift <= {7'd0,bit_value};
                        raw_data[7:0] <= {bit_value,7'd0};
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire

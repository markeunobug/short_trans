`timescale 1ns/1ps
`default_nettype none
// Passive per-transmit-window evidence; no output returns to the RX chain.
// Shares BER's indirect port without taking any normal FIFO/trace controls.
module ber_observer (
    input wire clk, reset_n, sample_valid, metric_valid, bit_valid,
    input wire chain_available, carrier, locked, parser_busy,
    input wire preamble, sync_found, header_error, length_error, crc_error,
    input wire good_frame, lock_lost, frame_timeout, search_timeout,
    input wire i2s_error, cdc_error, clipped, energy_above,
    input wire [3:0] parser_state,
    input wire [1:0] symbol_state,
    input wire [6:0] payload_bytes,
    input wire hard_bit,
    input wire [32:0] energy, threshold,
    input wire [7:0] confidence,
    input wire [3:0] phase,
    input wire signed [1:0] timing_adjust,
    input wire [6:0] bus_address,
    input wire bus_read_strobe, bus_write_strobe,
    input wire [7:0] bus_write_data, read_offset,
    output reg [7:0] bus_read_data
);
    reg active, frozen, frozen_chain;
    reg [31:0] window_id, cycles, fault_seen;
    reg [31:0] counters [0:16];
    reg [32:0] max_energy;
    reg [5:0] event_count;
    reg [4:0] event_write;
    reg [3:0] page;
    reg previous_carrier, previous_locked, previous_chain, previous_fault;
    reg previous_clipped;
    reg [3:0] previous_parser_state;
    (* ramstyle = "M9K" *) reg [255:0] memory [0:31];
    reg [255:0] ram_read;
    wire control = bus_write_strobe && bus_address == 7'h4a;
    wire arm = control && bus_write_data == 8'h10 && !active && chain_available;
    wire stop = control && (bus_write_data == 8'h20 || bus_write_data == 8'h02) && active;
    wire external_fault = i2s_error || cdc_error;
    wire [31:0] event_mask = {
        10'd0, (parser_state != previous_parser_state),
        (parser_state == 3 && previous_parser_state != 3),
        (parser_state == 2 && previous_parser_state != 2),
        (previous_parser_state == 1 && (parser_state == 6 || parser_state == 2 || parser_state == 3)),
        stop, arm,
        (sample_valid && clipped && !previous_clipped),
        (external_fault && !previous_fault),
        (!chain_available && previous_chain), search_timeout, frame_timeout,
        lock_lost, good_frame, crc_error, length_error, header_error,
        sync_found, preamble, (!locked && previous_locked),
        (locked && !previous_locked), (!carrier && previous_carrier),
        (carrier && !previous_carrier)};
    wire [31:0] faults_now = {21'd0, search_timeout, frame_timeout, crc_error,
        length_error, header_error, (lock_lost && parser_busy),
        (sample_valid && clipped), external_fault, !chain_available,
        (lock_lost && !locked), lock_lost};
    wire [7:0] state = {cdc_error, i2s_error, energy_above,
                        external_fault, chain_available, parser_busy, locked, carrier};
    wire [255:0] event_record = {
        state, {6'd0,timing_adjust}, {4'd0,phase}, confidence,
        {7'd0,hard_bit}, {1'b0,payload_bytes}, {6'd0,symbol_state}, {4'd0,parser_state},
        31'd0, threshold, 31'd0, energy, event_mask, (arm ? 32'd0 : cycles)};
    wire [7:0] flags = {4'd0, (counters[16] != 0), (active ? chain_available : frozen_chain), frozen, active};
    reg [767:0] summary;
    integer i,k;
    function [31:0] inc_sat;
        input [31:0] v;
        begin inc_sat = (&v) ? v : v + 1'b1; end
    endfunction
    // RAM read is pipelined; seek or SPI inter-byte time supplies settling.
    always @(posedge clk) begin
        ram_read <= memory[{page,read_offset[5]}];
        if (arm || (active && ((event_mask != 0) || stop)))
            memory[arm ? 5'd0 : event_write] <= event_record;
    end
    always @(*) begin
        summary = 0;
        summary[31:0] = 32'h31304f42; // BO01
        summary[63:32] = window_id;
        summary[71:64] = flags;
        summary[79:72] = {2'd0,event_count};
        summary[87:80] = {3'd0,event_write};
        summary[95:88] = 8'd32;
        summary[127:96] = cycles;
        for (k=0; k<17; k=k+1)
            summary[(16+k*4)*8 +: 32] = counters[k];
        summary[735:672] = {31'd0,max_energy};
        summary[767:736] = fault_seen;
        bus_read_data = 0;
        if (bus_address == 7'h4e) begin
            if (read_offset >= 8'ha0)
                bus_read_data = summary[(read_offset-8'ha0)*8 +: 8];
            else if (read_offset >= 8'h40 && read_offset < 8'h80)
                bus_read_data = ({page,read_offset[5]} < event_count || event_count == 32) ?
                    ram_read[read_offset[4:0]*8 +: 8] : 8'd0;
        end
    end
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            active<=0; frozen<=0; frozen_chain<=0; window_id<=0; cycles<=0; max_energy<=0;
            fault_seen<=0;event_count<=0;event_write<=0;page<=0;
            previous_carrier<=0;previous_locked<=0;previous_chain<=0;
            previous_fault<=0;previous_clipped<=0;previous_parser_state<=0;
            for(i=0;i<17;i=i+1)counters[i]<=0;
        end else begin
            if (control && bus_write_data >= 8'h80 && bus_write_data <= 8'h8f)
                page <= bus_write_data[3:0];
            if (arm) begin
                active<=1;frozen<=0;window_id<=window_id+1'b1;
                cycles<=0;max_energy<=0;fault_seen<=0;
                event_count<=1;event_write<=1;page<=0;
                previous_carrier<=0;previous_locked<=0;previous_chain<=1;
                previous_fault<=0;previous_clipped<=0;previous_parser_state<=parser_state;
                for(i=0;i<17;i=i+1)counters[i]<=0;
            end else if (active) begin
                cycles<=inc_sat(cycles);
                previous_parser_state<=parser_state;
                previous_carrier<=carrier;previous_locked<=locked;
                previous_chain<=chain_available;previous_fault<=external_fault;
                if(sample_valid)previous_clipped<=clipped;
                fault_seen<=fault_seen | faults_now;
                if(sample_valid)counters[0]<=inc_sat(counters[0]);
                if(metric_valid)counters[1]<=inc_sat(counters[1]);
                if(metric_valid && energy_above)counters[2]<=inc_sat(counters[2]);
                if(carrier && !previous_carrier)counters[3]<=inc_sat(counters[3]);
                if(preamble)counters[4]<=inc_sat(counters[4]);
                if(locked && !previous_locked)counters[5]<=inc_sat(counters[5]);
                if(sync_found)counters[6]<=inc_sat(counters[6]);
                if(header_error)counters[7]<=inc_sat(counters[7]);
                if(length_error)counters[8]<=inc_sat(counters[8]);
                if(crc_error)counters[9]<=inc_sat(counters[9]);
                if(good_frame)counters[10]<=inc_sat(counters[10]);
                if(lock_lost && parser_busy)counters[11]<=inc_sat(counters[11]);
                if(frame_timeout)counters[12]<=inc_sat(counters[12]);
                if(search_timeout)counters[13]<=inc_sat(counters[13]);
                if(!chain_available)counters[14]<=inc_sat(counters[14]);
                if(bit_valid)counters[15]<=inc_sat(counters[15]);
                if(metric_valid && energy>max_energy)max_energy<=energy;
                if(event_mask != 0)begin
                    event_write<=event_write+1'b1;
                    if(event_count<32)event_count<=event_count+1'b1;
                    else counters[16]<=inc_sat(counters[16]);
                end
                if(stop)begin active<=0;frozen<=1;frozen_chain<=chain_available;end
            end
        end
    end
endmodule
`default_nettype wire

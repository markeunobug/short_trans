`timescale 1ns/1ps
// Uses a waveform produced by STM32 fsk_tx.c under its HAL mock, not a DSP model.
module ook_tx_fixture_chain_tb;
 reg clk=0, reset_n=0, sample_valid=0; reg signed [19:0] sample_data=0;
 reg [4095:0] fixture_file;
 reg [11:0] dac_mem [0:139199]; integer i, errors=0, frames=0, payload_count=0, parser_errors=0;
 reg [7:0] payload [0:3]; reg [7:0] frame_vt [0:1], frame_seq [0:1], frame_len [0:1]; reg frame_time_valid [0:1], frame_is_base [0:1]; reg [31:0] frame_ts [0:1];
 wire metric_valid; wire [31:0] energy; wire energy_ready; wire hard_bit,bit_valid,bit_value,locked,preamble,lock_lost; wire [3:0] phase;
 wire busy,sync_found,frame_valid,good_frame; wire [7:0] vt,seq,len; wire [31:0] ts; wire tsv,tb,payload_valid,last,header_error,length_error,crc_error,timeout_error;
 always #5 clk=~clk;
 ook_iq_correlator demod(.clk(clk),.reset_n(reset_n),.sample_valid(sample_valid),.sample_data(sample_data),.metric_valid(metric_valid),.energy(energy),.energy_ready(energy_ready));
 ook_symbol_sync sync(.clk(clk),.reset_n(reset_n),.metric_valid(metric_valid),.energy(energy),.low_threshold(32'd400),.high_threshold(32'd600),.parser_busy(busy),.hard_bit(hard_bit),.bit_valid(bit_valid),.bit_value(bit_value),.symbol_locked(locked),.candidate_active(),.preamble_detected(preamble),.lock_lost(lock_lost),.selected_phase(phase));
 fsk_frame_rx parser(.clk(clk),.rst_n(reset_n),.bit_valid(bit_valid),.bit_value(bit_value),.lock_lost(lock_lost),.busy(busy),.sync_found(sync_found),.frame_valid(frame_valid),.good_frame(good_frame),.frame_version_type(vt),.frame_sequence(seq),.frame_payload_length(len),.frame_timestamp(ts),.frame_timestamp_valid(tsv),.frame_is_time_base(tb),.frame_payload_valid(payload_valid),.frame_payload_data(),.frame_payload_last(last),.header_error(header_error),.length_error(length_error),.crc_error(crc_error),.timeout_error(timeout_error));
 always @(posedge clk) begin
  if(crc_error || header_error || length_error || timeout_error) parser_errors=parser_errors+1;
  if(frame_valid) begin frame_vt[frames]=vt;frame_seq[frames]=seq;frame_len[frames]=len;frame_time_valid[frames]=tsv;frame_is_base[frames]=tb;frame_ts[frames]=ts;frames=frames+1;end
  if(payload_valid && payload_count<4) payload[payload_count]=parser.frame_payload_data;
  if(payload_valid) payload_count=payload_count+1;
 end
 initial begin
  if(!$value$plusargs("FIXTURE=%s",fixture_file)) begin $display("FAIL missing FIXTURE path");$finish;end
  $readmemh(fixture_file,dac_mem);
  reset_n=1; #1 reset_n=0; repeat(5) @(posedge clk); reset_n=1;
  for(i=0;i<139200;i=i+1) begin @(posedge clk); sample_data <= ($signed({1'b0,dac_mem[i]}) - 20'sd2048) <<< 6; sample_valid<=1; end
  @(posedge clk);sample_valid<=0;repeat(1000) @(posedge clk);
  if(frames!=2) begin $display("FAIL frames=%0d crc=%0d header=%0d timeout=%0d energy=%0d",frames,crc_error,header_error,timeout_error,energy);errors=errors+1;end
  if(frame_vt[0]!=8'h21 || frame_seq[0]!=0 || frame_len[0]!=0 || !frame_time_valid[0] || !frame_is_base[0] || frame_ts[0] != 32'd1790121600) begin $display("FAIL TIME_BASE metadata vt=%h seq=%0d len=%0d tv=%0d base=%0d ts=%0d",frame_vt[0],frame_seq[0],frame_len[0],frame_time_valid[0],frame_is_base[0],frame_ts[0]);errors=errors+1;end
  if(frame_vt[1]!=8'h20 || frame_seq[1]!=0 || frame_len[1]!=4 || !frame_time_valid[1] || frame_is_base[1] || frame_ts[1] != 0) begin $display("FAIL DATA metadata");errors=errors+1;end
  if(parser_errors!=0) begin $display("FAIL unexpected parser error");errors=errors+1;end
  if(payload_count!=4 || payload[0]!=8'h01 || payload[1]!=8'h23 || payload[2]!=8'h45 || payload[3]!=8'h67) begin $display("FAIL DATA payload count=%0d",payload_count);errors=errors+1;end
  if(errors==0) $display("PASS: ook_tx_fixture_chain_tb"); else $display("FAIL: ook_tx_fixture_chain_tb errors=%0d",errors);
  $finish;
 end
endmodule

`timescale 1ns/1ps
module ook_chain_tb;
 reg clk=0, reset_n=0, sample_valid=0; reg signed [19:0] sample_data=0;
 wire metric_valid; wire [31:0] energy; wire energy_ready;
 wire hard_bit, bit_valid, bit_value, locked, preamble, lock_lost; wire [3:0] phase;
 wire busy, sync_found, frame_valid, good_frame; wire [7:0] vt,seq,len; wire [31:0] ts; wire tsv,tb;
 wire payload_valid,last,header_error,length_error,crc_error,timeout_error;
 reg signed [19:0] mem [0:71999]; integer i; integer errors=0; integer frame_count=0;
 always #5 clk=~clk;
 ook_iq_correlator demod(.clk(clk),.reset_n(reset_n),.sample_valid(sample_valid),.sample_data(sample_data),.metric_valid(metric_valid),.energy(energy),.energy_ready(energy_ready));
 ook_symbol_sync sync(.clk(clk),.reset_n(reset_n),.metric_valid(metric_valid),.energy(energy),.low_threshold(32'd400),.high_threshold(32'd600),.parser_busy(busy),.hard_bit(hard_bit),.bit_valid(bit_valid),.bit_value(bit_value),.symbol_locked(locked),.preamble_detected(preamble),.lock_lost(lock_lost),.selected_phase(phase));
 fsk_frame_rx parser(.clk(clk),.rst_n(reset_n),.bit_valid(bit_valid),.bit_value(bit_value),.lock_lost(lock_lost),.busy(busy),.sync_found(sync_found),.frame_valid(frame_valid),.good_frame(good_frame),.frame_version_type(vt),.frame_sequence(seq),.frame_payload_length(len),.frame_timestamp(ts),.frame_timestamp_valid(tsv),.frame_is_time_base(tb),.frame_payload_valid(payload_valid),.frame_payload_data(),.frame_payload_last(last),.header_error(header_error),.length_error(length_error),.crc_error(crc_error),.timeout_error(timeout_error));
 always @(posedge clk) begin if(frame_valid) frame_count=frame_count+1;  end
 initial begin
  $readmemh("tb/ook_frame.samples.mem",mem);
  reset_n=1; #1 reset_n=0; repeat(5) @(posedge clk); reset_n=1;
  $display("RESET phase=%h ptr=%h acc=%h",demod.phase,demod.wr_ptr,demod.i_acc);
  for(i=0;i<62400;i=i+1) begin @(posedge clk); sample_data<=mem[i]; sample_valid<=1; end
  @(posedge clk); sample_valid<=0; repeat(200) @(posedge clk);
  if(frame_count != 1) begin $display("FAIL frame_count=%0d sync=%0d crc=%0d header=%0d timeout=%0d energy=%0d",frame_count,sync_found,crc_error,header_error,timeout_error,energy); errors=errors+1; end
  if(vt != 8'h10 || seq != 8'h2a || len != 0) begin $display("FAIL metadata vt=%h seq=%h len=%0d",vt,seq,len);errors=errors+1;end
  if(errors==0) $display("PASS: ook_chain_tb"); else $display("FAIL: ook_chain_tb errors=%0d",errors);
  $finish;
 end
endmodule

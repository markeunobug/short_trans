`timescale 1ns/1ps
module ook_validation_vectors_tb;
 reg clk=0,reset_n=0,sample_valid=0; reg signed [19:0] sample_data=0;
 reg signed [19:0] mem[0:310000]; integer count,i,prefix,expect_frames,expect_seq0,expect_len0,expect_fill,expect_crc,expect_bytes,errors=0,frames=0,crc_count=0;
 reg [63:0] expected_meta[0:7]; reg [7:0] expected_payload[0:511]; reg [4095:0] meta_file,payload_file; reg [4095:0] file;
 reg [7:0] seqs[0:1], lens[0:1], vts[0:1]; reg tv[0:1],base[0:1]; reg [7:0] payload[0:63]; integer payload_count=0;
 wire mv; wire [31:0] en; wire er,hb,bv,bval,locked,pre,loss; wire [3:0] phase; wire busy,sf,fv,gf;wire[7:0]vt,seq,len,pd;wire[31:0]ts;wire tsv,tbase,pv,last,he,le,ce,to;
 always #5 clk=~clk;
 ook_iq_correlator d(.clk(clk),.reset_n(reset_n),.sample_valid(sample_valid),.sample_data(sample_data),.metric_valid(mv),.energy(en),.energy_ready(er));
 ook_symbol_sync s(.clk(clk),.reset_n(reset_n),.metric_valid(mv),.energy(en),.low_threshold(400),.high_threshold(600),.parser_busy(busy),.hard_bit(hb),.bit_valid(bv),.bit_value(bval),.symbol_locked(locked),.candidate_active(),.preamble_detected(pre),.lock_lost(loss),.selected_phase(phase));
 fsk_frame_rx p(.clk(clk),.rst_n(reset_n),.bit_valid(bv),.bit_value(bval),.lock_lost(loss),.busy(busy),.sync_found(sf),.frame_valid(fv),.good_frame(gf),.frame_version_type(vt),.frame_sequence(seq),.frame_payload_length(len),.frame_timestamp(ts),.frame_timestamp_valid(tsv),.frame_is_time_base(tbase),.frame_payload_valid(pv),.frame_payload_data(pd),.frame_payload_last(last),.header_error(he),.length_error(le),.crc_error(ce),.timeout_error(to));
 always @(posedge clk) begin
  if(he || le || to) begin $display("FAIL unexpected parser error"); errors=errors+1; end
  if(fv) begin
   if(frames>=expect_frames || {6'b0,vt,seq,len,ts,tsv,tbase} !== expected_meta[frames]) begin $display("FAIL metadata frame=%0d actual=%h expected=%h",frames,{6'b0,vt,seq,len,ts,tsv,tbase},expected_meta[frames]);errors=errors+1;end
   vts[frames]=vt;seqs[frames]=seq;lens[frames]=len;tv[frames]=tsv;base[frames]=tbase;frames=frames+1;end
  if(pv && payload_count<64) payload[payload_count]=pd;
  if(pv) begin
   if(payload_count>=expect_bytes || pd !== expected_payload[payload_count]) begin $display("FAIL payload index=%0d",payload_count);errors=errors+1;end
   payload_count=payload_count+1;
  end
  if(ce) crc_count=crc_count+1;
 end
 initial begin
  if(!$value$plusargs("META=%s",meta_file)||!$value$plusargs("PAYLOAD=%s",payload_file)||!$value$plusargs("CRC=%d",expect_crc)||!$value$plusargs("BYTES=%d",expect_bytes)) begin $display("FAIL scoreboard args");$finish;end
  prefix=0; expect_len0=-1; expect_fill=-1; if($value$plusargs("PREFIX=%d",prefix)) begin end if(!$value$plusargs("FILE=%s",file)||!$value$plusargs("COUNT=%d",count)||!$value$plusargs("EXPECT_FRAMES=%d",expect_frames)||!$value$plusargs("EXPECT_SEQ0=%d",expect_seq0)) begin $display("FAIL args");$finish;end
  $readmemh(meta_file,expected_meta,0,expect_frames-1);
  if(expect_bytes>0) $readmemh(payload_file,expected_payload,0,expect_bytes-1);
  $readmemh(file,mem,0,count-1); reset_n=1;#1 reset_n=0;repeat(5)@(posedge clk);reset_n=1;
  for(i=0;i<prefix;i=i+1)begin @(posedge clk);sample_data<=0;sample_valid<=1;end
  for(i=0;i<count;i=i+1)begin @(posedge clk);sample_data<=mem[i];sample_valid<=1;end
  @(posedge clk);sample_valid<=0;repeat(1000)@(posedge clk);
  if(crc_count!=expect_crc || payload_count!=expect_bytes) begin $display("FAIL counts crc=%0d bytes=%0d",crc_count,payload_count);errors=errors+1;end
  if(frames!=expect_frames)begin $display("FAIL frames=%0d expected=%0d crc=%0d",frames,expect_frames,crc_count);errors=errors+1;end
  if(frames>0 && expect_len0>=0 && lens[0] != expect_len0[7:0]) begin $display("FAIL len0=%0d expected=%0d",lens[0],expect_len0);errors=errors+1;end
  if(expect_fill>=0) for(i=0;i<expect_len0;i=i+1) if(payload[i] != expect_fill[7:0]) begin $display("FAIL payload[%0d]",i);errors=errors+1;end
  if(frames>0 && seqs[0] != expect_seq0[7:0])begin $display("FAIL seq0=%0d expected=%0d",seqs[0],expect_seq0);errors=errors+1;end
  if(errors==0)$display("PASS: ook_validation_vectors_tb frames=%0d seq0=%0d crc=%0d",frames,seqs[0],crc_count);else $display("FAIL: ook_validation_vectors_tb errors=%0d",errors);
  $finish;
 end
endmodule

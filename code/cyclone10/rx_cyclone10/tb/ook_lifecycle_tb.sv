`timescale 1ns/1ps
module ook_lifecycle_tb;
  reg clk=0, reset_n=0, metric_valid=0;
  reg [31:0] energy=0;
  reg parser_busy=0;
  wire hard_bit,bit_valid,bit_value,locked,candidate,preamble,lock_lost;
  wire [3:0] phase;
  integer lost_count=0;
  integer replay_count=0;
  reg [15:0] replay_word=0;
  always #5 clk=~clk;
  ook_symbol_sync dut(.clk(clk),.reset_n(reset_n),.metric_valid(metric_valid),
    .energy(energy),.low_threshold(32'd400),.high_threshold(32'd600),
    .parser_busy(parser_busy),.hard_bit(hard_bit),.bit_valid(bit_valid),.bit_value(bit_value),
    .symbol_locked(locked),.candidate_active(candidate),.preamble_detected(preamble),
    .lock_lost(lock_lost),.selected_phase(phase));
  always @(posedge clk) begin
    if(lock_lost) lost_count=lost_count+1;
    if(bit_valid) begin replay_count=replay_count+1;replay_word={replay_word[14:0],bit_value};end
  end
  task reset_chain;
    begin
      @(negedge clk);reset_n=0;metric_valid=0;parser_busy=0;
      repeat(3) @(negedge clk);
      reset_n=1;lost_count=0;replay_count=0;replay_word=0;
    end
  endtask
  task metric;
    input [31:0] value;
    begin
      @(negedge clk);energy=value;metric_valid=1;
      @(negedge clk);metric_valid=0;
      repeat(47) @(negedge clk);
    end
  endtask
  task bit_symbol;
    input value;
    integer j;
    begin for(j=0;j<10;j=j+1) metric(value ? 1000 : 0);end
  endtask
  task word16;
    input [15:0] value;
    integer j;
    begin for(j=15;j>=0;j=j-1) bit_symbol(value[j]);end
  endtask
  // Seed only history state to exercise disjoint viable intervals and wraparound.
  task check_phase_window;
    input [9:0] mask;
    input integer origin;
    input integer expected;
    integer n, index;
    begin
      reset_chain;
      dut.metric_phase=origin;
      for(n=0;n<10;n=n+1) begin
        index=(origin+n)%10;
        dut.history_count[index]=31;
        dut.history[index]=mask[n] ? (32'hAAAA06B7 >> 1) : 0;
      end
      for(n=0;n<10;n=n+1) metric(1000);
      if(phase!==expected[3:0]) $fatal(1,"phase midpoint mask=%b origin=%0d actual=%0d expected=%0d",mask,origin,phase,expected);
    end
  endtask
  initial begin
    check_phase_window(10'b1111100111,0,7);
    check_phase_window(10'b1111100111,8,5);
    check_phase_window(10'b1111111111,9,3);
    check_phase_window(10'b0000000001,4,4);
    reset_chain;
    metric(599);if(hard_bit!==0)$fatal(1,"below high changed zero");
    metric(600);if(hard_bit!==1)$fatal(1,"high equality not one");
    metric(500);if(hard_bit!==1)$fatal(1,"hysteresis one not retained");
    metric(400);if(hard_bit!==0)$fatal(1,"low equality not zero");
    metric(500);if(hard_bit!==0)$fatal(1,"hysteresis zero not retained");
    metric(32'hffffffff);if(hard_bit!==1)$fatal(1,"uint32 max mishandled");
    reset_chain;
    word16(16'haaaa);
    if(candidate!==1)$fatal(1,"preamble did not create candidate");
    repeat(600010) @(negedge clk);
    if(candidate!==0 || locked!==0)$fatal(1,"candidate stuck after metric gap");
    if(lost_count!==0)$fatal(1,"search timeout generated frame loss");
    reset_chain;
    word16(16'haaaa);word16(16'h06b7);
    if(locked!==1)$fatal(1,"sync did not acquire");
    // Real parser becomes busy upon receiving the fast replayed sync.
    parser_busy=1;
    repeat(40) @(negedge clk);
    if(replay_count!=16 || replay_word!=16'h06b7)
      $fatal(1,"SYNC fast replay count=%0d word=%h",replay_count,replay_word);
    // A long valid run of zeros is legal data, not a metric dropout.
    repeat(64) bit_symbol(0);
    if(locked!==1 || lost_count!=0)$fatal(1,"long zero data unlocked");
    repeat(600010) @(negedge clk);
    if(locked!==0 || lost_count!=1)$fatal(1,"locked metric dropout not released once");
    repeat(600010) @(negedge clk);
    if(lost_count!=1)$fatal(1,"repeated lock-loss event");
    $display("PASS: ook_lifecycle_tb threshold boundaries, candidate gap, fast SYNC, long zero and dropout");
    $finish;
  end
  initial begin #100000000;$fatal(1,"test watchdog");end
endmodule

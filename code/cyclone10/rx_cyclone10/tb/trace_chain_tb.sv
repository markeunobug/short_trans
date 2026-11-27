`timescale 1ns/1ps
// Production demodulators and symbol synchronizers feed the passive observer.
// Accelerated but valid spacing leaves 80 clocks between ADC samples.
module trace_chain_tb;
    reg clk=0,reset_n=0,sv=0;
    always #5 clk=~clk;
    reg signed [19:0] sample=0;
    reg [6:0] addr=0;reg wr=0;reg [7:0] data=0;
    reg [111:0] cfg={32'd600,32'd400,16'd200,8'd32,8'd64,8'd12,8'd2};
    wire ov,ready,hb,bv,bit_value,locked,pre,lost,candidate;
    wire [31:0] oe;wire [3:0] phase;
    wire fv,fh,fc_ok,above,nr,nu,fc;
    wire signed [32:0] fs;
    wire [32:0] total,noise,threshold,se;
    wire [31:0] e0,e1;wire [7:0] confidence,sc;
    wire flock,fpre,flost,ftime,fbv,fb;wire [3:0] fp;wire [1:0] fa;
    reg signed [19:0] samples[0:71999];
    integer i,ocount=0,fcount=0,replays=0;
    reg [31:0] expected_oe,expected_e0,expected_e1;
    reg [32:0] expected_noise,expected_threshold;
    reg [31:0] expected_flags;
    wire [31:0] flags={15'd0,(oe>=600),ready,10'd0,bit_value,1'b0,locked,(ready&&hb),hb};
    wire [31:0] events={25'd0,lost,pre,5'd0};
    wire [31:0] fflags={13'd0,fc_ok,1'b0,above,nr,10'd0,fb,1'b0,flock,fc,fh};
    wire [31:0] fevents={18'd0,ftime,6'd0,flost,fpre,5'd0};
    ook_iq_correlator ook(.clk(clk),.reset_n(reset_n),.sample_valid(sv),.sample_data(sample),.metric_valid(ov),.energy(oe),.energy_ready(ready));
    ook_symbol_sync os(.clk(clk),.reset_n(reset_n),.metric_valid(ov),.energy(oe),.low_threshold(32'd400),.high_threshold(32'd600),
        .parser_busy(1'b0),.hard_bit(hb),.bit_valid(bv),.bit_value(bit_value),.symbol_locked(locked),.candidate_active(candidate),
        .preamble_detected(pre),.lock_lost(lost),.selected_phase(phase));
    fsk_demod_core fsk(.clk(clk),.reset_n(reset_n),.sample_valid(sv),.sample_data(sample),.noise_track_enable(!fc),.carrier_active(fc),
        .noise_multiplier_q4_4(8'd64),.noise_offset(16'd200),.confidence_threshold(8'd32),.metric_valid(fv),.hard_bit(fh),
        .soft_metric(fs),.total_energy(total),.confidence(confidence),.confidence_ok(fc_ok),.energy_f0(e0),.energy_f1(e1),
        .noise_energy(noise),.carrier_threshold(threshold),.energy_above_threshold(above),.noise_ready(nr),.noise_update(nu));
    fsk_symbol_sync #(.SYNC_TIMEOUT_SYMBOLS(0)) fss(.clk(clk),.reset_n(reset_n),.metric_valid(fv),.hard_bit(fh),.total_energy(total),.confidence(confidence),
        .frame_sync_found(1'b0),.frame_end(1'b0),
        .carrier_present(above),.preamble_confidence_threshold(8'd32),.carrier_active(fc),.sync_locked(flock),.preamble_detected(fpre),
        .lock_lost(flost),.search_timeout(ftime),.bit_valid(fbv),.bit_value(fb),.symbol_energy(se),.symbol_confidence(sc),.selected_phase(fp),.timing_adjust(fa));
    demod_trace ot(.clk(clk),.reset_n(reset_n),.sample_valid(sv),.metric_valid(ov),.energy0(oe),.energy1(32'd0),.noise(33'd0),
        .threshold(33'd600),.soft($signed({1'b0,oe})-33'sd500),.confidence(8'd0),.state_flags(flags),.event_flags(events),.bit_valid(bv),
        .phase(phase),.timing_adjust(2'd0),.config_data(cfg),.chain_available(reset_n),.bus_address(addr),.bus_read_strobe(1'b0),
        .bus_write_strobe(wr),.bus_write_data(data),.bus_read_data());
    demod_trace ft(.clk(clk),.reset_n(reset_n),.sample_valid(sv),.metric_valid(fv),.energy0(e0),.energy1(e1),.noise(noise),
        .threshold(threshold),.soft(fs),.confidence(confidence),.state_flags(fflags),.event_flags(fevents),.bit_valid(fbv),
        .phase(fp),.timing_adjust(fa),.config_data({cfg[111:8],8'd1}),.chain_available(reset_n),.bus_address(addr),.bus_read_strobe(1'b0),
        .bus_write_strobe(wr),.bus_write_data(data),.bus_read_data());
    task write_reg(input [6:0] a,input [7:0] d);
        begin @(negedge clk);addr=a;data=d;wr=1;@(negedge clk);wr=0;end
    endtask
    always @(posedge clk) if(reset_n) begin
        if(ov) expected_oe=oe;
        if(fv) begin expected_e0=e0;expected_e1=e1;expected_noise=noise;expected_threshold=threshold;expected_flags=fflags;end
        if(ot.armed && ot.delay_count==1) begin
            ocount=ocount+1;
            if(ot.completed_record[63:32]!==expected_oe || ot.completed_record[288]!==hb) $fatal(1,"OOK alignment");
            if(ot.completed_record[337:336]!=0) $fatal(1,"timing encoding");
            if(ot.completed_record[305]) begin
                replays=replays+1;
                if(ot.completed_record[351:344]!=16) $fatal(1,"replay count");
            end
        end
        if(ft.armed && ft.delay_count==1) begin
            fcount=fcount+1;
            if(ft.completed_record[63:32]!==expected_e0 || ft.completed_record[95:64]!==expected_e1 ||
                ft.completed_record[128:96]!==expected_noise || ft.completed_record[192:160]!==expected_threshold ||
                ft.completed_record[304]!==expected_flags[16] || ft.completed_record[306]!==expected_flags[18])
                $fatal(1,"FSK pipeline alignment");
        end
    end
    initial begin
        $readmemh("tb/ook_frame.samples.mem",samples);
        #2;reset_n=1;#2;reset_n=0;repeat(5)@(negedge clk);reset_n=1;
        write_reg('h34,1);write_reg('h35,0);write_reg('h36,0);write_reg('h33,1);
        for(i=0;i<62400;i=i+1) begin
            @(negedge clk);sample=samples[i];sv=1;
            @(negedge clk);sv=0;
            repeat(78) @(negedge clk);
        end
        write_reg('h33,2);
        for(i=0;i<100;i=i+1) begin
            @(negedge clk);sample=0;sv=1;
            @(negedge clk);sv=0;repeat(78)@(negedge clk);
        end
        if(ocount<1000 || fcount<1000 || replays!=1 || !ot.ready || !ft.ready) $fatal(1,"coverage counts %0d %0d %0d",ocount,fcount,replays);
        if(ot.count!=512 || ft.count!=512 || ot.trigger_index!=511 || ft.trigger_index!=511)
            $fatal(1,"production depth/trigger");
        if((ot.memory[ot.trigger_ptr][31:0]-ot.memory[ot.first_ptr][31:0])!=511*48 ||
           (ft.memory[ft.trigger_ptr][31:0]-ft.memory[ft.first_ptr][31:0])!=511*48)
            $fatal(1,"production timestamps");
        $display("trace_chain_tb: PASS metrics OOK=%0d FSK=%0d replay=%0d",ocount,fcount,replays);$finish;
    end
    initial begin #100000000; $fatal(1,"timeout");end
endmodule

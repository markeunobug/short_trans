`timescale 1ns/1ps

// Real symbol synchronizer -> normal parser + passive BER observer. Metrics
// represent 1 ms samples, ten per symbol; simulation time is accelerated.
module ber_lock_budget_case #(parameter integer LIMIT=100)(output reg done=0);
    reg clk=0; always #5 clk=~clk;
    reg reset_n=0, metric=0, hard=0, carrier=0;
    reg [7:0] confidence=0;
    wire locked,lost,timeout,bv,bit_value,preamble;
    wire sync_found,frame_valid,payload_valid;
    wire [7:0] payload_data;
    reg wr=0; reg [6:0] address=0; reg [7:0] wdata=0;
    wire [7:0] rdata;
    reg [7:0] body[0:72]; integer bytes,good=0,payloads=0,locks=0,losses=0,timeouts=0;
    integer i,j,tick,scenario; reg [7:0] c8; reg [15:0] c16;

    fsk_symbol_sync #(.LOCK_TIMEOUT_SYMBOLS(LIMIT)) symbol_sync(
        .clk(clk),.reset_n(reset_n),.metric_valid(metric),.hard_bit(hard),
        .total_energy(33'd2000),.confidence(confidence),.carrier_present(carrier),
        .preamble_confidence_threshold(8'd140),.carrier_active(),.sync_locked(locked),
        .preamble_detected(preamble),.lock_lost(lost),.search_timeout(timeout),
        .bit_valid(bv),.bit_value(bit_value),.symbol_energy(),.symbol_confidence(),
        .selected_phase(),.timing_adjust());
    fsk_frame_rx #(.BIT_TIMEOUT_CYCLES(5000)) parser(
        .clk(clk),.rst_n(reset_n),.bit_valid(bv),.bit_value(bit_value),.lock_lost(lost),
        .busy(),.sync_found(sync_found),.frame_valid(frame_valid),.good_frame(),
        .frame_version_type(),.frame_sequence(),.frame_payload_length(),.frame_timestamp(),
        .frame_timestamp_valid(),.frame_is_time_base(),.frame_payload_valid(payload_valid),
        .frame_payload_data(payload_data),.frame_payload_last(),.header_error(),
        .length_error(),.crc_error(),.timeout_error());
    ber_capture #(.BIT_TIMEOUT_CYCLES(5000)) observer(
        .clk(clk),.reset_n(reset_n),.sample_valid(metric),.chain_available(1'b1),
        .sync_found(sync_found),.bit_valid(bv),.bit_value(bit_value),.lock_lost(lost),
        .bus_address(address),.bus_read_strobe(1'b0),.bus_write_strobe(wr),
        .bus_write_data(wdata),.bus_read_data(rdata));
    always @(negedge clk) if(reset_n) begin
        if(frame_valid) good=good+1;
        if(payload_valid) begin
            if(payload_data !== ((((payloads%64)*37)^8'h5a)&8'hff))
                $fatal(1,"Normal payload bytes differ LIMIT=%0d index=%0d",LIMIT,payloads);
            payloads=payloads+1;
        end
        if(preamble) locks=locks+1;
        if(lost) losses=losses+1;
        if(timeout) timeouts=timeouts+1;
    end
    function [7:0] crc8; input [7:0] old,data; integer k; reg [7:0] v;
        begin v=old^data;for(k=0;k<8;k=k+1)v=v[7]?(v<<1)^8'h07:v<<1;crc8=v;end
    endfunction
    function [15:0] crc16; input [15:0] old;input [7:0] data;integer k;reg [15:0] v;
        begin v=old^{data,8'd0};for(k=0;k<8;k=k+1)v=v[15]?(v<<1)^16'h1021:v<<1;crc16=v;end
    endfunction
    task drive; input value,present; input [7:0] quality;
        begin @(negedge clk);hard=value;carrier=present;confidence=quality;metric=1;
            @(posedge clk);#1;@(negedge clk);metric=0;end
    endtask
    task reset_case;
        begin @(negedge clk);reset_n=0;metric=0;carrier=0;wr=0;
            repeat(4)@(posedge clk);@(negedge clk);reset_n=1;
            repeat(3)@(posedge clk);good=0;payloads=0;locks=0;losses=0;timeouts=0;
            @(negedge clk);address=7'h4a;wdata=1;wr=1;
            @(negedge clk);wr=0;
        end
    endtask
    task train;
        integer q,d;
        begin
            for(q=0;q<4;q=q+1)drive(1,1,180);
            for(q=0;q<160;q=q+1)begin
                d=((q%10)>5)?(q%10)-5:5-(q%10);
                drive(((q/10)%2)==0,1,230-d*14);
            end
            repeat(16)@(posedge clk);
            if(!locked||locks<1)$fatal(1,"LIMIT=%0d failed preamble acquisition",LIMIT);
        end
    endtask
    task send_bit;input value;integer q;
        begin for(q=0;q<10;q=q+1)drive(value,1,230);end
    endtask
    task build_body;input integer payload_length;input is_base;
        integer q,offset;
        begin
            for(q=0;q<73;q=q+1)body[q]=0;
            body[0]=is_base?8'h21:8'h20;body[1]=1;body[2]=payload_length;
            c8=0;for(q=0;q<3;q=q+1)c8=crc8(c8,body[q]);body[3]=c8;
            offset=is_base?8:7;
            for(q=4;q<offset;q=q+1)body[q]=q;
            for(q=0;q<payload_length;q=q+1)body[offset+q]=(q*37)^8'h5a;
            c16=16'hffff;for(q=0;q<offset+payload_length;q=q+1)c16=crc16(c16,body[q]);
            body[offset+payload_length]=c16[15:8];body[offset+payload_length+1]=c16[7:0];
            bytes=offset+payload_length+2;
        end
    endtask
    task send_frame;
        integer q,k;reg [15:0] word;
        begin word=16'h06b7;for(q=15;q>=0;q=q-1)send_bit(word[q]);
            for(q=0;q<bytes;q=q+1)for(k=7;k>=0;k=k-1)send_bit(body[q][k]);
            repeat(200)@(posedge clk);
        end
    endtask
    initial begin
        // TIME_BASE fits both limits; DATA32 and DATA64 must fit the production
        // override. Short-frame success is not evidence of long-frame support.
        for(scenario=0;scenario<3;scenario=scenario+1)begin
            reset_case();build_body(scenario==0?0:(scenario==1?32:64),scenario==0);
            train();send_frame();
            $display("LIMIT=%0d scenario=%0d good=%0d payload=%0d loss=%0d timeout=%0d capture_bits=%0d flags=%h",
                LIMIT,scenario,good,payloads,losses,timeouts,observer.bit_count,observer.record_header[87:80]);
            if(scenario==0)begin
                if(good!=1)$fatal(1,"TIME_BASE failed LIMIT=%0d",LIMIT);
            end else if(LIMIT==100)begin
                // After release, the remaining continuous data can also cause
                // failed preamble searches. Require the timeout, not exactly
                // one total timeout pulse across the rest of the long stream.
                if(good!=0||timeouts<1||observer.bit_count!=83||observer.record_header[87:80]!=8'h14)
                    $fatal(1,"Did not reproduce 83-bit header-good lock-loss at LIMIT=100");
            end else begin
                if(good!=1||payloads!=(scenario==1?32:64)||losses!=0)
                    $fatal(1,"Long frame failed LIMIT=%0d",LIMIT);
                if(scenario==1&&(observer.bit_count!=328||observer.record_header[87:80]!=8'h71))
                    $fatal(1,"DATA32 observer did not capture valid 328-bit body");
            end
        end
        // Long budget still ends lock on missing carrier, no indefinite lock.
        reset_case();train();
        for(i=0;i<40;i=i+1)drive(0,0,0);
        repeat(5)@(posedge clk);
        if(locked||losses!=1)$fatal(1,"Carrier-loss protection changed");
        // Consecutive DATA32 frames must reacquire after the existing carrier
        // gap without a global reset or consuming/resetting normal state.
        if(LIMIT>100)begin
            reset_case();build_body(32,0);train();send_frame();
            for(i=0;i<40;i=i+1)drive(0,0,0);
            // Payload checker indexes the newly emitted frame from zero.
            payloads=0;
            train();send_frame();
            if(good!=2||payloads!=32||observer.committed!=2||observer.count!=2)
                $fatal(1,"Consecutive DATA32 frames did not both complete");
        end
        // Continuous carrier still has a finite guard, not an indefinite lock.
        reset_case();train();
        for(i=0;i<(LIMIT+3)*10;i=i+1)drive(1,1,230);
        if(timeouts<1||losses<1)$fatal(1,"Bounded lock timeout disabled");
        done=1;
    end
endmodule

module ber_lock_budget_tb;
    wire short_done,long_done;
    ber_lock_budget_case #(.LIMIT(100)) original(short_done);
    ber_lock_budget_case #(.LIMIT(640)) corrected(long_done);
    initial begin wait(short_done&&long_done);
        $display("PASS real sync/parser/observer: 100-symbol cap truncates DATA at 83 bits; 640 supports TIME_BASE/DATA32/DATA64, consecutive frames, carrier-loss release and bounded timeout");
        $finish;end
    initial begin #2000000;$fatal(1,"testbench watchdog");end
endmodule

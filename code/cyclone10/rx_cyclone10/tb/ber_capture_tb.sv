`timescale 1ns/1ps
module ber_capture_tb;
    // Match the production ~30 MHz oversampling domain, not a faster ideal bus.
    reg clk=0; always #17 clk=~clk;
    reg reset_n=0, available=1, bv=0, bit_value=0, lost=0;
    reg direct=1, rd=0, wr=0;
    reg [6:0] address=0;
    reg [7:0] wdata=0;
    wire [7:0] data;
    reg sck=0, nss=1, mosi=0;
    wire miso, preload, srd, swr, spi_error;
    wire [6:0] saddress; wire [7:0] swdata;
    wire sync_found, fv, pv, plast, busy;
    wire [7:0] vt,seq,len,pdata;
    wire [31:0] stamp;
    wire tv,tb,herr,lerr,cerr,terr;
    wire rfv,rpv,rplast,rsync,rb;
    wire [7:0] rvt,rseq,rlen,rpdata;
    wire [31:0] rstamp;
    wire rtv,rtb,rh,rl,rc,rt;
    integer goods=0, crc_errors=0;
    integer delivered_bytes=0;
    reg inject_sync=0;
    reg [7:0] raw [0:40], record_data [0:63], second [0:63], status [0:31];
    reg [7:0] value;
    integer i,j,k,base_good;
    reg [7:0] c8; reg [15:0] c16;

    fsk_frame_rx #(.BIT_TIMEOUT_CYCLES(5000)) parser (
        .clk(clk),.rst_n(reset_n),.bit_valid(bv),.bit_value(bit_value),.lock_lost(lost),
        .busy(busy),.sync_found(sync_found),.frame_valid(fv),.good_frame(),
        .frame_version_type(vt),.frame_sequence(seq),.frame_payload_length(len),
        .frame_timestamp(stamp),.frame_timestamp_valid(tv),.frame_is_time_base(tb),
        .frame_payload_valid(pv),.frame_payload_data(pdata),.frame_payload_last(plast),
        .header_error(herr),.length_error(lerr),.crc_error(cerr),.timeout_error(terr));
    // Independent production parser/FIFO with no attached sidecar. All cycle
    // outputs and externally readable FIFO state must stay identical.
    fsk_frame_rx #(.BIT_TIMEOUT_CYCLES(5000)) reference_parser (
        .clk(clk),.rst_n(reset_n),.bit_valid(bv),.bit_value(bit_value),.lock_lost(lost),
        .busy(rb),.sync_found(rsync),.frame_valid(rfv),.good_frame(),
        .frame_version_type(rvt),.frame_sequence(rseq),.frame_payload_length(rlen),
        .frame_timestamp(rstamp),.frame_timestamp_valid(rtv),.frame_is_time_base(rtb),
        .frame_payload_valid(rpv),.frame_payload_data(rpdata),.frame_payload_last(rplast),
        .header_error(rh),.length_error(rl),.crc_error(rc),.timeout_error(rt));
    wire [15:0] fifo_good, ref_fifo_good;
    wire [3:0] fifo_count, ref_fifo_count;
    wire [8:0] fifo_level, ref_fifo_level;
    wire [7:0] fifo_data, ref_fifo_data;
    wire [7:0] remaining, ref_remaining;
    wire normal_read = fifo_count!=0 && remaining!=0;
    wire normal_pop = fifo_count!=0 && remaining==0;
    rx_frame_fifo fifo (.clk(clk),.rst_n(reset_n),.frame_valid(fv),
        .frame_version_type(vt),.frame_sequence(seq),.frame_payload_length(len),
        .frame_timestamp(stamp),.frame_timestamp_valid(tv),.frame_is_time_base(tb),
        .frame_payload_valid(pv),.frame_payload_data(pdata),.frame_payload_last(plast),
        .rx_data_pop(normal_read),.pop_frame(normal_pop),.drop_frame(1'b0),.clear_errors(1'b0),
        .frame_count(fifo_count),.payload_level(fifo_level),.good_frame_count(fifo_good),
        .head_payload_data(fifo_data),.head_remaining(remaining),
        .head_version_type(),.head_sequence(),.head_length(),.head_timestamp(),
        .head_timestamp_valid(),.head_is_time_base(),.fifo_overflow_sticky(),
        .protocol_error_sticky(),.ingress_busy());
    rx_frame_fifo reference_fifo (.clk(clk),.rst_n(reset_n),.frame_valid(rfv),
        .frame_version_type(rvt),.frame_sequence(rseq),.frame_payload_length(rlen),
        .frame_timestamp(rstamp),.frame_timestamp_valid(rtv),.frame_is_time_base(rtb),
        .frame_payload_valid(rpv),.frame_payload_data(rpdata),.frame_payload_last(rplast),
        .rx_data_pop(normal_read),.pop_frame(normal_pop),.drop_frame(1'b0),.clear_errors(1'b0),
        .frame_count(ref_fifo_count),.payload_level(ref_fifo_level),.good_frame_count(ref_fifo_good),
        .head_payload_data(ref_fifo_data),.head_remaining(ref_remaining),
        .head_version_type(),.head_sequence(),.head_length(),.head_timestamp(),
        .head_timestamp_valid(),.head_is_time_base(),.fifo_overflow_sticky(),
        .protocol_error_sticky(),.ingress_busy());
    wire [7:0] obs_data, obs_offset;
    ber_observer observer(.clk(clk),.reset_n(reset_n),.sample_valid(1'b1),.metric_valid(bv),.bit_valid(bv),
        .chain_available(available),.carrier(1'b1),.locked(1'b1),.parser_busy(busy),
        .preamble(1'b0),.sync_found(sync_found),.header_error(herr),.length_error(lerr),.crc_error(cerr),
        .good_frame(fv),.lock_lost(lost),.frame_timeout(terr),.search_timeout(1'b0),
        .i2s_error(1'b0),.cdc_error(1'b0),.clipped(1'b0),.energy_above(1'b1),
        .parser_state(4'd0),.symbol_state(2'd0),.payload_bytes(7'd0),.hard_bit(bit_value),
        .energy(33'd100),.threshold(33'd10),.confidence(8'd100),.phase(4'd1),.timing_adjust(2'd0),
        .bus_address(direct?address:saddress),.bus_read_strobe(direct?rd:srd),
        .bus_write_strobe(direct?wr:swr),.bus_write_data(direct?wdata:swdata),
        .read_offset(obs_offset),.bus_read_data(obs_data));
    ber_capture #(.BIT_TIMEOUT_CYCLES(5000)) dut (.clk(clk),.reset_n(reset_n),
        .sample_valid(1'b1),.chain_available(available),.sync_found(sync_found || inject_sync),
        .bit_valid(bv),.bit_value(bit_value),.lock_lost(lost),
        .observer_read_data(obs_data),.observer_read_offset(obs_offset),
        .bus_address(direct?address:saddress),.bus_read_strobe(direct?rd:srd),
        .bus_write_strobe(direct?wr:swr),.bus_write_data(direct?wdata:swdata),.bus_read_data(data));
    spi1_slave spi (.clk_sys(clk),.rst_sys_n(reset_n),.spi_sck(sck),.spi_nss(nss),
        .spi_mosi(mosi),.spi_miso(miso),.bus_address(saddress),.bus_read_preload(preload),
        .bus_read_strobe(srd),.bus_read_data(data),.bus_write_strobe(swr),
        .bus_write_data(swdata),.spi_protocol_error(spi_error));
    always @(negedge clk) if(reset_n) begin
        if ({busy,sync_found,fv,vt,seq,len,stamp,tv,tb,pv,pdata,plast,herr,lerr,cerr,terr} !==
            {rb,rsync,rfv,rvt,rseq,rlen,rstamp,rtv,rtb,rpv,rpdata,rplast,rh,rl,rc,rt})
            $fatal(1,"production parser changed");
        if ({fifo_count,fifo_level,fifo_good,fifo_data} !== {ref_fifo_count,ref_fifo_level,ref_fifo_good,ref_fifo_data})
            $fatal(1,"production FIFO changed");
        if(fv) goods=goods+1;
        if(cerr) crc_errors=crc_errors+1;
        if(normal_read) delivered_bytes=delivered_bytes+1;
    end
    task check; input ok; input [512:0] message;
        begin if(!ok) $fatal(1,"%s",message); end
    endtask
    task write_reg; input [6:0] a; input [7:0] d;
        begin @(negedge clk); direct=1; address=a;wdata=d;wr=1;
        @(negedge clk);wr=0;repeat(3) @(negedge clk);end
    endtask
    task read_byte; output [7:0] d;
        begin address=7'h4e;repeat(3) @(negedge clk);d=data;rd=1;
        @(negedge clk);rd=0;end
    endtask
    task read_record;
        begin write_reg(7'h4d,0);for(k=0;k<64;k=k+1) read_byte(record_data[k]);end
    endtask
    task send_bit; input b;
        begin @(negedge clk);bv=1;bit_value=b;end
    endtask
    task sync_word;
        reg [15:0] s;integer n;
        begin s=16'h06b7;for(n=15;n>=0;n=n-1) send_bit(s[n]);end
    endtask
    task finish_bits;
        begin @(negedge clk);bv=0;repeat(100) @(negedge clk);end
    endtask
    task send_frame;
        integer n,b;
        begin sync_word();for(n=0;n<41;n=n+1)for(b=7;b>=0;b=b-1)send_bit(raw[n][b]);finish_bits();end
    endtask
    task pulse_loss;
        begin @(negedge clk);bv=0;lost=1;@(negedge clk);lost=0;repeat(100) @(negedge clk);end
    endtask
    function [7:0] crc8;input [7:0] c,d;integer n;reg[7:0]v;
        begin v=c^d;for(n=0;n<8;n=n+1)v=v[7]?(v<<1)^8'h07:v<<1;crc8=v;end
    endfunction
    function [15:0] crc16;input [15:0] c;input[7:0]d;integer n;reg[15:0]v;
        begin v=c^{d,8'd0};for(n=0;n<8;n=n+1)v=v[15]?(v<<1)^16'h1021:v<<1;crc16=v;end
    endfunction
    task make_frame;
        begin raw[0]=8'h20;raw[1]=7;raw[2]=32;c8=0;
        for(i=0;i<3;i=i+1)c8=crc8(c8,raw[i]);raw[3]=c8;
        for(i=4;i<39;i=i+1)raw[i]=i*7+3;
        c16=16'hffff;for(i=0;i<39;i=i+1)c16=crc16(c16,raw[i]);raw[39]=c16[15:8];raw[40]=c16[7:0];end
    endtask
    task spi_byte; input [7:0] tx; output [7:0] rx;integer n;
        begin rx=0;for(n=7;n>=0;n=n-1)begin
        mosi=tx[n];#350;sck=1;#100;rx[n]=miso;#350;sck=0;#50;end end
    endtask
    task spi_seek; input [7:0] offset;reg[7:0] junk;
        begin direct=0;nss=0;#500;spi_byte(8'h4d,junk);spi_byte(offset,junk);nss=1;#500;end
    endtask
    task spi_record;
        reg[7:0] junk;integer n;
        begin spi_seek(0);nss=0;#500;spi_byte(8'hce,junk);
        for(n=0;n<64;n=n+1)spi_byte(0,second[n]);nss=1;#500;end
    endtask
    initial begin
        repeat(5) @(negedge clk);reset_n=1;make_frame();send_frame();
        check(goods==1 && dut.count==0 && !dut.enabled,"default disabled / normal good");
        write_reg(7'h4a,8'h10);
        write_reg(7'h4a,1);send_frame();read_record();
        check(record_data[10]==8'h71 && record_data[8]==8'h48 && record_data[9]==1 && record_data[11]==41,"good flags/count");
        for(i=0;i<41;i=i+1)check(record_data[i+16]==raw[i],"raw bit start/byte recovery");
        spi_record();for(i=0;i<64;i=i+1)check(second[i]==record_data[i],"SPI synchronous RAM stream");
        // Abort a read mid-byte, then seek from zero. READ never pops.
        spi_seek(0);nss=0;#500;spi_byte(8'hce,value);mosi=0;#400;sck=1;#500;sck=0;nss=1;#500;
        spi_record();for(i=0;i<64;i=i+1)check(second[i]==record_data[i],"SPI retry after partial byte");
        check(dut.count==1,"READ non-destructive");write_reg(7'h4a,8);
        raw[20]=raw[20]^8'h04;base_good=goods;send_frame();read_record();
        check(goods==base_good && crc_errors==1 && record_data[10]==8'h51,"CRC bad only in diagnostics");
        for(i=0;i<41;i=i+1)check(record_data[i+16]==raw[i],"known payload flip retained exactly");
        write_reg(7'h4a,8);make_frame();raw[3]=raw[3]^1;send_frame();read_record();
        check((record_data[10]&8'h10)==0,"bad header CRC observed");write_reg(7'h4a,8);pulse_loss();
        make_frame();raw[2]=65;send_frame();read_record();check((record_data[10]&8'h40)==0,"wrong length never expected DATA");
        write_reg(7'h4a,8);pulse_loss();
        sync_word();send_bit(1);send_bit(0);send_bit(1);finish_bits();
        write_reg(7'h4a,2);repeat(100) @(negedge clk);read_record();
        check(record_data[8]==3 && record_data[11]==1 && record_data[16]==8'ha0 && record_data[10]==8,"partial STOP padding");
        write_reg(7'h4a,8);pulse_loss();write_reg(7'h4a,1);sync_word();send_bit(1);finish_bits();
        repeat(5100) @(negedge clk);read_record();check(record_data[10]==2 && record_data[8]==1,"timeout");write_reg(7'h4a,8);
        sync_word();send_bit(1);send_bit(1);pulse_loss();read_record();check(record_data[10]==4,"lock loss");write_reg(7'h4a,8);
        sync_word();send_bit(0);finish_bits();available=0;repeat(100) @(negedge clk);read_record();
        check(record_data[10]==4,"chain unavailable");write_reg(7'h4a,8);available=1;pulse_loss();
        // Valid header CRC but an unexpected type must not imply DATA alignment.
        make_frame();raw[0]=8'h21;c8=0;
        for(i=0;i<3;i=i+1)c8=crc8(c8,raw[i]);raw[3]=c8;
        send_frame();read_record();
        check((record_data[10]&8'h50)==8'h10,"wrong type kept raw, not expected DATA");
        write_reg(7'h4a,8);pulse_loss();
        // STOP has deterministic priority over a coincident next bit.
        sync_word();send_bit(1);send_bit(0);finish_bits();
        @(negedge clk);address=7'h4a;wdata=2;wr=1;bv=1;bit_value=1;
        @(negedge clk);wr=0;bv=0;repeat(100) @(negedge clk);read_record();
        check(record_data[8]==2 && record_data[16]==8'h80 && record_data[10]==8,"STOP wins coincident bit");
        write_reg(7'h4a,8);pulse_loss();write_reg(7'h4a,1);
        // Fill sidecar and keep sending: normal receiver continues unconditionally.
        base_good=goods;make_frame();for(j=0;j<9;j=j+1)send_frame();
        check(dut.count==8 && dut.dropped==1,"full queue drop new only");
        check(goods==base_good+9 && fifo_count==0 && delivered_bytes>=11*32,"normal FIFO continues while diagnostic full");
        read_record();for(i=0;i<64;i=i+1)second[i]=record_data[i];
        fork
            send_frame();
            begin read_record();for(i=0;i<64;i=i+1)check(second[i]==record_data[i],"head stable during simultaneous capture/read");end
        join
        read_record();
        for(i=0;i<64;i=i+1)check(second[i]==record_data[i],"full queue preserves head");
        // Pop in same cycle as capture completion, then during publish commit.
        sync_word();for(i=0;i<41;i=i+1)for(k=7;k>=0;k=k-1)begin
            send_bit(raw[i][k]);if(i==40 && k==0)begin address=7'h4a;wdata=8;wr=1;end
        end
        @(negedge clk);bv=0;wr=0;
        wait(dut.publish_index==63);@(negedge clk);address=7'h4a;wdata=8;wr=1;
        @(negedge clk);wr=0;repeat(5) @(negedge clk);
        check(dut.count==7,"simultaneous publish/POP count");
        write_reg(7'h4d,8'h80);read_byte(status[0]);
        write_reg(7'h4a,8); // Mutate live queue after the status latch.
        write_reg(7'h4d,8'h81);
        for(i=1;i<32;i=i+1)read_byte(status[i]);
        check({status[3],status[2],status[1],status[0]}==32'h31305342 && status[5]==7,"coherent status snapshot");
        check(dut.count==6,"status read does not alter live queue");
        write_reg(7'h4a,4);check(dut.count==6 && dut.protocol_errors!=0,"CLEAR rejected while enabled");
        write_reg(7'h4a,2);repeat(100) @(negedge clk);write_reg(7'h4a,4);
        check(dut.count==0 && !dut.enabled,"STOP CLEAR");
        // Accepted sync during an unfinished observation cannot restart it.
        pulse_loss();write_reg(7'h4a,1);sync_word();send_bit(1);finish_bits();
        inject_sync=1;@(negedge clk);inject_sync=0;repeat(3) @(negedge clk);
        check(dut.missed_sync==1 && dut.bit_count==1,"busy sync counted without restart");
        write_reg(7'h4a,2);repeat(100) @(negedge clk);write_reg(7'h4a,4);
        // Empty/invalid stream and control errors are private to diagnostics.
        write_reg(7'h4a,8);write_reg(7'h4a,3);write_reg(7'h4d,8'h3f);read_byte(value);
        check(dut.protocol_errors==3,"empty POP/invalid control/offset counted");
        // Reset during an enabled session returns to OFF, with empty queue.
        pulse_loss();write_reg(7'h4a,1);@(negedge clk);reset_n=0;
        repeat(5) @(negedge clk);reset_n=1;repeat(5) @(negedge clk);
        check(!dut.enabled && dut.count==0 && dut.started==0,"reset defaults OFF");
        $display("PASS ber_capture: raw/CRC/partial/timeout/loss/STOP/full/concurrent POP/snapshot/SPI retry + parser/FIFO differential");$finish;
    end
    initial begin #100000000;$fatal(1,"test timeout");end
endmodule

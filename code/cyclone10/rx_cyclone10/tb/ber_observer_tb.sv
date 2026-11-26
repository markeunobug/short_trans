`timescale 1ns/1ps
module ber_observer_tb;
    reg clk=0;always #17 clk=~clk;
    reg rst=0, sample=0, metric=0, bv=0, available=1;
    reg carrier=0, locked=0, busy=0, preamble=0, sync=0;
    reg herr=0,lerr=0,cerr=0,good=0,lost=0,timeout=0,search=0;
    reg i2s=0,cdc=0,clip=0,above=0;
    reg[3:0] ps=0;reg[1:0] ss=0;reg[6:0] pb=0;
    reg [32:0] energy=33'h100000012, threshold=33'h100000020;
    reg [7:0] conf=100;
    reg direct=1, rd=0, wr=0;
    reg [6:0] addr=0;reg[7:0] wd=0;
    wire[7:0] offset, obs_data, data;
    reg sck=0,nss=1,mosi=0;
    wire miso,preload,srd,swr,spierror;wire[6:0] sa;wire[7:0] sw;
    wire[6:0] a=direct?addr:sa;
    wire r=direct?rd:srd,w=direct?wr:swr;
    wire[7:0] v=direct?wd:sw;
    reg[7:0] summary[0:95],saved[0:95],pages[0:1023],junk;
    integer i,j,fd;
    ber_capture capture(.clk(clk),.reset_n(rst),.sample_valid(sample),
        .chain_available(available),.sync_found(sync),.bit_valid(bv),.bit_value(1'b0),.lock_lost(lost),
        .observer_read_data(obs_data),.observer_read_offset(offset),.bus_address(a),
        .bus_read_strobe(r),.bus_write_strobe(w),.bus_write_data(v),.bus_read_data(data));
    ber_observer obs(.clk(clk),.reset_n(rst),.sample_valid(sample),.metric_valid(metric),.bit_valid(bv),
        .chain_available(available),.carrier(carrier),.locked(locked),.parser_busy(busy),
        .preamble(preamble),.sync_found(sync),.header_error(herr),.length_error(lerr),.crc_error(cerr),
        .good_frame(good),.lock_lost(lost),.frame_timeout(timeout),.search_timeout(search),
        .i2s_error(i2s),.cdc_error(cdc),.clipped(clip),.energy_above(above),
        .parser_state(ps),.symbol_state(ss),.payload_bytes(pb),.hard_bit(1'b0),
        .energy(energy),.threshold(threshold),.confidence(conf),.phase(4'd7),.timing_adjust(-2'sd1),
        .bus_address(a),.bus_read_strobe(r),.bus_write_strobe(w),.bus_write_data(v),
        .read_offset(offset),.bus_read_data(obs_data));
    spi1_slave spi(.clk_sys(clk),.rst_sys_n(rst),.spi_sck(sck),.spi_nss(nss),.spi_mosi(mosi),
        .spi_miso(miso),.bus_address(sa),.bus_read_preload(preload),.bus_read_strobe(srd),
        .bus_read_data(data),.bus_write_strobe(swr),.bus_write_data(sw),.spi_protocol_error(spierror));
    task check(input bit ok,input string msg);if(!ok)$fatal(1,"%s",msg);endtask
    task write_reg(input[6:0] address,input[7:0] value);
        @(negedge clk);direct=1;addr=address;wd=value;wr=1;
        @(negedge clk);wr=0;repeat(3)@(negedge clk);
    endtask
    task read_byte(output[7:0] value);
        addr=7'h4e;repeat(3)@(negedge clk);value=data;rd=1;
        @(negedge clk);rd=0;
    endtask
    task read_summary;
        write_reg(7'h4d,8'ha0);for(integer k=0;k<96;k++)read_byte(summary[k]);
    endtask
    task spi_byte(input[7:0] tx,output[7:0] rx);
        rx=0;for(integer k=7;k>=0;k--)begin
            mosi=tx[k];#350;sck=1;#100;rx[k]=miso;#350;sck=0;#50;
        end
    endtask
    task spi_seek(input[7:0] value);
        direct=0;nss=0;#500;spi_byte(8'h4d,junk);spi_byte(value,junk);nss=1;#500;
    endtask
    function[31:0] count(input integer index);
        count={summary[19+4*index],summary[18+4*index],summary[17+4*index],summary[16+4*index]};
    endfunction
    initial begin
        repeat(5)@(negedge clk);rst=1;
        sample=1;metric=1;repeat(10)@(negedge clk);sample=0;metric=0;
        check(obs.counters[0]==0,"disabled observer counted");
        write_reg(7'h4a,8'h10);sample=1;metric=1;
        repeat(20)@(negedge clk);sample=0;metric=0;
        write_reg(7'h4a,8'h20);read_summary();
        check(summary[0]=="B" && summary[1]=="O" && summary[4]==1,"signature/window ID");
        check(count(0)==20 && count(1)==20 && count(6)==0,"no-sync failure must retain sampling evidence");
        check(summary[9]==2 && summary[8]==6,"arm/end events for no signal");
        check({summary[91],summary[90],summary[89],summary[88],summary[87],summary[86],summary[85],summary[84]}==64'h100000012,"33-bit max energy");
        for(i=0;i<96;i++)saved[i]=summary[i];
        available=0;i2s=1;sample=1;metric=1;repeat(8)@(negedge clk);
        read_summary();for(i=0;i<96;i++)check(saved[i]==summary[i],"frozen snapshot mutated");
        available=1;i2s=0;sample=0;metric=0;
        write_reg(7'h4a,8'h10);
        @(negedge clk);carrier=1;above=1;metric=1;sample=1;ss=1;
        @(negedge clk);locked=1;preamble=1;ss=2;
        @(negedge clk);preamble=0;sync=1;busy=1;bv=1;ps=1;
        @(negedge clk);sync=0;ps=6;
        @(negedge clk);ps=2;pb=5;
        @(negedge clk);ps=3;
        @(negedge clk);herr=1;ps=0;
        @(negedge clk);herr=0;lost=1;locked=0;ss=0;
        @(negedge clk);lost=0;busy=0;bv=0;
        @(negedge clk);good=1;ps=5;
        @(negedge clk);good=0;lost=1;
        @(negedge clk);lost=0;sample=0;metric=0;carrier=0;above=0;
        write_reg(7'h4a,8'h20);read_summary();
        check(count(3)==1 && count(4)==1 && count(5)==1 && count(6)==1,"stage pulse counters");
        check(count(7)==1 && count(10)==1 && count(11)==1,"parser loss distinct from normal tail");
        check(capture.protocol_errors==0,"observer controls corrupted classic BER status");
        fd=$fopen("observer_summary.hex","w");for(i=0;i<96;i++)$fdisplay(fd,"%02x",summary[i]);$fclose(fd);
        for(j=0;j<16;j++)begin
            write_reg(7'h4a,8'h80+j);write_reg(7'h4d,8'h40);
            for(i=0;i<64;i++)read_byte(pages[j*64+i]);
        end
        fd=$fopen("observer_events.hex","w");for(i=0;i<1024;i++)$fdisplay(fd,"%02x",pages[i]);$fclose(fd);
        // Physical ~1 MHz SPI stream and retry after an aborted byte.
        spi_seek(8'ha0);nss=0;#500;spi_byte(8'hce,junk);
        for(i=0;i<96;i++)begin spi_byte(0,junk);check(junk==summary[i],"SPI summary stream");end
        nss=1;#500;
        write_reg(7'h4a,8'h80);spi_seek(8'h40);nss=0;#500;spi_byte(8'hce,junk);
        mosi=0;#400;sck=1;#500;sck=0;nss=1;#500;
        spi_seek(8'h40);nss=0;#500;spi_byte(8'hce,junk);
        for(i=0;i<64;i++)begin spi_byte(0,junk);check(junk==pages[i],"SPI event retry");end
        nss=1;#500;
        write_reg(7'h4a,8'h10);
        for(i=0;i<80;i++)begin @(negedge clk);carrier=~carrier;end
        write_reg(7'h4a,8'h02);read_summary();
        check(summary[9]==32 && count(16)>0 && summary[8][3],"bounded ring overflow not reported");
        check(!obs.active && obs.frozen,"BER STOP did not freeze observer");
        write_reg(7'h4a,8'h10);write_reg(7'h4a,8'h20);read_summary();
        check(count(16)==0 && summary[4]==4,"fresh window did not reset evidence");
        $display("PASS: observer no-sync/stages/33-bit metrics/freeze/SPI/reseek/wrap/tail distinction");$finish;
    end
    initial begin #20000000;$fatal(1,"observer test timeout");end
endmodule

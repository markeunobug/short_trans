`timescale 1ns/1ps
module demod_trace_tb;
    reg clk=0, reset_n=0;
    always #17 clk=~clk;
    reg sck=0, nss=1, mosi=0;
    wire miso;
    wire [6:0] addr;
    wire preload, rd, wr, error;
    wire [7:0] rdata, wdata;
    reg sample_valid=0, metric_valid=0, bv=0, available=1;
    reg [31:0] e0=0, events=0, flags=0;
    reg [111:0] cfg={32'd600,32'd400,16'd200,8'd32,8'd64,8'd12,8'd1};
    wire signed [32:0] soft = -$signed({1'b0,e0});
    reg [7:0] b, ignore;
    integer i,j,fd;
    reg [7:0] captured[0:447];
    spi1_slave spi(.clk_sys(clk),.rst_sys_n(reset_n),.spi_sck(sck),.spi_nss(nss),
        .spi_mosi(mosi),.spi_miso(miso),.bus_address(addr),.bus_read_preload(preload),
        .bus_read_strobe(rd),.bus_write_strobe(wr),.bus_read_data(rdata),
        .bus_write_data(wdata),.spi_protocol_error(error));
    demod_trace #(.ADDR_BITS(3)) dut(.clk(clk),.reset_n(reset_n),.sample_valid(sample_valid),
        .metric_valid(metric_valid),.energy0(e0),.energy1(32'd0),.noise(33'h100000001),
        .threshold(33'h1ffffffff),.soft(soft),.confidence(8'd255),.state_flags(flags),
        .event_flags(events),.bit_valid(bv),.phase(4'd5),.timing_adjust(2'b11),
        .config_data(cfg),.chain_available(available),.bus_address(addr),
        .bus_read_strobe(rd),.bus_write_strobe(wr),.bus_write_data(wdata),.bus_read_data(rdata));
    task byte_io(input [7:0] tx, output [7:0] rx);
        integer k;
        begin
            rx=0;
            for(k=7;k>=0;k=k-1) begin
                mosi=tx[k]; #500; sck=1; #250; rx[k]=miso; #250; sck=0;
            end
            #300;
        end
    endtask
    task write_reg(input [6:0] a,input [7:0] v);
        begin nss=0; #500; byte_io({1'b0,a},ignore); byte_io(v,ignore); nss=1; #1000; end
    endtask
    task read_reg(input [6:0] a,output [7:0] v);
        begin nss=0; #500; byte_io({1'b1,a},ignore); byte_io(0,v); nss=1; #1000; end
    endtask
    task metric(input integer value);
        begin
            @(negedge clk); sample_valid=1;
            repeat(48) @(negedge clk);
            sample_valid=0; e0=value; metric_valid=1;
            @(negedge clk); metric_valid=0;
            repeat(70) @(negedge clk);
        end
    endtask
    task arm(input [7:0] mask,input [7:0] post);
        begin write_reg('h34,mask); write_reg('h35,post); write_reg('h36,0); write_reg('h33,1); end
    endtask
    initial begin
        #200; reset_n=1;
        arm(1,2);
        for(i=0;i<12;i=i+1) metric(i);
        write_reg('h33,2);
        metric(12); metric(13); metric(14);
        read_reg('h37,b); if(b!=6) $fatal(1,"not frozen");
        read_reg('h38,b); if(b!=8) $fatal(1,"wrong count");
        read_reg('h3e,b); if(b!=5) $fatal(1,"wrong trigger index");
        write_reg('h3a,0); write_reg('h3b,0);
        nss=0; #500; byte_io('hc2,ignore);
        for(j=0;j<448;j=j+1) byte_io(0,captured[j]);
        nss=1; #1000;
        if(captured[0]!=8'h44 || captured[4]!=1 || captured[28]!=8) $fatal(1,"header");
        for(j=0;j<8;j=j+1) begin
            if(captured[64+j*48+4] != j+7) $fatal(1,"ring ordering");
            if(captured[64+j*48+12]!=1 || captured[64+j*48+16]!=1) $fatal(1,"33 bit noise");
            if(captured[64+j*48+35]!=255 || captured[64+j*48+47]!=1) $fatal(1,"signed/config");
        end
        fd=$fopen("rtl_capture.bin","wb");
        for(j=0;j<448;j=j+1) $fwrite(fd,"%c",captured[j]);
        $fclose(fd);
        write_reg('h3a,64); write_reg('h3b,0);
        for(j=0;j<48;j=j+1) begin read_reg('h42,b); if(b!=captured[64+j]) $fatal(1,"split retry"); end
        arm(16,0); metric(99);
        @(negedge clk); events=32'h200;
        @(negedge clk); events=0;
        metric(100);
        read_reg('h37,b); if(b!=6) $fatal(1,"CRC pulse trigger lost");
        read_reg('h3e,b); if(b!=1) $fatal(1,"early trigger");
        arm(1,2); metric(101); cfg[15:8]=13;
        #200; read_reg('h37,b); if(b!=12) $fatal(1,"config change not invalidated");
        arm(1,2); metric(102); available=0;
        #200; read_reg('h37,b); if(b!=12) $fatal(1,"ADC loss not invalidated");
        available=1; arm(1,2); metric(103); write_reg('h33,4);
        read_reg('h37,b); if(b!=12) $fatal(1,"abort");
        arm(1,8); read_reg('h37,b); if(b!=8) $fatal(1,"invalid post accepted");
        for(i=1;i<7;i=i+1) begin
            flags=0; events=0; #100;
            arm(1<<i,0); metric(200+i);
            @(negedge clk);
            case(i)
                1:flags=2;
                2:flags=4;
                3:events=32'h40;
                4:events=32'h200;
                5:events=32'h100;
                6:events=32'h80;
            endcase
            @(negedge clk);events=0;
            metric(210+i);
            read_reg('h37,b);if(b!=6) $fatal(1,"event mask %0d",i);
        end
        $display("demod_trace_tb: PASS"); $finish;
    end
    initial begin #100000000; $fatal(1,"timeout"); end
endmodule

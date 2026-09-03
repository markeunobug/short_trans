`timescale 1ns/1ps

module protocol_crc_tb;
    reg  [7:0]  crc8_in;
    reg  [15:0] crc16_in;
    reg  [7:0]  data_in;
    wire [7:0]  crc8_out;
    wire [15:0] crc16_out;

    crc8_atm crc8_dut (
        .crc_in (crc8_in),
        .data_in(data_in),
        .crc_out(crc8_out)
    );

    crc16_ccitt crc16_dut (
        .crc_in (crc16_in),
        .data_in(data_in),
        .crc_out(crc16_out)
    );

    task feed_byte;
        input [7:0] value;
        begin
            data_in = value;
            #1;
            crc8_in  = crc8_out;
            crc16_in = crc16_out;
            #1;
        end
    endtask

    initial begin
        crc8_in  = 8'h00;
        crc16_in = 16'hFFFF;
        data_in  = 8'h00;
        #1;

        feed_byte(8'h31); // "1"
        feed_byte(8'h32);
        feed_byte(8'h33);
        feed_byte(8'h34);
        feed_byte(8'h35);
        feed_byte(8'h36);
        feed_byte(8'h37);
        feed_byte(8'h38);
        feed_byte(8'h39);

        if (crc8_in !== 8'hF4)
            $fatal(1, "CRC-8/ATM vector failed: got %02h", crc8_in);
        if (crc16_in !== 16'h29B1)
            $fatal(1, "CRC-16/CCITT-FALSE vector failed: got %04h", crc16_in);

        $display("protocol_crc_tb: PASS");
        $finish;
    end
endmodule

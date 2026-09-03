`timescale 1ns/1ps
`default_nettype none

// CRC-16/CCITT-FALSE (poly=0x1021, init=0xFFFF, non-reflected, xorout=0).
module crc16_ccitt (
    input  wire [15:0] crc_in,
    input  wire [7:0]  data_in,
    output wire [15:0] crc_out
);

    function [15:0] crc16_next;
        input [15:0] crc_value;
        input [7:0]  data_value;
        integer bit_index;
        reg [15:0] value;
        begin
            value = crc_value ^ {data_value, 8'h00};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (value[15])
                    value = {value[14:0], 1'b0} ^ 16'h1021;
                else
                    value = {value[14:0], 1'b0};
            end
            crc16_next = value;
        end
    endfunction

    assign crc_out = crc16_next(crc_in, data_in);

endmodule

`default_nettype wire

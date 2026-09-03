`timescale 1ns/1ps
`default_nettype none

// CRC-8/ATM (poly=0x07, init=0x00, non-reflected, xorout=0x00).
module crc8_atm (
    input  wire [7:0] crc_in,
    input  wire [7:0] data_in,
    output wire [7:0] crc_out
);

    function [7:0] crc8_next;
        input [7:0] crc_value;
        input [7:0] data_value;
        integer bit_index;
        reg [7:0] value;
        begin
            value = crc_value ^ data_value;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (value[7])
                    value = {value[6:0], 1'b0} ^ 8'h07;
                else
                    value = {value[6:0], 1'b0};
            end
            crc8_next = value;
        end
    endfunction

    assign crc_out = crc8_next(crc_in, data_in);

endmodule

`default_nettype wire

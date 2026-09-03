`timescale 1ns/1ps
`default_nettype none

// Converts the signed 32-bit I2S sample to the demodulator's signed 20-bit
// input. The arithmetic right shift is runtime configurable; values outside
// the 20-bit range saturate instead of wrapping.
module sample_preprocess (
    input  wire signed [31:0] sample_in,
    input  wire        [4:0]  shift_amount,
    output reg  signed [19:0] sample_out,
    output reg                 clipped_positive,
    output reg                 clipped_negative
);

    localparam signed [31:0] MAX_SAMPLE = 32'sd524287;
    localparam signed [31:0] MIN_SAMPLE = -32'sd524288;

    reg signed [31:0] shifted_sample;

    always @(*) begin
        shifted_sample = sample_in >>> shift_amount;
        clipped_positive = 1'b0;
        clipped_negative = 1'b0;

        if (shifted_sample > MAX_SAMPLE) begin
            sample_out = 20'sh7ffff;
            clipped_positive = 1'b1;
        end else if (shifted_sample < MIN_SAMPLE) begin
            sample_out = 20'sh80000;
            clipped_negative = 1'b1;
        end else begin
            sample_out = shifted_sample[19:0];
        end
    end

endmodule

`default_nettype wire

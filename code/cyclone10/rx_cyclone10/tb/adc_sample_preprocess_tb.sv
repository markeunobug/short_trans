`timescale 1ns/1ps

module adc_sample_preprocess_tb;
    logic signed [31:0] sample_in;
    logic [4:0] shift_amount;
    wire signed [19:0] sample_out;
    wire clipped_positive;
    wire clipped_negative;

    sample_preprocess dut (
        .sample_in(sample_in),
        .shift_amount(shift_amount),
        .sample_out(sample_out),
        .clipped_positive(clipped_positive),
        .clipped_negative(clipped_negative)
    );

    task automatic check_value(
        input logic signed [31:0] value,
        input logic [4:0] shift,
        input logic signed [19:0] expected,
        input logic expect_pos_clip,
        input logic expect_neg_clip
    );
        begin
            sample_in = value;
            shift_amount = shift;
            #1;
            if (sample_out !== expected ||
                clipped_positive !== expect_pos_clip ||
                clipped_negative !== expect_neg_clip) begin
                $fatal(1,
                    "FAIL: input=%08x shift=%0d output=%05x pos=%b neg=%b",
                    value, shift, sample_out,
                    clipped_positive, clipped_negative);
            end
        end
    endtask

    initial begin
        check_value(32'sh12345000, 5'd12, 20'sh12345, 1'b0, 1'b0);
        check_value(-32'sd4096, 5'd12, -20'sd1, 1'b0, 1'b0);
        check_value(32'sh7fffffff, 5'd0, 20'sh7ffff, 1'b1, 1'b0);
        check_value(-32'sh7fffffff, 5'd0, 20'sh80000, 1'b0, 1'b1);
        check_value(32'sd524287, 5'd0, 20'sh7ffff, 1'b0, 1'b0);
        check_value(-32'sd524288, 5'd0, 20'sh80000, 1'b0, 1'b0);
        $display("adc_sample_preprocess_tb: PASS");
        $finish;
    end
endmodule

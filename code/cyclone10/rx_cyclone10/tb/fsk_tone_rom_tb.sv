`timescale 1ns/1ps

module fsk_tone_rom_tb;
    logic [6:0] phase_index;
    wire signed [15:0] cos_f0;
    wire signed [15:0] sin_f0;
    wire signed [15:0] cos_f1;
    wire signed [15:0] sin_f1;
    logic [63:0] expected [0:119];
    integer index;
    integer errors;

    fsk_tone_rom dut (
        .phase_index (phase_index),
        .cos_f0      (cos_f0),
        .sin_f0      (sin_f0),
        .cos_f1      (cos_f1),
        .sin_f1      (sin_f1)
    );

    initial begin
        $readmemh(
            "tb/fsk_tone_coefficients.mem",
            expected
        );
        errors = 0;
        phase_index = 7'd0;

        for (index = 0; index < 120; index = index + 1) begin
            phase_index = index[6:0];
            #1;
            if ({cos_f0, sin_f0, cos_f1, sin_f1} !== expected[index]) begin
                $error("ROM mismatch at phase %0d: got %h expected %h",
                       index,
                       {cos_f0, sin_f0, cos_f1, sin_f1},
                       expected[index]);
                errors = errors + 1;
            end
        end

        phase_index = 7'd120;
        #1;
        if ({cos_f0, sin_f0, cos_f1, sin_f1} !==
            {16'sd32767, 16'sd0, 16'sd32767, 16'sd0}) begin
            $error("default ROM value is not phase zero");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: all 120 Q1.15 reference entries match");
        else
            $fatal(1, "FAIL: %0d tone ROM errors", errors);
        $finish;
    end
endmodule

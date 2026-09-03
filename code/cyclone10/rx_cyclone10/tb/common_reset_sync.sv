`timescale 1ns/1ps

module common_reset_sync;
    reg clk;
    reg arst_n;
    wire srst_n;
    wire srst;

    reset_sync #(.STAGES(2)) dut (
        .clk   (clk),
        .arst_n(arst_n),
        .srst_n(srst_n),
        .srst  (srst)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        arst_n = 1'b0;
        #1;
        if (srst_n !== 1'b0 || srst !== 1'b1) $fatal(1, "reset did not assert");

        #22;
        arst_n = 1'b1;
        #3;
        if (srst_n !== 1'b0) $fatal(1, "reset released too early");
        #10;
        if (srst_n !== 1'b1 || srst !== 1'b0) $fatal(1, "reset did not release synchronously");

        #2;
        arst_n = 1'b0;
        #1;
        if (srst_n !== 1'b0 || srst !== 1'b1) $fatal(1, "reset did not assert asynchronously");

        $display("common_reset_sync: PASS");
        $finish;
    end
endmodule

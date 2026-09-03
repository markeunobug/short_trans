`timescale 1ns/1ps

module common_cdc_pulse;
    reg src_clk;
    reg dst_clk;
    reg src_rst_n;
    reg dst_rst_n;
    reg src_pulse;
    wire dst_pulse;
    integer pulse_count;

    cdc_pulse #(.SYNC_STAGES(2)) dut (
        .src_clk  (src_clk),
        .src_rst_n(src_rst_n),
        .src_pulse(src_pulse),
        .dst_clk  (dst_clk),
        .dst_rst_n(dst_rst_n),
        .dst_pulse(dst_pulse)
    );

    always #3.5 src_clk = ~src_clk;
    always #5.5 dst_clk = ~dst_clk;

    always @(posedge dst_clk) begin
        if (dst_pulse) pulse_count = pulse_count + 1;
    end

    task send_source_pulse;
        begin
            @(negedge src_clk);
            src_pulse = 1'b1;
            @(negedge src_clk);
            src_pulse = 1'b0;
        end
    endtask

    initial begin
        src_clk = 1'b0;
        dst_clk = 1'b0;
        src_rst_n = 1'b0;
        dst_rst_n = 1'b0;
        src_pulse = 1'b0;
        pulse_count = 0;

        #17;
        src_rst_n = 1'b1;
        dst_rst_n = 1'b1;

        send_source_pulse;
        #13;
        send_source_pulse;
        #17;
        send_source_pulse;
        #60;

        if (pulse_count !== 3) $fatal(1, "expected 3 destination pulses, got %0d", pulse_count);
        $display("common_cdc_pulse: PASS");
        $finish;
    end
endmodule

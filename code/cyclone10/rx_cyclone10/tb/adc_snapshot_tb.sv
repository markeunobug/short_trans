`timescale 1ns/1ps

module adc_snapshot_tb;

    logic               clk_sys = 1'b0;
    logic               rst_sys_n = 1'b0;
    logic signed [31:0] sample_data = 32'sd0;
    logic               sample_valid = 1'b0;
    logic               snapshot_trigger = 1'b0;
    logic               read_next = 1'b0;
    wire [31:0]         read_data;
    wire                read_valid;
    wire                snapshot_busy;
    wire                snapshot_ready;
    wire [10:0]         samples_remaining;

    integer errors = 0;
    integer sample_index;

    always #16.667 clk_sys = ~clk_sys;

    adc_snapshot dut (
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n),
        .sample_data(sample_data),
        .sample_valid(sample_valid),
        .snapshot_trigger(snapshot_trigger),
        .read_next(read_next),
        .read_data(read_data),
        .read_valid(read_valid),
        .snapshot_busy(snapshot_busy),
        .snapshot_ready(snapshot_ready),
        .samples_remaining(samples_remaining)
    );

    function automatic [31:0] pattern(input integer index);
        begin
            case (index)
                0: pattern = 32'h12345678;
                1: pattern = 32'h80000000;
                2: pattern = 32'h7fffffff;
                default: pattern = 32'ha5000000 + index;
            endcase
        end
    endfunction

    task automatic pulse_trigger;
        begin
            @(negedge clk_sys);
            snapshot_trigger = 1'b1;
            @(negedge clk_sys);
            snapshot_trigger = 1'b0;
        end
    endtask

    task automatic read_and_check(input integer index);
        begin
            @(negedge clk_sys);
            read_next = 1'b1;
            @(posedge clk_sys);
            #1;
            if (!read_valid) begin
                $display("ERROR: read_valid missing at word %0d", index);
                errors = errors + 1;
            end
            if (read_data !== pattern(index)) begin
                $display("ERROR: snapshot[%0d] expected %08x, got %08x",
                         index, pattern(index), read_data);
                errors = errors + 1;
            end
            @(negedge clk_sys);
            read_next = 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk_sys);
        @(negedge clk_sys);
        rst_sys_n = 1'b1;

        pulse_trigger();
        @(posedge clk_sys);
        #1;
        if (!snapshot_busy || snapshot_ready) begin
            $display("ERROR: trigger did not start capture");
            errors = errors + 1;
        end

        // Reads are ignored until all 1024 samples have been captured.
        @(negedge clk_sys);
        read_next = 1'b1;
        @(posedge clk_sys);
        #1;
        if (read_valid) begin
            $display("ERROR: read accepted while snapshot_busy");
            errors = errors + 1;
        end
        @(negedge clk_sys);
        read_next = 1'b0;

        for (sample_index = 0; sample_index < 1024; sample_index = sample_index + 1) begin
            @(negedge clk_sys);
            sample_data = pattern(sample_index);
            sample_valid = 1'b1;
            @(posedge clk_sys);
            #1;
        end
        @(negedge clk_sys);
        sample_valid = 1'b0;
        sample_data = 32'hffffffff;
        @(posedge clk_sys);
        #1;

        if (snapshot_busy || !snapshot_ready || samples_remaining != 11'd1024) begin
            $display("ERROR: snapshot did not freeze at 1024 points: busy=%b ready=%b remaining=%0d",
                     snapshot_busy, snapshot_ready, samples_remaining);
            errors = errors + 1;
        end

        // A pending snapshot cannot be overwritten by another trigger or by
        // continued live samples.
        pulse_trigger();
        repeat (5) begin
            @(negedge clk_sys);
            sample_valid = 1'b1;
            sample_data = 32'hfeed0000 + sample_index;
            @(posedge clk_sys);
        end
        @(negedge clk_sys);
        sample_valid = 1'b0;
        @(posedge clk_sys);
        #1;
        if (snapshot_busy || !snapshot_ready || samples_remaining != 11'd1024) begin
            $display("ERROR: frozen snapshot was overwritten or restarted");
            errors = errors + 1;
        end

        for (sample_index = 0; sample_index < 1024; sample_index = sample_index + 1) begin
            read_and_check(sample_index);
            if (sample_index != 1023 &&
                samples_remaining != (11'd1023 - sample_index)) begin
                $display("ERROR: remaining count wrong after word %0d: %0d",
                         sample_index, samples_remaining);
                errors = errors + 1;
            end
        end

        @(posedge clk_sys);
        #1;
        if (snapshot_ready || snapshot_busy || samples_remaining != 11'd0) begin
            $display("ERROR: final read did not release snapshot");
            errors = errors + 1;
        end

        pulse_trigger();
        @(posedge clk_sys);
        #1;
        if (!snapshot_busy) begin
            $display("ERROR: snapshot could not be retriggered after full read");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: 1024-point capture, freeze, sequential read and retrigger verified");
        else
            $fatal(1, "FAIL: %0d snapshot checks failed", errors);
        $finish;
    end

endmodule

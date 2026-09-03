`timescale 1ns/1ps

// 1024-word raw ADC snapshot. sample_data/sample_valid must already be in the
// clk_sys domain (normally through the project async sample FIFO).
module adc_snapshot (
    input  wire                    clk_sys,
    input  wire                    rst_sys_n,

    input  wire signed [31:0]      sample_data,
    input  wire                    sample_valid,
    input  wire                    snapshot_trigger,

    input  wire                    read_next,
    output reg [31:0]              read_data,
    output reg                     read_valid,
    output reg                     snapshot_busy,
    output reg                     snapshot_ready,
    output reg [10:0]              samples_remaining
);

    (* ramstyle = "M9K" *) reg [31:0] sample_mem [0:1023];
    reg [9:0]  write_index;
    reg [9:0]  read_index;

    // Keep the memory path synchronous and free of reset logic so Quartus can
    // map the 32 kbit storage to embedded RAM. Capture and read states are
    // mutually exclusive, so one memory port is sufficient.
    always @(posedge clk_sys) begin
        if (snapshot_busy && sample_valid)
            sample_mem[write_index] <= sample_data;
        else if (snapshot_ready && read_next)
            read_data <= sample_mem[read_index];
    end

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            write_index       <= 10'd0;
            read_index        <= 10'd0;
            read_valid        <= 1'b0;
            snapshot_busy     <= 1'b0;
            snapshot_ready    <= 1'b0;
            samples_remaining <= 11'd0;
        end else begin
            read_valid <= 1'b0;

            // A trigger is accepted only when no captured image is pending.
            // The first sample captured is the first sample_valid after this
            // trigger cycle.
            if (snapshot_trigger && !snapshot_busy && !snapshot_ready) begin
                write_index       <= 10'd0;
                read_index        <= 10'd0;
                snapshot_busy     <= 1'b1;
                samples_remaining <= 11'd0;
            end else if (snapshot_busy && sample_valid) begin
                if (write_index == 10'd1023) begin
                    write_index       <= 10'd0;
                    read_index        <= 10'd0;
                    snapshot_busy     <= 1'b0;
                    snapshot_ready    <= 1'b1;
                    samples_remaining <= 11'd1024;
                end else begin
                    write_index <= write_index + 10'd1;
                end
            end else if (snapshot_ready && read_next) begin
                // Synchronous word read. read_valid marks read_data as valid
                // after this clock edge. Memory remains unchanged while read.
                read_valid <= 1'b1;
                if (samples_remaining == 11'd1) begin
                    read_index        <= 10'd0;
                    samples_remaining <= 11'd0;
                    snapshot_ready    <= 1'b0;
                end else begin
                    read_index        <= read_index + 10'd1;
                    samples_remaining <= samples_remaining - 11'd1;
                end
            end
        end
    end

endmodule

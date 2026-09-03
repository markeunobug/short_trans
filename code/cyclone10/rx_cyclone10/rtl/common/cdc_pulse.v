`default_nettype none

// Toggle based pulse synchronizer.
// src_pulse may be one source-clock cycle wide. The destination pulse is
// exactly one destination-clock cycle wide when source and destination reset
// domains are released from a common reset sequence.
module cdc_pulse #(
    parameter integer SYNC_STAGES = 2
) (
    input  wire src_clk,
    input  wire src_rst_n,
    input  wire src_pulse,
    input  wire dst_clk,
    input  wire dst_rst_n,
    output wire dst_pulse
);

    reg src_toggle;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [SYNC_STAGES-1:0] dst_sync_ff;
    reg dst_sync_d;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            src_toggle <= 1'b0;
        end else if (src_pulse) begin
            src_toggle <= ~src_toggle;
        end
    end

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_sync_ff <= {SYNC_STAGES{1'b0}};
            dst_sync_d  <= 1'b0;
        end else begin
            dst_sync_ff[0] <= src_toggle;
            dst_sync_ff[SYNC_STAGES-1:1] <= dst_sync_ff[SYNC_STAGES-2:0];
            dst_sync_d <= dst_sync_ff[SYNC_STAGES-1];
        end
    end

    assign dst_pulse = dst_sync_ff[SYNC_STAGES-1] ^ dst_sync_d;

endmodule

`default_nettype wire

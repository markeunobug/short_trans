`default_nettype none

// Asynchronous assertion and synchronous deassertion reset synchronizer.
// Each clock domain should use its own instance of this module.
module reset_sync #(
    parameter integer STAGES = 2
) (
    input  wire clk,
    input  wire arst_n,
    output wire srst_n,
    output wire srst
);

    // The parameter is intentionally constrained to two or more stages.
    // The implementation below is kept as plain Verilog-2001 so it is
    // accepted by Quartus and by the standalone ModelSim testbench.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [STAGES-1:0] sync_ff;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            sync_ff <= {STAGES{1'b0}};
        end else begin
            sync_ff[0] <= 1'b1;
            sync_ff[STAGES-1:1] <= sync_ff[STAGES-2:0];
        end
    end

    assign srst_n = sync_ff[STAGES-1];
    assign srst   = ~srst_n;

endmodule

`default_nettype wire

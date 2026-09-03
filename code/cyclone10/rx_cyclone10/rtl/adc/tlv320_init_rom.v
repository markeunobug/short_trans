`timescale 1ns/1ps
`default_nettype none

// Fixed TLV320ADC6120 page-0 initialization and readback sequence.
// See TLV320_INIT_REGISTERS.md for the data-sheet and schematic basis of
// every value. The controller interprets wait_us only for OP_WAIT entries.
module tlv320_init_rom (
    input  wire [5:0] address,
    output reg  [2:0] op,
    output reg  [7:0] reg_addr,
    output reg  [7:0] data,
    output reg  [7:0] mask,
    output reg  [15:0] wait_us
);

    localparam [2:0] OP_WRITE  = 3'd0;
    localparam [2:0] OP_VERIFY = 3'd1;
    localparam [2:0] OP_WAIT   = 3'd2;
    localparam [2:0] OP_END    = 3'd3;

    always @* begin
        op       = OP_END;
        reg_addr = 8'h00;
        data     = 8'h00;
        mask     = 8'h00;
        wait_us  = 16'd0;

        case (address)
            // SOFTWARE_RESET
            6'd0:  begin op = OP_WRITE; reg_addr = 8'h00; data = 8'h00; end
            6'd1:  begin op = OP_WRITE; reg_addr = 8'h01; data = 8'h01; end
            6'd2:  begin op = OP_WAIT;  wait_us = 16'd1000; end
            6'd3:  begin op = OP_WRITE; reg_addr = 8'h00; data = 8'h00; end

            // WAKE_UP. AVDD is 3.3 V and AREG is generated internally.
            6'd4:  begin op = OP_WRITE; reg_addr = 8'h02; data = 8'h81; end
            6'd5:  begin op = OP_WAIT;  wait_us = 16'd10000; end

            // CONFIG_CLOCK: GPIO1=MCLK, ASI master, 24.576 MHz -> 48 kHz.
            6'd6:  begin op = OP_WRITE; reg_addr = 8'h21; data = 8'hA2; end
            6'd7:  begin op = OP_WRITE; reg_addr = 8'h13; data = 8'h87; end
            6'd8:  begin op = OP_WRITE; reg_addr = 8'h14; data = 8'h44; end
            6'd9:  begin op = OP_WRITE; reg_addr = 8'h16; data = 8'h10; end

            // CONFIG_ASI: I2S, 32-bit slots, standard polarity/offset.
            6'd10: begin op = OP_WRITE; reg_addr = 8'h07; data = 8'h70; end
            6'd11: begin op = OP_WRITE; reg_addr = 8'h08; data = 8'h00; end
            6'd12: begin op = OP_WRITE; reg_addr = 8'h09; data = 8'h00; end
            6'd13: begin op = OP_WRITE; reg_addr = 8'h0B; data = 8'h00; end

            // CONFIG_CH1: differential line input, DC coupled, 0 dB,
            // DRE disabled, 0 dB digital volume, default 12-Hz HPF.
            6'd14: begin op = OP_WRITE; reg_addr = 8'h3C; data = 8'h90; end
            6'd15: begin op = OP_WRITE; reg_addr = 8'h3D; data = 8'h00; end
            6'd16: begin op = OP_WRITE; reg_addr = 8'h3E; data = 8'hC9; end
            6'd17: begin op = OP_WRITE; reg_addr = 8'h6B; data = 8'h01; end

            // POWER_UP: enable only CH1 input/output, then ADC and PLL.
            6'd18: begin op = OP_WRITE; reg_addr = 8'h73; data = 8'h80; end
            6'd19: begin op = OP_WRITE; reg_addr = 8'h74; data = 8'h80; end
            6'd20: begin op = OP_WRITE; reg_addr = 8'h75; data = 8'h60; end
            6'd21: begin op = OP_WAIT;  wait_us = 16'd10000; end

            // READBACK: writable configuration followed by live status.
            6'd22: begin op = OP_VERIFY; reg_addr = 8'h02; data = 8'h81; mask = 8'h81; end
            6'd23: begin op = OP_VERIFY; reg_addr = 8'h21; data = 8'hA2; mask = 8'hFF; end
            6'd24: begin op = OP_VERIFY; reg_addr = 8'h13; data = 8'h87; mask = 8'hFF; end
            6'd25: begin op = OP_VERIFY; reg_addr = 8'h14; data = 8'h44; mask = 8'hFF; end
            6'd26: begin op = OP_VERIFY; reg_addr = 8'h07; data = 8'h70; mask = 8'hFF; end
            6'd27: begin op = OP_VERIFY; reg_addr = 8'h0B; data = 8'h00; mask = 8'h3F; end
            6'd28: begin op = OP_VERIFY; reg_addr = 8'h3C; data = 8'h90; mask = 8'hFD; end
            6'd29: begin op = OP_VERIFY; reg_addr = 8'h3D; data = 8'h00; mask = 8'hFF; end
            6'd30: begin op = OP_VERIFY; reg_addr = 8'h3E; data = 8'hC9; mask = 8'hFF; end
            6'd31: begin op = OP_VERIFY; reg_addr = 8'h6B; data = 8'h01; mask = 8'hFF; end
            6'd32: begin op = OP_VERIFY; reg_addr = 8'h73; data = 8'h80; mask = 8'hF0; end
            6'd33: begin op = OP_VERIFY; reg_addr = 8'h74; data = 8'h80; mask = 8'hF0; end
            6'd34: begin op = OP_VERIFY; reg_addr = 8'h75; data = 8'h60; mask = 8'hFD; end
            6'd35: begin op = OP_VERIFY; reg_addr = 8'h15; data = 8'h44; mask = 8'hFF; end
            6'd36: begin op = OP_VERIFY; reg_addr = 8'h76; data = 8'h80; mask = 8'hC0; end
            6'd37: begin op = OP_VERIFY; reg_addr = 8'h77; data = 8'hE0; mask = 8'hE0; end

            6'd38: begin op = OP_END; end
            default: begin op = OP_END; end
        endcase
    end

endmodule

`default_nettype wire

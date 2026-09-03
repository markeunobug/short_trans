`timescale 1ns/1ps

// Standard I2S receiver for two 32-bit slots. WS=0 is CH1 (left).
// The transmitter changes WS one BCLK before the next slot's MSB; therefore
// the bit sampled with a WS transition is the previous slot's final bit.
module i2s_rx_ch1 (
    input  wire                    clk_i2s,
    input  wire                    rst_i2s_n,
    input  wire                    i2s_fsync,
    input  wire                    i2s_sdout,
    input  wire                    clear_errors,

    output reg signed [31:0]       sample_data,
    output reg                     sample_valid,
    output reg                     format_error,
    output reg [15:0]              format_error_count
);

    reg                            edge_armed;
    reg                            synchronized;
    reg                            fsync_d;
    reg                            active_slot;
    reg [5:0]                      bit_count;
    reg [31:0]                     shift_reg;

    wire [31:0] shifted_word = {shift_reg[30:0], i2s_sdout};

    always @(posedge clk_i2s or negedge rst_i2s_n) begin
        if (!rst_i2s_n) begin
            edge_armed        <= 1'b0;
            synchronized      <= 1'b0;
            fsync_d            <= 1'b0;
            active_slot       <= 1'b0;
            bit_count         <= 6'd0;
            shift_reg         <= 32'd0;
            sample_data       <= 32'sd0;
            sample_valid      <= 1'b0;
            format_error      <= 1'b0;
            format_error_count <= 16'd0;
        end else begin
            sample_valid <= 1'b0;

            if (clear_errors) begin
                format_error       <= 1'b0;
                format_error_count <= 16'd0;
            end

            // Ignore the static WS level immediately after reset. The first
            // real WS transition establishes a trustworthy slot boundary.
            if (!edge_armed) begin
                fsync_d     <= i2s_fsync;
                edge_armed <= 1'b1;
            end else if (!synchronized) begin
                fsync_d <= i2s_fsync;
                if (i2s_fsync != fsync_d) begin
                    synchronized <= 1'b1;
                    active_slot  <= i2s_fsync;
                    bit_count    <= 6'd0;
                    shift_reg    <= 32'd0;
                end
            end else if (bit_count < 6'd31) begin
                if (i2s_fsync != active_slot) begin
                    // WS changed before all 32 bits arrived. The current SD
                    // bit belongs to the malformed old slot and is discarded.
                    active_slot <= i2s_fsync;
                    bit_count   <= 6'd0;
                    shift_reg   <= 32'd0;
                    format_error <= 1'b1;
                    if (clear_errors)
                        format_error_count <= 16'd1;
                    else if (format_error_count != 16'hffff)
                        format_error_count <= format_error_count + 16'd1;
                end else begin
                    shift_reg <= shifted_word;
                    bit_count <= bit_count + 6'd1;
                end
            end else if (bit_count == 6'd31) begin
                shift_reg <= shifted_word;
                if (i2s_fsync != active_slot) begin
                    // Expected transition: this sampled bit is the old slot's
                    // LSB, while the next sampled bit will be the new MSB.
                    if (active_slot == 1'b0) begin
                        sample_data  <= shifted_word;
                        sample_valid <= 1'b1;
                    end
                    active_slot <= i2s_fsync;
                    bit_count   <= 6'd0;
                    shift_reg   <= 32'd0;
                end else begin
                    // No transition after 32 bits. Count this malformed slot
                    // once, then wait for an edge to re-establish alignment.
                    bit_count    <= 6'd32;
                    format_error <= 1'b1;
                    if (clear_errors)
                        format_error_count <= 16'd1;
                    else if (format_error_count != 16'hffff)
                        format_error_count <= format_error_count + 16'd1;
                end
            end else begin
                // Recovery from an overlong/lost slot. The error was already
                // counted when the expected 32-bit boundary was missed. If WS
                // remains stuck, count each additional missing 32-bit slot.
                if (i2s_fsync != active_slot) begin
                    active_slot <= i2s_fsync;
                    bit_count   <= 6'd0;
                    shift_reg   <= 32'd0;
                end else if (bit_count == 6'd63) begin
                    bit_count    <= 6'd32;
                    format_error <= 1'b1;
                    if (clear_errors)
                        format_error_count <= 16'd1;
                    else if (format_error_count != 16'hffff)
                        format_error_count <= format_error_count + 16'd1;
                end else begin
                    bit_count <= bit_count + 6'd1;
                end
            end
        end
    end

endmodule

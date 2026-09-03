`timescale 1ns/1ps
`default_nettype none

// Fixed TLV320ADC6120 initialization controller.
//
// A failure is either an I2C NACK or a masked readback mismatch. The complete
// sequence is attempted at most MAX_ATTEMPTS times. After the final failed
// attempt, init_error remains asserted until a new rising edge on reinit.
module tlv320_init_ctrl #(
    parameter integer CLK_HZ = 30000000,
    parameter integer I2C_HZ = 100000,
    parameter integer POWER_WAIT_US = 2000,
    parameter integer MAX_ATTEMPTS = 3
) (
    input  wire       clk_sys,
    input  wire       rst_sys_n,
    input  wire       reinit,

    input  wire       i2c_sda_in,
    output wire       i2c_scl_drive_low,
    output wire       i2c_sda_drive_low,

    output reg        init_busy,
    output reg        init_done,
    output reg        init_error,
    output wire       adc_data_valid,
    output reg  [1:0] attempt_count,
    output reg  [2:0] last_error_code,
    output reg  [5:0] last_failed_entry,
    output reg  [7:0] last_read_data,
    output wire [3:0] state_debug
);

    localparam [3:0] ST_POWER_WAIT     = 4'd0;
    localparam [3:0] ST_SOFTWARE_RESET = 4'd1;
    localparam [3:0] ST_WAKE_UP        = 4'd2;
    localparam [3:0] ST_CONFIG_CLOCK   = 4'd3;
    localparam [3:0] ST_CONFIG_ASI     = 4'd4;
    localparam [3:0] ST_CONFIG_CH1     = 4'd5;
    localparam [3:0] ST_POWER_UP       = 4'd6;
    localparam [3:0] ST_READBACK       = 4'd7;
    localparam [3:0] ST_RUN            = 4'd8;
    localparam [3:0] ST_ERROR          = 4'd9;

    localparam [2:0] OP_WRITE  = 3'd0;
    localparam [2:0] OP_VERIFY = 3'd1;
    localparam [2:0] OP_WAIT   = 3'd2;
    localparam [2:0] OP_END    = 3'd3;

    localparam [2:0] ERR_NONE     = 3'd0;
    localparam [2:0] ERR_I2C_NACK = 3'd1;
    localparam [2:0] ERR_READBACK = 3'd2;

    localparam integer CYCLES_PER_US_RAW = CLK_HZ / 1000000;
    localparam integer CYCLES_PER_US =
        (CYCLES_PER_US_RAW < 1) ? 1 : CYCLES_PER_US_RAW;
    localparam integer POWER_WAIT_CYCLES = POWER_WAIT_US * CYCLES_PER_US;

    reg [3:0] state;
    reg [5:0] rom_address;
    wire [2:0] rom_op;
    wire [7:0] rom_reg_addr;
    wire [7:0] rom_data;
    wire [7:0] rom_mask;
    wire [15:0] rom_wait_us;

    reg [31:0] delay_count;
    reg        delay_active;
    reg [31:0] power_wait_count;

    reg master_cmd_valid;
    reg transaction_active;
    wire master_cmd_ready;
    wire master_done;
    wire master_nack;
    wire master_busy;
    wire [7:0] master_read_data;

    reg reinit_d;
    wire reinit_pulse = reinit & ~reinit_d;

    assign adc_data_valid = init_done & ~init_error;
    assign state_debug = state;

    tlv320_init_rom u_init_rom (
        .address  (rom_address),
        .op       (rom_op),
        .reg_addr (rom_reg_addr),
        .data     (rom_data),
        .mask     (rom_mask),
        .wait_us  (rom_wait_us)
    );

    i2c_master #(
        .CLK_HZ (CLK_HZ),
        .I2C_HZ (I2C_HZ)
    ) u_i2c_master (
        .clk            (clk_sys),
        .rst_n          (rst_sys_n),
        .cmd_valid      (master_cmd_valid),
        .cmd_ready      (master_cmd_ready),
        .cmd_read       (rom_op == OP_VERIFY),
        .cmd_dev_addr   (7'h4E),
        .cmd_reg_addr   (rom_reg_addr),
        .cmd_write_data (rom_data),
        .read_data      (master_read_data),
        .done           (master_done),
        .nack           (master_nack),
        .busy           (master_busy),
        .sda_in         (i2c_sda_in),
        .scl_drive_low  (i2c_scl_drive_low),
        .sda_drive_low  (i2c_sda_drive_low)
    );

    // Advance the high-level state at fixed ROM boundaries. Keeping these
    // semantic states visible makes SignalTap bring-up much easier.
    task advance_sequence;
        begin
            delay_active <= 1'b0;
            case (rom_address)
                6'd3:  begin state <= ST_WAKE_UP;      rom_address <= 6'd4;  end
                6'd5:  begin state <= ST_CONFIG_CLOCK; rom_address <= 6'd6;  end
                6'd9:  begin state <= ST_CONFIG_ASI;   rom_address <= 6'd10; end
                6'd13: begin state <= ST_CONFIG_CH1;   rom_address <= 6'd14; end
                6'd17: begin state <= ST_POWER_UP;     rom_address <= 6'd18; end
                6'd21: begin state <= ST_READBACK;     rom_address <= 6'd22; end
                default: rom_address <= rom_address + 6'd1;
            endcase
        end
    endtask

    task fail_attempt;
        input [2:0] error_code;
        begin
            last_error_code   <= error_code;
            last_failed_entry <= rom_address;
            transaction_active <= 1'b0;
            delay_active <= 1'b0;

            if (attempt_count < MAX_ATTEMPTS) begin
                attempt_count <= attempt_count + 2'd1;
                state <= ST_POWER_WAIT;
                rom_address <= 6'd0;
                power_wait_count <= 32'd0;
                init_busy <= 1'b1;
                init_done <= 1'b0;
                init_error <= 1'b0;
            end else begin
                state <= ST_ERROR;
                init_busy <= 1'b0;
                init_done <= 1'b0;
                init_error <= 1'b1;
            end
        end
    endtask

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            state              <= ST_POWER_WAIT;
            rom_address        <= 6'd0;
            delay_count        <= 32'd0;
            delay_active       <= 1'b0;
            power_wait_count   <= 32'd0;
            master_cmd_valid   <= 1'b0;
            transaction_active <= 1'b0;
            reinit_d           <= 1'b0;
            init_busy          <= 1'b1;
            init_done          <= 1'b0;
            init_error         <= 1'b0;
            attempt_count      <= 2'd1;
            last_error_code    <= ERR_NONE;
            last_failed_entry  <= 6'd0;
            last_read_data     <= 8'd0;
        end else begin
            reinit_d <= reinit;
            master_cmd_valid <= 1'b0;

            case (state)
                ST_POWER_WAIT: begin
                    init_busy <= 1'b1;
                    init_done <= 1'b0;
                    init_error <= 1'b0;
                    transaction_active <= 1'b0;
                    delay_active <= 1'b0;

                    if (POWER_WAIT_CYCLES <= 1 ||
                        power_wait_count >= POWER_WAIT_CYCLES - 1) begin
                        power_wait_count <= 32'd0;
                        rom_address <= 6'd0;
                        state <= ST_SOFTWARE_RESET;
                    end else begin
                        power_wait_count <= power_wait_count + 32'd1;
                    end
                end

                ST_SOFTWARE_RESET,
                ST_WAKE_UP,
                ST_CONFIG_CLOCK,
                ST_CONFIG_ASI,
                ST_CONFIG_CH1,
                ST_POWER_UP,
                ST_READBACK: begin
                    init_busy <= 1'b1;
                    init_done <= 1'b0;
                    init_error <= 1'b0;

                    if (rom_op == OP_WRITE || rom_op == OP_VERIFY) begin
                        delay_active <= 1'b0;

                        if (!transaction_active && master_cmd_ready) begin
                            master_cmd_valid <= 1'b1;
                            transaction_active <= 1'b1;
                        end

                        if (transaction_active && master_done) begin
                            transaction_active <= 1'b0;
                            last_read_data <= master_read_data;

                            if (master_nack) begin
                                fail_attempt(ERR_I2C_NACK);
                            end else if (rom_op == OP_VERIFY &&
                                         ((master_read_data & rom_mask) !=
                                          (rom_data & rom_mask))) begin
                                fail_attempt(ERR_READBACK);
                            end else begin
                                advance_sequence;
                            end
                        end
                    end else if (rom_op == OP_WAIT) begin
                        transaction_active <= 1'b0;

                        if (!delay_active) begin
                            delay_count <= rom_wait_us * CYCLES_PER_US;
                            delay_active <= 1'b1;
                        end else if (delay_count <= 1) begin
                            delay_count <= 32'd0;
                            delay_active <= 1'b0;
                            advance_sequence;
                        end else begin
                            delay_count <= delay_count - 32'd1;
                        end
                    end else if (rom_op == OP_END) begin
                        state <= ST_RUN;
                        init_busy <= 1'b0;
                        init_done <= 1'b1;
                        init_error <= 1'b0;
                        transaction_active <= 1'b0;
                    end
                end

                ST_RUN: begin
                    init_busy <= 1'b0;
                    init_done <= 1'b1;
                    init_error <= 1'b0;
                    transaction_active <= 1'b0;
                    delay_active <= 1'b0;

                    if (reinit_pulse) begin
                        state <= ST_POWER_WAIT;
                        rom_address <= 6'd0;
                        power_wait_count <= 32'd0;
                        attempt_count <= 2'd1;
                        last_error_code <= ERR_NONE;
                        last_failed_entry <= 6'd0;
                        init_busy <= 1'b1;
                        init_done <= 1'b0;
                    end
                end

                ST_ERROR: begin
                    init_busy <= 1'b0;
                    init_done <= 1'b0;
                    init_error <= 1'b1;
                    transaction_active <= 1'b0;
                    delay_active <= 1'b0;

                    if (reinit_pulse) begin
                        state <= ST_POWER_WAIT;
                        rom_address <= 6'd0;
                        power_wait_count <= 32'd0;
                        attempt_count <= 2'd1;
                        last_error_code <= ERR_NONE;
                        last_failed_entry <= 6'd0;
                        init_busy <= 1'b1;
                        init_error <= 1'b0;
                    end
                end

                default: begin
                    state <= ST_ERROR;
                    init_busy <= 1'b0;
                    init_done <= 1'b0;
                    init_error <= 1'b1;
                    last_error_code <= ERR_READBACK;
                end
            endcase
        end
    end

endmodule

`default_nettype wire

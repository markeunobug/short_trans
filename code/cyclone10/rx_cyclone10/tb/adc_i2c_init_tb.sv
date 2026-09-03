`timescale 1ns/1ps

module adc_i2c_init_tb;

    localparam integer CLK_HZ = 4000000;
    localparam integer I2C_HZ = 100000;

    reg clk_sys = 1'b0;
    reg rst_sys_n = 1'b0;
    reg reinit = 1'b0;
    always #125 clk_sys = ~clk_sys;

    wire scl_drive_low;
    wire sda_drive_low;
    tri1 scl_bus;
    tri1 sda_bus;
    reg slave_sda_low = 1'b0;

    assign scl_bus = scl_drive_low ? 1'b0 : 1'bz;
    assign sda_bus = sda_drive_low ? 1'b0 : 1'bz;
    assign sda_bus = slave_sda_low ? 1'b0 : 1'bz;

    wire init_busy;
    wire init_done;
    wire init_error;
    wire adc_data_valid;
    wire [1:0] attempt_count;
    wire [2:0] last_error_code;
    wire [5:0] last_failed_entry;
    wire [7:0] last_read_data;
    wire [3:0] state_debug;

    reg [7:0] registers [0:255];
    reg [7:0] current_page = 8'd0;
    reg nack_all = 1'b0;
    reg [7:0] corrupt_reg = 8'hFF;
    integer corrupt_reads_remaining = 0;
    integer transaction_count = 0;
    integer software_reset_count = 0;
    integer errors = 0;
    integer i;

    tlv320_init_ctrl #(
        .CLK_HZ       (CLK_HZ),
        .I2C_HZ       (I2C_HZ),
        .POWER_WAIT_US(200),
        .MAX_ATTEMPTS (3)
    ) dut (
        .clk_sys             (clk_sys),
        .rst_sys_n           (rst_sys_n),
        .reinit              (reinit),
        .i2c_sda_in          (sda_bus),
        .i2c_scl_drive_low   (scl_drive_low),
        .i2c_sda_drive_low   (sda_drive_low),
        .init_busy           (init_busy),
        .init_done           (init_done),
        .init_error          (init_error),
        .adc_data_valid      (adc_data_valid),
        .attempt_count       (attempt_count),
        .last_error_code     (last_error_code),
        .last_failed_entry   (last_failed_entry),
        .last_read_data      (last_read_data),
        .state_debug         (state_debug)
    );

    task reset_registers;
        integer k;
        begin
            for (k = 0; k < 256; k = k + 1)
                registers[k] = 8'h00;
            registers[8'h07] = 8'h30;
            registers[8'h13] = 8'h02;
            registers[8'h14] = 8'h48;
            registers[8'h15] = 8'hFF;
            registers[8'h16] = 8'h10;
            registers[8'h21] = 8'h22;
            registers[8'h3C] = 8'h00;
            registers[8'h3D] = 8'h00;
            registers[8'h3E] = 8'hC9;
            registers[8'h6B] = 8'h01;
            registers[8'h73] = 8'hC0;
            registers[8'h74] = 8'h00;
            registers[8'h75] = 8'h00;
            registers[8'h76] = 8'h00;
            registers[8'h77] = 8'h80;
            current_page = 8'd0;
        end
    endtask

    task wait_start;
        begin : wait_start_block
            forever begin
                @(negedge sda_bus);
                if (scl_bus === 1'b1)
                    disable wait_start_block;
            end
        end
    endtask

    task wait_stop;
        begin : wait_stop_block
            forever begin
                @(posedge sda_bus);
                if (scl_bus === 1'b1)
                    disable wait_stop_block;
            end
        end
    endtask

    task recv_byte;
        output [7:0] value;
        integer bit_no;
        begin
            for (bit_no = 7; bit_no >= 0; bit_no = bit_no - 1) begin
                @(posedge scl_bus);
                value[bit_no] = sda_bus;
            end
        end
    endtask

    task recv_remaining_write_bits;
        output [7:0] value;
        input first_bit;
        integer bit_no;
        begin
            value[7] = first_bit;
            for (bit_no = 6; bit_no >= 0; bit_no = bit_no - 1) begin
                @(posedge scl_bus);
                value[bit_no] = sda_bus;
            end
        end
    endtask

    task slave_ack;
        input do_ack;
        begin
            @(negedge scl_bus);
            slave_sda_low = do_ack;
            @(posedge scl_bus);
            @(negedge scl_bus);
            slave_sda_low = 1'b0;
        end
    endtask

    task send_byte;
        input [7:0] value;
        integer bit_no;
        begin
            for (bit_no = 7; bit_no >= 0; bit_no = bit_no - 1) begin
                slave_sda_low = ~value[bit_no];
                @(posedge scl_bus);
                @(negedge scl_bus);
            end
            slave_sda_low = 1'b0;
            @(posedge scl_bus);
            if (sda_bus !== 1'b1) begin
                $display("ERROR: controller did not NACK a single-byte read");
                errors = errors + 1;
            end
            @(negedge scl_bus);
        end
    endtask

    task apply_write;
        input [7:0] reg_addr;
        input [7:0] value;
        begin
            if (reg_addr == 8'h00) begin
                current_page = value;
                registers[8'h00] = value;
            end else if (current_page == 8'h00 && reg_addr == 8'h01 && value[0]) begin
                software_reset_count = software_reset_count + 1;
                reset_registers();
            end else if (current_page == 8'h00) begin
                registers[reg_addr] = value;

                if (reg_addr == 8'h02 && value[0])
                    registers[8'h77] = 8'hC0;

                if (reg_addr == 8'h75 && value == 8'h60) begin
                    registers[8'h15] = 8'h44;
                    registers[8'h76] = 8'h80;
                    registers[8'h77] = 8'hE0;
                end
            end
        end
    endtask

    reg [7:0] slave_byte;
    reg [7:0] slave_reg_addr;
    reg [7:0] slave_write_data;
    reg [7:0] slave_read_data;
    reg address_ack;
    reg first_candidate_bit;
    reg repeated_start;

    initial begin : slave_model
        forever begin
            wait_start();
            transaction_count = transaction_count + 1;
            recv_byte(slave_byte);
            address_ack = !nack_all &&
                          (slave_byte[7:1] == 7'h4E) &&
                          (slave_byte[0] == 1'b0);
            slave_ack(address_ack);

            if (!address_ack) begin
                wait_stop();
            end else begin
                recv_byte(slave_reg_addr);
                slave_ack(1'b1);

                // A repeated START first raises SCL while SDA is high, then
                // pulls SDA low before SCL falls. A write-data bit remains
                // stable until the falling edge of SCL.
                @(posedge scl_bus);
                first_candidate_bit = sda_bus;
                repeated_start = 1'b0;

                if (first_candidate_bit === 1'b1) begin
                    fork : classify_after_register
                        begin
                            @(negedge sda_bus);
                            if (scl_bus === 1'b1)
                                repeated_start = 1'b1;
                        end
                        begin
                            @(negedge scl_bus);
                            repeated_start = 1'b0;
                        end
                    join_any
                    disable classify_after_register;
                end

                if (repeated_start) begin
                    recv_byte(slave_byte);
                    address_ack = !nack_all && (slave_byte == {7'h4E, 1'b1});
                    slave_ack(address_ack);
                    if (address_ack) begin
                        slave_read_data = registers[slave_reg_addr];
                        if (slave_reg_addr == corrupt_reg &&
                            corrupt_reads_remaining > 0) begin
                            slave_read_data = slave_read_data ^ 8'h01;
                            corrupt_reads_remaining = corrupt_reads_remaining - 1;
                        end
                        send_byte(slave_read_data);
                    end
                    wait_stop();
                end else begin
                    // The first data bit was sampled on the classification
                    // posedge. For a logic-one bit, the classifier already
                    // consumed the following falling edge of SCL.
                    recv_remaining_write_bits(slave_write_data,
                                              first_candidate_bit);
                    slave_ack(1'b1);
                    apply_write(slave_reg_addr, slave_write_data);
                    wait_stop();
                end
            end
        end
    end

    task pulse_reinit;
        begin
            // Drive control inputs away from the DUT sampling edge to avoid
            // a simulator scheduling race with the posedge state machine.
            @(negedge clk_sys);
            reinit = 1'b1;
            @(negedge clk_sys);
            reinit = 1'b0;
        end
    endtask

    task wait_for_done;
        input integer timeout_us;
        integer ticks;
        begin
            ticks = 0;
            while (!init_done && !init_error && ticks < timeout_us * 4) begin
                @(posedge clk_sys);
                ticks = ticks + 1;
            end
            if (!init_done && !init_error) begin
                $display("ERROR: initialization timeout, state=%0d", state_debug);
                errors = errors + 1;
            end
        end
    endtask

    task check_fixed_registers;
        begin
            if (registers[8'h02] !== 8'h81 ||
                registers[8'h21] !== 8'hA2 ||
                registers[8'h13] !== 8'h87 ||
                registers[8'h14] !== 8'h44 ||
                registers[8'h07] !== 8'h70 ||
                registers[8'h3C] !== 8'h90 ||
                registers[8'h3D] !== 8'h00 ||
                registers[8'h3E] !== 8'hC9 ||
                registers[8'h6B] !== 8'h01 ||
                registers[8'h73] !== 8'h80 ||
                registers[8'h74] !== 8'h80 ||
                registers[8'h75] !== 8'h60) begin
                $display("ERROR: fixed register image does not match the ROM");
                errors = errors + 1;
            end
        end
    endtask

    initial begin : stimulus
        reset_registers();
        repeat (8) @(posedge clk_sys);
        rst_sys_n = 1'b1;

        // Scenario 1: normal initialization.
        wait_for_done(100000);
        if (!init_done || init_error || !adc_data_valid || attempt_count != 1) begin
            $display("ERROR: normal initialization failed");
            errors = errors + 1;
        end
        check_fixed_registers();

        // Scenario 2: one readback mismatch causes a complete second attempt.
        corrupt_reg = 8'h14;
        corrupt_reads_remaining = 1;
        pulse_reinit();
        wait_for_done(180000);
        if (!init_done || init_error || attempt_count != 2 ||
            last_error_code != 3'd2 || last_failed_entry != 6'd25) begin
            $display("ERROR: retry mismatch done=%0b error=%0b attempt=%0d code=%0d entry=%0d",
                     init_done, init_error, attempt_count,
                     last_error_code, last_failed_entry);
            errors = errors + 1;
        end

        // Scenario 3: persistent address NACK fails exactly three attempts.
        nack_all = 1'b1;
        pulse_reinit();
        wait_for_done(100000);
        if (!init_error || init_done || adc_data_valid || attempt_count != 3 ||
            last_error_code != 3'd1 || last_failed_entry != 6'd0) begin
            $display("ERROR: persistent NACK did not latch ERROR on attempt 3");
            errors = errors + 1;
        end

        // Scenario 4: reinit clears the latched error and runs the fixed ROM.
        nack_all = 1'b0;
        corrupt_reg = 8'hFF;
        corrupt_reads_remaining = 0;
        pulse_reinit();
        wait_for_done(100000);
        if (!init_done || init_error || !adc_data_valid || attempt_count != 1) begin
            $display("ERROR: reinit did not recover from latched ERROR");
            errors = errors + 1;
        end
        check_fixed_registers();

        // Address-level NACK attempts cannot reach the software-reset data
        // write. The observable resets are: normal run (1), readback retry
        // scenario (2), and recovery after latched error (1).
        if (software_reset_count != 4) begin
            $display("ERROR: expected 4 completed software resets, got %0d",
                     software_reset_count);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: adc_i2c_init_tb transactions=%0d resets=%0d",
                     transaction_count, software_reset_count);
        else
            $fatal(1, "FAIL: adc_i2c_init_tb errors=%0d", errors);

        #1000;
        $finish;
    end

    initial begin
        #500000000;
        $fatal(1, "FAIL: adc_i2c_init_tb global timeout");
    end

endmodule

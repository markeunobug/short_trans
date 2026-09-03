`timescale 1ns/1ps

module adc_i2c_master_tb;

    localparam integer CLK_HZ = 4000000;
    localparam integer I2C_HZ = 100000;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #125 clk = ~clk;

    reg        cmd_valid = 1'b0;
    wire       cmd_ready;
    reg        cmd_read = 1'b0;
    reg [6:0]  cmd_dev_addr = 7'h4E;
    reg [7:0]  cmd_reg_addr = 8'd0;
    reg [7:0]  cmd_write_data = 8'd0;
    wire [7:0] read_data;
    wire       done;
    wire       nack;
    wire       busy;
    wire       scl_drive_low;
    wire       sda_drive_low;

    tri1 scl_bus;
    tri1 sda_bus;
    reg slave_sda_low = 1'b0;

    assign scl_bus = scl_drive_low ? 1'b0 : 1'bz;
    assign sda_bus = sda_drive_low ? 1'b0 : 1'bz;
    assign sda_bus = slave_sda_low ? 1'b0 : 1'bz;

    reg [7:0] registers [0:255];
    reg expected_read_mode = 1'b0;
    reg nack_next_address = 1'b0;
    integer start_count = 0;
    integer stop_count = 0;
    integer errors = 0;
    integer i;

    i2c_master #(
        .CLK_HZ (CLK_HZ),
        .I2C_HZ (I2C_HZ)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .cmd_valid      (cmd_valid),
        .cmd_ready      (cmd_ready),
        .cmd_read       (cmd_read),
        .cmd_dev_addr   (cmd_dev_addr),
        .cmd_reg_addr   (cmd_reg_addr),
        .cmd_write_data (cmd_write_data),
        .read_data      (read_data),
        .done           (done),
        .nack           (nack),
        .busy           (busy),
        .sda_in         (sda_bus),
        .scl_drive_low  (scl_drive_low),
        .sda_drive_low  (sda_drive_low)
    );

    task wait_start;
        begin : wait_start_block
            forever begin
                @(negedge sda_bus);
                if (scl_bus === 1'b1) begin
                    start_count = start_count + 1;
                    disable wait_start_block;
                end
            end
        end
    endtask

    task wait_stop;
        begin : wait_stop_block
            forever begin
                @(posedge sda_bus);
                if (scl_bus === 1'b1) begin
                    stop_count = stop_count + 1;
                    disable wait_stop_block;
                end
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

            // The master must NACK the only byte in a single-byte read.
            @(posedge scl_bus);
            if (sda_bus !== 1'b1) begin
                $display("ERROR: master did not NACK the read byte");
                errors = errors + 1;
            end
            @(negedge scl_bus);
        end
    endtask

    reg [7:0] slave_byte;
    reg [7:0] slave_reg_addr;
    reg       address_ack;

    initial begin : slave_model
        forever begin
            wait_start();
            recv_byte(slave_byte);
            address_ack = !nack_next_address &&
                          (slave_byte[7:1] == 7'h4E) &&
                          (slave_byte[0] == 1'b0);
            slave_ack(address_ack);
            nack_next_address = 1'b0;

            if (!address_ack) begin
                wait_stop();
            end else begin
                recv_byte(slave_reg_addr);
                slave_ack(1'b1);

                if (expected_read_mode) begin
                    wait_start();
                    recv_byte(slave_byte);
                    address_ack = (slave_byte == {7'h4E, 1'b1});
                    slave_ack(address_ack);
                    if (address_ack)
                        send_byte(registers[slave_reg_addr]);
                    wait_stop();
                end else begin
                    recv_byte(slave_byte);
                    registers[slave_reg_addr] = slave_byte;
                    slave_ack(1'b1);
                    wait_stop();
                end
            end
        end
    end

    task issue_command;
        input do_read;
        input [7:0] reg_addr;
        input [7:0] write_value;
        begin
            expected_read_mode = do_read;
            @(posedge clk);
            while (!cmd_ready)
                @(posedge clk);
            cmd_read = do_read;
            cmd_reg_addr = reg_addr;
            cmd_write_data = write_value;
            cmd_valid = 1'b1;
            @(posedge clk);
            cmd_valid = 1'b0;
            wait(done === 1'b1);
            @(posedge clk);
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            if (scl_drive_low && scl_bus !== 1'b0) begin
                $display("ERROR: SCL drive-low did not pull the bus low");
                errors = errors + 1;
            end
            if (sda_drive_low && sda_bus !== 1'b0) begin
                $display("ERROR: SDA drive-low did not pull the bus low");
                errors = errors + 1;
            end
        end
    end

    initial begin : stimulus
        for (i = 0; i < 256; i = i + 1)
            registers[i] = 8'd0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        issue_command(1'b0, 8'h55, 8'hA6);
        if (nack || registers[8'h55] !== 8'hA6) begin
            $display("ERROR: single-byte write failed");
            errors = errors + 1;
        end

        issue_command(1'b1, 8'h55, 8'h00);
        if (nack || read_data !== 8'hA6) begin
            $display("ERROR: single-byte read failed, got %02h", read_data);
            errors = errors + 1;
        end

        nack_next_address = 1'b1;
        issue_command(1'b0, 8'h22, 8'h5A);
        if (!nack) begin
            $display("ERROR: address NACK was not reported");
            errors = errors + 1;
        end

        if (busy || scl_bus !== 1'b1 || sda_bus !== 1'b1) begin
            $display("ERROR: bus was not released after the final STOP");
            errors = errors + 1;
        end

        if (start_count != 4 || stop_count != 3) begin
            $display("ERROR: unexpected START/STOP count: starts=%0d stops=%0d",
                     start_count, stop_count);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: adc_i2c_master_tb");
        else
            $fatal(1, "FAIL: adc_i2c_master_tb errors=%0d", errors);

        #1000;
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "FAIL: adc_i2c_master_tb timeout");
    end

endmodule

`timescale 1ns/1ps

module spi_task7_tb;

    localparam integer SPI_HALF_NS = 500;

    reg clk_sys = 1'b0;
    reg rst_sys_n = 1'b0;
    always #17 clk_sys = ~clk_sys;

    reg spi_sck = 1'b0;
    reg spi_nss = 1'b1;
    reg spi_mosi = 1'b0;
    wire spi_miso;

    wire [6:0] bus_address;
    wire bus_read_strobe;
    wire [7:0] bus_read_data;
    wire bus_write_strobe;
    wire [7:0] bus_write_data;
    wire spi_protocol_error;

    reg adc_init_done = 1'b1;
    reg adc_init_error = 1'b0;
    reg carrier_detected = 1'b1;
    reg symbol_locked = 1'b1;
    reg i2c_error = 1'b0;
    reg i2s_error = 1'b0;
    reg cdc_error = 1'b0;
    reg protocol_error = 1'b0;
    reg [15:0] crc_error_count = 16'h1234;
    reg [15:0] last_soft_metric = 16'h89AB;
    reg [7:0] last_energy_f0 = 8'h31;
    reg [7:0] last_energy_f1 = 8'h42;
    reg [7:0] last_confidence = 8'h53;

    reg frame_valid = 1'b0;
    reg [7:0] frame_version_type = 8'd0;
    reg [7:0] frame_sequence = 8'd0;
    reg [7:0] frame_payload_length = 8'd0;
    reg frame_payload_valid = 1'b0;
    reg [7:0] frame_payload_data = 8'd0;
    reg frame_payload_last = 1'b0;

    reg signed [31:0] sample_data = 32'sd0;
    reg sample_valid = 1'b0;
    wire snapshot_trigger;
    wire snapshot_read_next;
    wire [31:0] snapshot_read_data;
    wire snapshot_read_valid;
    wire snapshot_busy;
    wire snapshot_ready;
    wire [10:0] snapshot_samples_remaining;

    wire clear_errors_pulse;
    wire adc_reinit_pulse;
    wire [4:0] sample_shift;
    wire [7:0] energy_margin;
    wire [7:0] confidence_threshold;

    integer failures = 0;
    integer index;
    integer word_index;
    reg [7:0] rx_byte;
    reg [7:0] dummy_byte;
    reg [7:0] expected_byte;
    reg [31:0] expected_word;

    spi1_slave u_spi1_slave (
        .clk_sys            (clk_sys),
        .rst_sys_n          (rst_sys_n),
        .spi_sck            (spi_sck),
        .spi_nss            (spi_nss),
        .spi_mosi           (spi_mosi),
        .spi_miso           (spi_miso),
        .bus_address        (bus_address),
        .bus_read_strobe    (bus_read_strobe),
        .bus_read_data      (bus_read_data),
        .bus_write_strobe   (bus_write_strobe),
        .bus_write_data     (bus_write_data),
        .spi_protocol_error (spi_protocol_error)
    );

    spi_register_bank u_spi_register_bank (
        .clk_sys                    (clk_sys),
        .rst_sys_n                  (rst_sys_n),
        .bus_address               (bus_address),
        .bus_read_strobe           (bus_read_strobe),
        .bus_read_data             (bus_read_data),
        .bus_write_strobe          (bus_write_strobe),
        .bus_write_data            (bus_write_data),
        .spi_protocol_error        (spi_protocol_error),
        .adc_init_done             (adc_init_done),
        .adc_init_error            (adc_init_error),
        .carrier_detected          (carrier_detected),
        .symbol_locked             (symbol_locked),
        .i2c_error                 (i2c_error),
        .i2s_error                 (i2s_error),
        .cdc_error                 (cdc_error),
        .protocol_error            (protocol_error),
        .crc_error_count           (crc_error_count),
        .last_soft_metric          (last_soft_metric),
        .last_energy_f0            (last_energy_f0),
        .last_energy_f1            (last_energy_f1),
        .last_confidence           (last_confidence),
        .frame_valid               (frame_valid),
        .frame_version_type        (frame_version_type),
        .frame_sequence            (frame_sequence),
        .frame_payload_length      (frame_payload_length),
        .frame_payload_valid       (frame_payload_valid),
        .frame_payload_data        (frame_payload_data),
        .frame_payload_last        (frame_payload_last),
        .snapshot_busy             (snapshot_busy),
        .snapshot_ready            (snapshot_ready),
        .snapshot_samples_remaining(snapshot_samples_remaining),
        .snapshot_read_data        (snapshot_read_data),
        .snapshot_read_valid       (snapshot_read_valid),
        .snapshot_read_next        (snapshot_read_next),
        .clear_errors_pulse        (clear_errors_pulse),
        .adc_reinit_pulse          (adc_reinit_pulse),
        .snapshot_start_pulse      (snapshot_trigger),
        .sample_shift              (sample_shift),
        .energy_margin             (energy_margin),
        .confidence_threshold      (confidence_threshold)
    );

    adc_snapshot u_adc_snapshot (
        .clk_sys           (clk_sys),
        .rst_sys_n         (rst_sys_n),
        .sample_data       (sample_data),
        .sample_valid      (sample_valid),
        .snapshot_trigger  (snapshot_trigger),
        .read_next         (snapshot_read_next),
        .read_data         (snapshot_read_data),
        .read_valid        (snapshot_read_valid),
        .snapshot_busy     (snapshot_busy),
        .snapshot_ready    (snapshot_ready),
        .samples_remaining (snapshot_samples_remaining)
    );

    task automatic check_byte;
        input [7:0] actual;
        input [7:0] expected;
        input [8*48-1:0] label_text;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s expected=%02x actual=%02x at %0t",
                         label_text, expected, actual, $time);
                failures = failures + 1;
            end
        end
    endtask

    task automatic spi_begin;
        begin
            spi_sck = 1'b0;
            spi_mosi = 1'b0;
            spi_nss = 1'b0;
            #200;
        end
    endtask

    task automatic spi_end;
        begin
            #100;
            spi_nss = 1'b1;
            spi_sck = 1'b0;
            spi_mosi = 1'b0;
            #250;
            if (spi_miso !== 1'bz) begin
                $display("FAIL: MISO is not high impedance while NSS is high");
                failures = failures + 1;
            end
        end
    endtask

    task automatic spi_transfer;
        input [7:0] tx_data;
        output [7:0] rx_data;
        integer bit_index;
        begin
            rx_data = 8'd0;
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                spi_mosi = tx_data[bit_index];
                #SPI_HALF_NS;
                spi_sck = 1'b1;
                #1;
                rx_data[bit_index] = spi_miso;
                #499;
                spi_sck = 1'b0;
            end
        end
    endtask

    task automatic spi_read_one;
        input [6:0] address;
        output [7:0] value;
        begin
            spi_begin();
            spi_transfer({1'b1, address}, dummy_byte);
            spi_transfer(8'd0, value);
            spi_end();
        end
    endtask

    task automatic spi_write_one;
        input [6:0] address;
        input [7:0] value;
        begin
            spi_begin();
            spi_transfer({1'b0, address}, dummy_byte);
            spi_transfer(value, dummy_byte);
            spi_end();
        end
    endtask

    task automatic inject_frame;
        input [7:0] version_type;
        input [7:0] sequence_value;
        input integer length;
        input [7:0] payload_base;
        integer payload_index;
        begin
            @(negedge clk_sys);
            frame_version_type = version_type;
            frame_sequence = sequence_value;
            frame_payload_length = length[7:0];
            frame_valid = 1'b1;
            @(negedge clk_sys);
            frame_valid = 1'b0;
            for (payload_index = 0; payload_index < length; payload_index = payload_index + 1) begin
                frame_payload_valid = 1'b1;
                frame_payload_data = payload_base + payload_index[7:0];
                frame_payload_last = (payload_index == length - 1);
                @(negedge clk_sys);
            end
            frame_payload_valid = 1'b0;
            frame_payload_last = 1'b0;
            frame_payload_data = 8'd0;
            repeat (3) @(negedge clk_sys);
        end
    endtask

    initial begin
        repeat (8) @(posedge clk_sys);
        rst_sys_n = 1'b1;
        repeat (8) @(posedge clk_sys);

        if (spi_miso !== 1'bz) begin
            $display("FAIL: MISO reset/deselected state is not Z");
            failures = failures + 1;
        end

        // Device identity and normal-register auto increment.
        spi_begin();
        spi_transfer(8'h80, dummy_byte);
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'hA7, "DEVICE_ID");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h10, "FW_VERSION");
        spi_end();

        spi_begin();
        spi_transfer(8'h11, dummy_byte);
        spi_transfer(8'h07, dummy_byte);
        spi_transfer(8'h34, dummy_byte);
        spi_transfer(8'h56, dummy_byte);
        spi_end();
        spi_begin();
        spi_transfer(8'h91, dummy_byte);
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h07, "SAMPLE_SHIFT R/W");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h34, "ENERGY_MARGIN R/W");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h56, "CONF_THRESHOLD R/W");
        spi_end();

        // Diagnostic auto increment and byte ordering.
        spi_begin();
        spi_transfer(8'hA0, dummy_byte);
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'hAB, "LAST_SOFT_L");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h89, "LAST_SOFT_H");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h31, "LAST_ENERGY_0");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h42, "LAST_ENERGY_1");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h53, "LAST_CONFIDENCE");
        spi_end();

        // Two frames prove descriptor atomicity and segmented RX_DATA reads.
        inject_frame(8'h12, 8'h21, 4, 8'hA1);
        inject_frame(8'h13, 8'h22, 3, 8'hB1);
        spi_begin();
        spi_transfer(8'h84, dummy_byte);
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h02, "FRAME_COUNT two frames");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h12, "HEAD_VERSION_TYPE first");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h21, "HEAD_SEQUENCE first");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h04, "HEAD_LENGTH first");
        spi_end();

        spi_begin();
        spi_transfer(8'hC0, dummy_byte);
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'hA1, "RX_DATA segment 1 byte 0");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'hA2, "RX_DATA segment 1 byte 1");
        spi_end();
        spi_begin();
        spi_transfer(8'hC0, dummy_byte);
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'hA3, "RX_DATA segment 2 byte 0");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'hA4, "RX_DATA segment 2 byte 1");
        spi_end();
        spi_write_one(7'h10, 8'h08);

        spi_begin();
        spi_transfer(8'h84, dummy_byte);
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h01, "FRAME_COUNT after POP");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h13, "HEAD_VERSION_TYPE second");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h22, "HEAD_SEQUENCE second");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h03, "HEAD_LENGTH second");
        spi_end();
        spi_read_one(7'h40, rx_byte);
        check_byte(rx_byte, 8'hB1, "RX_DATA before DROP");
        spi_write_one(7'h10, 8'h10);
        spi_read_one(7'h04, rx_byte);
        check_byte(rx_byte, 8'h00, "FRAME_COUNT after DROP");

        // Zero-length frames require no RX_DATA access before POP.
        inject_frame(8'h14, 8'h23, 0, 8'h00);
        spi_read_one(7'h07, rx_byte);
        check_byte(rx_byte, 8'h00, "zero length metadata");
        spi_write_one(7'h10, 8'h08);
        spi_read_one(7'h04, rx_byte);
        check_byte(rx_byte, 8'h00, "zero length POP");

        // Fill all 256 payload bytes. The next frame must be discarded while
        // all four old descriptors and bytes remain intact.
        inject_frame(8'h20, 8'h30, 64, 8'h00);
        inject_frame(8'h20, 8'h31, 64, 8'h40);
        inject_frame(8'h20, 8'h32, 64, 8'h80);
        inject_frame(8'h20, 8'h33, 64, 8'hC0);
        inject_frame(8'h20, 8'h34, 1, 8'hEE);
        spi_read_one(7'h04, rx_byte);
        check_byte(rx_byte, 8'h04, "overflow preserves four old frames");
        spi_begin();
        spi_transfer(8'h88, dummy_byte);
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h00, "RX level low at 256");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h01, "RX level high at 256");
        spi_end();
        spi_read_one(7'h03, rx_byte);
        if (!rx_byte[4]) begin
            $display("FAIL: FIFO overflow flag was not set");
            failures = failures + 1;
        end
        repeat (4)
            spi_write_one(7'h10, 8'h10);
        spi_read_one(7'h04, rx_byte);
        check_byte(rx_byte, 8'h00, "all full frames dropped");
        spi_write_one(7'h10, 8'h01);

        // Snapshot capture and complete continuous byte-stream read.
        spi_write_one(7'h10, 8'h04);
        wait (snapshot_busy);
        for (index = 0; index < 1024; index = index + 1) begin
            @(negedge clk_sys);
            sample_data = 32'h10000000 + index;
            sample_valid = 1'b1;
        end
        @(negedge clk_sys);
        sample_valid = 1'b0;
        wait (snapshot_ready);
        repeat (20) @(posedge clk_sys);

        spi_begin();
        spi_transfer(8'hB0, dummy_byte);
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h00, "snapshot count low 1024");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h04, "snapshot count high 1024");
        spi_end();

        spi_begin();
        spi_transfer(8'hC1, dummy_byte);
        for (index = 0; index < 4096; index = index + 1) begin
            spi_transfer(8'h00, rx_byte);
            word_index = index / 4;
            expected_word = 32'h10000000 + word_index;
            case (index % 4)
                0: expected_byte = expected_word[31:24];
                1: expected_byte = expected_word[23:16];
                2: expected_byte = expected_word[15:8];
                default: expected_byte = expected_word[7:0];
            endcase
            if (rx_byte !== expected_byte) begin
                $display("FAIL: snapshot byte %0d expected=%02x actual=%02x",
                         index, expected_byte, rx_byte);
                failures = failures + 1;
            end
        end
        spi_end();
        spi_begin();
        spi_transfer(8'hB0, dummy_byte);
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h00, "snapshot count low empty");
        spi_transfer(8'h00, rx_byte);
        check_byte(rx_byte, 8'h00, "snapshot count high empty");
        spi_end();

        // Incomplete byte transaction sets the SPI protocol error sticky bit.
        spi_begin();
        for (index = 7; index >= 4; index = index - 1) begin
            spi_mosi = 1'b1;
            #SPI_HALF_NS;
            spi_sck = 1'b1;
            #SPI_HALF_NS;
            spi_sck = 1'b0;
        end
        spi_end();
        spi_read_one(7'h03, rx_byte);
        if (!rx_byte[2]) begin
            $display("FAIL: partial SPI byte did not set protocol error");
            failures = failures + 1;
        end

        if (failures == 0)
            $display("spi_task7_tb: PASS");
        else
            $display("spi_task7_tb: FAIL (%0d checks)", failures);

        $finish;
    end

endmodule

`timescale 1ns/1ps
`default_nettype none

// Wire-level SPI regression for the Mode-2 OOK register transaction contract.
// This intentionally instantiates the production slave and register bank; all
// dynamic signals below are real register-bank inputs, not mock registers.
module ook_spi_config_tb;
    localparam integer SPI_HALF_NS = 500;
    reg clk_sys = 1'b0;
    reg rst_sys_n = 1'b0;
    always #17 clk_sys = ~clk_sys;

    reg spi_sck = 1'b0, spi_nss = 1'b1, spi_mosi = 1'b0;
    wire spi_miso;
    wire [6:0] bus_address;
    wire bus_read_preload, bus_read_strobe, bus_write_strobe, spi_protocol_error;
    wire [7:0] bus_read_data, bus_write_data;

    reg rx_busy = 1'b0, sweep_active = 1'b0;
    reg [31:0] ook_energy = 32'h11223344;
    reg change_energy_on_preload = 1'b0;
    wire clear_errors_pulse, adc_reinit_pulse, snapshot_start_pulse;
    wire sweep_start_pulse, sweep_abort_pulse, snapshot_read_next, config_apply_pulse;
    wire [4:0] sample_shift;
    wire [7:0] energy_margin, confidence_threshold, sweep_average_count;
    wire [15:0] noise_offset, sweep_settle_samples, sweep_window_samples;
    wire [31:0] sweep_phase_increment, ask_low_active, ask_high_active;
    wire [1:0] rx_mode_active;
    integer failures = 0;
    reg [7:0] rx_byte, ignored;
    reg [31:0] read_u32;

    // Changes the source on the preload edge. The register bank must still
    // return the pre-edge value throughout this transaction.
    always @(posedge clk_sys) begin
        if (change_energy_on_preload && bus_read_preload)
            ook_energy <= 32'haabbccdd;
    end

    spi1_slave u_spi1 (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n), .spi_sck(spi_sck),
        .spi_nss(spi_nss), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .bus_address(bus_address), .bus_read_preload(bus_read_preload),
        .bus_read_strobe(bus_read_strobe), .bus_read_data(bus_read_data),
        .bus_write_strobe(bus_write_strobe), .bus_write_data(bus_write_data),
        .spi_protocol_error(spi_protocol_error)
    );

    spi_register_bank u_bank (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n), .bus_address(bus_address),
        .bus_read_preload(bus_read_preload), .bus_read_strobe(bus_read_strobe),
        .bus_read_data(bus_read_data), .bus_write_strobe(bus_write_strobe),
        .bus_write_data(bus_write_data), .spi_protocol_error(spi_protocol_error),
        .adc_init_done(1'b1), .adc_init_error(1'b0), .carrier_detected(1'b0),
        .symbol_locked(1'b0), .i2c_error(1'b0), .i2s_error(1'b0), .cdc_error(1'b0),
        .protocol_error(1'b0), .crc_error_count(16'd0), .last_soft_metric(16'd0),
        .last_energy_f0(8'd0), .last_energy_f1(8'd0), .last_confidence(8'd0),
        .rx_busy(rx_busy), .ook_energy(ook_energy), .ook_hard_bit(1'b0),
        .ook_symbol_locked(1'b0), .ook_energy_ready(1'b1),
        .sweep_active(sweep_active), .sweep_busy(1'b0), .sweep_done(1'b0),
        .sweep_error(1'b0), .sweep_energy_sum(64'd0), .sweep_energy_min(32'd0),
        .sweep_energy_max(32'd0), .sweep_clip_count(32'd0), .sweep_window_count(8'd0),
        .frame_valid(1'b0), .frame_version_type(8'd0), .frame_sequence(8'd0),
        .frame_payload_length(8'd0), .frame_timestamp(32'd0),
        .frame_timestamp_valid(1'b0), .frame_is_time_base(1'b0),
        .frame_payload_valid(1'b0), .frame_payload_data(8'd0), .frame_payload_last(1'b0),
        .snapshot_busy(1'b0), .snapshot_ready(1'b0), .snapshot_samples_remaining(11'd0),
        .snapshot_read_data(32'd0), .snapshot_read_valid(1'b0), .snapshot_read_next(snapshot_read_next),
        .clear_errors_pulse(clear_errors_pulse), .adc_reinit_pulse(adc_reinit_pulse),
        .snapshot_start_pulse(snapshot_start_pulse), .sweep_start_pulse(sweep_start_pulse),
        .sweep_abort_pulse(sweep_abort_pulse), .sample_shift(sample_shift),
        .energy_margin(energy_margin), .noise_offset(noise_offset),
        .confidence_threshold(confidence_threshold), .sweep_phase_increment(sweep_phase_increment),
        .sweep_settle_samples(sweep_settle_samples), .sweep_window_samples(sweep_window_samples),
        .sweep_average_count(sweep_average_count), .rx_mode_active(rx_mode_active),
        .ask_low_active(ask_low_active), .ask_high_active(ask_high_active),
        .config_apply_pulse(config_apply_pulse)
    );

    task automatic check_byte(input [7:0] actual, input [7:0] expected, input [8*64-1:0] label_text);
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s expected=%02x actual=%02x at %0t", label_text, expected, actual, $time);
                failures = failures + 1;
            end
        end
    endtask
    task automatic check_u32(input [31:0] actual, input [31:0] expected, input [8*64-1:0] label_text);
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s expected=%08x actual=%08x at %0t", label_text, expected, actual, $time);
                failures = failures + 1;
            end
        end
    endtask
    task automatic spi_begin; begin spi_sck=0; spi_mosi=0; spi_nss=0; #200; end endtask
    task automatic spi_end; begin #100; spi_nss=1; spi_sck=0; spi_mosi=0; #250; end endtask
    task automatic spi_transfer(input [7:0] tx_data, output [7:0] rx_data);
        integer bit_index;
        begin
            rx_data = 0;
            for (bit_index=7; bit_index>=0; bit_index=bit_index-1) begin
                spi_mosi=tx_data[bit_index]; #SPI_HALF_NS; spi_sck=1; #1;
                rx_data[bit_index]=spi_miso; #499; spi_sck=0;
            end
        end
    endtask
    task automatic spi_write_one(input [6:0] address, input [7:0] value);
        begin spi_begin; spi_transfer({1'b0,address}, ignored); spi_transfer(value, ignored); spi_end; end
    endtask
    task automatic spi_read_one(input [6:0] address, output [7:0] value);
        begin spi_begin; spi_transfer({1'b1,address}, ignored); spi_transfer(0, value); spi_end; end
    endtask
    task automatic spi_write_u32(input [6:0] address, input [31:0] value);
        begin
            spi_begin; spi_transfer({1'b0,address}, ignored);
            spi_transfer(value[7:0], ignored); spi_transfer(value[15:8], ignored);
            spi_transfer(value[23:16], ignored); spi_transfer(value[31:24], ignored); spi_end;
        end
    endtask
    task automatic spi_read_u32(input [6:0] address, output [31:0] value);
        reg [7:0] b0,b1,b2,b3;
        begin
            spi_begin; spi_transfer({1'b1,address}, ignored);
            spi_transfer(0,b0); spi_transfer(0,b1); spi_transfer(0,b2); spi_transfer(0,b3); spi_end;
            value={b3,b2,b1,b0};
        end
    endtask
    task automatic stage(input [7:0] mode, input [31:0] low, input [31:0] high);
        begin spi_write_one(7'h65,mode); spi_write_u32(7'h66,low); spi_write_u32(7'h6a,high); end
    endtask
    task automatic read_status(output [7:0] status); begin spi_read_one(7'h6f,status); end endtask
    task automatic wait_apply;
        integer wait_cycles;
        begin
            for (wait_cycles=0; wait_cycles<20; wait_cycles=wait_cycles+1) @(posedge clk_sys);
        end
    endtask
    task automatic spi_read_energy_change_after_preload(output [31:0] value);
        reg [7:0] b0,b1,b2,b3;
        begin
            spi_begin;
            change_energy_on_preload = 1'b1;
            spi_transfer(8'hf8, ignored);
            spi_transfer(0,b0); spi_transfer(0,b1); spi_transfer(0,b2); spi_transfer(0,b3);
            spi_end;
            change_energy_on_preload = 1'b0;
            value={b3,b2,b1,b0};
        end
    endtask

    initial begin
        repeat (8) @(posedge clk_sys); rst_sys_n=1; repeat (8) @(posedge clk_sys);
        check_byte(rx_mode_active, 8'd1, "reset active FSK");
        check_u32(ask_low_active, 32'd400, "reset low");
        check_u32(ask_high_active, 32'd600, "reset high");

        // Pending snapshots its original shadows. Later shadow edits cannot alter it.
        rx_busy=1;
        stage(8'd2,32'h11223344,32'h55667788); spi_write_one(7'h6e,8'h01); read_status(rx_byte);
        check_byte(rx_byte & 8'h01,8'h01,"pending while RX busy");
        stage(8'd1,32'h01020304,32'h05060708);
        check_byte(rx_mode_active,8'd1,"active held while pending");
        rx_busy=0; wait_apply;
        check_byte(rx_mode_active,8'd2,"pending mode snapshot applied");
        check_u32(ask_low_active,32'h11223344,"pending low snapshot applied");
        check_u32(ask_high_active,32'h55667788,"pending high snapshot applied");
        spi_read_one(7'h7e,rx_byte); check_byte(rx_byte,8'd1,"generation after first apply");

        // Invalid mode rejects, and global CLEAR_ERRORS does not hide config error.
        stage(8'd5,32'd10,32'd20); spi_write_one(7'h6e,8'h01); read_status(rx_byte);
        check_byte(rx_byte & 8'h02,8'h02,"invalid mode sticky error");
        spi_write_one(7'h10,8'h01); read_status(rx_byte);
        check_byte(rx_byte & 8'h02,8'h02,"global clear preserves config error");
        spi_write_one(7'h6e,8'h02); read_status(rx_byte);
        check_byte(rx_byte & 8'h02,8'h00,"ASK control clears config error");

        // Equal thresholds are rejected.
        stage(8'd1,32'h00000099,32'h00000099); spi_write_one(7'h6e,8'h01); read_status(rx_byte);
        check_byte(rx_byte & 8'h02,8'h02,"equal thresholds rejected");
        spi_write_one(7'h6e,8'h02);

        // Sweep prevents apply until it ends, then applies the committed snapshot.
        sweep_active=1;
        stage(8'd1,32'h00000190,32'h00000258); spi_write_one(7'h6e,8'h01); wait_apply; read_status(rx_byte);
        check_byte(rx_byte & 8'h09,8'h09,"pending held during sweep");
        check_byte(rx_mode_active,8'd2,"active held during sweep");
        sweep_active=0; wait_apply;
        check_byte(rx_mode_active,8'd1,"sweep-released apply mode");
        check_u32(ask_low_active,32'h00000190,"sweep-released low");
        check_u32(ask_high_active,32'h00000258,"sweep-released high");
        spi_read_one(7'h7e,rx_byte); check_byte(rx_byte,8'd2,"generation after sweep apply");

        // 0x78 latches exactly at SPI read preload, before this source change.
        ook_energy=32'h11223344;
        spi_read_energy_change_after_preload(read_u32);
        check_u32(read_u32,32'h11223344,"ASK energy coherent preload latch");

        if (failures == 0) $display("ook_spi_config_tb: PASS");
        else $display("ook_spi_config_tb: FAIL (%0d checks)",failures);
        $finish;
    end
endmodule

`default_nettype wire

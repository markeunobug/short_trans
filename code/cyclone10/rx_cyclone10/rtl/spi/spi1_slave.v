`timescale 1ns/1ps
`default_nettype none

// SPI Mode 0 slave front-end, sampled by the 30 MHz system clock.
//
// The external SPI pins are asynchronous to clk_sys. Three-stage sampling and
// edge detection form the CDC boundary; all byte-level register transactions
// are emitted in clk_sys. This architecture is intended for the frozen V1.0
// rate of approximately 1 MHz and requires clk_sys to be at least 12 times SCK.
module spi1_slave (
    input  wire       clk_sys,
    input  wire       rst_sys_n,

    input  wire       spi_sck,
    input  wire       spi_nss,
    input  wire       spi_mosi,
    output wire       spi_miso,

    output reg  [6:0] bus_address,
    output reg        bus_read_strobe,
    input  wire [7:0] bus_read_data,
    output reg        bus_write_strobe,
    output reg  [7:0] bus_write_data,
    output reg        spi_protocol_error
);

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg sck_meta;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg sck_sync;
    reg sck_prev;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg nss_meta;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg nss_sync;
    reg nss_prev;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg mosi_meta;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg mosi_sync;

    reg [7:0] rx_shift;
    reg [7:0] tx_shift;
    reg [2:0] bit_count;
    reg       command_seen;
    reg       read_mode;
    reg [6:0] current_address;
    reg       read_load_pending;
    reg       tx_byte_loaded;
    reg       miso_value;

    wire sck_rise;
    wire sck_fall;
    wire nss_fall;
    wire nss_rise;
    wire [7:0] assembled_byte;
    wire [6:0] next_read_address;

    assign sck_rise = sck_sync && !sck_prev;
    assign sck_fall = !sck_sync && sck_prev;
    assign nss_fall = !nss_sync && nss_prev;
    assign nss_rise = nss_sync && !nss_prev;
    assign assembled_byte = {rx_shift[6:0], mosi_sync};
    assign next_read_address = ((current_address == 7'h40) ||
                                (current_address == 7'h41)) ?
                               current_address : current_address + 1'b1;

    // Raw NSS controls the output enable so deselection cannot be delayed by
    // the synchronizer. The data value itself is generated in clk_sys.
    assign spi_miso = spi_nss ? 1'bz : miso_value;

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            sck_meta  <= 1'b0;
            sck_sync  <= 1'b0;
            sck_prev  <= 1'b0;
            nss_meta  <= 1'b1;
            nss_sync  <= 1'b1;
            nss_prev  <= 1'b1;
            mosi_meta <= 1'b0;
            mosi_sync <= 1'b0;
        end else begin
            sck_meta  <= spi_sck;
            sck_sync  <= sck_meta;
            sck_prev  <= sck_sync;
            nss_meta  <= spi_nss;
            nss_sync  <= nss_meta;
            nss_prev  <= nss_sync;
            mosi_meta <= spi_mosi;
            mosi_sync <= mosi_meta;
        end
    end

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            bus_address       <= 7'd0;
            bus_read_strobe   <= 1'b0;
            bus_write_strobe  <= 1'b0;
            bus_write_data    <= 8'd0;
            spi_protocol_error <= 1'b0;
            rx_shift          <= 8'd0;
            tx_shift          <= 8'd0;
            bit_count         <= 3'd0;
            command_seen      <= 1'b0;
            read_mode         <= 1'b0;
            current_address   <= 7'd0;
            read_load_pending <= 1'b0;
            tx_byte_loaded    <= 1'b0;
            miso_value        <= 1'b0;
        end else begin
            bus_read_strobe    <= 1'b0;
            bus_write_strobe   <= 1'b0;
            spi_protocol_error <= 1'b0;

            // The register bank has one full clk_sys cycle to decode the
            // request. Loading here still leaves ample setup time before the
            // next external SCK rising edge at the specified 1 MHz rate.
            if (read_load_pending) begin
                tx_shift          <= bus_read_data;
                tx_byte_loaded    <= 1'b1;
                read_load_pending <= 1'b0;
            end

            if (nss_fall) begin
                rx_shift          <= 8'd0;
                tx_shift          <= 8'd0;
                bit_count         <= 3'd0;
                command_seen      <= 1'b0;
                read_mode         <= 1'b0;
                current_address   <= 7'd0;
                read_load_pending <= 1'b0;
                tx_byte_loaded    <= 1'b0;
                miso_value        <= 1'b0;
            end else if (nss_rise) begin
                if (bit_count != 0)
                    spi_protocol_error <= 1'b1;
                rx_shift          <= 8'd0;
                bit_count         <= 3'd0;
                command_seen      <= 1'b0;
                read_load_pending <= 1'b0;
                tx_byte_loaded    <= 1'b0;
                miso_value        <= 1'b0;
            end else if (!nss_sync) begin
                if (sck_rise) begin
                    rx_shift <= assembled_byte;

                    // A read data byte becomes architecturally consumed only
                    // when its first bit is actually clocked. Loading a byte
                    // for possible transmission must not pop RX_DATA or
                    // SNAPSHOT_DATA when NSS ends the transaction instead.
                    if (command_seen && read_mode && bit_count == 3'd0)
                        bus_read_strobe <= 1'b1;

                    if (bit_count == 3'd7) begin
                        bit_count <= 3'd0;
                        rx_shift  <= 8'd0;
                        if (!command_seen) begin
                            command_seen    <= 1'b1;
                            read_mode       <= assembled_byte[7];
                            current_address <= assembled_byte[6:0];
                            bus_address     <= assembled_byte[6:0];
                            if (assembled_byte[7]) begin
                                read_load_pending <= 1'b1;
                            end
                        end else if (read_mode) begin
                            current_address   <= next_read_address;
                            bus_address       <= next_read_address;
                            read_load_pending <= 1'b1;
                        end else begin
                            bus_address      <= current_address;
                            bus_write_data   <= assembled_byte;
                            bus_write_strobe <= 1'b1;
                            current_address  <= current_address + 1'b1;
                        end
                    end else begin
                        bit_count <= bit_count + 1'b1;
                    end
                end

                if (sck_fall && command_seen && read_mode) begin
                    if (tx_byte_loaded) begin
                        miso_value     <= tx_shift[7];
                        tx_byte_loaded <= 1'b0;
                    end else begin
                        tx_shift   <= {tx_shift[6:0], 1'b0};
                        miso_value <= tx_shift[6];
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire

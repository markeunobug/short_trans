`timescale 1ns/1ps
`default_nettype none

// Single-register I2C master used by the TLV320ADC6120 initializer.
//
// The physical pins must be implemented as open-drain at the integration
// boundary:
//   assign ADC_SCL = scl_drive_low ? 1'b0 : 1'bz;
//   assign ADC_SDA = sda_drive_low ? 1'b0 : 1'bz;
//
// SCL is never actively driven high. Clock stretching is not implemented;
// the TLV320ADC6120 data sheet does not require it for register accesses.
module i2c_master #(
    parameter integer CLK_HZ = 30000000,
    parameter integer I2C_HZ = 100000
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       cmd_valid,
    output wire       cmd_ready,
    input  wire       cmd_read,
    input  wire [6:0] cmd_dev_addr,
    input  wire [7:0] cmd_reg_addr,
    input  wire [7:0] cmd_write_data,

    output reg  [7:0] read_data,
    output reg        done,
    output reg        nack,
    output wire       busy,

    input  wire       sda_in,
    output reg        scl_drive_low,
    output reg        sda_drive_low
);

    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            clog2 = 0;
            while (v > 0) begin
                clog2 = clog2 + 1;
                v = v >> 1;
            end
        end
    endfunction

    localparam integer QUARTER_CYCLES_RAW = CLK_HZ / (I2C_HZ * 4);
    localparam integer QUARTER_CYCLES =
        (QUARTER_CYCLES_RAW < 1) ? 1 : QUARTER_CYCLES_RAW;
    localparam integer DIV_WIDTH =
        (clog2(QUARTER_CYCLES) < 1) ? 1 : clog2(QUARTER_CYCLES);

    localparam [3:0] ST_IDLE        = 4'd0;
    localparam [3:0] ST_START       = 4'd1;
    localparam [3:0] ST_TX_BYTE     = 4'd2;
    localparam [3:0] ST_RX_ACK      = 4'd3;
    localparam [3:0] ST_RESTART     = 4'd4;
    localparam [3:0] ST_RX_BYTE     = 4'd5;
    localparam [3:0] ST_MASTER_NACK = 4'd6;
    localparam [3:0] ST_STOP        = 4'd7;

    localparam [1:0] ACK_ADDR_W = 2'd0;
    localparam [1:0] ACK_REG    = 2'd1;
    localparam [1:0] ACK_DATA   = 2'd2;
    localparam [1:0] ACK_ADDR_R = 2'd3;

    reg [3:0] state;
    reg [1:0] phase;
    reg [2:0] bit_index;
    reg [1:0] ack_return;
    reg [7:0] tx_byte;

    reg       read_latched;
    reg [6:0] dev_addr_latched;
    reg [7:0] reg_addr_latched;
    reg [7:0] write_data_latched;

    reg [DIV_WIDTH-1:0] divider_count;
    wire quarter_tick = (divider_count == QUARTER_CYCLES - 1);

    assign cmd_ready = (state == ST_IDLE);
    assign busy = (state != ST_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divider_count <= {DIV_WIDTH{1'b0}};
        end else if (state == ST_IDLE) begin
            divider_count <= {DIV_WIDTH{1'b0}};
        end else if (quarter_tick) begin
            divider_count <= {DIV_WIDTH{1'b0}};
        end else begin
            divider_count <= divider_count + {{(DIV_WIDTH-1){1'b0}}, 1'b1};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= ST_IDLE;
            phase              <= 2'd0;
            bit_index          <= 3'd7;
            ack_return         <= ACK_ADDR_W;
            tx_byte            <= 8'd0;
            read_latched       <= 1'b0;
            dev_addr_latched   <= 7'd0;
            reg_addr_latched   <= 8'd0;
            write_data_latched <= 8'd0;
            read_data          <= 8'd0;
            done               <= 1'b0;
            nack               <= 1'b0;
            scl_drive_low      <= 1'b0;
            sda_drive_low      <= 1'b0;
        end else begin
            done <= 1'b0;

            if (state == ST_IDLE) begin
                scl_drive_low <= 1'b0;
                sda_drive_low <= 1'b0;

                if (cmd_valid) begin
                    read_latched       <= cmd_read;
                    dev_addr_latched   <= cmd_dev_addr;
                    reg_addr_latched   <= cmd_reg_addr;
                    write_data_latched <= cmd_write_data;
                    read_data          <= 8'd0;
                    nack               <= 1'b0;
                    phase              <= 2'd0;
                    state              <= ST_START;
                end
            end else if (quarter_tick) begin
                case (state)
                    ST_START: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b0;
                                sda_drive_low <= 1'b0;
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                // START: SDA falls while SCL is released high.
                                sda_drive_low <= 1'b1;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                scl_drive_low <= 1'b1;
                                phase <= 2'd3;
                            end
                            default: begin
                                tx_byte    <= {dev_addr_latched, 1'b0};
                                bit_index  <= 3'd7;
                                ack_return <= ACK_ADDR_W;
                                phase      <= 2'd0;
                                state      <= ST_TX_BYTE;
                            end
                        endcase
                    end

                    ST_TX_BYTE: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= ~tx_byte[bit_index];
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                phase <= 2'd3;
                            end
                            default: begin
                                scl_drive_low <= 1'b1;
                                if (bit_index == 3'd0) begin
                                    phase <= 2'd0;
                                    state <= ST_RX_ACK;
                                end else begin
                                    bit_index <= bit_index - 3'd1;
                                    phase <= 2'd0;
                                end
                            end
                        endcase
                    end

                    ST_RX_ACK: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= 1'b0;
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                if (sda_in !== 1'b0)
                                    nack <= 1'b1;
                                phase <= 2'd3;
                            end
                            default: begin
                                scl_drive_low <= 1'b1;
                                phase <= 2'd0;

                                if (nack || (sda_in !== 1'b0)) begin
                                    state <= ST_STOP;
                                end else begin
                                    case (ack_return)
                                        ACK_ADDR_W: begin
                                            tx_byte    <= reg_addr_latched;
                                            bit_index  <= 3'd7;
                                            ack_return <= ACK_REG;
                                            state      <= ST_TX_BYTE;
                                        end
                                        ACK_REG: begin
                                            if (read_latched) begin
                                                state <= ST_RESTART;
                                            end else begin
                                                tx_byte    <= write_data_latched;
                                                bit_index  <= 3'd7;
                                                ack_return <= ACK_DATA;
                                                state      <= ST_TX_BYTE;
                                            end
                                        end
                                        ACK_DATA: begin
                                            state <= ST_STOP;
                                        end
                                        default: begin
                                            bit_index <= 3'd7;
                                            read_data <= 8'd0;
                                            state <= ST_RX_BYTE;
                                        end
                                    endcase
                                end
                            end
                        endcase
                    end

                    ST_RESTART: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= 1'b0;
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                sda_drive_low <= 1'b1;
                                phase <= 2'd3;
                            end
                            default: begin
                                scl_drive_low <= 1'b1;
                                tx_byte    <= {dev_addr_latched, 1'b1};
                                bit_index  <= 3'd7;
                                ack_return <= ACK_ADDR_R;
                                phase      <= 2'd0;
                                state      <= ST_TX_BYTE;
                            end
                        endcase
                    end

                    ST_RX_BYTE: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= 1'b0;
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                read_data[bit_index] <= sda_in;
                                phase <= 2'd3;
                            end
                            default: begin
                                scl_drive_low <= 1'b1;
                                if (bit_index == 3'd0) begin
                                    phase <= 2'd0;
                                    state <= ST_MASTER_NACK;
                                end else begin
                                    bit_index <= bit_index - 3'd1;
                                    phase <= 2'd0;
                                end
                            end
                        endcase
                    end

                    ST_MASTER_NACK: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= 1'b0;
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                phase <= 2'd3;
                            end
                            default: begin
                                scl_drive_low <= 1'b1;
                                phase <= 2'd0;
                                state <= ST_STOP;
                            end
                        endcase
                    end

                    ST_STOP: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= 1'b1;
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                // STOP: SDA rises while SCL is released high.
                                sda_drive_low <= 1'b0;
                                phase <= 2'd3;
                            end
                            default: begin
                                scl_drive_low <= 1'b0;
                                sda_drive_low <= 1'b0;
                                done <= 1'b1;
                                phase <= 2'd0;
                                state <= ST_IDLE;
                            end
                        endcase
                    end

                    default: begin
                        state <= ST_IDLE;
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b0;
                    end
                endcase
            end
        end
    end

endmodule

`default_nettype wire

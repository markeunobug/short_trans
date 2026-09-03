`timescale 1ns/1ps
`default_nettype none

// Packet-aware receive queue in the 30 MHz system clock domain.
//
// The protocol decoder presents frame_valid one cycle before the payload
// stream. A frame is made visible to the SPI side only after its final payload
// byte has arrived. Payload bytes and descriptors therefore commit atomically.
// A rejected frame is drained from the input without disturbing older frames.
module rx_frame_fifo #(
    parameter integer DESC_ADDR_WIDTH = 3
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        frame_valid,
    input  wire [7:0]  frame_version_type,
    input  wire [7:0]  frame_sequence,
    input  wire [7:0]  frame_payload_length,
    input  wire        frame_payload_valid,
    input  wire [7:0]  frame_payload_data,
    input  wire        frame_payload_last,

    input  wire        rx_data_pop,
    input  wire        pop_frame,
    input  wire        drop_frame,
    input  wire        clear_errors,

    output wire [7:0]  head_version_type,
    output wire [7:0]  head_sequence,
    output wire [7:0]  head_length,
    output wire [7:0]  head_payload_data,
    output wire [7:0]  head_remaining,
    output reg  [8:0]  payload_level,
    output reg  [3:0]  frame_count,
    output reg  [15:0] good_frame_count,
    output reg         fifo_overflow_sticky,
    output reg         protocol_error_sticky,
    output reg         ingress_busy
);

    localparam integer DESC_DEPTH = (1 << DESC_ADDR_WIDTH);

    (* ramstyle = "M9K" *) reg [7:0] payload_mem [0:255];
    reg [7:0] desc_version_type [0:DESC_DEPTH-1];
    reg [7:0] desc_sequence     [0:DESC_DEPTH-1];
    reg [7:0] desc_length       [0:DESC_DEPTH-1];

    reg [7:0] payload_wr_ptr;
    reg [7:0] payload_rd_ptr;
    reg [DESC_ADDR_WIDTH-1:0] desc_wr_ptr;
    reg [DESC_ADDR_WIDTH-1:0] desc_rd_ptr;
    reg [7:0] head_bytes_read;

    reg       ingress_accept;
    reg [7:0] ingress_version_type;
    reg [7:0] ingress_sequence;
    reg [7:0] ingress_length;
    reg [6:0] ingress_count;
    reg [7:0] ingress_start_ptr;

    wire desc_full;
    wire [8:0] payload_free;
    wire start_has_capacity;
    wire read_byte_event;
    wire pop_event;
    wire drop_event;
    wire desc_pop_event;
    wire final_length_ok;
    wire rollback_event;
    wire ingress_write_event;
    wire commit_payload_event;
    wire commit_zero_event;
    wire commit_event;
    wire [8:0] payload_remove_count;

    assign desc_full = (frame_count == DESC_DEPTH);
    assign payload_free = 9'd256 - payload_level;
    assign start_has_capacity = (frame_payload_length <= 8'd64) &&
                                !desc_full &&
                                (payload_free >= {1'b0, frame_payload_length});

    assign head_version_type = (frame_count != 0) ? desc_version_type[desc_rd_ptr] : 8'd0;
    assign head_sequence     = (frame_count != 0) ? desc_sequence[desc_rd_ptr] : 8'd0;
    assign head_length       = (frame_count != 0) ? desc_length[desc_rd_ptr] : 8'd0;
    assign head_remaining    = (frame_count != 0) ?
                               (desc_length[desc_rd_ptr] - head_bytes_read) : 8'd0;
    assign head_payload_data = (frame_count != 0 && head_remaining != 0) ?
                               payload_mem[payload_rd_ptr] : 8'd0;

    assign drop_event = drop_frame && (frame_count != 0);
    assign pop_event = pop_frame && (frame_count != 0) &&
                       (head_remaining == 0) && !drop_event;
    assign desc_pop_event = drop_event || pop_event;
    assign read_byte_event = rx_data_pop && (frame_count != 0) &&
                             (head_remaining != 0) && !drop_event;

    assign final_length_ok = (ingress_count + 1'b1 == ingress_length);
    assign rollback_event = frame_payload_valid && ingress_busy &&
                            frame_payload_last && ingress_accept &&
                            !final_length_ok;
    assign ingress_write_event = frame_payload_valid && ingress_busy &&
                                 ingress_accept &&
                                 (ingress_count < ingress_length) &&
                                 !rollback_event;
    assign commit_payload_event = frame_payload_valid && ingress_busy &&
                                  frame_payload_last && ingress_accept &&
                                  final_length_ok;
    assign commit_zero_event = frame_valid && !ingress_busy &&
                               (frame_payload_length == 0) &&
                               start_has_capacity;
    assign commit_event = commit_payload_event || commit_zero_event;

    assign payload_remove_count = drop_event ? {1'b0, head_remaining} :
                                  (read_byte_event ? 9'd1 : 9'd0);

    always @(posedge clk) begin
        if (ingress_write_event)
            payload_mem[payload_wr_ptr] <= frame_payload_data;

        if (commit_event) begin
            if (commit_zero_event) begin
                desc_version_type[desc_wr_ptr] <= frame_version_type;
                desc_sequence[desc_wr_ptr]     <= frame_sequence;
                desc_length[desc_wr_ptr]       <= frame_payload_length;
            end else begin
                desc_version_type[desc_wr_ptr] <= ingress_version_type;
                desc_sequence[desc_wr_ptr]     <= ingress_sequence;
                desc_length[desc_wr_ptr]       <= ingress_length;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            payload_wr_ptr        <= 8'd0;
            payload_rd_ptr        <= 8'd0;
            payload_level         <= 9'd0;
            desc_wr_ptr           <= {DESC_ADDR_WIDTH{1'b0}};
            desc_rd_ptr           <= {DESC_ADDR_WIDTH{1'b0}};
            frame_count           <= 4'd0;
            head_bytes_read       <= 8'd0;
            good_frame_count      <= 16'd0;
            fifo_overflow_sticky  <= 1'b0;
            protocol_error_sticky <= 1'b0;
            ingress_busy          <= 1'b0;
            ingress_accept        <= 1'b0;
            ingress_version_type  <= 8'd0;
            ingress_sequence      <= 8'd0;
            ingress_length        <= 8'd0;
            ingress_count         <= 7'd0;
            ingress_start_ptr     <= 8'd0;
        end else begin
            if (clear_errors) begin
                fifo_overflow_sticky  <= 1'b0;
                protocol_error_sticky <= 1'b0;
            end

            // Descriptor count and pointers support simultaneous producer and
            // consumer activity without losing either event.
            case ({commit_event, desc_pop_event})
                2'b10: frame_count <= frame_count + 1'b1;
                2'b01: frame_count <= frame_count - 1'b1;
                default: frame_count <= frame_count;
            endcase
            if (commit_event)
                desc_wr_ptr <= desc_wr_ptr + 1'b1;
            if (desc_pop_event)
                desc_rd_ptr <= desc_rd_ptr + 1'b1;

            if (commit_event && good_frame_count != 16'hFFFF)
                good_frame_count <= good_frame_count + 1'b1;

            if (desc_pop_event)
                head_bytes_read <= 8'd0;
            else if (read_byte_event)
                head_bytes_read <= head_bytes_read + 1'b1;

            if (payload_remove_count != 0)
                payload_rd_ptr <= payload_rd_ptr + payload_remove_count[7:0];

            if (rollback_event)
                payload_wr_ptr <= ingress_start_ptr;
            else if (ingress_write_event)
                payload_wr_ptr <= payload_wr_ptr + 1'b1;

            payload_level <= payload_level +
                             (ingress_write_event ? 9'd1 : 9'd0) -
                             payload_remove_count -
                             (rollback_event ? {2'b00, ingress_count} : 9'd0);

            if (frame_valid) begin
                if (ingress_busy) begin
                    protocol_error_sticky <= 1'b1;
                end else if (frame_payload_length > 8'd64) begin
                    protocol_error_sticky <= 1'b1;
                    ingress_busy          <= 1'b0;
                    ingress_accept        <= 1'b0;
                end else if (!start_has_capacity) begin
                    fifo_overflow_sticky <= 1'b1;
                    if (frame_payload_length != 0) begin
                        ingress_busy   <= 1'b1;
                        ingress_accept <= 1'b0;
                        ingress_length <= frame_payload_length;
                        ingress_count  <= 7'd0;
                    end
                end else if (frame_payload_length != 0) begin
                    ingress_busy         <= 1'b1;
                    ingress_accept       <= 1'b1;
                    ingress_version_type <= frame_version_type;
                    ingress_sequence     <= frame_sequence;
                    ingress_length       <= frame_payload_length;
                    ingress_count        <= 7'd0;
                    ingress_start_ptr    <= payload_wr_ptr;
                end
            end

            if (frame_payload_valid) begin
                if (!ingress_busy) begin
                    protocol_error_sticky <= 1'b1;
                end else if (frame_payload_last) begin
                    if (ingress_accept && !final_length_ok)
                        protocol_error_sticky <= 1'b1;
                    ingress_busy   <= 1'b0;
                    ingress_accept <= 1'b0;
                    ingress_count  <= 7'd0;
                end else if (ingress_accept) begin
                    if (ingress_count < ingress_length)
                        ingress_count <= ingress_count + 1'b1;
                    else
                        protocol_error_sticky <= 1'b1;
                end
            end

            if (rx_data_pop && !read_byte_event)
                protocol_error_sticky <= 1'b1;
            if (pop_frame && !pop_event)
                protocol_error_sticky <= 1'b1;
            if (drop_frame && !drop_event)
                protocol_error_sticky <= 1'b1;
        end
    end

endmodule

`default_nettype wire

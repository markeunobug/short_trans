`default_nettype none

// Generic dual-clock FIFO using binary and Gray-coded pointers.
//
// ADDR_WIDTH is the address width, so the storage depth is 2**ADDR_WIDTH.
// wr_accept and rd_accept are local-clock-domain handshake indications.
// rd_data is registered and is valid when rd_valid is asserted.
// The two reset inputs should be asserted together before normal operation.
module async_fifo #(
    parameter integer DATA_WIDTH = 8,
    parameter integer ADDR_WIDTH = 8
) (
    input  wire                    wr_clk,
    input  wire                    wr_rst_n,
    input  wire                    wr_en,
    input  wire [DATA_WIDTH-1:0]   wr_data,
    output wire                    wr_full,
    output wire                    wr_accept,
    output wire [ADDR_WIDTH:0]     wr_level,

    input  wire                    rd_clk,
    input  wire                    rd_rst_n,
    input  wire                    rd_en,
    output reg  [DATA_WIDTH-1:0]   rd_data,
    output wire                    rd_empty,
    output wire                    rd_accept,
    output reg                     rd_valid,
    output wire [ADDR_WIDTH:0]     rd_level
);

    localparam integer PTR_WIDTH = ADDR_WIDTH + 1;
    localparam integer FIFO_DEPTH = (1 << ADDR_WIDTH);
    localparam integer FULL_XOR_MASK = (1 << ADDR_WIDTH) | (1 << (ADDR_WIDTH - 1));

    reg [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];

    reg [PTR_WIDTH-1:0] wr_bin;
    reg [PTR_WIDTH-1:0] wr_gray;
    reg [PTR_WIDTH-1:0] rd_bin;
    reg [PTR_WIDTH-1:0] rd_gray;

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [PTR_WIDTH-1:0] rd_gray_wr_ff1;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [PTR_WIDTH-1:0] rd_gray_wr_ff2;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [PTR_WIDTH-1:0] wr_gray_rd_ff1;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [PTR_WIDTH-1:0] wr_gray_rd_ff2;

    reg wr_full_reg;
    reg rd_empty_reg;

    function [PTR_WIDTH-1:0] gray_to_bin;
        input [PTR_WIDTH-1:0] gray_value;
        integer bit_index;
        begin
            gray_to_bin[PTR_WIDTH-1] = gray_value[PTR_WIDTH-1];
            for (bit_index = PTR_WIDTH-2; bit_index >= 0; bit_index = bit_index - 1) begin
                gray_to_bin[bit_index] = gray_to_bin[bit_index+1] ^ gray_value[bit_index];
            end
        end
    endfunction

    wire wr_fire = wr_en && !wr_full_reg;
    wire rd_fire = rd_en && !rd_empty_reg;

    wire [PTR_WIDTH-1:0] wr_bin_next;
    wire [PTR_WIDTH-1:0] wr_gray_next;
    wire [PTR_WIDTH-1:0] rd_bin_next;
    wire [PTR_WIDTH-1:0] rd_gray_next;
    wire                 wr_full_next;
    wire                 rd_empty_next;
    wire [PTR_WIDTH-1:0] rd_bin_wr_sync;
    wire [PTR_WIDTH-1:0] wr_bin_rd_sync;

    assign wr_bin_next  = wr_bin + (wr_fire ? {{(PTR_WIDTH-1){1'b0}}, 1'b1} : {PTR_WIDTH{1'b0}});
    assign wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
    assign rd_bin_next  = rd_bin + (rd_fire ? {{(PTR_WIDTH-1){1'b0}}, 1'b1} : {PTR_WIDTH{1'b0}});
    assign rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

    // A Gray write pointer is full when it equals the read pointer with the
    // two wrap bits inverted. The mask form also supports ADDR_WIDTH == 1.
    assign wr_full_next = (wr_gray_next == (rd_gray_wr_ff2 ^ FULL_XOR_MASK));
    assign rd_empty_next = (rd_gray_next == wr_gray_rd_ff2);

    assign wr_full   = wr_full_reg;
    assign rd_empty  = rd_empty_reg;
    assign wr_accept = wr_fire;
    assign rd_accept = rd_fire;

    // Pointer subtraction is modulo 2**(ADDR_WIDTH+1), which gives the
    // occupancy visible from the corresponding local clock domain.
    assign rd_bin_wr_sync = gray_to_bin(rd_gray_wr_ff2);
    assign wr_bin_rd_sync = gray_to_bin(wr_gray_rd_ff2);
    assign wr_level = wr_bin - rd_bin_wr_sync;
    assign rd_level = wr_bin_rd_sync - rd_bin;

    // Synchronize the read pointer into the write clock domain and update the
    // write-side pointer and full flag.
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_gray_wr_ff1 <= {PTR_WIDTH{1'b0}};
            rd_gray_wr_ff2 <= {PTR_WIDTH{1'b0}};
            wr_bin         <= {PTR_WIDTH{1'b0}};
            wr_gray        <= {PTR_WIDTH{1'b0}};
            wr_full_reg    <= 1'b0;
        end else begin
            rd_gray_wr_ff1 <= rd_gray;
            rd_gray_wr_ff2 <= rd_gray_wr_ff1;
            wr_bin         <= wr_bin_next;
            wr_gray        <= wr_gray_next;
            wr_full_reg    <= wr_full_next;
        end
    end

    // The memory write is intentionally local to the write clock domain.
    always @(posedge wr_clk) begin
        if (wr_fire) begin
            mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
        end
    end

    // Synchronize the write pointer into the read clock domain and update the
    // read-side pointer and empty flag.
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_gray_rd_ff1 <= {PTR_WIDTH{1'b0}};
            wr_gray_rd_ff2 <= {PTR_WIDTH{1'b0}};
            rd_bin         <= {PTR_WIDTH{1'b0}};
            rd_gray        <= {PTR_WIDTH{1'b0}};
            rd_empty_reg   <= 1'b1;
            rd_data        <= {DATA_WIDTH{1'b0}};
            rd_valid       <= 1'b0;
        end else begin
            wr_gray_rd_ff1 <= wr_gray;
            wr_gray_rd_ff2 <= wr_gray_rd_ff1;
            rd_bin         <= rd_bin_next;
            rd_gray        <= rd_gray_next;
            rd_empty_reg   <= rd_empty_next;
            rd_valid       <= rd_fire;
            if (rd_fire) begin
                rd_data <= mem[rd_bin[ADDR_WIDTH-1:0]];
            end
        end
    end

endmodule

`default_nettype wire

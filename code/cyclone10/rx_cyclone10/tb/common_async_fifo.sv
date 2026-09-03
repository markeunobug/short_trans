`timescale 1ns/1ps

module common_async_fifo;
    localparam integer DATA_WIDTH = 8;
    localparam integer ADDR_WIDTH = 2;

    reg wr_clk;
    reg rd_clk;
    reg wr_rst_n;
    reg rd_rst_n;
    reg wr_en;
    reg [DATA_WIDTH-1:0] wr_data;
    wire wr_full;
    wire wr_accept;
    wire [ADDR_WIDTH:0] wr_level;
    reg rd_en;
    wire [DATA_WIDTH-1:0] rd_data;
    wire rd_empty;
    wire rd_accept;
    wire rd_valid;
    wire [ADDR_WIDTH:0] rd_level;

    integer expected [0:31];
    integer expected_wr;
    integer expected_rd;
    integer read_count;

    async_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .wr_clk   (wr_clk),
        .wr_rst_n (wr_rst_n),
        .wr_en    (wr_en),
        .wr_data  (wr_data),
        .wr_full  (wr_full),
        .wr_accept(wr_accept),
        .wr_level (wr_level),
        .rd_clk   (rd_clk),
        .rd_rst_n (rd_rst_n),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .rd_empty (rd_empty),
        .rd_accept(rd_accept),
        .rd_valid (rd_valid),
        .rd_level (rd_level)
    );

    always #5 wr_clk = ~wr_clk;
    always #7 rd_clk = ~rd_clk;

    always @(posedge wr_clk) begin
        if (wr_accept) begin
            expected[expected_wr] = wr_data;
            expected_wr = expected_wr + 1;
        end
    end

    always @(negedge rd_clk) begin
        if (rd_valid) begin
            if (rd_data !== expected[expected_rd]) begin
                $fatal(1, "FIFO order error: expected %02x got %02x", expected[expected_rd], rd_data);
            end
            expected_rd = expected_rd + 1;
            read_count = read_count + 1;
        end
    end

    task write_word;
        input [DATA_WIDTH-1:0] value;
        begin
            @(negedge wr_clk);
            wr_data = value;
            wr_en = 1'b1;
            @(negedge wr_clk);
            wr_en = 1'b0;
        end
    endtask

    task read_words;
        input integer count;
        begin
            @(negedge rd_clk);
            rd_en = 1'b1;
            repeat (count) @(negedge rd_clk);
            rd_en = 1'b0;
        end
    endtask

    initial begin
        wr_clk = 1'b0;
        rd_clk = 1'b0;
        wr_rst_n = 1'b0;
        rd_rst_n = 1'b0;
        wr_en = 1'b0;
        wr_data = 8'h00;
        rd_en = 1'b0;
        expected_wr = 0;
        expected_rd = 0;
        read_count = 0;

        #23;
        wr_rst_n = 1'b1;
        rd_rst_n = 1'b1;

        write_word(8'h10);
        write_word(8'h11);
        write_word(8'h12);
        write_word(8'h13);
        #20;
        if (!wr_full) $fatal(1, "FIFO did not assert full after four writes");

        write_word(8'hEE);
        if (expected_wr !== 4) $fatal(1, "write while full was incorrectly accepted");

        read_words(4);
        #30;
        if (read_count !== 4) $fatal(1, "expected four reads, got %0d", read_count);
        if (!rd_empty) $fatal(1, "FIFO did not become empty");

        write_word(8'h20);
        write_word(8'h21);
        write_word(8'h22);
        write_word(8'h23);
        read_words(2);
        #30;
        write_word(8'h24);
        write_word(8'h25);
        read_words(4);
        #40;
        if (read_count !== 10) $fatal(1, "expected ten total reads, got %0d", read_count);

        $display("common_async_fifo: PASS");
        $finish;
    end
endmodule

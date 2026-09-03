`timescale 1ns/1ps

`include "fsk_sync_word.vh"

module protocol_frame_rx_tb;

    localparam logic [15:0] SYNC_WORD = `FSK_SYNC_WORD;

    logic       clk = 1'b0;
    logic       rst_n = 1'b0;
    logic       bit_valid = 1'b0;
    logic       bit_value = 1'b0;
    logic       lock_lost = 1'b0;

    wire        busy;
    wire        sync_found;
    wire        frame_valid;
    wire        good_frame;
    wire [7:0]  frame_version_type;
    wire [7:0]  frame_sequence;
    wire [7:0]  frame_payload_length;
    wire        frame_payload_valid;
    wire [7:0]  frame_payload_data;
    wire        frame_payload_last;
    wire        header_error;
    wire        length_error;
    wire        crc_error;
    wire        timeout_error;

    logic [7:0]  crc8_in;
    logic [7:0]  crc8_data;
    wire  [7:0]  crc8_out;
    logic [15:0] crc16_in;
    logic [7:0]  crc16_data;
    wire  [15:0] crc16_out;

    integer errors = 0;
    integer good_frames = 0;
    integer sync_events = 0;
    integer header_errors = 0;
    integer length_errors = 0;
    integer crc_errors = 0;
    integer timeout_errors = 0;

    always #5 clk = ~clk;

    fsk_frame_rx #(
        .SYNC_WORD(SYNC_WORD),
        .BIT_TIMEOUT_CYCLES(8)
    ) dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .bit_valid            (bit_valid),
        .bit_value            (bit_value),
        .lock_lost            (lock_lost),
        .busy                 (busy),
        .sync_found           (sync_found),
        .frame_valid          (frame_valid),
        .good_frame           (good_frame),
        .frame_version_type   (frame_version_type),
        .frame_sequence       (frame_sequence),
        .frame_payload_length (frame_payload_length),
        .frame_payload_valid  (frame_payload_valid),
        .frame_payload_data   (frame_payload_data),
        .frame_payload_last   (frame_payload_last),
        .header_error         (header_error),
        .length_error         (length_error),
        .crc_error            (crc_error),
        .timeout_error        (timeout_error)
    );

    crc8_atm crc8_dut (
        .crc_in  (crc8_in),
        .data_in (crc8_data),
        .crc_out (crc8_out)
    );

    crc16_ccitt crc16_dut (
        .crc_in  (crc16_in),
        .data_in (crc16_data),
        .crc_out (crc16_out)
    );

    always @(posedge clk) begin
        #1;
        if (sync_found)
            sync_events = sync_events + 1;
        if (frame_valid)
            good_frames = good_frames + 1;
        if (header_error)
            header_errors = header_errors + 1;
        if (length_error)
            length_errors = length_errors + 1;
        if (crc_error)
            crc_errors = crc_errors + 1;
        if (timeout_error)
            timeout_errors = timeout_errors + 1;
    end

    function automatic [7:0] crc8_update;
        input [7:0] crc_value;
        input [7:0] data_value;
        integer index;
        reg [7:0] value;
        begin
            value = crc_value ^ data_value;
            for (index = 0; index < 8; index = index + 1) begin
                if (value[7])
                    value = {value[6:0], 1'b0} ^ 8'h07;
                else
                    value = {value[6:0], 1'b0};
            end
            crc8_update = value;
        end
    endfunction

    function automatic [15:0] crc16_update;
        input [15:0] crc_value;
        input [7:0] data_value;
        integer index;
        reg [15:0] value;
        begin
            value = crc_value ^ {data_value, 8'h00};
            for (index = 0; index < 8; index = index + 1) begin
                if (value[15])
                    value = {value[14:0], 1'b0} ^ 16'h1021;
                else
                    value = {value[14:0], 1'b0};
            end
            crc16_update = value;
        end
    endfunction

    function automatic [7:0] payload_value;
        input integer index;
        begin
            payload_value = 8'h40 + index[7:0] * 8'h03;
        end
    endfunction

    task automatic send_bit;
        input logic value;
        begin
            @(negedge clk);
            bit_value = value;
            bit_valid = 1'b1;
            @(negedge clk);
            bit_valid = 1'b0;
        end
    endtask

    task automatic send_byte;
        input logic [7:0] value;
        integer index;
        begin
            for (index = 7; index >= 0; index = index - 1)
                send_bit(value[index]);
        end
    endtask

    task automatic send_word;
        input logic [15:0] value;
        integer index;
        begin
            for (index = 15; index >= 0; index = index - 1)
                send_bit(value[index]);
        end
    endtask

    task automatic send_packet;
        input integer length;
        input integer sync_error_count;
        input logic bad_header_crc;
        input logic bad_payload;
        input logic bad_frame_crc;
        reg [15:0] sync_to_send;
        reg [7:0] header0;
        reg [7:0] header1;
        reg [7:0] header2;
        reg [7:0] header3;
        reg [7:0] transmitted_header3;
        reg [15:0] frame_crc;
        reg [7:0] transmitted_payload;
        integer index;
        begin
            sync_to_send = SYNC_WORD;
            if (sync_error_count == 1)
                sync_to_send = SYNC_WORD ^ 16'h0001;
            else if (sync_error_count >= 2)
                sync_to_send = SYNC_WORD ^ 16'h0003;

            header0 = 8'h12;
            header1 = 8'h5A;
            header2 = length[7:0];
            header3 = crc8_update(crc8_update(crc8_update(8'h00, header0), header1), header2);
            transmitted_header3 = header3;
            if (bad_header_crc)
                transmitted_header3 = header3 ^ 8'h01;

            frame_crc = 16'hFFFF;
            frame_crc = crc16_update(frame_crc, header0);
            frame_crc = crc16_update(frame_crc, header1);
            frame_crc = crc16_update(frame_crc, header2);
            frame_crc = crc16_update(frame_crc, header3);
            for (index = 0; index < length; index = index + 1)
                frame_crc = crc16_update(frame_crc, payload_value(index));
            if (bad_frame_crc)
                frame_crc = frame_crc ^ 16'h0001;

            send_word(sync_to_send);
            send_byte(header0);
            send_byte(header1);
            send_byte(header2);
            send_byte(transmitted_header3);
            for (index = 0; index < length; index = index + 1) begin
                transmitted_payload = payload_value(index);
                if (bad_payload && index == 0)
                    transmitted_payload = transmitted_payload ^ 8'h01;
                send_byte(transmitted_payload);
            end
            send_byte(frame_crc[15:8]);
            send_byte(frame_crc[7:0]);
        end
    endtask

    task automatic expect_good_frame;
        input integer expected_length;
        integer cycles;
        integer index;
        logic found;
        logic saw_last;
        begin
            // The parser asserts frame_valid during the half-cycle after the
            // final CRC bit is sampled, so check the current level first.
            found = frame_valid;
            begin : wait_for_frame_valid
                if (!found) begin
                    for (cycles = 0; cycles < 4; cycles = cycles + 1) begin
                        @(posedge clk);
                        #1;
                        if (frame_valid) begin
                            found = 1'b1;
                            disable wait_for_frame_valid;
                        end
                    end
                end
            end
            if (!found) begin
                $display("ERROR: expected good frame length=%0d", expected_length);
                errors = errors + 1;
            end
            if (frame_version_type !== 8'h12 || frame_sequence !== 8'h5A ||
                frame_payload_length !== expected_length[7:0]) begin
                $display("ERROR: header mismatch version=%02x seq=%02x len=%0d",
                         frame_version_type, frame_sequence, frame_payload_length);
                errors = errors + 1;
            end
            for (index = 0; index < expected_length; index = index + 1) begin
                saw_last = 1'b0;
                begin : wait_for_payload_byte
                    for (cycles = 0; cycles < 4; cycles = cycles + 1) begin
                        @(posedge clk);
                        #1;
                        if (frame_payload_valid) begin
                            if (frame_payload_data !== payload_value(index)) begin
                                $display("ERROR: payload[%0d] expected=%02x got=%02x",
                                         index, payload_value(index), frame_payload_data);
                                errors = errors + 1;
                            end
                            if (frame_payload_last !== (index == expected_length - 1)) begin
                                $display("ERROR: payload_last mismatch at index=%0d", index);
                                errors = errors + 1;
                            end
                            saw_last = 1'b1;
                            disable wait_for_payload_byte;
                        end
                    end
                end
                if (!saw_last) begin
                    $display("ERROR: missing payload byte index=%0d", index);
                    errors = errors + 1;
                end
            end
        end
    endtask

    task automatic expect_no_good_frame;
        integer cycles;
        integer before_count;
        begin
            before_count = good_frames;
            repeat (32) begin
                @(posedge clk);
                #1;
            end
            if (good_frames != before_count) begin
                $display("ERROR: invalid frame produced frame_valid");
                errors = errors + 1;
            end
        end
    endtask

    initial begin : test_sequence
        reg [7:0] vector_data [0:8];
        integer index;

        vector_data[0] = "1";
        vector_data[1] = "2";
        vector_data[2] = "3";
        vector_data[3] = "4";
        vector_data[4] = "5";
        vector_data[5] = "6";
        vector_data[6] = "7";
        vector_data[7] = "8";
        vector_data[8] = "9";

        #2;
        rst_n = 1'b0;
        #18;
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Standard check values: CRC-8/ATM("123456789")=F4,
        // CRC-16/CCITT-FALSE("123456789")=29B1.
        crc8_in = 8'h00;
        crc16_in = 16'hFFFF;
        for (index = 0; index < 9; index = index + 1) begin
            crc8_data = vector_data[index];
            crc16_data = vector_data[index];
            #1;
            crc8_in = crc8_out;
            crc16_in = crc16_out;
        end
        #1;
        if (crc8_in !== 8'hF4 || crc16_in !== 16'h29B1) begin
            $display("ERROR: CRC vector got crc8=%02x crc16=%04x", crc8_in, crc16_in);
            errors = errors + 1;
        end

        send_packet(0, 0, 1'b0, 1'b0, 1'b0);
        expect_good_frame(0);
        send_packet(1, 0, 1'b0, 1'b0, 1'b0);
        expect_good_frame(1);
        send_packet(64, 0, 1'b0, 1'b0, 1'b0);
        expect_good_frame(64);
        send_packet(1, 1, 1'b0, 1'b0, 1'b0);
        expect_good_frame(1);

        send_packet(65, 0, 1'b0, 1'b0, 1'b0);
        expect_no_good_frame();
        send_packet(1, 2, 1'b0, 1'b0, 1'b0);
        expect_no_good_frame();
        send_packet(1, 0, 1'b1, 1'b0, 1'b0);
        expect_no_good_frame();
        send_packet(1, 0, 1'b0, 1'b1, 1'b0);
        expect_no_good_frame();
        send_packet(1, 0, 1'b0, 1'b0, 1'b1);
        expect_no_good_frame();

        send_word(SYNC_WORD);
        send_byte(8'h12);
        repeat (12) begin
            @(posedge clk);
            #1;
        end
        if (timeout_errors == 0) begin
            $display("ERROR: parser timeout was not reported");
            errors = errors + 1;
        end

        lock_lost = 1'b1;
        @(posedge clk);
        #1;
        lock_lost = 1'b0;
        if (busy) begin
            $display("ERROR: lock_lost did not return parser to search state");
            errors = errors + 1;
        end

        if (good_frames != 4) begin
            $display("ERROR: expected 4 good frames, got %0d", good_frames);
            errors = errors + 1;
        end
        if (sync_events < 5) begin
            $display("ERROR: sync search did not accept expected valid sync words");
            errors = errors + 1;
        end
        if (header_errors == 0 || length_errors == 0 || crc_errors < 2) begin
            $display("ERROR: error counters header=%0d length=%0d crc=%0d",
                     header_errors, length_errors, crc_errors);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("protocol_frame_rx_tb: PASS");
        else
            $fatal(1, "protocol_frame_rx_tb: FAIL errors=%0d", errors);
        $finish;
    end

endmodule

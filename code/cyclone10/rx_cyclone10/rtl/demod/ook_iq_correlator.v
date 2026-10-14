`timescale 1ns/1ps
`default_nettype none

// Fixed 48 kSPS 1800 Hz OOK front end.
// The 80-entry Q7 LUT spans exactly three carrier cycles.  The correlator
// keeps an 80-sample sliding I/Q sum and produces one metric every 48 samples
// (1 ms).  Energy = min(0xffffffff, (I*I + Q*Q) >> 28); the shift maps a
// sine amplitude near 65--80 ADC units to the provisional 400/600 thresholds (A=80 gives 616).
module ook_iq_correlator (
    input wire clk, input wire reset_n,
    input wire sample_valid, input wire signed [19:0] sample_data,
    output reg metric_valid, output reg [31:0] energy, output reg energy_ready
);
    localparam integer WINDOW = 80;
    localparam integer STEP = 48;
    reg signed [27:0] i_history [0:WINDOW-1];
    reg signed [27:0] q_history [0:WINDOW-1];
    reg [6:0] wr_ptr;
    reg [6:0] phase;
    reg [6:0] fill_count;
    reg [5:0] step_count;
    reg signed [35:0] i_acc, q_acc;
    reg signed [7:0] coeff_i, coeff_q;
    wire signed [27:0] prod_i = sample_data * coeff_i;
    wire signed [27:0] prod_q = sample_data * coeff_q;
    wire signed [36:0] i_next_w = {i_acc[35], i_acc} + {{9{prod_i[27]}}, prod_i} - {{9{i_history[wr_ptr][27]}}, i_history[wr_ptr]};
    wire signed [36:0] q_next_w = {q_acc[35], q_acc} + {{9{prod_q[27]}}, prod_q} - {{9{q_history[wr_ptr][27]}}, q_history[wr_ptr]};
    // Register each energy stage so the input multiply, sliding sum,
    // absolute value and square no longer share one 30 MHz timing path.
    // Metric values/cadence are unchanged; output latency is four clk cycles.
    reg signed [36:0] metric_i, metric_q;
    reg [35:0] i_abs, q_abs;
    reg [71:0] i_sq, q_sq;
    reg [72:0] e_sum;
    reg sum_valid, abs_valid, square_valid, energy_valid;
    function signed [7:0] lut_i; input [6:0] index; begin
        case(index)
            7'd0: lut_i = 8'sd127;
            7'd1: lut_i = 8'sd123;
            7'd2: lut_i = 8'sd113;
            7'd3: lut_i = 8'sd97;
            7'd4: lut_i = 8'sd75;
            7'd5: lut_i = 8'sd49;
            7'd6: lut_i = 8'sd20;
            7'd7: lut_i = -8'sd10;
            7'd8: lut_i = -8'sd39;
            7'd9: lut_i = -8'sd66;
            7'd10: lut_i = -8'sd90;
            7'd11: lut_i = -8'sd108;
            7'd12: lut_i = -8'sd121;
            7'd13: lut_i = -8'sd127;
            7'd14: lut_i = -8'sd125;
            7'd15: lut_i = -8'sd117;
            7'd16: lut_i = -8'sd103;
            7'd17: lut_i = -8'sd82;
            7'd18: lut_i = -8'sd58;
            7'd19: lut_i = -8'sd30;
            7'd20: lut_i = 8'sd0;
            7'd21: lut_i = 8'sd30;
            7'd22: lut_i = 8'sd58;
            7'd23: lut_i = 8'sd82;
            7'd24: lut_i = 8'sd103;
            7'd25: lut_i = 8'sd117;
            7'd26: lut_i = 8'sd125;
            7'd27: lut_i = 8'sd127;
            7'd28: lut_i = 8'sd121;
            7'd29: lut_i = 8'sd108;
            7'd30: lut_i = 8'sd90;
            7'd31: lut_i = 8'sd66;
            7'd32: lut_i = 8'sd39;
            7'd33: lut_i = 8'sd10;
            7'd34: lut_i = -8'sd20;
            7'd35: lut_i = -8'sd49;
            7'd36: lut_i = -8'sd75;
            7'd37: lut_i = -8'sd97;
            7'd38: lut_i = -8'sd113;
            7'd39: lut_i = -8'sd123;
            7'd40: lut_i = -8'sd127;
            7'd41: lut_i = -8'sd123;
            7'd42: lut_i = -8'sd113;
            7'd43: lut_i = -8'sd97;
            7'd44: lut_i = -8'sd75;
            7'd45: lut_i = -8'sd49;
            7'd46: lut_i = -8'sd20;
            7'd47: lut_i = 8'sd10;
            7'd48: lut_i = 8'sd39;
            7'd49: lut_i = 8'sd66;
            7'd50: lut_i = 8'sd90;
            7'd51: lut_i = 8'sd108;
            7'd52: lut_i = 8'sd121;
            7'd53: lut_i = 8'sd127;
            7'd54: lut_i = 8'sd125;
            7'd55: lut_i = 8'sd117;
            7'd56: lut_i = 8'sd103;
            7'd57: lut_i = 8'sd82;
            7'd58: lut_i = 8'sd58;
            7'd59: lut_i = 8'sd30;
            7'd60: lut_i = 8'sd0;
            7'd61: lut_i = -8'sd30;
            7'd62: lut_i = -8'sd58;
            7'd63: lut_i = -8'sd82;
            7'd64: lut_i = -8'sd103;
            7'd65: lut_i = -8'sd117;
            7'd66: lut_i = -8'sd125;
            7'd67: lut_i = -8'sd127;
            7'd68: lut_i = -8'sd121;
            7'd69: lut_i = -8'sd108;
            7'd70: lut_i = -8'sd90;
            7'd71: lut_i = -8'sd66;
            7'd72: lut_i = -8'sd39;
            7'd73: lut_i = -8'sd10;
            7'd74: lut_i = 8'sd20;
            7'd75: lut_i = 8'sd49;
            7'd76: lut_i = 8'sd75;
            7'd77: lut_i = 8'sd97;
            7'd78: lut_i = 8'sd113;
            7'd79: lut_i = 8'sd123;
            default: lut_i = 8'sd0;
        endcase
end endfunction
    function signed [7:0] lut_q; input [6:0] index; begin
        case(index)
            7'd0: lut_q = 8'sd0;
            7'd1: lut_q = 8'sd30;
            7'd2: lut_q = 8'sd58;
            7'd3: lut_q = 8'sd82;
            7'd4: lut_q = 8'sd103;
            7'd5: lut_q = 8'sd117;
            7'd6: lut_q = 8'sd125;
            7'd7: lut_q = 8'sd127;
            7'd8: lut_q = 8'sd121;
            7'd9: lut_q = 8'sd108;
            7'd10: lut_q = 8'sd90;
            7'd11: lut_q = 8'sd66;
            7'd12: lut_q = 8'sd39;
            7'd13: lut_q = 8'sd10;
            7'd14: lut_q = -8'sd20;
            7'd15: lut_q = -8'sd49;
            7'd16: lut_q = -8'sd75;
            7'd17: lut_q = -8'sd97;
            7'd18: lut_q = -8'sd113;
            7'd19: lut_q = -8'sd123;
            7'd20: lut_q = -8'sd127;
            7'd21: lut_q = -8'sd123;
            7'd22: lut_q = -8'sd113;
            7'd23: lut_q = -8'sd97;
            7'd24: lut_q = -8'sd75;
            7'd25: lut_q = -8'sd49;
            7'd26: lut_q = -8'sd20;
            7'd27: lut_q = 8'sd10;
            7'd28: lut_q = 8'sd39;
            7'd29: lut_q = 8'sd66;
            7'd30: lut_q = 8'sd90;
            7'd31: lut_q = 8'sd108;
            7'd32: lut_q = 8'sd121;
            7'd33: lut_q = 8'sd127;
            7'd34: lut_q = 8'sd125;
            7'd35: lut_q = 8'sd117;
            7'd36: lut_q = 8'sd103;
            7'd37: lut_q = 8'sd82;
            7'd38: lut_q = 8'sd58;
            7'd39: lut_q = 8'sd30;
            7'd40: lut_q = 8'sd0;
            7'd41: lut_q = -8'sd30;
            7'd42: lut_q = -8'sd58;
            7'd43: lut_q = -8'sd82;
            7'd44: lut_q = -8'sd103;
            7'd45: lut_q = -8'sd117;
            7'd46: lut_q = -8'sd125;
            7'd47: lut_q = -8'sd127;
            7'd48: lut_q = -8'sd121;
            7'd49: lut_q = -8'sd108;
            7'd50: lut_q = -8'sd90;
            7'd51: lut_q = -8'sd66;
            7'd52: lut_q = -8'sd39;
            7'd53: lut_q = -8'sd10;
            7'd54: lut_q = 8'sd20;
            7'd55: lut_q = 8'sd49;
            7'd56: lut_q = 8'sd75;
            7'd57: lut_q = 8'sd97;
            7'd58: lut_q = 8'sd113;
            7'd59: lut_q = 8'sd123;
            7'd60: lut_q = 8'sd127;
            7'd61: lut_q = 8'sd123;
            7'd62: lut_q = 8'sd113;
            7'd63: lut_q = 8'sd97;
            7'd64: lut_q = 8'sd75;
            7'd65: lut_q = 8'sd49;
            7'd66: lut_q = 8'sd20;
            7'd67: lut_q = -8'sd10;
            7'd68: lut_q = -8'sd39;
            7'd69: lut_q = -8'sd66;
            7'd70: lut_q = -8'sd90;
            7'd71: lut_q = -8'sd108;
            7'd72: lut_q = -8'sd121;
            7'd73: lut_q = -8'sd127;
            7'd74: lut_q = -8'sd125;
            7'd75: lut_q = -8'sd117;
            7'd76: lut_q = -8'sd103;
            7'd77: lut_q = -8'sd82;
            7'd78: lut_q = -8'sd58;
            7'd79: lut_q = -8'sd30;
            default: lut_q = 8'sd0;
        endcase
end endfunction
    always @(*) begin
        coeff_i = lut_i(phase);
        coeff_q = lut_q(phase);
    end
    integer k;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wr_ptr <= 0; phase <= 0; fill_count <= 0; step_count <= 0;
            i_acc <= 0; q_acc <= 0; metric_valid <= 0; energy <= 0; energy_ready <= 0;
            metric_i <= 0; metric_q <= 0;
            i_abs <= 0; q_abs <= 0; i_sq <= 0; q_sq <= 0; e_sum <= 0;
            sum_valid <= 0; abs_valid <= 0; square_valid <= 0; energy_valid <= 0;
            for (k=0;k<WINDOW;k=k+1) begin i_history[k] <= 0; q_history[k] <= 0; end
        end else begin
            metric_valid <= energy_valid;
            sum_valid <= 1'b0;
            abs_valid <= sum_valid;
            square_valid <= abs_valid;
            energy_valid <= square_valid;
            if (sum_valid) begin
                i_abs <= metric_i[36] ? (~metric_i[35:0] + 1'b1) : metric_i[35:0];
                q_abs <= metric_q[36] ? (~metric_q[35:0] + 1'b1) : metric_q[35:0];
            end
            if (abs_valid) begin
                i_sq <= i_abs * i_abs;
                q_sq <= q_abs * q_abs;
            end
            if (square_valid)
                e_sum <= {1'b0, i_sq} + {1'b0, q_sq};
            if (energy_valid) begin
                energy_ready <= 1'b1;
                if (|e_sum[72:60]) energy <= 32'hffffffff;
                else energy <= e_sum[59:28];
            end
            if (sample_valid) begin
                i_history[wr_ptr] <= prod_i;
                q_history[wr_ptr] <= prod_q;
                i_acc <= i_next_w[35:0];
                q_acc <= q_next_w[35:0];
                wr_ptr <= (wr_ptr == WINDOW-1) ? 0 : wr_ptr + 1'b1;
                phase <= (phase == WINDOW-1) ? 0 : phase + 1'b1;
                if (fill_count < WINDOW) fill_count <= fill_count + 1'b1;
                if ((fill_count >= WINDOW-1) && (step_count == STEP-1)) begin
                    step_count <= 0;
                    metric_i <= i_next_w;
                    metric_q <= q_next_w;
                    sum_valid <= 1'b1;
                end else if (fill_count >= WINDOW-1) begin
                    step_count <= step_count + 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire


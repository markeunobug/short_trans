`timescale 1ns/1ps

// One 120-sample reference period at 48 kSPS.
// f0 advances by 4/120 turns per sample (1.6 kHz), while f1 advances
// by 5/120 turns per sample (2.0 kHz). Coefficients are signed Q1.15
// values generated as round(32767 * sin/cos(theta)).
module fsk_tone_rom (
    input  wire [6:0] phase_index,
    output reg  signed [15:0] cos_f0,
    output reg  signed [15:0] sin_f0,
    output reg  signed [15:0] cos_f1,
    output reg  signed [15:0] sin_f1
);

    always @* begin
        cos_f0 = 16'sd32767;
        sin_f0 = 16'sd0;
        cos_f1 = 16'sd32767;
        sin_f1 = 16'sd0;

        case (phase_index)
            7'd0: begin cos_f0 = 16'sd32767; sin_f0 = 16'sd0; cos_f1 = 16'sd32767; sin_f1 = 16'sd0; end
            7'd1: begin cos_f0 = 16'sd32051; sin_f0 = 16'sd6813; cos_f1 = 16'sd31650; sin_f1 = 16'sd8481; end
            7'd2: begin cos_f0 = 16'sd29934; sin_f0 = 16'sd13328; cos_f1 = 16'sd28377; sin_f1 = 16'sd16383; end
            7'd3: begin cos_f0 = 16'sd26509; sin_f0 = 16'sd19260; cos_f1 = 16'sd23170; sin_f1 = 16'sd23170; end
            7'd4: begin cos_f0 = 16'sd21925; sin_f0 = 16'sd24351; cos_f1 = 16'sd16384; sin_f1 = 16'sd28377; end
            7'd5: begin cos_f0 = 16'sd16384; sin_f0 = 16'sd28377; cos_f1 = 16'sd8481; sin_f1 = 16'sd31650; end
            7'd6: begin cos_f0 = 16'sd10126; sin_f0 = 16'sd31163; cos_f1 = 16'sd0; sin_f1 = 16'sd32767; end
            7'd7: begin cos_f0 = 16'sd3425; sin_f0 = 16'sd32587; cos_f1 = -16'sd8481; sin_f1 = 16'sd31650; end
            7'd8: begin cos_f0 = -16'sd3425; sin_f0 = 16'sd32587; cos_f1 = -16'sd16383; sin_f1 = 16'sd28377; end
            7'd9: begin cos_f0 = -16'sd10126; sin_f0 = 16'sd31163; cos_f1 = -16'sd23170; sin_f1 = 16'sd23170; end
            7'd10: begin cos_f0 = -16'sd16383; sin_f0 = 16'sd28377; cos_f1 = -16'sd28377; sin_f1 = 16'sd16383; end
            7'd11: begin cos_f0 = -16'sd21925; sin_f0 = 16'sd24351; cos_f1 = -16'sd31650; sin_f1 = 16'sd8481; end
            7'd12: begin cos_f0 = -16'sd26509; sin_f0 = 16'sd19260; cos_f1 = -16'sd32767; sin_f1 = 16'sd0; end
            7'd13: begin cos_f0 = -16'sd29934; sin_f0 = 16'sd13328; cos_f1 = -16'sd31650; sin_f1 = -16'sd8481; end
            7'd14: begin cos_f0 = -16'sd32051; sin_f0 = 16'sd6813; cos_f1 = -16'sd28377; sin_f1 = -16'sd16383; end
            7'd15: begin cos_f0 = -16'sd32767; sin_f0 = 16'sd0; cos_f1 = -16'sd23170; sin_f1 = -16'sd23170; end
            7'd16: begin cos_f0 = -16'sd32051; sin_f0 = -16'sd6813; cos_f1 = -16'sd16384; sin_f1 = -16'sd28377; end
            7'd17: begin cos_f0 = -16'sd29934; sin_f0 = -16'sd13328; cos_f1 = -16'sd8481; sin_f1 = -16'sd31650; end
            7'd18: begin cos_f0 = -16'sd26509; sin_f0 = -16'sd19260; cos_f1 = 16'sd0; sin_f1 = -16'sd32767; end
            7'd19: begin cos_f0 = -16'sd21925; sin_f0 = -16'sd24351; cos_f1 = 16'sd8481; sin_f1 = -16'sd31650; end
            7'd20: begin cos_f0 = -16'sd16384; sin_f0 = -16'sd28377; cos_f1 = 16'sd16384; sin_f1 = -16'sd28377; end
            7'd21: begin cos_f0 = -16'sd10126; sin_f0 = -16'sd31163; cos_f1 = 16'sd23170; sin_f1 = -16'sd23170; end
            7'd22: begin cos_f0 = -16'sd3425; sin_f0 = -16'sd32587; cos_f1 = 16'sd28377; sin_f1 = -16'sd16384; end
            7'd23: begin cos_f0 = 16'sd3425; sin_f0 = -16'sd32587; cos_f1 = 16'sd31650; sin_f1 = -16'sd8481; end
            7'd24: begin cos_f0 = 16'sd10126; sin_f0 = -16'sd31163; cos_f1 = 16'sd32767; sin_f1 = 16'sd0; end
            7'd25: begin cos_f0 = 16'sd16384; sin_f0 = -16'sd28377; cos_f1 = 16'sd31650; sin_f1 = 16'sd8481; end
            7'd26: begin cos_f0 = 16'sd21925; sin_f0 = -16'sd24351; cos_f1 = 16'sd28377; sin_f1 = 16'sd16384; end
            7'd27: begin cos_f0 = 16'sd26509; sin_f0 = -16'sd19260; cos_f1 = 16'sd23170; sin_f1 = 16'sd23170; end
            7'd28: begin cos_f0 = 16'sd29934; sin_f0 = -16'sd13328; cos_f1 = 16'sd16384; sin_f1 = 16'sd28377; end
            7'd29: begin cos_f0 = 16'sd32051; sin_f0 = -16'sd6813; cos_f1 = 16'sd8481; sin_f1 = 16'sd31650; end
            7'd30: begin cos_f0 = 16'sd32767; sin_f0 = 16'sd0; cos_f1 = 16'sd0; sin_f1 = 16'sd32767; end
            7'd31: begin cos_f0 = 16'sd32051; sin_f0 = 16'sd6813; cos_f1 = -16'sd8481; sin_f1 = 16'sd31650; end
            7'd32: begin cos_f0 = 16'sd29934; sin_f0 = 16'sd13328; cos_f1 = -16'sd16383; sin_f1 = 16'sd28377; end
            7'd33: begin cos_f0 = 16'sd26509; sin_f0 = 16'sd19260; cos_f1 = -16'sd23170; sin_f1 = 16'sd23170; end
            7'd34: begin cos_f0 = 16'sd21925; sin_f0 = 16'sd24351; cos_f1 = -16'sd28377; sin_f1 = 16'sd16383; end
            7'd35: begin cos_f0 = 16'sd16384; sin_f0 = 16'sd28377; cos_f1 = -16'sd31650; sin_f1 = 16'sd8481; end
            7'd36: begin cos_f0 = 16'sd10126; sin_f0 = 16'sd31163; cos_f1 = -16'sd32767; sin_f1 = 16'sd0; end
            7'd37: begin cos_f0 = 16'sd3425; sin_f0 = 16'sd32587; cos_f1 = -16'sd31650; sin_f1 = -16'sd8481; end
            7'd38: begin cos_f0 = -16'sd3425; sin_f0 = 16'sd32587; cos_f1 = -16'sd28377; sin_f1 = -16'sd16383; end
            7'd39: begin cos_f0 = -16'sd10126; sin_f0 = 16'sd31163; cos_f1 = -16'sd23170; sin_f1 = -16'sd23170; end
            7'd40: begin cos_f0 = -16'sd16383; sin_f0 = 16'sd28377; cos_f1 = -16'sd16383; sin_f1 = -16'sd28377; end
            7'd41: begin cos_f0 = -16'sd21925; sin_f0 = 16'sd24351; cos_f1 = -16'sd8481; sin_f1 = -16'sd31650; end
            7'd42: begin cos_f0 = -16'sd26509; sin_f0 = 16'sd19260; cos_f1 = 16'sd0; sin_f1 = -16'sd32767; end
            7'd43: begin cos_f0 = -16'sd29934; sin_f0 = 16'sd13328; cos_f1 = 16'sd8481; sin_f1 = -16'sd31650; end
            7'd44: begin cos_f0 = -16'sd32051; sin_f0 = 16'sd6813; cos_f1 = 16'sd16383; sin_f1 = -16'sd28377; end
            7'd45: begin cos_f0 = -16'sd32767; sin_f0 = 16'sd0; cos_f1 = 16'sd23170; sin_f1 = -16'sd23170; end
            7'd46: begin cos_f0 = -16'sd32051; sin_f0 = -16'sd6813; cos_f1 = 16'sd28377; sin_f1 = -16'sd16384; end
            7'd47: begin cos_f0 = -16'sd29934; sin_f0 = -16'sd13328; cos_f1 = 16'sd31650; sin_f1 = -16'sd8481; end
            7'd48: begin cos_f0 = -16'sd26509; sin_f0 = -16'sd19260; cos_f1 = 16'sd32767; sin_f1 = 16'sd0; end
            7'd49: begin cos_f0 = -16'sd21925; sin_f0 = -16'sd24351; cos_f1 = 16'sd31650; sin_f1 = 16'sd8481; end
            7'd50: begin cos_f0 = -16'sd16383; sin_f0 = -16'sd28377; cos_f1 = 16'sd28377; sin_f1 = 16'sd16384; end
            7'd51: begin cos_f0 = -16'sd10126; sin_f0 = -16'sd31163; cos_f1 = 16'sd23170; sin_f1 = 16'sd23170; end
            7'd52: begin cos_f0 = -16'sd3425; sin_f0 = -16'sd32587; cos_f1 = 16'sd16383; sin_f1 = 16'sd28377; end
            7'd53: begin cos_f0 = 16'sd3425; sin_f0 = -16'sd32587; cos_f1 = 16'sd8481; sin_f1 = 16'sd31650; end
            7'd54: begin cos_f0 = 16'sd10126; sin_f0 = -16'sd31163; cos_f1 = 16'sd0; sin_f1 = 16'sd32767; end
            7'd55: begin cos_f0 = 16'sd16384; sin_f0 = -16'sd28377; cos_f1 = -16'sd8481; sin_f1 = 16'sd31650; end
            7'd56: begin cos_f0 = 16'sd21925; sin_f0 = -16'sd24351; cos_f1 = -16'sd16383; sin_f1 = 16'sd28377; end
            7'd57: begin cos_f0 = 16'sd26509; sin_f0 = -16'sd19260; cos_f1 = -16'sd23170; sin_f1 = 16'sd23170; end
            7'd58: begin cos_f0 = 16'sd29934; sin_f0 = -16'sd13328; cos_f1 = -16'sd28377; sin_f1 = 16'sd16384; end
            7'd59: begin cos_f0 = 16'sd32051; sin_f0 = -16'sd6813; cos_f1 = -16'sd31650; sin_f1 = 16'sd8481; end
            7'd60: begin cos_f0 = 16'sd32767; sin_f0 = 16'sd0; cos_f1 = -16'sd32767; sin_f1 = 16'sd0; end
            7'd61: begin cos_f0 = 16'sd32051; sin_f0 = 16'sd6813; cos_f1 = -16'sd31650; sin_f1 = -16'sd8481; end
            7'd62: begin cos_f0 = 16'sd29934; sin_f0 = 16'sd13328; cos_f1 = -16'sd28377; sin_f1 = -16'sd16383; end
            7'd63: begin cos_f0 = 16'sd26509; sin_f0 = 16'sd19260; cos_f1 = -16'sd23170; sin_f1 = -16'sd23170; end
            7'd64: begin cos_f0 = 16'sd21925; sin_f0 = 16'sd24351; cos_f1 = -16'sd16384; sin_f1 = -16'sd28377; end
            7'd65: begin cos_f0 = 16'sd16384; sin_f0 = 16'sd28377; cos_f1 = -16'sd8481; sin_f1 = -16'sd31650; end
            7'd66: begin cos_f0 = 16'sd10126; sin_f0 = 16'sd31163; cos_f1 = 16'sd0; sin_f1 = -16'sd32767; end
            7'd67: begin cos_f0 = 16'sd3425; sin_f0 = 16'sd32587; cos_f1 = 16'sd8481; sin_f1 = -16'sd31650; end
            7'd68: begin cos_f0 = -16'sd3425; sin_f0 = 16'sd32587; cos_f1 = 16'sd16384; sin_f1 = -16'sd28377; end
            7'd69: begin cos_f0 = -16'sd10126; sin_f0 = 16'sd31163; cos_f1 = 16'sd23170; sin_f1 = -16'sd23170; end
            7'd70: begin cos_f0 = -16'sd16383; sin_f0 = 16'sd28377; cos_f1 = 16'sd28377; sin_f1 = -16'sd16384; end
            7'd71: begin cos_f0 = -16'sd21925; sin_f0 = 16'sd24351; cos_f1 = 16'sd31650; sin_f1 = -16'sd8481; end
            7'd72: begin cos_f0 = -16'sd26509; sin_f0 = 16'sd19260; cos_f1 = 16'sd32767; sin_f1 = 16'sd0; end
            7'd73: begin cos_f0 = -16'sd29934; sin_f0 = 16'sd13328; cos_f1 = 16'sd31650; sin_f1 = 16'sd8481; end
            7'd74: begin cos_f0 = -16'sd32051; sin_f0 = 16'sd6813; cos_f1 = 16'sd28377; sin_f1 = 16'sd16383; end
            7'd75: begin cos_f0 = -16'sd32767; sin_f0 = 16'sd0; cos_f1 = 16'sd23170; sin_f1 = 16'sd23170; end
            7'd76: begin cos_f0 = -16'sd32051; sin_f0 = -16'sd6813; cos_f1 = 16'sd16384; sin_f1 = 16'sd28377; end
            7'd77: begin cos_f0 = -16'sd29934; sin_f0 = -16'sd13328; cos_f1 = 16'sd8481; sin_f1 = 16'sd31650; end
            7'd78: begin cos_f0 = -16'sd26509; sin_f0 = -16'sd19260; cos_f1 = 16'sd0; sin_f1 = 16'sd32767; end
            7'd79: begin cos_f0 = -16'sd21925; sin_f0 = -16'sd24351; cos_f1 = -16'sd8481; sin_f1 = 16'sd31650; end
            7'd80: begin cos_f0 = -16'sd16384; sin_f0 = -16'sd28377; cos_f1 = -16'sd16384; sin_f1 = 16'sd28377; end
            7'd81: begin cos_f0 = -16'sd10126; sin_f0 = -16'sd31163; cos_f1 = -16'sd23170; sin_f1 = 16'sd23170; end
            7'd82: begin cos_f0 = -16'sd3425; sin_f0 = -16'sd32587; cos_f1 = -16'sd28377; sin_f1 = 16'sd16384; end
            7'd83: begin cos_f0 = 16'sd3425; sin_f0 = -16'sd32587; cos_f1 = -16'sd31650; sin_f1 = 16'sd8481; end
            7'd84: begin cos_f0 = 16'sd10126; sin_f0 = -16'sd31163; cos_f1 = -16'sd32767; sin_f1 = 16'sd0; end
            7'd85: begin cos_f0 = 16'sd16384; sin_f0 = -16'sd28377; cos_f1 = -16'sd31650; sin_f1 = -16'sd8481; end
            7'd86: begin cos_f0 = 16'sd21925; sin_f0 = -16'sd24351; cos_f1 = -16'sd28377; sin_f1 = -16'sd16383; end
            7'd87: begin cos_f0 = 16'sd26509; sin_f0 = -16'sd19260; cos_f1 = -16'sd23170; sin_f1 = -16'sd23170; end
            7'd88: begin cos_f0 = 16'sd29934; sin_f0 = -16'sd13328; cos_f1 = -16'sd16384; sin_f1 = -16'sd28377; end
            7'd89: begin cos_f0 = 16'sd32051; sin_f0 = -16'sd6813; cos_f1 = -16'sd8481; sin_f1 = -16'sd31650; end
            7'd90: begin cos_f0 = 16'sd32767; sin_f0 = 16'sd0; cos_f1 = 16'sd0; sin_f1 = -16'sd32767; end
            7'd91: begin cos_f0 = 16'sd32051; sin_f0 = 16'sd6813; cos_f1 = 16'sd8481; sin_f1 = -16'sd31650; end
            7'd92: begin cos_f0 = 16'sd29934; sin_f0 = 16'sd13328; cos_f1 = 16'sd16383; sin_f1 = -16'sd28377; end
            7'd93: begin cos_f0 = 16'sd26509; sin_f0 = 16'sd19260; cos_f1 = 16'sd23170; sin_f1 = -16'sd23170; end
            7'd94: begin cos_f0 = 16'sd21925; sin_f0 = 16'sd24351; cos_f1 = 16'sd28377; sin_f1 = -16'sd16384; end
            7'd95: begin cos_f0 = 16'sd16383; sin_f0 = 16'sd28377; cos_f1 = 16'sd31650; sin_f1 = -16'sd8481; end
            7'd96: begin cos_f0 = 16'sd10126; sin_f0 = 16'sd31163; cos_f1 = 16'sd32767; sin_f1 = 16'sd0; end
            7'd97: begin cos_f0 = 16'sd3425; sin_f0 = 16'sd32587; cos_f1 = 16'sd31650; sin_f1 = 16'sd8481; end
            7'd98: begin cos_f0 = -16'sd3425; sin_f0 = 16'sd32587; cos_f1 = 16'sd28377; sin_f1 = 16'sd16383; end
            7'd99: begin cos_f0 = -16'sd10126; sin_f0 = 16'sd31163; cos_f1 = 16'sd23170; sin_f1 = 16'sd23170; end
            7'd100: begin cos_f0 = -16'sd16384; sin_f0 = 16'sd28377; cos_f1 = 16'sd16383; sin_f1 = 16'sd28377; end
            7'd101: begin cos_f0 = -16'sd21925; sin_f0 = 16'sd24351; cos_f1 = 16'sd8481; sin_f1 = 16'sd31650; end
            7'd102: begin cos_f0 = -16'sd26509; sin_f0 = 16'sd19260; cos_f1 = 16'sd0; sin_f1 = 16'sd32767; end
            7'd103: begin cos_f0 = -16'sd29934; sin_f0 = 16'sd13328; cos_f1 = -16'sd8481; sin_f1 = 16'sd31650; end
            7'd104: begin cos_f0 = -16'sd32051; sin_f0 = 16'sd6813; cos_f1 = -16'sd16384; sin_f1 = 16'sd28377; end
            7'd105: begin cos_f0 = -16'sd32767; sin_f0 = 16'sd0; cos_f1 = -16'sd23170; sin_f1 = 16'sd23170; end
            7'd106: begin cos_f0 = -16'sd32051; sin_f0 = -16'sd6813; cos_f1 = -16'sd28377; sin_f1 = 16'sd16384; end
            7'd107: begin cos_f0 = -16'sd29934; sin_f0 = -16'sd13328; cos_f1 = -16'sd31650; sin_f1 = 16'sd8481; end
            7'd108: begin cos_f0 = -16'sd26509; sin_f0 = -16'sd19260; cos_f1 = -16'sd32767; sin_f1 = 16'sd0; end
            7'd109: begin cos_f0 = -16'sd21925; sin_f0 = -16'sd24351; cos_f1 = -16'sd31650; sin_f1 = -16'sd8481; end
            7'd110: begin cos_f0 = -16'sd16383; sin_f0 = -16'sd28377; cos_f1 = -16'sd28377; sin_f1 = -16'sd16384; end
            7'd111: begin cos_f0 = -16'sd10126; sin_f0 = -16'sd31163; cos_f1 = -16'sd23170; sin_f1 = -16'sd23170; end
            7'd112: begin cos_f0 = -16'sd3425; sin_f0 = -16'sd32587; cos_f1 = -16'sd16384; sin_f1 = -16'sd28377; end
            7'd113: begin cos_f0 = 16'sd3425; sin_f0 = -16'sd32587; cos_f1 = -16'sd8481; sin_f1 = -16'sd31650; end
            7'd114: begin cos_f0 = 16'sd10126; sin_f0 = -16'sd31163; cos_f1 = 16'sd0; sin_f1 = -16'sd32767; end
            7'd115: begin cos_f0 = 16'sd16384; sin_f0 = -16'sd28377; cos_f1 = 16'sd8481; sin_f1 = -16'sd31650; end
            7'd116: begin cos_f0 = 16'sd21925; sin_f0 = -16'sd24351; cos_f1 = 16'sd16384; sin_f1 = -16'sd28377; end
            7'd117: begin cos_f0 = 16'sd26509; sin_f0 = -16'sd19260; cos_f1 = 16'sd23170; sin_f1 = -16'sd23170; end
            7'd118: begin cos_f0 = 16'sd29934; sin_f0 = -16'sd13328; cos_f1 = 16'sd28377; sin_f1 = -16'sd16384; end
            7'd119: begin cos_f0 = 16'sd32051; sin_f0 = -16'sd6813; cos_f1 = 16'sd31650; sin_f1 = -16'sd8481; end
            default: begin cos_f0 = 16'sd32767; sin_f0 = 16'sd0; cos_f1 = 16'sd32767; sin_f1 = 16'sd0; end
        endcase
    end

endmodule


// Excellent System ES8712 sound controller + OKI MSM6585 ADPCM decoder (Varia Metal), after MAME 0.289's es8712.cpp and msm5205.cpp.
//
// The ES8712 is a programmable address counter: the 68000 writes a start and an end address (20 bits each) and a "go"; it then streams the sample ROM (2 MB, two banks of 1 MB,
// selected by the board's control register) a nibble per VCK pulse of the MSM6585 (high nibble of a byte first, as MAME's recording shows), and raises an interrupt when it has run past the end.
// The MSM6585 (640 kHz master clock, prescaler 40 -> VCK = 16 kHz = every 6000 clocks of the 96 MHz machine clock) decodes one 4-bit ADPCM nibble per VCK into a 12-bit sample:
//   new = signal + diff(step, nibble); clamped to -2048..2047; step += {-1,-1,-1,-1,2,4,6,8}[nibble & 7], clamped to 0..48; while reset is high: signal = 0, step = 0.
// Per VCK, as in MAME (msm5205_device::update_adpcm, es8712_device::msm_int): the ES8712 first hands over the next nibble (or stops: end reached -> MSM reset, IRQ asserted), then the MSM decodes.
// Registers (write, byte offsets 0..6 at 0x500001, 0x500003 ...): 0..2 start (low, mid, high), 3..5 end, 6 go.  A write of the "reset" address 0x500000 resets the device (stops, IRQ cleared).
// Play with start >= end while playing: stops and asserts the IRQ, the MSM keeps running on its last nibble (MAME does the same).  The IRQ line stays asserted until the next play or reset.
// The sample byte is read through a level-style ROM port (o_addr / i_data / i_ok, like the OKI's): a VCK waits (a few clocks at most) until the byte of the current address is there.
`default_nettype none
module metro_es8712 (
    input  logic               clk,
    input  logic               rst,
    input  logic               i_wr,               // one clock: a register write
    input  logic [2:0]         i_a,                // register offset 0..6
    input  logic [7:0]         i_d,
    input  logic               i_reset_w,          // one clock: the device reset write (0x500000)
    input  logic               i_bank,             // sample ROM bank (1 MB halves)
    output logic               o_irq,              // the reset handler line: asserted at the end of a sample
    output logic [20:0]        o_addr,             // byte address in the 2 MB sample region
    input  logic [7:0]         i_data,
    input  logic               i_ok,               // i_data is the byte of o_addr
    output logic signed [15:0] o_audio
);
    logic [19:0] start_r, end_r;
    logic [20:0] base;                             // 21 bits: 0x100000 = past the bank (MAME stops there)
    logic        playing, trig, msm_rst, pend;
    logic [3:0]  nib;                              // the MSM's data latch
    logic signed [11:0] sig;
    logic [5:0]  step;

    assign o_addr = {i_bank, base[19:0]};

    function automatic logic [10:0] stepval(input logic [5:0] s);       // floor(16 * 1.1^s)
        case (s)
            6'd0: stepval = 11'd16;   6'd1: stepval = 11'd17;   6'd2: stepval = 11'd19;   6'd3: stepval = 11'd21;   6'd4: stepval = 11'd23;
            6'd5: stepval = 11'd25;   6'd6: stepval = 11'd28;   6'd7: stepval = 11'd31;   6'd8: stepval = 11'd34;   6'd9: stepval = 11'd37;
            6'd10: stepval = 11'd41;  6'd11: stepval = 11'd45;  6'd12: stepval = 11'd50;  6'd13: stepval = 11'd55;  6'd14: stepval = 11'd60;
            6'd15: stepval = 11'd66;  6'd16: stepval = 11'd73;  6'd17: stepval = 11'd80;  6'd18: stepval = 11'd88;  6'd19: stepval = 11'd97;
            6'd20: stepval = 11'd107; 6'd21: stepval = 11'd118; 6'd22: stepval = 11'd130; 6'd23: stepval = 11'd143; 6'd24: stepval = 11'd157;
            6'd25: stepval = 11'd173; 6'd26: stepval = 11'd190; 6'd27: stepval = 11'd209; 6'd28: stepval = 11'd230; 6'd29: stepval = 11'd253;
            6'd30: stepval = 11'd279; 6'd31: stepval = 11'd307; 6'd32: stepval = 11'd337; 6'd33: stepval = 11'd371; 6'd34: stepval = 11'd408;
            6'd35: stepval = 11'd449; 6'd36: stepval = 11'd494; 6'd37: stepval = 11'd544; 6'd38: stepval = 11'd598; 6'd39: stepval = 11'd658;
            6'd40: stepval = 11'd724; 6'd41: stepval = 11'd796; 6'd42: stepval = 11'd876; 6'd43: stepval = 11'd963; 6'd44: stepval = 11'd1060;
            6'd45: stepval = 11'd1166; 6'd46: stepval = 11'd1282; 6'd47: stepval = 11'd1411; default: stepval = 11'd1552;
        endcase
    endfunction

    function automatic logic signed [6:0] ishift(input logic [2:0] n);   // index_shift = {-1,-1,-1,-1,2,4,6,8}
        case (n)
            3'd4: ishift = 7'sd2;  3'd5: ishift = 7'sd4;  3'd6: ishift = 7'sd6;  3'd7: ishift = 7'sd8;
            default: ishift = -7'sd1;
        endcase
    endfunction

    // VCK = every 6000 clocks; a VCK waits for the ROM byte of the current address while playing
    logic [12:0] vdiv;
    wire         vck_tick = (vdiv == 13'd5999);
    wire         go = (vck_tick || pend) && (!playing || i_ok);

    // the ES8712's step of this VCK, then the MSM's decode of the latched nibble
    wire         past_end = (base >= 21'h100000) || (base > {1'b0, end_r});
    wire         stop_now = playing && past_end;
    wire  [3:0]  nib_n    = (playing && !past_end) ? (trig ? i_data[3:0] : i_data[7:4]) : nib;
    wire         rst_n    = msm_rst || stop_now;
    // the decode runs in three clocks after the VCK's hand-over (timing at 96 MHz): the nibble and reset are latched, then the sum / step, then the clamp
    logic [3:0]  nib_l;
    logic        rst_l, dec1, dec2;
    logic signed [14:0] sum_r, stp_r;
    wire  [10:0] sv       = stepval(step);
    wire  [11:0] mag      = (nib_l[2] ? {1'b0, sv} : 12'd0) + (nib_l[1] ? {2'b0, sv[10:1]} : 12'd0) + (nib_l[0] ? {3'b0, sv[10:2]} : 12'd0) + {4'b0, sv[10:3]};
    wire signed [14:0] sum   = nib_l[3] ? (15'(sig) - $signed({3'b0, mag})) : (15'(sig) + $signed({3'b0, mag}));
    wire signed [14:0] stp   = $signed({9'b0, step}) + 15'(ishift(nib_l[2:0]));

    always_ff @(posedge clk) begin
        dec1 <= 1'b0; dec2 <= 1'b0;
        vdiv <= vck_tick ? 13'd0 : vdiv + 13'd1;
        if (vck_tick) pend <= 1'b1;
        if (rst || i_reset_w) begin
            playing <= 1'b0; trig <= 1'b0; msm_rst <= 1'b1; o_irq <= 1'b0; base <= '0; pend <= 1'b0;
        end else begin
            if (i_wr) begin
                case (i_a)
                    3'd0: start_r[7:0]   <= i_d;
                    3'd1: start_r[15:8]  <= i_d;
                    3'd2: start_r[19:16] <= i_d[3:0];
                    3'd3: end_r[7:0]     <= i_d;
                    3'd4: end_r[15:8]    <= i_d;
                    3'd5: end_r[19:16]   <= i_d[3:0];
                    3'd6: begin                                         // go
                        if (start_r < end_r) begin
                            if (!playing) begin playing <= 1'b1; msm_rst <= 1'b0; o_irq <= 1'b0; base <= {1'b0, start_r}; trig <= 1'b0; end
                        end else if (playing) begin
                            playing <= 1'b0; o_irq <= 1'b1;
                        end
                    end
                    default: ;
                endcase
            end
            if (go) begin
                pend <= 1'b0;
                if (playing) begin
                    if (stop_now) begin playing <= 1'b0; msm_rst <= 1'b1; o_irq <= 1'b1; trig <= 1'b0; end
                    else begin
                        nib  <= nib_n;
                        trig <= ~trig;
                        if (trig) base <= base + 21'd1;
                    end
                end
                nib_l <= nib_n; rst_l <= rst_n; dec1 <= 1'b1;
            end
            if (dec1) begin sum_r <= sum; stp_r <= stp; dec2 <= 1'b1; end
            if (dec2) begin
                if (rst_l) begin sig <= 12'sd0; step <= 6'd0; end
                else begin
                    sig  <= (sum_r > 15'sd2047) ? 12'sd2047 : (sum_r < -15'sd2048) ? -12'sd2048 : sum_r[11:0];
                    step <= (stp_r > 15'sd48) ? 6'd48 : (stp_r < 15'sd0) ? 6'd0 : stp_r[5:0];
                end
            end
        end
    end

    assign o_audio = {sig[11], sig, 3'b000};                                  // signal x 8

    initial begin nib_l = 0; rst_l = 1; dec1 = 0; dec2 = 0; sum_r = 0; stp_r = 0; playing = 0; trig = 0; msm_rst = 1; pend = 0; nib = 0; sig = 0; step = 0; o_irq = 0; base = 0; start_r = 0; end_r = 0; vdiv = 0; end
endmodule
`default_nettype wire

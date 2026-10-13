// Clock enables for the Metro board from the 96 MHz machine clock (the dot clock, 6.0 MHz = /16, is generated inside metro_vdp):
// the 68000 as the alternating phase enables fx68k wants, like mcatadv_cen.sv: 12 MHz = 96 MHz / 8 (phases four clocks apart), or, with
// `fast`, 16 MHz = 96 MHz / 6 (phases three apart; Daitoride and Puzzli have a 32 MHz crystal / 2 on the CPU).
// The sound enables (uPD78C10, YM, M6295) are in metro_sound.
`default_nettype none
module metro_cen (
    input  logic clk,
    input  logic fast,                   // static per game (the board id)
    input  logic mid13,                  // 13.333 MHz (Mahjong Gakuensai: 26.666 MHz / 2 = 96 MHz / 7.2): a phase every 3.6 clocks (3 or 4)
    output logic cen_phi1, cen_phi2
);
    logic [2:0] c = 3'd0;
    wire  [2:0] last = fast ? 3'd5 : 3'd7;
    wire  [2:0] mid  = fast ? 3'd2 : 3'd3;
    logic [4:0] acc = 5'd0;
    logic       ph = 1'b0;
    wire  [5:0] acc_n = {1'b0, acc} + 6'd5;                 // 5 / 18 of a phase a clock
    always_ff @(posedge clk) begin
        if (mid13) begin
            if (acc_n >= 6'd18) begin acc <= 5'(acc_n - 6'd18); ph <= ~ph; cen_phi1 <= ph; cen_phi2 <= ~ph; end
            else begin acc <= acc_n[4:0]; cen_phi1 <= 1'b0; cen_phi2 <= 1'b0; end
        end else begin
            c <= (c == last || c > last) ? 3'd0 : c + 3'd1;     // wraps at 6 or 8
            cen_phi1 <= (c == last);
            cen_phi2 <= (c == mid);
        end
    end
endmodule
`default_nettype wire

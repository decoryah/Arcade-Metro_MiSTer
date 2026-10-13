// The YM2610's two sample ROM ports (ADPCM-A and ADPCM-B) on the SDRAM's one OKI-style client (level protocol: the address presented is served when i_ok is high for it,
// rtl/metro_sdram.sv o_oki_ok).  Each port presents a byte address that changes now and then (A: a new one every 1.5 us slot, B: at the sample rate); the byte is read when
// the address is not the one last served and then kept for the chip.  A and B take the client in turn, one read at a time.
//
// ADPCM-A: the six channels take the port in turn, one per 1.5 us slot, and each presents its own byte address, so the address changes at every slot (666 k a second)
// although a channel moves to a new byte only every second turn (two 4-bit samples per byte) and the idle channels do not move at all.  Read one by one that is about
// 960 000 reads a second of the memory (Blazing Tornado, 24 s of a session in the bench: 23 million), ten times the 55 000 bytes a second the samples need, at a priority
// above the graphics.  So A's last 8 bytes read are kept (FIFO, tagged by byte address): the second turn of every byte and every idle channel answer from them at once.
// The ROM never changes while the machine runs; the tags are cleared while rst is held (the download keeps it).
`default_nettype none
module metro_ympcm (
    input  logic        clk,
    input  logic        rst,
    input  logic [21:0] i_a_addr,          // ADPCM-A byte address (4 MB)
    input  logic [20:0] i_b_addr,          // ADPCM-B byte address (2 MB)
    input  logic [22:0] i_a_off,           // where A's region starts relative to B's (the SDRAM client's base)
    output logic [22:0] o_addr,            // to the SDRAM client
    input  logic  [7:0] i_data,
    input  logic        i_ok,
    output logic  [7:0] o_a_data,
    output logic  [7:0] o_b_data
);
    localparam int NC = 8;                 // A's byte cache entries (>= the six channels)

    logic          a_have, b_have, sel_a, sel_b;
    logic [21:0]   a_served;
    logic [20:0]   b_served;
    logic [NC*22-1:0] c_tag;
    logic [NC*8-1:0]  c_dat;
    logic [NC-1:0] c_v;
    logic [2:0]    c_wp;

    logic [NC-1:0] c_hit;
    logic [7:0]    c_hit_dat;
    always_comb begin
        c_hit_dat = 8'h00;
        for (int i = 0; i < NC; i++) begin
            c_hit[i] = c_v[i] && (c_tag[i*22 +: 22] == i_a_addr);
            if (c_hit[i]) c_hit_dat = c_hit_dat | c_dat[i*8 +: 8];
        end
    end
    wire  a_hit  = |c_hit;

    wire  a_want = !a_have || (i_a_addr != a_served);
    wire  b_want = !b_have || (i_b_addr != b_served);

    assign o_addr = sel_a ? (23'(i_a_addr) + i_a_off) : 23'(i_b_addr);

    always_ff @(posedge clk) begin
        if (rst) begin
            a_have <= 1'b0; b_have <= 1'b0; sel_a <= 1'b0; sel_b <= 1'b0;
            o_a_data <= 8'h00; o_b_data <= 8'h00; a_served <= '0; b_served <= '0;
            c_v <= '0; c_wp <= 3'd0;
        end else if (sel_a) begin
            if (i_ok) begin
                o_a_data <= i_data; a_served <= i_a_addr; a_have <= 1'b1; sel_a <= 1'b0;
                c_tag[c_wp*22 +: 22] <= i_a_addr; c_dat[c_wp*8 +: 8] <= i_data; c_v[c_wp] <= 1'b1; c_wp <= c_wp + 3'd1;
            end
        end else if (sel_b) begin
            if (i_ok) begin o_b_data <= i_data; b_served <= i_b_addr; b_have <= 1'b1; sel_b <= 1'b0; end
        end else begin
            if (a_want) begin
                if (a_hit) begin o_a_data <= c_hit_dat; a_served <= i_a_addr; a_have <= 1'b1; end
                else       sel_a <= 1'b1;
            end else if (b_want) sel_b <= 1'b1;
        end
    end
endmodule
`default_nettype wire

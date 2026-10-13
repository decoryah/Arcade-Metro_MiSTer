// Program-ROM read adapter: metro_main holds rom_req (with a stable word address) until it sees rom_ack, while metro_sdram's main-ROM client takes a
// one-clock read pulse (it latches the address then) and answers with a one-clock valid.  The data is held with ack until req drops.
//
// A read from the SDRAM answers about 13 clocks after AS, just after the 68000 samples DTACK, which cost one wait state on every program-ROM cycle
// (40 instead of 32 clocks, about 16% of the CPU's speed; the board has none).  So the words are kept in a direct-mapped cache of 512 words
// (METRO, 2026-10-09: 2048 words, a 512-word cache still waited on 19.5 % of the program-ROM cycles of Lady Killer's attract, 13 % of them for two wait states, about 10 % of the
// CPU's time: the game's per-frame work then spilled across the vblank where MAME's CPU finishes it inside, a 34-sprite group of the instruction panel was missing in single frames)
// and, after every demand, the next word is fetched into it in the background: sequential code and small loops answer from the cache in about
// 5 clocks (as fast as the work RAM), only a jump to code not seen recently waits for the SDRAM.  ROM content never changes while the machine
// runs; the tags are cleared while rst is held (the download keeps it for far more than the 512 clocks the sweep needs).
`default_nettype none
module metro_romif #(
    parameter int IDX = 11                   // cache index bits: 2^IDX words
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        req,
    input  logic [20:1] addr,                // 2 MB of program ROM (family F; Varia Metal 1 MB, Toride II 512 KB, Dharma the lower 256 KB)
    output logic        ack,
    output logic [15:0] data,
    output logic        rd,              // to metro_sdram i_mrom_rd
    output logic [20:0] raddr,           // to metro_sdram i_mrom_addr (word address)
    input  logic        valid,
    input  logic [15:0] rdata
);
    typedef enum logic [2:0] {S_IDLE, S_LK, S_WAIT, S_PF0, S_PF1, S_PFWAIT} st_e;
    st_e st;

    logic [20:1] a_q;                                   // the word being served
    wire  [20:1] pf_a = a_q + 20'd1;                    // the word after it

    // cache: 512 words, index = addr[9:1], tag = addr[18:10] plus a valid bit
    localparam int TW = 20 - IDX;                       // tag bits (the valid bit comes on top)
    logic [15:0]   cdata [0:(1 << IDX) - 1];
    logic [TW:0]   ctag  [0:(1 << IDX) - 1];
    logic [IDX-1:0] swp;
    logic [15:0]   q_data;
    logic [TW:0]   q_tag;

    wire [IDX-1:0] ridx = (st == S_PF0) ? pf_a[IDX:1] : addr[IDX:1];
    wire       fill = !rst && valid && (st == S_WAIT || st == S_PFWAIT);
    wire [20:1] fa  = (st == S_WAIT) ? a_q : pf_a;

    always_ff @(posedge clk) begin
        if (rst)       ctag[swp]   <= '0;
        else if (fill) ctag[fa[IDX:1]] <= {1'b1, fa[20:IDX+1]};
        if (fill)      cdata[fa[IDX:1]] <= rdata;
        q_data <= cdata[ridx];
        q_tag  <= ctag[ridx];
    end

    always_ff @(posedge clk) begin
        rd <= 1'b0;
        if (rst) begin
            swp <= swp + 1'b1;
            st  <= S_IDLE;
            ack <= 1'b0;
        end else begin
            if (!req) ack <= 1'b0;
            case (st)
                S_IDLE: if (req && !ack) begin
                    a_q <= addr;
                    st  <= S_LK;                        // the cache read of addr is issued now, its answer is there next clock
                end
                S_LK: begin                             // q_data/q_tag: the cache entry of a_q
                    if (q_tag == {1'b1, a_q[20:IDX+1]}) begin
                        data <= q_data; ack <= 1'b1; st <= S_PF0;
                    end else begin
                        rd <= 1'b1; raddr <= {1'b0, a_q}; st <= S_WAIT;
                    end
                end
                S_WAIT: if (valid) begin                // (the fill into the cache happens in the write block above)
                    data <= rdata; ack <= 1'b1; st <= S_PF0;
                end
                S_PF0: st <= S_PF1;                     // the cache read of the next word is issued (ridx), its answer is there next clock
                S_PF1: begin
                    if (q_tag == {1'b1, pf_a[20:IDX+1]}) st <= S_IDLE;
                    else begin rd <= 1'b1; raddr <= {1'b0, pf_a}; st <= S_PFWAIT; end
                end
                S_PFWAIT: if (valid) st <= S_IDLE;
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire

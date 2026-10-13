// Two requesters (the 68000's program-ROM interface and the sound CPU's) share metro_sdram's single main-ROM client: one read in flight at a time,
// the 68000 first when both wait (its instruction fetches set the game's speed; the sound CPU is paced by its own state counts), round-robin otherwise.
// Each requester gives a one-clock `rd` pulse with a word address and gets the one-clock `valid` pulse with `rdata` back; no new pulse before the answer.
`default_nettype none
module metro_mrom_arb (
    input  logic        clk,
    input  logic        rst,
    input  logic        rd_a,
    input  logic [20:0] addr_a,
    output logic        valid_a,
    input  logic        rd_b,
    input  logic [20:0] addr_b,
    output logic        valid_b,
    output logic [15:0] rdata,
    // metro_sdram's client
    output logic        rd,
    output logic [20:0] raddr,
    input  logic        valid,
    input  logic [15:0] sdata
);
    logic        pend_a, pend_b, busy, who, last;       // who: 0 = A, 1 = B
    logic [20:0] qa, qb;
    assign rdata   = sdata;
    assign valid_a = valid && busy && !who;
    assign valid_b = valid && busy &&  who;

    always_ff @(posedge clk) begin
        rd <= 1'b0;
        if (rst) begin
            pend_a <= 1'b0; pend_b <= 1'b0; busy <= 1'b0; who <= 1'b0; last <= 1'b0;
        end else begin
            if (rd_a) begin pend_a <= 1'b1; qa <= addr_a; end
            if (rd_b) begin pend_b <= 1'b1; qb <= addr_b; end
            if (busy) begin
                if (valid) busy <= 1'b0;
            end else if (pend_a && (!pend_b || last)) begin          // A goes first unless it was served last and B waits
                rd <= 1'b1; raddr <= (rd_a ? addr_a : qa); busy <= 1'b1; who <= 1'b0; pend_a <= 1'b0; last <= 1'b0;
            end else if (pend_b) begin
                rd <= 1'b1; raddr <= (rd_b ? addr_b : qb); busy <= 1'b1; who <= 1'b1; pend_b <= 1'b0; last <= 1'b1;
            end
        end
    end
endmodule
`default_nettype wire

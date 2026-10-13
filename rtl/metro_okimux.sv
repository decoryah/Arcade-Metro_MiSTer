// Two users of the SDRAM's one OKI-style sample client (level protocol: the address presented is served when o_ok is high for it): the OKI M6295 core, which presents addresses
// all the time, and the ES8712 (Varia Metal), which needs one byte every 6000 clocks.  The OKI keeps the port; when the ES8712's address is not the one last served the port is
// given to it for the one read (the byte is latched here, so the ES8712 sees a stable i_es_data / es_ok whoever owns the port afterwards) and then returned.
`default_nettype none
module metro_okimux (
    input  logic        clk,
    input  logic        rst,
    input  logic        i_en,                   // Varia Metal only: no steals on the other boards
    input  logic [21:0] i_oki_addr,
    input  logic [20:0] i_es_addr,              // byte address in the ES8712's 2 MB
    input  logic [21:0] i_es_off,               // where the ES8712's region starts relative to the OKI region
    output logic [21:0] o_addr,                 // to the SDRAM client
    input  logic [7:0]  i_data,
    input  logic        i_ok,
    output logic        o_oki_ok,
    output logic [7:0]  o_es_data,
    output logic        o_es_ok
);
    logic        sel_es, es_have;
    logic [20:0] es_served;
    wire         es_want = i_en && (!es_have || (i_es_addr != es_served));

    assign o_addr    = sel_es ? (22'(i_es_addr) + i_es_off) : i_oki_addr;
    assign o_oki_ok  = i_ok && !sel_es;
    assign o_es_ok   = es_have && (i_es_addr == es_served);

    always_ff @(posedge clk) begin
        if (rst) begin sel_es <= 1'b0; es_have <= 1'b0; end
        else if (sel_es) begin
            if (i_ok) begin o_es_data <= i_data; es_served <= i_es_addr; es_have <= 1'b1; sel_es <= 1'b0; end
        end else if (es_want) sel_es <= 1'b1;
    end
    initial begin sel_es = 0; es_have = 0; es_served = 0; o_es_data = 0; end
endmodule
`default_nettype wire

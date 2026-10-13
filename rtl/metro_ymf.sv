// Wrapper of the YMF278B (OPL4) for family C (Mouse Shooter GoGo, Bal Cube, Daitoride's YMF278B version, Bang Bang Ball): the 68000's byte writes to its six ports and the status
// read, the chip clock (33.8688 MHz from the 96 MHz machine clock), the wave ROM (the `ymf` region of the set, 2.5 MB: Yamaha's YRW801 at 0 and the game's 512 KB at 0x200000)
// through the SDRAM's OKI-style client, and the mono mix of MAME's routing (every output of the chip on one speaker: DO0 + DO1 + DO2).
//
// The engine (rtl/ymf278b.sv, srg320's, derived from MAME) is paced by a chip-clock enable that is held back only when the byte it is about to sample has not arrived from the
// SDRAM (CAP_NEXT): its own memory timing gives 8 chip clocks (22.7 machine clocks) between the address and the sample, which the SDRAM normally meets.  The FM timers do not wait.
//
//   i_wr / i_a / i_d   a byte written to port i_a (0 .. 5: FM address 0 / data 0 / address 1 / data 1 / PCM address / PCM data), one clock, the data held
//   i_rd               one clock when the 68000 reads the status (port 0)
//   o_status           the status byte (valid whenever)
//   o_irq              level, high = interrupt requested (the FM timers' flags; the 68000's level 2)
`default_nettype none
module metro_ymf (
    input  logic        clk,                 // 96 MHz
    input  logic        rst,
    input  logic        i_wr,
    input  logic  [2:0] i_a,
    input  logic  [7:0] i_d,
    input  logic        i_rd,
    output logic  [7:0] o_status,
    output logic        o_irq,
    output logic [21:0] o_addr,              // wave ROM byte address (the engine's, 22 bits)
    input  logic  [7:0] i_data,
    input  logic        i_ok,                // i_data is the byte at o_addr
    output logic signed [15:0] o_audio,      // mono, updated at the chip's 44.1 kHz
    output logic        o_stall              // observation: the engine's clock enable is being held back
);
    // ------------------------------------------------------------------ chip clock: 33.8688 MHz = 96 MHz x 441 / 1250
    logic [10:0] acc = 11'd0;
    wire  [10:0] acc_n = acc + 11'd441;
    logic        ce_pat = 1'b0;
    always_ff @(posedge clk) begin
        if (acc_n >= 11'd1250) begin acc <= acc_n - 11'd1250; ce_pat <= 1'b1; end
        else begin acc <= acc_n; ce_pat <= 1'b0; end
    end

    // ------------------------------------------------------------------ the 68000's accesses: WR_N / RD_N go low a few clocks after the data and A are stable and stay low until the
    // engine has had four clock enables with them low (the engine looks at them on its enable only; the enable is held back while a byte of the wave ROM is awaited, so a fixed
    // pulse could pass between two enables or, worse, was let through the hold and the engine sampled a byte that had not arrived)
    logic  [2:0] a_r;
    logic  [7:0] d_r;
    logic        wr_act = 1'b0, rd_act = 1'b0;
    logic  [4:0] wr_age = 5'd0, rd_age = 5'd0;
    logic  [2:0] wr_ces = 3'd0, rd_ces = 3'd0;
    wire         ce;
    always_ff @(posedge clk) begin
        if (rst) begin wr_act <= 1'b0; rd_act <= 1'b0; end
        else begin
            if (wr_act) begin
                if (wr_age != 5'd31) wr_age <= wr_age + 5'd1;
                if (ce && wr_age >= 5'd6 && wr_ces != 3'd7) wr_ces <= wr_ces + 3'd1;
                if (wr_age >= 5'd30 && wr_ces >= 3'd4) wr_act <= 1'b0;
            end
            if (rd_act) begin
                if (rd_age != 5'd31) rd_age <= rd_age + 5'd1;
                if (ce && rd_age >= 5'd6 && rd_ces != 3'd7) rd_ces <= rd_ces + 3'd1;
                if (rd_age >= 5'd30 && rd_ces >= 3'd4) rd_act <= 1'b0;
            end
            if (i_wr) begin a_r <= i_a; d_r <= i_d; wr_act <= 1'b1; wr_age <= 5'd0; wr_ces <= 3'd0; end
            else if (i_rd && !wr_act) begin a_r <= 3'd0; rd_act <= 1'b1; rd_age <= 5'd0; rd_ces <= 3'd0; end
        end
    end
    wire wr_n = !(wr_act && wr_age >= 5'd6);
    wire rd_n = !(rd_act && rd_age >= 5'd6);

    // ------------------------------------------------------------------ the engine
    logic        mrd_n, cap_next;
    logic [21:0] ma;
    logic [15:0] out2_l, out2_r;
    wire         irq_n;
    wire   [7:0] status;
    wire         unmapped = ma >= 22'h280000;                  // MAME's map: ROM 0 .. 0x27FFFF, nothing above
    wire   [7:0] mdi  = unmapped ? 8'h00 : i_data;
    wire         mok  = unmapped || i_ok;
    wire         stall = cap_next && !mrd_n && !mok;
    assign       ce   = ce_pat && !stall;
    assign o_stall = stall;

    YMF278B u_ymf (
        .CLK(clk), .RST_N(!rst), .EN(1'b1), .CE(ce), .CE_TMR(ce_pat),
        .A(a_r), .DI(d_r), .DO(), .STATUS(status),
        .RD_N(rd_n), .WR_N(wr_n), .CS_N(1'b0), .IC_N(!rst),
        .IRQ_N(irq_n),
        .MA(ma), .CAP_NEXT(cap_next), .MDI(mdi), .MDO(), .MRD_N(mrd_n), .MWR_N(), .MCS_N(),
        .OUT0_L(), .OUT0_R(), .OUT1_L(), .OUT1_R(), .OUT2_L(out2_l), .OUT2_R(out2_r),
        .SND_EN(3'b111), .MONO(1'b0)
    );
    assign o_addr   = ma;
    assign o_irq    = !irq_n;
    assign o_status = status;

    // mono: MAME routes every output to one speaker (gain 1.0)
    wire signed [17:0] mix = $signed({out2_l[15], out2_l[15], out2_l}) + $signed({out2_r[15], out2_r[15], out2_r});
    always_ff @(posedge clk)
        o_audio <= (mix > 18'sd32767) ? 16'sd32767 : (mix < -18'sd32768) ? -16'sd32768 : mix[15:0];
endmodule
`default_nettype wire

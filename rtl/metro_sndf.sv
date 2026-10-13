// Family F's sound board (Blazing Tornado, Grand Striker 2; metro.cpp blzntrnd_state::sound_map / sound_io_map): a Z80 at 8 MHz, a YM2610 (jt10) at 8 MHz and the command latch
// of the 68000.  After mcatadv-mister's board (mcatadv_sound.sv, the same chip pair), the Z80's program through the SDRAM word client of the 68000's ROM and the sample ROMs
// through the OKI-style byte client.
//
//   0000-7FFF  ROM                      I/O 00 (write)  ROM bank = data & 7 (16 KB steps of the 128 KB at 8000-BFFF)
//   8000-BFFF  ROM, banked              I/O 40 (read)   the 68000's command latch (reading it clears the pending flag and so the NMI); writes are ignored
//   E000-FFFF  RAM                      I/O 80-83       the YM2610
//
// The command latch raises the Z80's NMI while it holds an unread byte (generic_latch_8's data pending output); the YM2610's IRQ output is the Z80's INT.
`default_nettype none
module metro_sndf #(
    parameter [12:0] RST_EXTRA = 13'h1fff,    // clocks the sound board stays in reset after the board's (85 us): the YM2610's pipelines need a long reset
    parameter        YM_DIV    = 6,           // clk_snd clocks to the YM2610's 8 MHz enable (48 MHz / 6)
    parameter [24:0] SSG_K     = 25'sd2055,   // 64 x the SSG's gain in the mono mix: 64.25 (a jt49 level step in ymfm's) x 2/3 x the route's 0.75
    parameter [24:0] FM_W      = 25'sd16      // 64 x the FM + ADPCM gain of each of the two outputs: 0.25 (Grand Striker 2's mono routes)
) (
    input  logic        clk,
    input  logic        clk_snd,
    input  logic        rst,
    input  logic        cen_z80,              // 8 MHz

    input  logic        i_stereo,             // Blazing Tornado (HUM-002 board): stereo, the SSG 0.75 on both sides and the FM / ADPCM left and right at 1.0; Grand Striker 2: mono, SSG 0.75 + FM 0.25 + 0.25
    input  logic  [7:0] cmd,
    input  logic        cmd_wr,

    // the Z80's program: word reads of the 68000's ROM client (word address 0x100000 + the byte address / 2 of the 128 KB)
    output logic        zr_rd,
    output logic [20:0] zr_addr,
    input  logic        zr_valid,
    input  logic [15:0] zr_data,

    // the sample ROMs
    output logic [21:0] pa_addr,              // ADPCM-A byte address
    output logic [20:0] pb_addr,              // ADPCM-B byte address
    input  logic  [7:0] pa_data,
    input  logic  [7:0] pb_data,

    output logic signed [15:0] snd_l, snd_r,
    output logic        snd_valid,
    output logic        dbg_z80_rd,
    output logic  [4:0] dbg_ev                // [0] ADPCM-A key on, [1] command latched, [2] command read, [3] YM IRQ, [4] Z80 held for its ROM
);
    // ---------------------------------------------------------------- reset
    logic [12:0] rst_cnt = '1;
    logic        rst_q = 1'b1;
    always_ff @(posedge clk) begin
        if (rst) rst_cnt <= RST_EXTRA;
        else if (rst_cnt != 13'd0) rst_cnt <= rst_cnt - 13'd1;
        rst_q <= rst | (rst_cnt != 13'd0);
    end

    // ---------------------------------------------------------------- Z80
    logic        mreq_n, iorq_n, rd_n, wr_n, m1_n;
    logic [15:0] A;
    logic  [7:0] di, dout;
    logic        ym_irq_n, nmi_pend, wait_n;

    tv80s_cen u_z80 (
        .reset_n(~rst_q), .clk(clk), .cen(cen_z80), .wait_n(wait_n), .int_n(ym_irq_n), .nmi_n(~nmi_pend), .busrq_n(1'b1),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n), .rfsh_n(), .halt_n(), .busak_n(),
        .A(A), .di(di), .dout(dout)
    );

    wire mem_rd = ~mreq_n & ~rd_n;
    wire mem_wr = ~mreq_n & ~wr_n;
    wire io_rd  = ~iorq_n & ~rd_n & m1_n;
    wire io_wr  = ~iorq_n & ~wr_n & m1_n;

    wire sel_rom0 = ~A[15];                                            // 0000-7FFF
    wire sel_bnk  = A[15] & ~A[14];                                    // 8000-BFFF
    wire sel_ram  = A[15] & A[14] & A[13];                             // E000-FFFF
    wire io_bank  = io_wr && (A[7:0] == 8'h00);
    wire io_latch = io_rd && (A[7:0] == 8'h40);
    wire io_ym    = (io_rd | io_wr) && (A[7:2] == 6'b100000);          // 80-83

    // ---------------------------------------------------------------- program ROM: bank, a 512 word cache (direct mapped, MLABs), WAIT while a word is fetched
    // (a one word cache turned every instruction of a two word wait loop into an SDRAM access: an ACT to one bank every 6 clocks, continuously; the 8 word cache that
    // followed still fetched ~1.6 million words a second in Blazing Tornado's sound driver, ~20 % of the SDRAM's time at a priority above the graphics)
    logic [2:0] bank = 3'd0;
    always_ff @(posedge clk) begin
        if (rst_q) bank <= 3'd0;
        else if (io_bank) bank <= dout[2:0];
    end
    wire [16:0] rb = sel_bnk ? {bank, A[13:0]} : {2'b00, A[14:0]};     // byte address in the 128 KB
    wire        rom_rd = mem_rd && (sel_rom0 || sel_bnk);
    localparam int CIDX = 9;                                           // 2^CIDX words
    localparam int CTAG = 16 - CIDX;                                   // tag bits of the 16 bit word address (the valid bit comes on top)
    // MLABs with a REGISTERED read (an asynchronous read next to a write is "unsupported read-during-write" for Quartus 17: the 512 words became 12,000 flip-flops and
    // missed timing by 0.65 ns, 20261011d's first fit).  The Z80 is slow against this clock (a bus cycle is 12 clocks): the lookup of the address takes two, c_ok says the registers
    // hold the entry of the address now on the bus.
    (* ramstyle = "MLAB" *) logic [CTAG:0]  c_tag [0:(1 << CIDX) - 1];
    (* ramstyle = "MLAB" *) logic [15:0]    c_dat [0:(1 << CIDX) - 1];
    logic [CIDX-1:0] c_swp = '0;                                       // clears the tags while the board is held in reset (the download keeps it for ages)
    logic [15:0] c_addr;                                               // the word address being fetched
    logic        z_pend;
    logic  [1:0] c_hold = 2'd0;                                        // after a fill the lookup registers need two clocks to show it: no second request meanwhile
    wire  [CIDX-1:0] c_idx = rb[CIDX:1];
    logic [CIDX-1:0] c_idx_q;
    logic [CTAG:0]   c_tq;
    logic [15:0]     c_dq;
    wire         c_ok = (c_idx_q == c_idx);                            // the looked-up entry is the one of this address
    wire         hit  = c_ok && c_tq[CTAG] && (c_tq[CTAG-1:0] == rb[16:CIDX+1]);
    assign wait_n = ~(rom_rd && !hit);
    wire         c_fill = zr_valid && z_pend && !rst_q;
    always_ff @(posedge clk) begin
        if (rst_q)       c_tag[c_swp] <= '0;
        else if (c_fill) c_tag[c_addr[CIDX-1:0]] <= {1'b1, c_addr[15:CIDX]};
        if (c_fill)      c_dat[c_addr[CIDX-1:0]] <= zr_data;
        c_idx_q <= c_idx;
        c_tq    <= c_tag[c_idx];
        c_dq    <= c_dat[c_idx];
    end
    always_ff @(posedge clk) begin
        zr_rd <= 1'b0;
        if (rst_q) begin c_swp <= c_swp + 1'b1; z_pend <= 1'b0; c_hold <= 2'd0; end
        else begin
            if (c_hold != 2'd0) c_hold <= c_hold - 2'd1;
            if (rom_rd && c_ok && !hit && !z_pend && c_hold == 2'd0) begin
                zr_rd <= 1'b1; zr_addr <= 21'h100000 + {5'd0, rb[16:1]}; z_pend <= 1'b1; c_addr <= rb[16:1];
            end
            if (zr_valid && z_pend) begin z_pend <= 1'b0; c_hold <= 2'd2; end
        end
    end
    wire [7:0] rom_q = rb[0] ? c_dq[7:0] : c_dq[15:8];

    // ---------------------------------------------------------------- RAM (8 KB)
`ifdef F_BUILD
    (* ramstyle = "M10K" *) logic [7:0] ram [0:8191];             // the dedicated family F build has the blocks (the old sound board is not built)
`else
    (* ramstyle = "MLAB" *) logic [7:0] ram [0:8191];            // (MLABs: the device's M10K blocks are used up)
`endif
    logic [7:0] ram_q;
    always_ff @(posedge clk) begin
        if (mem_wr && sel_ram) ram[A[12:0]] <= dout;
        ram_q <= ram[A[12:0]];
    end

    // ---------------------------------------------------------------- latch
    logic [7:0] cmd_l;
    always_ff @(posedge clk) begin
        if (rst_q) begin nmi_pend <= 1'b0; cmd_l <= 8'h00; end
        else begin
            if (cmd_wr) begin cmd_l <= cmd; nmi_pend <= 1'b1; end
            else if (io_latch) nmi_pend <= 1'b0;
        end
    end

    // ---------------------------------------------------------------- YM2610 on the 48 MHz clock
    logic [7:0]  ym_q;
    logic [19:0] adpcma_addr;
    logic  [4:0] adpcma_bank;
    logic        adpcma_roe_n, adpcmb_roe_n;
    logic [23:0] adpcmb_addr;
    logic signed [15:0] fm_l, fm_r;
    logic  [7:0] psg_a, psg_b, psg_c;
    logic        ym_sample;
    wire         ym_cs_n = ~io_ym;

    logic [2:0] ydiv = 3'd0;
    logic       cen_ym = 1'b0;
    always_ff @(posedge clk_snd) begin
        ydiv   <= (ydiv == YM_DIV - 1) ? 3'd0 : ydiv + 3'd1;
        cen_ym <= (ydiv == YM_DIV - 1);
    end
    logic rst_snd = 1'b1;
    always_ff @(posedge clk_snd) rst_snd <= rst_q;

    jt10 u_ym (
        .rst(rst_snd), .clk(clk_snd), .cen(cen_ym),
        .din(dout), .addr(A[1:0]), .cs_n(ym_cs_n), .wr_n(wr_n),
        .dout(ym_q), .irq_n(ym_irq_n),
        .adpcma_addr(adpcma_addr), .adpcma_bank(adpcma_bank), .adpcma_roe_n(adpcma_roe_n), .adpcma_data(pa_data),
        .adpcmb_addr(adpcmb_addr), .adpcmb_roe_n(adpcmb_roe_n), .adpcmb_data(pb_data),
        .psg_A(psg_a), .psg_B(psg_b), .psg_C(psg_c), .fm_left(fm_l), .fm_right(fm_r),
        .psg_snd(), .snd_right(), .snd_left(), .snd_sample(ym_sample), .ch_enable(6'h3F), .adpcmA_l_dbg()
    );
    assign pa_addr = {adpcma_bank[1:0], adpcma_addr};
    assign pb_addr = adpcmb_addr[20:0];

    // ---------------------------------------------------------------- Z80 data bus
    always_comb begin
        di = 8'h00;
        if (~iorq_n & ~m1_n & ~rd_n) di = 8'hFF;                 // interrupt acknowledge
        else if (io_latch) di = cmd_l;
        else if (io_ym & io_rd) di = ym_q;
        else if (mem_rd) begin
            if (sel_ram)                  di = ram_q;
            else if (sel_bnk | sel_rom0)  di = rom_q;
        end
    end

    // ---------------------------------------------------------------- mix (made on the chip's clock, handed over registered)
    // The SSG's three levels change at the chip's own (high) rate; one snapshot of them per output sample aliases the square waves into hash (a "scratchy" sound: the first
    // hardware test of Grand Striker 2).  What MAME's resampler delivers is their average over the sample period (YM_DIV * 144 clk_snd clocks): the box average here.
    localparam int SSG_N     = YM_DIV * 144;
    localparam int SSG_RECIP = (1 << 22) / SSG_N;
    logic [19:0] psg_acc = '0;
    logic  [9:0] psg_avg = '0;
    wire   [9:0] psg_now = {2'b00, psg_a} + {2'b00, psg_b} + {2'b00, psg_c};
    always_ff @(posedge clk_snd) begin
        if (ym_sample) begin
            psg_avg <= 10'((40'(psg_acc + 20'(psg_now)) * 40'(SSG_RECIP)) >> 22);
            psg_acc <= '0;
        end else begin
            psg_acc <= psg_acc + 20'(psg_now);
        end
    end
    // MAME's routes: SSG 0.75; Blazing Tornado FM / ADPCM left 1.0 to the left and right 1.0 to the right (64 / 64 here), Grand Striker 2 both 0.25 to the one output
    wire signed [24:0] ssg_part = $signed({15'd0, psg_avg}) * $signed(SSG_K);
    wire signed [24:0] fm_part_l = i_stereo ? ($signed(fm_l) <<< 6) : (($signed(fm_l) + $signed(fm_r)) * $signed(FM_W));
    wire signed [24:0] fm_part_r = i_stereo ? ($signed(fm_r) <<< 6) : (($signed(fm_l) + $signed(fm_r)) * $signed(FM_W));
    wire signed [24:0] mix_l = (ssg_part + fm_part_l) >>> 6;
    wire signed [24:0] mix_r = (ssg_part + fm_part_r) >>> 6;
    wire signed [15:0] out_l = (mix_l > 25'sd32767) ? 16'sd32767 : (mix_l < -25'sd32768) ? -16'sd32768 : mix_l[15:0];
    wire signed [15:0] out_r = (mix_r > 25'sd32767) ? 16'sd32767 : (mix_r < -25'sd32768) ? -16'sd32768 : mix_r[15:0];
    logic ym_sample_d = 1'b0;
    logic signed [15:0] out_l_r, out_r_r;
    always_ff @(posedge clk_snd) begin
        ym_sample_d <= ym_sample;
        if (ym_sample) begin out_l_r <= out_l; out_r_r <= out_r; end
    end
    always_ff @(posedge clk) begin
        snd_valid <= ym_sample_d;
        if (ym_sample_d) begin snd_l <= out_l_r; snd_r <= out_r_r; end
    end
    assign dbg_z80_rd = mem_rd;

    // ---------------------------------------------------------------- debug events
    logic ywr_d, ywr_dd, nmi_d;
    logic [7:0] ysel1;
    wire  ywr = io_ym & io_wr;
    always_ff @(posedge clk) begin
        ywr_d <= ywr; ywr_dd <= ywr_d; nmi_d <= nmi_pend;
        dbg_ev <= 5'd0;
        if (ywr_d & ~ywr_dd) begin
            if (A[1:0] == 2'd2) ysel1 <= dout;
            if (A[1:0] == 2'd3 && ysel1 == 8'h00 && !dout[7] && dout[5:0] != 6'd0) dbg_ev[0] <= 1'b1;
        end
        dbg_ev[1] <= nmi_pend & ~nmi_d;
        dbg_ev[2] <= io_latch;
        dbg_ev[3] <= ~ym_irq_n;
        dbg_ev[4] <= rom_rd & ~hit;
    end
endmodule
`default_nettype wire

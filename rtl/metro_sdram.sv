// Derived from searchsolved/Arcade-HyperDuel_MiSTer rtl/hyprduel_sdram.sv at 7f154f1e856ce5863f962821f2b330d1e8a85727 (GPL-3.0-or-later, see ../LICENSE).
// Renamed hyprduel_sdram -> metro_sdram.  METRO changes (marked in the code): image-layout address bases, 96 MHz refresh/init timing,
// the i_rd_late runtime read-capture option.  The shared-RAM (sr3) client and the debug/self-test scaffolding are kept but unused:
// tie i_sr3_req low, leave the dbg_* outputs open.
// SDRAM controller + ROM arbiter for the Hyper Duel core.
//
// Serves hyprduel_sys's three read clients plus a CPU shared-RAM port
// from one 16-bit SDRAM (MiSTer 32 MB module baseline: 4 banks x 8192
// rows x 512 cols) plus the ioctl download write path:
//
//   priority 0  download    byte pairs written as words (highest; core in reset)
//   priority 1  shared3 CPU RAM (single word R/W, byte enables via DQM)
//   priority 2  GFX stream  (i_gfx_req/addr/len -> len byte pulses)
//   priority 3  main 68000 ROM (single word, req/valid)
//   priority 4  OKI sample ROM (jt-style addr/ok, byte held stable)
//   refresh     slots into idle gaps, forced ahead of grants if overdue
//
// SDRAM byte map (matches mister/README.md and the MRA):
//   0x000000 main ROM (512 KB)   0x080000 GFX ROM (4 MB)
//   0x480000 OKI samples (256 KB)
//   0x500000 shared3 CPU RAM (112 KB, not downloaded via MRA)
//
// Policy: close-page. Every access is ACT, tRCD, CAS(+auto precharge
// on the last read), so banks are always precharged and refresh can
// slot in whenever the FSM is idle. A GFX stream is up to 64 bytes =
// 33 words; reads issue back-to-back (one word per cycle after CL2)
// and byte pulses drain from a small FIFO at one per cycle. Streams
// crossing a 512-word row boundary re-activate internally.
//
// Byte lanes follow the 68000/build_mainrom.py convention everywhere:
// even byte address = word[15:8], odd byte address = word[7:0].
//
// Timing at 80 MHz CL2: tRCD/tRP = 2 cycles, tRFC = 8, refresh every
// 625 cycles (64 ms / 8192 rows). On hardware SDRAM_CLK is the
// PLL-phase-shifted copy of clk (set in the .qsf); if board-level
// capture needs an extra cycle, bump P_RET by one.

module metro_sdram #(
    parameter bit P_SHORT_INIT = 1'b0,  // sim: skip the 100 us power-up wait
    parameter int P_RET = 3             // CAS cmd reg -> dq_in reg, cycles
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic        o_ready,        // init done
    input  logic        i_rd_late,      // METRO: 1 = capture read data one cycle later (OSD "SDRAM read capture"), tunes the pin timing on hardware

    // GFX ROM stream client (byte addresses within the GFX region: up to 16 MB)
    input  logic        i_gfx_req,      // 1-cycle pulse; addr/len then stable
    input  logic [25:0] i_gfx_addr,      // METRO: 26 bits (the F64 build: the graphics space above the first MB reaches the tile map RAM at 60 MB)
    input  logic [6:0]  i_gfx_len,      // bytes, 1..64
    // WORD-mode stream (even addr AND even len, e.g. renderer/CPU window):
    // each valid pulse carries TWO bytes - [15:8] = even (lower) address,
    // [7:0] = odd. Byte-mode requests (blitter, len 1) pulse one byte per
    // valid in [7:0].
    output logic [15:0] o_gfx_data,
    output logic        o_gfx_valid,

    // main 68000 ROM client (word address within 512 KB)
    input  logic [24:0] i_mrom_wbase,   // the main ROM's word address in the SDRAM (0x008000 = byte 0x10000 for every board but Varia Metal)
    input  logic        i_mrom_rd,      // 1-cycle pulse
    input  logic [20:0] i_mrom_addr,      // METRO: 21 bits (family F: 2 MB of program, the Z80's 128 KB 2 MB above it)
    output logic [15:0] o_mrom_data,
    output logic        o_mrom_valid,

    // OKI sample ROM client (byte address within the OKI region: up to 4 MB, jt ok-style); the region starts at i_oki_wbase (word address)
    input  logic [24:0] i_oki_wbase,
    input  logic [22:0] i_oki_addr,
    output logic [7:0]  o_oki_data,
    output logic        o_oki_ok,

    // shared3 CPU RAM (word R/W, byte enables via DQM)
    input  logic        i_sr3_req,      // level-held until ack
    input  logic        i_sr3_we,
    input  logic [16:0] i_sr3_addr,     // word address 0..57343
    input  logic [15:0] i_sr3_wdata,
    input  logic [1:0]  i_sr3_be,       // {UDS,LDS} byte enables
    output logic [15:0] o_sr3_rdata,
    output logic        o_sr3_ack,      // 1-cycle pulse (rdata valid on reads)

    // download write port (byte writes)
    input  logic        i_dl_wr,        // 1-cycle pulse per byte
    input  logic [25:0] i_dl_addr,      // byte address in SDRAM space (METRO: 26 bits, the F64 build holds 64 MB)
    input  logic [7:0]  i_dl_data,
    output logic        o_dl_busy,
    input  logic        i_dl_active,    // high during download (ioctl_download)

    // SDRAM pins
    output logic [12:0] SDRAM_A,
    output logic [1:0]  SDRAM_BA,
    inout  wire  [15:0] SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_CKE,

    // DEBUG: download verification
    output logic        dbg_dl_saw,       // dl_wr ever fired
    output logic [7:0]  dbg_dl_byte0,     // first download byte ADDRESS [15:8] (expect 00)
    output logic [7:0]  dbg_dl_byte1,     // first download byte ADDRESS [7:0]  (expect 00)
    output logic [23:0] dbg_dl_count,     // total download writes (full stream = 0x4C0000)
    output logic [15:0] dbg_selftest,     // EARLY readback of word 0 (us after write; decay probe)
    output logic [15:0] dbg_postdl,       // post-download GFX region probe (expect 0x3422)
    output logic [23:0] dbg_dl_written,   // SDRAM write CAS issued for DL owner
    output logic [15:0] dbg_dl_dropped,   // bytes lost to FIFO overflow (saturating)
    output logic [15:0] dbg_fsm_info,     // CMD_REF issue counter (live = refresh alive)
    output logic [15:0] dbg_sums,         // checksum self-test: 64 words via single reads
    output logic [15:0] dbg_sumb1,        // same 64 words via one 64-word burst, pass 1
    output logic [15:0] dbg_sumb2,        // burst pass 2 (mismatch vs pass 1 = marginal capture)
    // the hardware test overlay (metro_hud.sv): accesses (ACTs) by client and the time the controller was busy, in windows of 2^21 clocks (21.8 ms)
    output logic [95:0] o_st             // {busy clocks / 64, graphics, samples, shared RAM, program ROM, download}, 16 bits each
);

  // word-address bases (byte base / 2)
  // METRO: the SDRAM holds the MRA image as it is streamed (tools/metro_rom.py LAYOUT): byte address = image offset
  //   0x010000 main 68000 ROM (512 KB slot)  0x090000 sound CPU ROM  0x0B0000 OKI samples  0x100000 GFX ROM (4 MB slot)
  localparam logic [24:0] GFX_WBASE  = 25'h080000;
`ifdef F64
  localparam logic [24:0] SR3_WBASE  = 25'h1E00000; // word 0x1E00000 = byte 60 MB: family F's 053936 tile map RAM (256 KB; the image of Blazing Tornado ends at 35.1 MB)
`else
  localparam logic [24:0] SR3_WBASE  = 25'h0E00000; // word 0xE00000 = byte 28 MB: family F's 053936 tile map RAM (256 KB; the image of Grand Striker 2 ends at 26.1 MB)
`endif

  // command encoding {nCS, nRAS, nCAS, nWE}
  localparam logic [3:0] CMD_NOP  = 4'b0111;
  localparam logic [3:0] CMD_ACT  = 4'b0011;
  localparam logic [3:0] CMD_READ = 4'b0101;
  localparam logic [3:0] CMD_WRIT = 4'b0100;
  localparam logic [3:0] CMD_PALL = 4'b0010;
  localparam logic [3:0] CMD_REF  = 4'b0001;
  localparam logic [3:0] CMD_MODE = 4'b0000;

  localparam logic [12:0] MODE_REG = 13'h020;   // BL1, sequential, CL2

  localparam int REFRESH_PERIOD = 750;          // METRO: 7.8125 us at 96 MHz (upstream: 625 at 80 MHz)
  localparam int INIT_WAIT = P_SHORT_INIT ? 32 : 9600;   // METRO: 100 us at 96 MHz

  // initialized so the pins never show a live command (4'b0000 = MODE)
  // before the first clock edge
  /* verilator lint_off PROCASSINIT */
  logic [3:0] cmd = CMD_NOP;
  /* verilator lint_on PROCASSINIT */
  assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
  assign SDRAM_CKE = 1'b1;

  logic [15:0] dq_out;
  logic        dq_oe;
  assign SDRAM_DQ = dq_oe ? dq_out : 16'hzzzz;

  // METRO: i_rd_late adds one capture register (and one tag stage below) for boards whose DQ timing needs it
  logic [15:0] dq_in0, dq_in1;
  always_ff @(posedge clk) begin dq_in0 <= SDRAM_DQ; dq_in1 <= dq_in0; end
  wire  [15:0] dq_in = i_rd_late ? dq_in1 : dq_in0;

  // ------------------------------------------------------------------
  // read-return tag pipeline: written by the FSM at CAS issue, lands
  // in sync with dq_in P_RET cycles later.
  // 0=none, 1=gfx, 2=mrom, 3=oki, 4=sr3
  // ------------------------------------------------------------------
  logic [2:0] ret_tag [P_RET+2];
  always_ff @(posedge clk)
    for (int i = P_RET + 1; i > 0; i--) ret_tag[i] <= ret_tag[i-1];
  wire [2:0] land_tag = i_rd_late ? ret_tag[P_RET+1] : ret_tag[P_RET];

  // measurements for the overlay: observation only
  logic [20:0] m_win;
  logic [15:0] m_gfx, m_mrom, m_oki, m_sr3, m_dl;
  logic [21:0] m_busy;
  logic [95:0] m_st;
  assign o_st = m_st;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      m_win <= '0; m_gfx <= '0; m_mrom <= '0; m_oki <= '0; m_sr3 <= '0; m_dl <= '0; m_busy <= '0; m_st <= '0;
    end else begin
      m_win <= m_win + 21'd1;
      if (st == ST_ACT) begin
        case (owner)
          OWN_GFX:  if (m_gfx  != 16'hFFFF) m_gfx  <= m_gfx  + 16'd1;
          OWN_MROM: if (m_mrom != 16'hFFFF) m_mrom <= m_mrom + 16'd1;
          OWN_OKI:  if (m_oki  != 16'hFFFF) m_oki  <= m_oki  + 16'd1;
          OWN_SR3:  if (m_sr3  != 16'hFFFF) m_sr3  <= m_sr3  + 16'd1;
          default:  if (m_dl   != 16'hFFFF) m_dl   <= m_dl   + 16'd1;
        endcase
      end
      if (st != ST_IDLE || wait_cnt != 4'd0) m_busy <= m_busy + 22'd1;
      if (m_win == 21'h1FFFFF) begin
        m_st <= {m_busy[21:6], m_gfx, m_oki, m_sr3, m_mrom, m_dl};
        m_gfx <= '0; m_mrom <= '0; m_oki <= '0; m_sr3 <= '0; m_dl <= '0; m_busy <= '0;
      end
    end
  end

  // ------------------------------------------------------------------
  // main FSM (single driver for: cmd/addr/dqm, state, pends, refresh)
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    ST_INIT_WAIT, ST_INIT_PALL, ST_INIT_REF1, ST_INIT_REF2, ST_INIT_MODE,
    ST_IDLE, ST_ACT, ST_RCD, ST_CAS, ST_ROWGAP, ST_WWAIT, ST_RFC
  } st_e;
  st_e st;

  typedef enum logic [2:0] {OWN_GFX, OWN_MROM, OWN_OKI, OWN_DL, OWN_SR3} own_e;
  own_e owner;

  logic        gfx_pend, mrom_pend, oki_pend, sr3_pend;
  logic [1:0]  pdl_st;
  logic [1:0]  early_st;
  logic [15:0] dbg_refc;           // steady-state CMD_REF issue counter
  logic [7:0]  dl_grant_cnt;       // times FSM granted OWN_DL in ST_IDLE
  logic [25:0] gfx_addr_q;
  logic [6:0]  gfx_len_q;
  logic [20:0] mrom_addr_q;
  logic [22:0] oki_addr_q;
  logic [15:0] dl_data_q;          // full word {even byte, odd byte}
  logic [7:0]  dl_even_byte;       // stashed even byte awaiting its odd pair
  logic        sr3_rmw_fly;        // read-modify-write read in flight
  logic        sr3_busy;           // sr3 op accepted, ack not yet issued
  logic        probe_pend;         // GFX probe read request
  logic        probe_fly;          // GFX probe read in flight (ret tag 6)
  logic [24:0] probe_addr;         // word address for the next probe read
  // checksum self-test (runs once after the post-download probe):
  // 64 GFX words at SUM_BASE summed three ways - single reads (tag 6),
  // then two identical 64-word bursts (tag 7). Content wrong -> SUMS bad;
  // deterministic burst bug -> SUMB1 == SUMB2 both bad; marginal capture
  // -> SUMB1 != SUMB2.
  localparam logic [24:0] SUM_BASE = GFX_WBASE + 25'h032000;
  logic [3:0]  sum_st;
  logic [6:0]  sum_i;
  logic [15:0] sum_acc;
  logic        sumb_pend;          // burst-pass request
  logic        sum_fly;            // burst pass in flight (ret tag 7)
  logic [16:0] sum_wait;           // no-download fallback timer (sim preload)
  logic [16:0] sr3_addr_q;
  logic [15:0] sr3_wdata_q;
  logic [1:0]  sr3_be_q;
  logic        sr3_we_q;
  logic        sr3_wr_done;        // set in FSM at write CAS, cleared by landing block
  logic        gfx_start;          // pulse to the byte-path block
  logic        idle_d;             // METRO: the FSM was idle with no wait pending in the clock before
  logic        req_short;          // METRO: the granted request is 1 .. 3 words: its next ACT to the bank must wait for tRC (see the completion below)

  logic [24:0] cur_word;
  logic [6:0]  words_left;         // words remaining in the whole request
  logic [5:0]  cas_left;           // words remaining in this activation
  logic [3:0]  wait_cnt;
  logic [13:0] init_cnt;           // METRO: 14 bits -- INIT_WAIT is 9600 at 96 MHz, which a 13-bit counter (upstream, 80 MHz) never reaches
  logic [9:0]  ref_cnt;
  logic        ref_due, ref_urgent;

  // gfx byte-path backpressure (from the block below)
  logic        bf_room;

  // oki request detection: serve whenever addr differs from last served
  logic        oki_have;
  // METRO (family C): the client holds the whole 16-bit word it fetched and answers either of its two bytes from it: the YMF278B reads a, a+1, a, a+1 for every voice and sample,
  // which was four SDRAM accesses of the byte path a byte at a time.  oki_served_w is the word address (byte address bits 22:1: 23-bit byte addresses, family F's ADPCM-A reaches 6 MB).
`ifdef F_BUILD
  // the family F build keeps the byte client of its hardware-tested release: oki_served is the byte address, 23 bits (the YM2610's ADPCM-A sits at +2 MB of the region and
  // reaches 6 MB: Blazing Tornado's announcer is at A 0x3DB400; with 22 bits the served address never matched such a request and the byte was re-read back to back)
  logic [22:0] oki_served;
`else
  logic [21:0] oki_served_w;
  logic [15:0] oki_word;
`endif
  logic [22:0] oki_fly;      // address of the in-flight OKI read: a new
                             // request may relatch oki_addr_q before the
                             // previous word lands (pend clears at CAS)
`ifdef F_BUILD
  wire oki_want = !oki_have || (i_oki_addr != oki_served);
`else
  wire oki_want = !oki_have || (i_oki_addr[22:1] != oki_served_w);
`endif

  // METRO: the column / row / bank split of the word address: 32 MB modules 9 column bits (A8:0), the F64 build 10 (A9:0), every bank 8192 rows
`ifdef F64
  wire [9:0]  col10    = cur_word[9:0];
  wire [12:0] row13    = cur_word[22:10];
  wire [1:0]  bank2    = cur_word[24:23];
  localparam logic [10:0] ROW_WORDS = 11'd1024;
`else
  wire [9:0]  col10    = {1'b0, cur_word[8:0]};
  wire [12:0] row13    = cur_word[21:9];
  wire [1:0]  bank2    = cur_word[23:22];
  localparam logic [10:0] ROW_WORDS = 11'd512;
`endif
  wire [10:0] col_room = ROW_WORDS - {1'b0, col10};

  always_ff @(posedge clk) begin
    idle_d     <= (st == ST_IDLE) && (wait_cnt == 4'd0);
    cmd        <= CMD_NOP;
    SDRAM_A    <= '0;
    SDRAM_BA   <= bank2;
    dq_oe      <= 1'b0;
    ret_tag[0] <= 3'd0;
    gfx_start  <= 1'b0;
    sr3_wr_done <= 1'b0;
    dlf_pop    <= 1'b0;

    if (!rst_n) begin
      st <= ST_INIT_WAIT;
      owner <= OWN_GFX;
      o_ready <= 1'b0;
      gfx_pend <= 1'b0; mrom_pend <= 1'b0;
      oki_pend <= 1'b0; sr3_pend <= 1'b0;
      sr3_wr_done <= 1'b0;
      sr3_rmw_fly <= 1'b0;
      sr3_busy <= 1'b0;
      probe_pend <= 1'b0;
      probe_fly <= 1'b0;
      init_cnt <= '0; wait_cnt <= '0;
      cur_word <= '0; words_left <= '0; cas_left <= '0;
      ref_cnt <= '0; ref_due <= 1'b0; ref_urgent <= 1'b0;
      SDRAM_DQML <= 1'b1; SDRAM_DQMH <= 1'b1;
      dbg_dl_saw <= 1'b0;
      dbg_dl_byte0 <= '0;
      dbg_dl_byte1 <= '0;
      dbg_dl_count <= '0;
      dbg_dl_written <= '0;
      dbg_dl_dropped <= '0;
      dl_grant_cnt <= '0;
      dbg_selftest <= 16'hDEAD;
      dbg_postdl   <= 16'hDEAD;
      dbg_refc     <= '0;
      pdl_st       <= 2'd0;
      early_st     <= 2'd0;
      dbg_sums     <= 16'hDEAD;
      dbg_sumb1    <= 16'hDEAD;
      dbg_sumb2    <= 16'hDEAD;
      sum_st       <= 4'd0;
      sum_i        <= '0;
      sum_acc      <= '0;
      sumb_pend    <= 1'b0;
      sum_fly      <= 1'b0;
      sum_wait     <= '0;
      probe_addr   <= '0;
    end else begin
      // EARLY readback probe: read word 0 back microseconds after its two
      // bytes are written, while the download is still streaming. Compared
      // against dbg_postdl (same word, seconds later) this discriminates
      // "write never landed" from "data decayed = refresh dead on hardware".
      case (early_st)
        2'd0: if (dbg_dl_written >= 24'd4 && i_dl_active
                   && st == ST_IDLE && !mrom_pend) begin
                mrom_pend   <= 1'b1;
                mrom_addr_q <= 21'd0;
                early_st    <= 2'd1;
              end
        2'd1: if (o_mrom_valid && mrom_addr_q == 21'd0) begin
                dbg_selftest <= o_mrom_data;
                early_st     <= 2'd2;
              end
        default: ;
      endcase

      // post-download GFX probe: read GFX region word GFX_WBASE+4 (SDRAM
      // bytes 0x080008-9). Expected 0x3422 per the sim-verified
      // gfxrom.bin; anything else means the MRA GFX interleave is wrong.
      if (pdl_st == 2'd0 && dbg_dl_saw && !i_dl_active && dlf_empty) begin
        probe_pend <= 1'b1;
        probe_addr <= GFX_WBASE + 25'd4;
        pdl_st     <= 2'd1;
      end
      if (land_tag == 3'd6) begin
        probe_fly  <= 1'b0;
        if (pdl_st == 2'd1) begin
          dbg_postdl <= dq_in;
          pdl_st     <= 2'd2;
        end else begin
          // checksum single-read landing
          sum_acc <= sum_acc + dq_in;
          sum_i   <= sum_i + 7'd1;
          if (sum_i == 7'd63) sum_st <= 4'd3;
          else                sum_st <= 4'd1;
        end
      end

      // checksum burst landing (tag 7)
      if (land_tag == 3'd7) begin
        sum_acc <= sum_acc + dq_in;
        sum_i   <= sum_i + 7'd1;
        if (sum_i == 7'd63) sum_st <= (sum_st == 4'd4) ? 4'd5 : 4'd7;
      end

      // checksum self-test sequencer
      if (o_ready && !dbg_dl_saw && !sum_wait[16])
        sum_wait <= sum_wait + 17'd1;
      case (sum_st)
        4'd0: if (pdl_st == 2'd2 || sum_wait[16]) begin
                sum_i <= '0; sum_acc <= '0; sum_st <= 4'd1;
              end
        4'd1: if (!probe_pend && !probe_fly) begin
                probe_pend <= 1'b1;
                probe_addr <= SUM_BASE + 25'(sum_i);
                sum_st     <= 4'd2;
              end
        // 4'd2: waiting for the tag-6 landing above
        4'd3: begin
                dbg_sums <= sum_acc;
                sum_i <= '0; sum_acc <= '0;
                sumb_pend <= 1'b1; sum_st <= 4'd4;
              end
        // 4'd4: burst pass 1 in flight (tag-7 landings above)
        4'd5: begin
                dbg_sumb1 <= sum_acc;
                sum_i <= '0; sum_acc <= '0;
                sumb_pend <= 1'b1; sum_st <= 4'd6;
              end
        4'd6: sum_st <= 4'd7;   // hop so the ==63 landing maps pass 2 -> done
        // 4'd7: burst pass 2 in flight
        default: ;
      endcase
      if (sum_st == 4'd7 && sum_i == 7'd64) begin
        dbg_sumb2 <= sum_acc;
        sum_st <= 4'd8;
      end

      // DEBUG: capture download writes; byte0/1 hold the FIRST BYTE'S
      // ADDRESS (expect 0000) to rule out an ioctl offset
      if (i_dl_wr) begin
        dbg_dl_saw <= 1'b1;
        dbg_dl_count <= dbg_dl_count + 24'd1;
        if (dbg_dl_count == 24'd0) {dbg_dl_byte0, dbg_dl_byte1} <= i_dl_addr[15:0];
        if (i_dl_addr[0] && dlf_full && !(&dbg_dl_dropped))
          dbg_dl_dropped <= dbg_dl_dropped + 16'd2;  // word lost = 2 bytes
      end
      // refresh bookkeeping
      if (32'(ref_cnt) == REFRESH_PERIOD - 1) begin
        ref_cnt <= '0;
        ref_urgent <= ref_due;
        ref_due <= 1'b1;
      end else
        ref_cnt <= ref_cnt + 1'b1;

      // latch incoming requests (any state)
      if (i_gfx_req) begin
        gfx_pend <= 1'b1; gfx_addr_q <= i_gfx_addr; gfx_len_q <= i_gfx_len;
      end
      if (i_mrom_rd) begin
        mrom_pend <= 1'b1; mrom_addr_q <= i_mrom_addr;
      end
      // sr3_busy holds off relatching while the op is in flight: pend
      // clears at CAS but the requester keeps req asserted until ack,
      // and a relatch in that window would issue a duplicate op whose
      // phantom ack could complete a LATER request with stale data
      if (i_sr3_req && !sr3_pend && !sr3_busy) begin
        sr3_pend <= 1'b1; sr3_busy <= 1'b1;
        sr3_addr_q <= i_sr3_addr;
        sr3_wdata_q <= i_sr3_wdata; sr3_be_q <= i_sr3_be;
        sr3_we_q <= i_sr3_we;
      end
      if (o_sr3_ack) sr3_busy <= 1'b0;
      // rmw read landed: merge the untouched lanes into the write data and
      // promote to a full-word write (re-granted from ST_IDLE)
      if (land_tag == 3'd5) begin
        sr3_wdata_q <= {sr3_be_q[1] ? sr3_wdata_q[15:8] : dq_in[15:8],
                        sr3_be_q[0] ? sr3_wdata_q[7:0]  : dq_in[7:0]};
        sr3_be_q    <= 2'b11;
        sr3_rmw_fly <= 1'b0;
      end
      if (oki_want && !oki_pend && st == ST_IDLE) begin
        oki_pend <= 1'b1; oki_addr_q <= i_oki_addr;
      end

      case (st)
        // ---------------- init ----------------
        ST_INIT_WAIT: begin
          SDRAM_DQML <= 1'b1; SDRAM_DQMH <= 1'b1;
          init_cnt <= init_cnt + 1'b1;
          if (32'(init_cnt) == INIT_WAIT) st <= ST_INIT_PALL;
        end
        ST_INIT_PALL: begin
          cmd <= CMD_PALL; SDRAM_A <= 13'h400;
          wait_cnt <= 4'd2; st <= ST_INIT_REF1;
        end
        ST_INIT_REF1:
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else begin cmd <= CMD_REF; wait_cnt <= 4'd8; st <= ST_INIT_REF2; end
        ST_INIT_REF2:
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else begin cmd <= CMD_REF; wait_cnt <= 4'd8; st <= ST_INIT_MODE; end
        ST_INIT_MODE:
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else begin
            cmd <= CMD_MODE; SDRAM_A <= MODE_REG; SDRAM_BA <= 2'b00;
            wait_cnt <= 4'd2; st <= ST_IDLE; o_ready <= 1'b1;
          end

        // ---------------- grant ----------------
        ST_IDLE: begin
          SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else if (ref_urgent && !idle_d) begin
            // METRO: one more clock for the precharge of the access before (a refresh command right behind a 1 .. 3 word access came inside its tRP)
          end else if (idle_d && (ref_urgent || (ref_due && !gfx_pend && !mrom_pend
                                  && !oki_pend && dlf_empty && !sr3_pend))) begin
            cmd <= CMD_REF;
            ref_due <= 1'b0; ref_urgent <= 1'b0;
            dbg_refc <= dbg_refc + 16'd1;
            wait_cnt <= 4'd8; st <= ST_RFC;
          end else if (!dlf_empty) begin
            owner <= OWN_DL;
            req_short <= 1'b1;
            dl_data_q <= dlf[dlf_rp][15:0];
            dlf_pop   <= 1'b1;
            cur_word <= dlf[dlf_rp][40:16];
            if (!(&dl_grant_cnt)) dl_grant_cnt <= dl_grant_cnt + 8'd1;
            st <= ST_ACT;
          end else if (sr3_pend && !sr3_rmw_fly) begin
            owner <= OWN_SR3;
            req_short <= 1'b1;
            cur_word <= SR3_WBASE + 25'(sr3_addr_q);
            words_left <= 7'd1;
            st <= ST_ACT;
          end else if (mrom_pend) begin
            // v13 (2026-07-18): main-CPU ROM outranks GFX bursts. With
            // GFX first, every collision stalled the 68000 for a full
            // burst (up to ~70 cycles); in the heaviest scenes that
            // starvation ran the game's raster IRQ handler late enough
            // to push scroll writes past their line (the boss-split
            // artefact). A mrom grant is one word, so GFX loses almost
            // nothing, and the renderer holds 2.5x line budget at the
            // 3-line display lag.
            owner <= OWN_MROM;
            req_short <= 1'b1;
            cur_word <= i_mrom_wbase + 25'(mrom_addr_q);
            words_left <= 7'd1;
            st <= ST_ACT;
          end else if (oki_pend) begin
            // METRO (family F): the sample client ranks above the graphics stream: the YM2610's ADPCM-A wants a new byte every 1.5 us and a few queued 64-byte bursts
            // are longer than that (stale bytes = noise); one word costs the graphics next to nothing
            owner <= OWN_OKI;
            req_short <= 1'b1;
            cur_word <= i_oki_wbase + 25'(oki_addr_q[22:1]);
            words_left <= 7'd1;
            st <= ST_ACT;
          end else if (gfx_pend) begin
            owner <= OWN_GFX;
            req_short <= (((8'(gfx_addr_q[0]) + 8'(gfx_len_q) + 8'd1) >> 1) < 8'd4);
            cur_word <= GFX_WBASE + 25'(gfx_addr_q[25:1]);
            // ceil((start_is_odd + len) / 2) words cover the byte span
            words_left <= 7'((8'(gfx_addr_q[0]) + 8'(gfx_len_q) + 8'd1) >> 1);
            gfx_start <= 1'b1;
            st <= ST_ACT;
          end else if (probe_pend) begin
            owner <= OWN_MROM;                 // rides the mrom read path
            req_short <= 1'b1;
            probe_fly <= 1'b1;                 // but lands with tag 6
            probe_pend <= 1'b0;
            cur_word <= probe_addr;
            words_left <= 7'd1;
            st <= ST_ACT;
          end else if (sumb_pend) begin
            owner <= OWN_GFX;                  // rides the gfx burst path
            req_short <= 1'b0;
            sum_fly <= 1'b1;                   // but lands with tag 7
            sumb_pend <= 1'b0;
            cur_word <= SUM_BASE;
            words_left <= 7'd64;
            st <= ST_ACT;
          end
        end

        // ---------------- access ----------------
        ST_ACT: begin
          cmd <= CMD_ACT;
          SDRAM_A <= row13;
          cas_left <= (owner == OWN_GFX)
                      ? ((13'(words_left) > 13'(col_room))
                         ? 6'(col_room) : 6'(words_left))
                      : 6'd1;
          st <= ST_RCD;
        end
        ST_RCD: st <= ST_CAS;       // tRCD = 2 cycles (ACT, this, CAS)
        ST_CAS: begin
          // The MiSTer SDRAM board ties DQML/DQMH low, so byte masking is
          // impossible on hardware: ALL writes are full 16-bit words. The
          // download path pairs bytes into words; partial sr3 writes go
          // through read-modify-write (rmw read tagged 5, merged below).
          if (owner == OWN_DL) begin
            cmd <= CMD_WRIT; dq_oe <= 1'b1;
            dq_out <= dl_data_q;                     // {even byte, odd byte}
            SDRAM_A <= {2'b00, 1'b1, col10};         // A10 = auto precharge
            SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
            dbg_dl_written <= dbg_dl_written + 24'd2;  // counts BYTES
            wait_cnt <= 4'd4;                        // tWR + tRP (+1: tRC at 96 MHz, see req_short)
            st <= ST_WWAIT;
          end else if (owner == OWN_SR3 && sr3_we_q && sr3_be_q == 2'b11) begin
            // sr3 full-word write (partial writes arrive here only after
            // the rmw merge promotes be to 2'b11)
            cmd <= CMD_WRIT; dq_oe <= 1'b1;
            dq_out <= sr3_wdata_q;
            SDRAM_A <= {2'b00, 1'b1, col10};         // A10 = auto precharge
            SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
            sr3_pend <= 1'b0;
            sr3_wr_done <= 1'b1;                     // landing block pulses ack
            wait_cnt <= 4'd4;                        // tWR + tRP (+1)
            st <= ST_WWAIT;
          end else if (owner != OWN_GFX || sum_fly || bf_room) begin
            cmd <= CMD_READ;
            SDRAM_A <= {2'b00, (cas_left == 6'd1) ? 1'b1 : 1'b0, col10};   // AP on the last CAS
            ret_tag[0] <= (owner == OWN_GFX)  ? (sum_fly ? 3'd7 : 3'd1) :
                          (owner == OWN_MROM) ? (probe_fly ? 3'd6 : 3'd2) :
                          (owner == OWN_SR3)  ? (sr3_we_q ? 3'd5 : 3'd4) : 3'd3;
            if (owner == OWN_OKI) oki_fly <= oki_addr_q;
            if (owner == OWN_SR3) begin
              if (sr3_we_q) sr3_rmw_fly <= 1'b1;     // rmw read: keep pend
              else          sr3_pend <= 1'b0;
            end
            cur_word <= cur_word + 25'd1;
            words_left <= words_left - 7'd1;
            cas_left <= cas_left - 6'd1;
            if (cas_left == 6'd1) begin
              if (owner == OWN_GFX && words_left != 7'd1) begin
                wait_cnt <= 4'd3;                    // tRP after AP (+ tRAS of a short first part: the next ACT goes to the same bank)
                st <= ST_ROWGAP;                     // row-crossing re-ACT
              end else begin
                if (owner == OWN_GFX) begin
                  if (sum_fly) sum_fly <= 1'b0;
                  else         gfx_pend <= 1'b0;
                end
                if (owner == OWN_MROM && !probe_fly) mrom_pend <= 1'b0;
                if (owner == OWN_OKI)  oki_pend  <= 1'b0;
                // METRO: the 96 MHz machine clock gives 10.4 ns a cycle: ACT, tRCD, CAS(AP), 2 waits and the grant make 6 cycles = 62.5 ns between two ACTs to one bank, under the
                // 63 ns tRC of a -7 part (and under the 66 ns of some modules); a 1 .. 3 word access takes one more cycle.  The sound CPU's wait loops, the 68000's program fetches and the
                // ADPCM bytes are all such accesses, back to back in one bank (simulation: millions of tRC / tRP violations a minute in Blazing Tornado's sound board alone).
                wait_cnt <= req_short ? 4'd3 : 4'd2;
                st <= ST_IDLE;
              end
            end
          end
          // else: gfx FIFO lacks room, stall with NOP (row stays open)
        end
        ST_ROWGAP:
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else st <= ST_ACT;
        ST_WWAIT: begin
          SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else st <= ST_IDLE;
        end
        ST_RFC:
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else st <= ST_IDLE;
        default: st <= ST_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // mrom / oki / sr3 landing (single driver for their outputs)
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    o_mrom_valid <= 1'b0;
    o_sr3_ack <= 1'b0;
    if (!rst_n) begin
`ifdef F_BUILD
      oki_have <= 1'b0; oki_served <= '0;
      o_mrom_data <= '0; o_oki_data <= '0;
`else
      oki_have <= 1'b0; oki_served_w <= '0; oki_word <= '0;
      o_mrom_data <= '0;
`endif
      o_sr3_rdata <= '0;
    end else begin
      if (land_tag == 3'd2) begin
        o_mrom_data <= dq_in;
        o_mrom_valid <= 1'b1;
      end
      if (land_tag == 3'd3) begin
`ifdef F_BUILD
        o_oki_data <= oki_fly[0] ? dq_in[7:0] : dq_in[15:8];
        oki_served <= oki_fly;
`else
        oki_word <= dq_in;
        oki_served_w <= oki_fly[22:1];
`endif
        oki_have <= 1'b1;
      end
      if (land_tag == 3'd4) begin
        o_sr3_rdata <= dq_in;
        o_sr3_ack <= 1'b1;
      end
      if (sr3_wr_done) begin
        o_sr3_ack <= 1'b1;         // write ack (data already committed)
      end
    end
  end
  // ok is only presented while the requester's address matches what we
  // hold, so an address change drops ok on the same cycle (jt style)
`ifdef F_BUILD
  assign o_oki_ok = oki_have && (i_oki_addr == oki_served);
`else
  assign o_oki_ok = oki_have && (i_oki_addr[22:1] == oki_served_w);
  assign o_oki_data = i_oki_addr[0] ? oki_word[7:0] : oki_word[15:8];
`endif

  // ------------------------------------------------------------------
  // gfx byte path (single driver for FIFO + byte emit state)
  // 16-word FIFO; the FSM stalls CAS when fewer than 12 slots remain,
  // covering the P_RET words already in flight.
  // ------------------------------------------------------------------
  logic [15:0] bfifo [16];
  logic [3:0]  bf_wp, bf_rp;
  logic [4:0]  bf_cnt;
  logic        bf_hi;              // next byte from high lane (even addr)
  logic [6:0]  gfx_left;
  logic        skip_first;         // odd start address: drop first byte
  logic        gfx_wmode;          // even addr + even len: emit whole words

  assign bf_room = (bf_cnt < 5'd12);

  always_ff @(posedge clk) begin
    logic push, pop;
    push = 1'b0; pop = 1'b0;
    o_gfx_valid <= 1'b0;

    if (!rst_n) begin
      bf_wp <= '0; bf_rp <= '0; bf_cnt <= '0;
      bf_hi <= 1'b1; gfx_left <= '0; skip_first <= 1'b0;
      gfx_wmode <= 1'b0;
      o_gfx_data <= '0;
    end else begin
      if (gfx_start) begin
        bf_wp <= '0; bf_rp <= '0; bf_cnt <= '0;
        bf_hi <= 1'b1;
        gfx_left <= gfx_len_q;
        skip_first <= gfx_addr_q[0];
        gfx_wmode <= !gfx_addr_q[0] && !gfx_len_q[0];
      end else begin
        if (land_tag == 3'd1) begin
          bfifo[bf_wp] <= dq_in;
          bf_wp <= bf_wp + 1'b1;
          push = 1'b1;
        end
        if (bf_cnt != 0 && gfx_left != 0) begin
          if (gfx_wmode) begin
            // word mode: one whole word per valid, 2 bytes retired
            o_gfx_data <= bfifo[bf_rp];
            o_gfx_valid <= 1'b1;
            gfx_left <= gfx_left - 7'd2;
            bf_rp <= bf_rp + 1'b1;
            pop = 1'b1;
          end else if (skip_first) begin
            skip_first <= 1'b0;
            bf_hi <= 1'b0;         // word stays; low lane is byte one
          end else begin
            o_gfx_data <= {8'd0,
                           bf_hi ? bfifo[bf_rp][15:8] : bfifo[bf_rp][7:0]};
            o_gfx_valid <= 1'b1;
            gfx_left <= gfx_left - 7'd1;
            bf_hi <= !bf_hi;
            if (!bf_hi || gfx_left == 7'd1) begin
              bf_rp <= bf_rp + 1'b1; // low lane emitted (or stream done)
              pop = 1'b1;
            end
          end
        end
        case ({push, pop})
          2'b10: bf_cnt <= bf_cnt + 1'b1;
          2'b01: bf_cnt <= bf_cnt - 1'b1;
          default: ;
        endcase
      end
    end
  end

  // ------------------------------------------------------------------
  // download FIFO (16-deep, one WORD per entry): the ioctl byte stream
  // is strictly sequential from address 0, so bytes are paired into
  // words before entering the FIFO (even byte stashed, pushed with its
  // odd sibling). Full-word writes are mandatory because the MiSTer
  // SDRAM board ties DQML/DQMH low (no byte masking).
  // ------------------------------------------------------------------
  logic [40:0] dlf [0:15];      // {word_addr[24:0], data[15:0]}
  logic [3:0]  dlf_wp, dlf_rp;
  logic [4:0]  dlf_cnt;         // 0..16
  wire         dlf_empty = (dlf_cnt == 5'd0);
  wire         dlf_full  = (dlf_cnt == 5'd16);
  logic        dlf_pop;         // set by main FSM when it consumes a FIFO entry
  wire         dlf_push = i_dl_wr && i_dl_addr[0] && !dlf_full;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dlf_wp  <= '0;
      dlf_rp  <= '0;
      dlf_cnt <= '0;
    end else begin
      if (i_dl_wr && !i_dl_addr[0])
        dl_even_byte <= i_dl_data;
      if (dlf_push) begin
        dlf[dlf_wp] <= {i_dl_addr[25:1], dl_even_byte, i_dl_data};
        dlf_wp <= dlf_wp + 4'd1;
      end
      if (dlf_pop) begin
        dlf_rp <= dlf_rp + 4'd1;
      end
      case ({dlf_push, dlf_pop})
        2'b10:   dlf_cnt <= dlf_cnt + 5'd1;
        2'b01:   dlf_cnt <= dlf_cnt - 5'd1;
        default: ;
      endcase
    end
  end

  assign o_dl_busy = !o_ready || (dlf_cnt >= 5'd12);
  assign dbg_fsm_info = dbg_refc;   // REFC row: changing digits = refresh alive

endmodule

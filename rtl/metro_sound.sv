// The Metro sound board (Dharma family and the YM2151 family): uPD78C10 (rtl/upd78c10.sv) + 2 KB RAM + the board's glue of metro.cpp (metro_upd7810_state),
// a YM2413 or (i_ym2151, Daitoride / Pururun / Gun Master / Puzzli) a YM2151, and an OKI M6295.
//
//   68000 -> sound CPU:  the command byte is latched, NMI is pulsed, and the byte is shifted out LSB first on the serial input (RXD) -- `busy` (IN0 bit 7) is
//                        set until the sound CPU strobes port B bit 7 (1 -> 0)
//   port A               shared 8-bit bus; port B bits (1 -> 0 edges): 7 clear busy, 5 clock the YM2413 (if bit 2 low; bit 1 selects register / data),
//                        2 write the OKI, 3 read the OKI into port A (the OKI is selected when bit 4 is low)
//   port C bits 5:4      program ROM bank (0x4000-0x7fff); the program is the set's `audiocpu` region (128 KB, only 64 KB are reachable with this mask)
//   YM2151 boards (daitorid_portb_w): port B bit 6 clocks the YM2151 (bit 2 low: write register / data per bit 1, bit 3 low: read the status into port A), bits 5
//                        unused, the rest as above; the YM2151's IRQ is the CPU's INTF2; port C bits 6:4 are the ROM bank (all 128 KB)
//
// The CPU's timing is MAME's (see upd78c10.sv): 12 MHz crystal / 3 = 4 MHz state clock, the engine steps at a quarter of the 96 MHz clock.
// YM2413 3.579545 MHz and OKI 1.2 MHz (24 MHz / 20, pin 7 high: 9090.9 Hz) as in MAME.  The mix follows MAME's routing (YM2413 0.90, OKI 0.10 on a mono
// channel); the absolute levels are calibrated in docs/status.md.
`default_nettype none
module metro_sound #(
    parameter logic [2:0] BANKMASK = 3'd3,
    parameter int YM51_GAIN  = 389,         // YM2151 board mix gains (x256), fitted to MAME's audio with tools/audio_fit.py (docs/status.md): YM2151 1.52 (Pururun's YM-only windows 1.516,
    parameter int OKI51_GAIN = 1628         // all windows 1.54), OKI 6.36 = 4 x Dharma's 1.59 (MAME's routes 0.40 / 0.10; Gun Master's OKI-only windows give 6.2)
) (
    input  logic        clk,                // 96 MHz
    input  logic        rst,
    input  logic        i_ym2151,           // 1: YM2151 board (port B protocol, jt51, 128 KB program ROM banking); 0: YM2413 board
    input  logic        i_oki_ss,           // OKI pin 7 (sample rate): 1 = high, /132 (every board so far); 0 = low, /165 (only Sky Alert, family A)
    input  logic [1:0]  i_gain,         // output level (OSD): 0 = x4 (+12 dB over MAME), 1 = x2, 2 = x1 (MAME's level), 3 = x8; YM2151 boards: all one step of 8 lower (x0.5 ... x1)
    input  logic [7:0]  cmd,
    input  logic        cmd_wr,             // one-clock pulse: the 68000 wrote the sound command
    output logic        busy,
    // family D (Mouja, Mahjong Doukyuusei: no sound CPU): the 68000 drives the YM2413 and the OKI itself; the uPD78C10 is held in reset
    input  logic        i_direct,
    input  logic        d_ym_wr, d_ym_a0, d_oki_wr,     // one-clock pulses with d_data
    input  logic [7:0]  d_data,
    input  logic        i_oki_hi,           // 1: the OKI is routed louder (MAME 0.25 against 0.10 on the uPD78C10 boards)
    input  logic        i_ym_hi,            // 1: the YM2413 is routed at 2.00 (Mahjong Gakuensai) instead of 0.90
    input  logic [2:0]  i_oki_clk,          // OKI clock: 0 = 1.2 MHz (the uPD78C10 boards), 1 = 1.056 MHz (Doukyuusei), 2 = 2.0625 MHz (Mouja), 3 = 2.112 MHz (Doukyuusei Special, Gakuensai), 4 = 1.0 MHz (Varia Metal)
    input  logic signed [15:0] i_aux,       // Varia Metal: the ES8712 / MSM6585's output, mixed in at MAME's level (full scale of the MSM is 16 bits x 0.5)
    input  logic        i_loud,             // 1: a board whose MAME mix is loud (the ES8712's route is 1.0): scaled down by 4 (the YM2151 boards by 8), the OSD steps start there
    input  logic        i_oki_vm,           // 1: the OKI is routed at 0.5 (Varia Metal)
    output logic [7:0]  d_oki_status,
    // program ROM: word reads of metro_sdram's main-ROM client (via metro_mrom_arb)
    output logic        rom_rd,
    output logic [18:0] rom_addr,
    input  logic        rom_valid,
    input  logic [15:0] rom_data,
    // OKI sample ROM: jt6295's handshake, served by metro_sdram's OKI client
    output logic [17:0] oki_addr,
    input  logic [7:0]  oki_data,
    input  logic        oki_ok,
    output logic signed [15:0] audio,
    output logic signed [15:0] dbg_ym,      // the chips' outputs before the mix (calibration against MAME, tools/audio_cmp.py)
    output logic signed [15:0] dbg_oki,
    output logic        dbg_illegal
);
    // ------------------------------------------------------------------ clock enables
    logic [1:0] c4;
    logic [2:0] c6;
    always_ff @(posedge clk) begin
        if (rst) begin c4 <= 2'd0; c6 <= 3'd0; end
        else begin
            c4 <= c4 + 2'd1;
            if (c4 == 2'd3) c6 <= (c6 == 3'd5) ? 3'd0 : c6 + 3'd1;
        end
    end
    wire ce       = (c4 == 2'd3);                // 24 MHz engine enable
    wire ce_state = ce && (c6 == 3'd5);          // 4 MHz: one CPU state

    // ------------------------------------------------------------------ the CPU
    logic        mem_req, mem_we, mem_ack;
    logic [15:0] mem_a;
    logic [7:0]  mem_wd, mem_rd;
    logic [7:0]  o_pa, o_pb, o_pc, pa_in;
    logic        nmi, rxd_bit, rxd_sample;
    logic        ym_irq;                // the YM2151's IRQ, active high (INTF2)

    upd78c10 u_cpu (
        .clk(clk), .rst(rst || i_direct), .ce(ce), .ce_state(ce_state),
        .mem_req(mem_req), .mem_we(mem_we), .mem_a(mem_a), .mem_wd(mem_wd), .mem_ack(mem_ack), .mem_rd(mem_rd),
        .pa_in(pa_in), .o_pa(o_pa), .o_pb(o_pb), .o_pc(o_pc),
        .nmi(nmi), .intf2(ym_irq), .rxd_bit(rxd_bit), .rxd_sample(rxd_sample),
        .trc_stb(), .dbg_t(), .dbg_pc(), .dbg_ea(), .dbg_bc(), .dbg_de(), .dbg_hl(), .dbg_sp(), .dbg_irr(),
        .dbg_a(), .dbg_v(), .dbg_psw(), .dbg_iff(), .dbg_illegal(dbg_illegal));

    // ------------------------------------------------------------------ memory: program ROM (fixed + banked), 2 KB RAM at 0x8000
    logic [7:0] sram [0:2047];
    logic [7:0] ram_q;
    logic [2:0] bank;
    assign bank = o_pc[6:4] & (i_ym2151 ? 3'd7 : BANKMASK);
    wire        is_rom = !mem_a[15];
    wire        is_ram = (mem_a[15:11] == 5'b10000);
    wire [16:0] rom_byte = {mem_a[14] ? bank : 3'd0, mem_a[13:0]};
    wire [15:0] rom_word = rom_byte[16:1];
    logic [15:0] cw_d, cw_a, wsel;               // one-word cache of the last program ROM word
    logic        cw_v;
    typedef enum logic [1:0] {M_IDLE, M_RAM, M_ROMW} msta_e;
    msta_e msta;

    always_ff @(posedge clk) begin
        rom_rd <= 1'b0;
        if (rst) begin
            mem_ack <= 1'b0; msta <= M_IDLE; cw_v <= 1'b0; mem_rd <= 8'd0;
        end else if (!mem_req) begin
            mem_ack <= 1'b0; msta <= M_IDLE;
        end else if (!mem_ack) begin
            case (msta)
            M_IDLE: begin
                if (is_ram) begin
                    ram_q <= sram[mem_a[10:0]];
                    if (mem_we) sram[mem_a[10:0]] <= mem_wd;
                    msta <= M_RAM;
                end else if (is_rom && !mem_we) begin
                    if (cw_v && cw_a == rom_word) begin
                        mem_rd <= rom_byte[0] ? cw_d[7:0] : cw_d[15:8];
                        mem_ack <= 1'b1;
                    end else begin
                        rom_rd <= 1'b1; rom_addr <= 19'h40000 + {3'd0, rom_word};   // audiocpu region: image 0x90000 = main-ROM word 0x40000
                        wsel <= rom_word; msta <= M_ROMW;
                    end
                end else begin                                                       // ROM write, unmapped: nothing
                    mem_rd <= 8'd0; mem_ack <= 1'b1;
                end
            end
            M_RAM: begin
                mem_rd <= ram_q; mem_ack <= 1'b1;
            end
            M_ROMW: if (rom_valid) begin
                cw_d <= rom_data; cw_a <= wsel; cw_v <= 1'b1;
                mem_rd <= rom_byte[0] ? rom_data[7:0] : rom_data[15:8];
                mem_ack <= 1'b1;
            end
            default: msta <= M_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ the board: command latch, port A bus, port B strobes
    logic [7:0] porta, portb, sound_data, prev_pa, prev_pb;
    logic [7:0] oki_dout;
    logic       oki_wrn, oki_rd_pulse;
    logic [5:0] ymw_cs;
    logic       ym_a0;
    logic [7:0] ym_d;
    logic       ym51_pend, ym51_a0;
    logic [7:0] ym51_d;
    logic [7:0] jt51_dout;
    logic       opll_cen, ym_phase;                    // 3.579545 MHz enable (below) and its half-rate phase
    wire        ym_cen_p1 = opll_cen && ym_phase;
    assign pa_in   = porta;
    assign rxd_bit = sound_data[0];
    localparam int YMW_HOLD = 40;                // clocks CS/WR stay low: spans one or two YM2413 phiM enables (IKAOPLL samples on its enable only)

    always_ff @(posedge clk) begin
        nmi <= 1'b0;
        oki_wrn <= 1'b1;
        if (ymw_cs != 6'd0) ymw_cs <= ymw_cs - 6'd1;
        if (ym_cen_p1) ym51_pend <= 1'b0;                 // a pending YM2151 write is handed to jt51 on its next cen_p1 (below)
        if (rst) begin
            porta <= 8'd0; portb <= 8'd0; sound_data <= 8'd0; busy <= 1'b0; prev_pa <= 8'd0; prev_pb <= 8'd0; ymw_cs <= 6'd0; ym51_pend <= 1'b0;
        end else if (i_direct) begin
            if (d_ym_wr) begin ymw_cs <= 6'(YMW_HOLD); ym_a0 <= d_ym_a0; ym_d <= d_data; end
            if (d_oki_wr) begin porta <= d_data; oki_wrn <= 1'b0; end
        end else begin
            if (rxd_sample) sound_data <= {1'b0, sound_data[7:1]};
            if (cmd_wr) begin sound_data <= cmd; busy <= 1'b1; nmi <= 1'b1; end
            if (o_pa != prev_pa) begin porta <= o_pa; prev_pa <= o_pa; end
            if (o_pb != prev_pb) begin
                prev_pb <= o_pb;
                if (portb[7] && !o_pb[7]) begin
                    busy <= 1'b0;
                    portb <= o_pb;
                end else if (!i_ym2151 && portb[5] && !o_pb[5]) begin
                    if (!o_pb[2]) begin ymw_cs <= 6'(YMW_HOLD); ym_a0 <= o_pb[1]; ym_d <= porta; end
                    portb <= o_pb;
                end else if (i_ym2151 && portb[6] && !o_pb[6]) begin
`ifdef VERILATOR
                    if ($test$plusargs("YMDBG")) $display("YMSTROBE pb=%02x pa=%02x status=%02x", o_pb, porta, jt51_dout);
`endif
                    if (!o_pb[2]) begin ym51_pend <= 1'b1; ym51_a0 <= o_pb[1]; ym51_d <= porta; end
                    if (!o_pb[3]) porta <= o_pb[1] ? jt51_dout : 8'hFF;            // ymfm: the status register on odd offsets, 0xFF on the data port
                    portb <= o_pb;
                end else begin
                    if (portb[2] && !o_pb[2] && !o_pb[4]) begin oki_wrn <= 1'b0; end
                    if (portb[3] && !o_pb[3] && !o_pb[4]) porta <= oki_dout;
                    portb <= o_pb;
                end
            end
        end
    end

    // ------------------------------------------------------------------ YM2413 (IKAOPLL): 3.579545 MHz enable from the 96 MHz clock, with a reset-time
    // enable so that the chip sees its reset (it samples IC_n only on its enable; see Arcade-HyperDuel_MiSTer rtl/hyprduel_sys.sv)
    logic [26:0] opll_acc;
    always_ff @(posedge clk)
        if (rst) begin opll_acc <= '0; opll_cen <= 1'b0; end
        else begin
            if (opll_acc + 27'd3579545 >= 27'd96000000) begin
                opll_acc <= opll_acc + 27'd3579545 - 27'd96000000;
                opll_cen <= 1'b1;
            end else begin
                opll_acc <= opll_acc + 27'd3579545;
                opll_cen <= 1'b0;
            end
        end
    logic [2:0]  opll_rst_div;
    logic [12:0] opll_rst_cnt;
    logic        opll_rst_cen;
    always_ff @(posedge clk) begin
        opll_rst_cen <= 1'b0;
        if (!rst) begin
            opll_rst_div <= '0;
            opll_rst_cnt <= '0;
        end else if (opll_rst_cnt != 13'd4608) begin
            opll_rst_div <= opll_rst_div + 3'd1;
            if (opll_rst_div == 3'd0) begin
                opll_rst_cen <= 1'b1;
                opll_rst_cnt <= opll_rst_cnt + 13'd1;
            end
        end
    end
    wire opll_pcen = rst ? opll_rst_cen : opll_cen;
    wire signed [15:0] opll_acc_out;
    wire [1:0]         opll_dout;
    wire               ym_cs = (ymw_cs != 6'd0);

    IKAOPLL #(
        .FULLY_SYNCHRONOUS        (1),
        .FAST_RESET               (0),
        .ALTPATCH_CONFIG_MODE     (0),
        .USE_PIPELINED_MULTIPLIER (1)
    ) u_opll (
        .i_XIN_EMUCLK         (clk),
        .o_XOUT               (),
        .i_phiM_PCEN_n        (~opll_pcen),
        .i_IC_n               (~rst),
        .i_ALTPATCH_EN        (1'b0),
        .i_CS_n               (!ym_cs),
        .i_WR_n               (!ym_cs),
        .i_A0                 (ym_a0),
        .i_D                  (ym_d),
        .o_D                  (opll_dout),
        .o_D_OE               (),
        .o_DAC_EN_MO          (),
        .o_DAC_EN_RO          (),
        .o_IMP_NOFLUC_SIGN    (),
        .o_IMP_NOFLUC_MAG     (),
        .o_IMP_FLUC_SIGNED_MO (),
        .o_IMP_FLUC_SIGNED_RO (),
        .i_ACC_SIGNED_MOVOL   (5'sd2),
        .i_ACC_SIGNED_ROVOL   (5'sd3),
        .o_ACC_SIGNED_STRB    (),
        .o_ACC_SIGNED         (opll_acc_out)
    );

    // ------------------------------------------------------------------ YM2151 (jt51), 3.579545 MHz (the same enable as the OPLL) with cen_p1 at half that.
    // As in Arcade-HyperDuel_MiSTer: jt51 raises its busy flag only for a write that coincides with cen_p1, so a write waits for the next cen_p1
    // (at most 0.5 us; the sound program never writes twice within that).
    always_ff @(posedge clk)
        if (rst) ym_phase <= 1'b0;
        else if (opll_cen) ym_phase <= ~ym_phase;
    wire ym_cen    = opll_cen;
    wire jt51_irq_n;
    wire signed [15:0] jt51_xl, jt51_xr;
    jt51 u_ym2151 (
        .rst(rst), .clk(clk), .cen(ym_cen), .cen_p1(ym_cen_p1),
        .cs_n(!(ym51_pend && ym_cen_p1)), .wr_n(1'b0), .a0(ym51_a0), .din(ym51_d), .dout(jt51_dout),
        .ct1(), .ct2(), .irq_n(jt51_irq_n),
        .sample(), .left(), .right(), .xleft(jt51_xl), .xright(jt51_xr)
    );
    assign ym_irq = i_ym2151 && !jt51_irq_n;
`ifdef VERILATOR
    always_ff @(posedge clk) if (i_ym2151 && !rst && ym51_pend && ym_cen_p1 && $test$plusargs("YMDBG")) $display("YMWRITE a0=%0d d=%02x", ym51_a0, ym51_d);
`endif
    logic signed [15:0] ym2151_mono;                 // registered: keeps the adder out of the mix's cone
    always_ff @(posedge clk) ym2151_mono <= 16'((17'(jt51_xl) + 17'(jt51_xr)) >>> 1);

    // ------------------------------------------------------------------ OKI M6295 (jt6295), clock 1.2 MHz = 96 MHz / 80, pin 7 per board (i_oki_ss)
    logic [6:0] okidiv;
    logic [26:0] oki_acc;
    wire  [26:0] oki_inc = (i_oki_clk == 3'd1) ? 27'd1056000 : (i_oki_clk == 3'd2) ? 27'd2062500 : (i_oki_clk == 3'd4) ? 27'd1000000 : 27'd2112000;
    wire  [26:0] oki_sum = oki_acc + oki_inc;
    logic        oki_cen_f;
    wire         oki_cen = (i_oki_clk == 3'd0) ? (okidiv == 7'd0) : oki_cen_f;
    always_ff @(posedge clk) begin
        oki_cen_f <= 1'b0;
        if (rst) begin okidiv <= '0; oki_acc <= '0; end
        else begin
            okidiv <= (okidiv == 7'd79) ? 7'd0 : okidiv + 7'd1;
            if (oki_sum >= 27'd96000000) begin oki_acc <= oki_sum - 27'd96000000; oki_cen_f <= 1'b1; end
            else oki_acc <= oki_sum;
        end
    end
    logic signed [13:0] oki_snd;

    jt6295 #(.INTERPOL(0)) u_oki (
        .rst(rst), .clk(clk), .cen(oki_cen), .ss(i_oki_ss),
        .wrn(oki_wrn), .din(porta), .dout(oki_dout),
        .rom_addr(oki_addr), .rom_data(oki_data), .rom_ok(oki_ok),
        .sound(oki_snd), .sample()
    );

    assign dbg_ym  = i_ym2151 ? ym2151_mono : opll_acc_out;
    assign dbg_oki = {{2{oki_snd[13]}}, oki_snd};
    assign d_oki_status = oki_dout;

    // ------------------------------------------------------------------ mono mix.  The two gains are FITTED to MAME's own output of the same session
    // (tools/audio_fit.py: per half second E_mame = a^2 E_ym + b^2 E_oki over 14 s of Dharma, residual within a few percent): a = 6.35 for the YM2413 accumulator,
    // b = 1.59 for the OKI's 14-bit output; this is MAME's level (its routing is YM2413 x0.90, OKI x0.10), i_gain scales it up.
    always_comb begin
        logic signed [25:0] ymm, okim, mix;
        ymm  = i_ym2151 ? ((26'(ym2151_mono) * 26'(YM51_GAIN)) >>> 8) : ((26'(opll_acc_out) * (i_ym_hi ? 26'sd3611 : 26'sd1625)) >>> 8);       // 1625 / 256 = 6.35 = MAME's 0.90 route; 2.00 / 0.90 = 2.222
        okim = (26'(oki_snd) * (i_ym2151 ? 26'(OKI51_GAIN) : i_oki_vm ? 26'sd2040 : i_oki_hi ? 26'sd1020 : 26'sd408)) >>> 8;
        mix  = ymm + okim + 26'(i_aux);
        // YM2151 boards are far louder in MAME than the YM2413 boards (MAME's own output peaks at 12-25 thousand against 3 thousand for Dharma: YM2151 and OKI routes
        // 0.40 against 0.10; the first hardware test of 20261007c: "much louder", Gun Master "scratchy" = the x4 default clipped), so the OSD steps start 18 dB lower
        // there: the default is x0.5 of MAME's level, about the loudness of Dharma / Toride II at their default (active-window RMS 1.4-3.7 thousand against 1.6 thousand).
        // Varia Metal (i_loud) is only half as loud as that: its default is MAME's own level (user, hardware test of 20261009c: "a bit low" at x0.5).
        if (i_ym2151) mix = mix >>> 3;
        else if (i_loud) mix = mix >>> 2;
        case (i_gain)
            2'd0:    mix = mix <<< 2;
            2'd1:    mix = mix <<< 1;
            2'd3:    mix = mix <<< 3;
            default: ;
        endcase
        if (mix > 26'sd32767)       audio = 16'sd32767;
        else if (mix < -26'sd32768) audio = -16'sd32768;
        else                        audio = mix[15:0];
    end
endmodule
`default_nettype wire

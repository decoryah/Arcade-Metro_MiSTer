// Metro main board (Dharma Doujou, metro.cpp 0.289 `dharma_map`): the 68000 (fx68k, 12 MHz via the phase enables), its program ROM port, 64 KB
// work RAM, the Imagetek I4220 (metro_vdp), the I/O ports, and the sound-CPU command latch.  Bus cycle structure follows
// mcatadv-mister/mister/rtl/mcatadv_main.sv.  docs/hardware.md sections 3-5 describe the map and the sound interface.
//
//   0x000000-0x03FFFF  program ROM (256 KB)                      read through rom_req/rom_addr/rom_ack/rom_data
//   0x400000-0x40FFFF  work RAM 64 KB, mirrored every 0x10000 up to 0x4FFFFF
//   0x800000-0x87FFFF  Imagetek I4220 (metro_vdp, v2 map)
//   0x8788A9 (byte)    sound command (overlays the VDP window; MAME: sound_data_w)
//   0xC00000 IN0 (coins, start, service, tilt; bit 7 = sound CPU busy)   0xC00002 IN1 (joysticks)   0xC00004 DSW0   0xC00006 IN2
//   0xC00001 (byte w)  soundstatus_w, 0xC00002-0xC00009 writes: coin counters -- accepted and ignored
//
// IRQ: the VDP's level output drives the 68000's level 2 (autovector).
`default_nettype none
module metro_main #(
    parameter int GFX_AW   = 24,
    parameter int P_PIXDIV = 16,        // system clocks per dot (96 MHz / 16 = 6.0 MHz)
    parameter int P_H_TOTAL = 392,
    parameter int P_VLAST  = 262,
    parameter int P_HS_BEG = 336,
    parameter int P_HS_END = 368,
    parameter int P_VS_BEG = 232,
    parameter int P_VS_END = 236
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_phi1, cen_phi2,
    input  logic        win_mame,                    // 1: show chip lines 0..223 like MAME instead of the CRTC window
    input  logic        flip_force,                  // 1: flip the picture whatever the game sets (the Flip Screen DIP)
    input  logic        pal_latch,                   // 1: the picture uses the palette as it was at the start of the frame (OSD)
    input  logic [7:0]  i_board,                     // image config byte 0: board id (tools/metro_rom.py BOARDS); picks the memory map, anything unknown: Dharma's

    // program ROM (word reads; 18-bit word address inside the 512 KB)
    output logic        rom_req,
    output logic [20:1] rom_addr,
    input  logic        rom_ack,
    input  logic [15:0] rom_data,

    // GFX ROM stream (metro_vdp's protocol)
    output logic              gfx_req,
    output logic [GFX_AW:0]    gfx_addr,
    output logic [6:0]        gfx_len,
    input  logic [15:0]       gfx_data,
    input  logic              gfx_valid,
    input  logic [31:0]       gfx_size,

    // inputs (active low as MAME's ports; bit 7 of IN0 is replaced by snd_busy)
    input  logic [15:0] in0, in1, dsw0, dsw1, in2,
    // family F (boards 18 / 19): the Konami 053936's registers as the 68000 wrote them (control block, line RAM through its own port) and its tile map RAM through port B
    output logic [15:0] o_roz_ctrl [16],
    // the hardware test overlay's measurements (metro_hud.sv): the plane's 16 words above the video chip's 16, valid at the clock of o_hud_frame
    output logic [511:0] o_hud_st,
    output logic        o_hud_frame,
    input  logic        i_roz_prio,                  // hardware test switches (OSD): the plane's graphics reads first / the 68000's sprite writes not held
    input  logic        i_no_hold,
    input  logic        i_vlog_off,                  // hardware test switch (OSD "Tile RAM frame sync"): 1 = the layer RAM is written live as before (F_VLOG builds)
    // the 053936's tile map RAM (256 KB) lives in the SDRAM (metro_sdram's shared-RAM client): the 68000's accesses and the plane's map reads
    output logic        o_sr3_req,
    output logic        o_sr3_we,
    output logic [16:0] o_sr3_addr,
    output logic [15:0] o_sr3_wdata,
    output logic  [1:0] o_sr3_be,
    input  logic [15:0] i_sr3_rdata,
    input  logic        i_sr3_ack,

    // family D (the I4300 boards: Mouja, Mahjong Doukyuusei; no sound CPU): the mahjong keys (rows 0..3, six bits each, 0 = pressed) and the 68000's access to the
    // YM2413 and the OKI M6295 (the top routes them to metro_sound's direct port); the OKI's 18-bit sample address comes back as a 22-bit ROM address (bank switching)
    input  logic [23:0] i_mj,
    input  logic        i_ee_ld_wr,                  // Doukyuusei Special's EEPROM: its initial contents from the loader
    input  logic [6:0]  i_ee_ld_addr,
    input  logic [7:0]  i_ee_ld_data,
    output logic        d_ym_wr, d_ym_a0, d_oki_wr,
    // family C (YMF278B on the 68000 bus): a byte written to its port o_ymf_a (0 .. 5), the status read, its status and interrupt
    output logic        o_ymf_wr, o_ymf_rd,
    output logic  [2:0] o_ymf_a,
    output logic  [7:0] o_ymf_d,
    input  logic  [7:0] i_ymf_status,
    input  logic        i_ymf_irq,
    output logic [7:0]  d_data,
    input  logic [7:0]  d_oki_status,
    // Varia Metal (board 17): the ES8712 sound controller's register writes, its sample ROM bank (control register bit 4) and its interrupt line (gated by control bit 6, level 3)
    output logic        o_es_wr, o_es_rst,
    output logic [2:0]  o_es_a,
    output logic [7:0]  o_es_d,
    output logic        o_es_bank,
    input  logic        i_es_irq,
    input  logic [17:0] oki_a,
    output logic [21:0] oki_a22,
    output logic        fam_d_o,

    // sound CPU interface (a stand-in until the uPD78C10 exists)
    output logic [7:0]  snd_cmd,
    output logic        snd_cmd_wr,
    input  logic        snd_busy,

    // video
    output logic        hs, vs, de, hblank, vblank, ce_pix,
    output logic [4:0]  r5, g5, b5,

    // debug / trace
    output logic        irq_o,
    output logic        vbl_o,                       // one clock at the start of vblank (VDP cause bit 0 set)
    output logic        cpu_halted,
    output logic        trc_stb,
    output logic [23:1] trc_addr,
    output logic        trc_rw,
    output logic [15:0] trc_data,
    output logic [1:0]  trc_be,
    output logic        gfx_overrun
);
    // ------------------------------------------------------------------ CPU
    logic [23:1] eab;
    logic [15:0] oEdb, iEdb;
    logic        eRWn, ASn, LDSn, UDSn, VMAn, E;
    logic        FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
    logic        DTACKn;
    logic        irq;
    logic        irq3;                              // Varia Metal: the ES8712's interrupt, level 3
    logic [2:0]  vdp_lvl;
    logic [7:0]  vdp_vec;
    logic        tmr_fire;
    logic        fam_d_r, mouja_r, dsp_r;           // the board's family (registered from the board id below); dsp_r = Doukyuusei Special
    logic        fam_c_r, msgogo_r, bl_r;                 // family C (22 msgogo, 23 balcube, 24 daitoa): I4220 + YMF278B on the 68000 bus, no sound CPU
    logic        gk1_r, gk2_r;                      // Mahjong Gakuensai (20) / Gakuensai 2 (21): Doukyuusei Special's map with the sound chips, the OKI banks and the 93C46 at other addresses
    wire iack = FC2 & FC1 & FC0 & ~ASn;

    logic pwr_d;
    always_ff @(posedge clk) pwr_d <= reset;

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(reset | pwr_d), .pwrUp(reset),
        .enPhi1(cen_phi1), .enPhi2(cen_phi2),
        .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
        .E(E), .VMAn(VMAn),
        .FC0(FC0), .FC1(FC1), .FC2(FC2),
        .BGn(BGn),
        .oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
        .DTACKn(DTACKn), .VPAn(fam_d_r ? 1'b1 : ~iack),
        .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(fam_d_r ? ~vdp_lvl[0] : fam_c_r ? ~(irq && !i_ymf_irq) : (vm_r || f_r) ? ~(irq | irq3) : 1'b1), .IPL1n(fam_d_r ? ~vdp_lvl[1] : fam_c_r ? ~i_ymf_irq : (vm_r || f_r) ? ~irq3 : ~irq), .IPL2n(fam_d_r ? ~vdp_lvl[2] : 1'b1),        // level 2 (family D: the chip's level)
        .iEdb(iEdb), .oEdb(oEdb),
        .eab(eab)
    );
    assign cpu_halted = ~oHALTEDn;
    assign irq_o = irq;

    // ------------------------------------------------------------------ decode
    wire [23:0] ba = {eab, 1'b0};
    // Memory maps (metro.cpp) and I/O layouts, chosen by the board id (tools/metro_rom.py BOARDS).  RAM (64 KB mirrored over 1 MB), the video chip (512 KB window) and the I/O
    // block (16 bytes) sit at three of 0x400000 / 0x800000 / 0xC00000 (RAM also at 0xF00000, the I/O word block at 0x400000 ...); the sound command is the odd byte of VDP base + 0x788A8.
    //   id  board              ROM    RAM   VDP     I/O   I/O layout
    //   1   dharma             256 K  4     8       C     0
    //   2   toride2g           512 K  4     C       8     0
    //   3   pururun, gunmast   512 K  8     C       4     0
    //   4   daitorid           256 K  8     4       C     0
    //   5   puzzli             as 4
    //   6   puzzlia            as 3
    //   7   karatour (+ ladykill, moegonta)   512 K  F   8   4   2     (I4100, 320 x 240)
    //   8   pangpoms           256 K  C     4       8     1     (I4100, 360 x 224)
    //   9   skyalert           256 K  C     8       4     1     (I4100, 360 x 224)
    //   10  lastfort           256 K  4     8       C     1     (I4100, 360 x 224)
    //   11  lastforg           512 K  C     0x880000 4     2     (I4100, 360 x 224)
    //   12  poitto             256 K  4     C       8     0     (I4100, 360 x 224: Toride II's map)
    //   13  sankokushi         512 K  7     8       C     0     (I4220, 320 x 240, vblank irq 5 like karatour)
    //   14  dokyusei           256 K  F     4       I/O at VDP + 0x78880 (mahjong matrix), YM2413 C, OKI D, OKI banks 8 / A     (I4300, 16 MHz, no sound CPU)
    //   15  mouja              512 K  F     4       I/O at VDP + 0x78880 (joysticks), YM2413 C, OKI D, OKI bank 8, timer irq    (I4300, 16 MHz, no sound CPU)
    //   17  vmetal             1 M    F     1       P1_P2 / SYSTEM 2, DSW scan 3, OKI 4, ES8712 5, control 0x200001   (I4220, 16 MHz, 304 x 224, ROT90, ES8712 + MSM6585 + OKI, VDP irq level 1, ES irq level 3)
    //   16  dokyusp            256 K  F     2       I/O at VDP + 0x78880 (mahjong matrix), OKI bank 5, YM2413 6, OKI 7, EEPROM C (cs) / D (data)   (I4300, 16 MHz, 384 x 224, no sound CPU)
    // I/O layouts (word index = address bits 3..1):
    //   0  IN0 (coins, bit 7 = sound busy) / IN1 (P1 low byte, P2 high byte) / DSW0 / IN2             at words 0 / 1 / 2 / 3                  (Dharma, Toride II, the YM2151 boards)
    //   1  soundstatus (byte 1: 1 = sound CPU idle) / IN0 coins / P1 joystick / P2 joystick / DSW0 / DSW1 / IN3        at words 0 / 2 / 3 / 4 / 5 / 6 / 7     (Pang Pom's, Sky Alert, Last Fortress)
    //   2  soundstatus / IN0 = P2 joystick / IN1 coins / DSW0 (game options) / DSW1 (coinage, flip) / IN2 = P1 joystick  at words 0 / 1 / 2 / 3 / 5 / 6   (Karate Tournament, Lady Killer, Last Fortress VG460)
    logic       rom512_r, wide_r, tall_r, i4100_r, rom1m_r, vm_r, f_r, rom2m_r;
    logic       bt_r, early_r, ext5_r, scan_r, tdx_r, tdx1_r;                // the board's flags for the video chip and the ROZ layer, registered: static after the load, kept off the fit's long path (cfg -> compare -> 2048 loads)
    logic [3:0] n_ram_r;
    logic [4:0] vdp5_r;                 // address bits 23..19 of the video chip window
    logic [1:0] q_io_r, io_cls_r;
    logic [3:0] c_in_q, c_dsw_q, c_ymf_q;                          // family C: the 1 MB block (address bits 23:20) of the inputs, the DIP switch matrix and the YMF278B
    logic [22:0] snd_w_r;               // word address of the sound command's word (VDP base + 0x788A8)
    // the board is static (the image's configuration), so the map selects are registered: keeps their mux out of the address decode's cone
    always_ff @(posedge clk) begin
        unique case (i_board)
            8'd2:    begin rom512_r <= 1'b1; n_ram_r <= 4'h4; vdp5_r <= 5'b11000; q_io_r <= 2'd2; io_cls_r <= 2'd0; end
            8'd3, 8'd6: begin rom512_r <= 1'b1; n_ram_r <= 4'h8; vdp5_r <= 5'b11000; q_io_r <= 2'd1; io_cls_r <= 2'd0; end
            8'd4, 8'd5: begin rom512_r <= 1'b0; n_ram_r <= 4'h8; vdp5_r <= 5'b01000; q_io_r <= 2'd3; io_cls_r <= 2'd0; end
            8'd7:    begin rom512_r <= 1'b1; n_ram_r <= 4'hF; vdp5_r <= 5'b10000; q_io_r <= 2'd1; io_cls_r <= 2'd2; end
            8'd8:    begin rom512_r <= 1'b0; n_ram_r <= 4'hC; vdp5_r <= 5'b01000; q_io_r <= 2'd2; io_cls_r <= 2'd1; end
            8'd9:    begin rom512_r <= 1'b0; n_ram_r <= 4'hC; vdp5_r <= 5'b10000; q_io_r <= 2'd1; io_cls_r <= 2'd1; end
            8'd10:   begin rom512_r <= 1'b0; n_ram_r <= 4'h4; vdp5_r <= 5'b10000; q_io_r <= 2'd3; io_cls_r <= 2'd1; end
            8'd11:   begin rom512_r <= 1'b1; n_ram_r <= 4'hC; vdp5_r <= 5'b10001; q_io_r <= 2'd1; io_cls_r <= 2'd2; end
            8'd12:   begin rom512_r <= 1'b0; n_ram_r <= 4'h4; vdp5_r <= 5'b11000; q_io_r <= 2'd2; io_cls_r <= 2'd0; end
            8'd13:   begin rom512_r <= 1'b1; n_ram_r <= 4'h7; vdp5_r <= 5'b10000; q_io_r <= 2'd3; io_cls_r <= 2'd0; end
            8'd14:   begin rom512_r <= 1'b0; n_ram_r <= 4'hF; vdp5_r <= 5'b01000; q_io_r <= 2'd0; io_cls_r <= 2'd0; end
            8'd15:   begin rom512_r <= 1'b1; n_ram_r <= 4'hF; vdp5_r <= 5'b01000; q_io_r <= 2'd0; io_cls_r <= 2'd0; end
            8'd16:   begin rom512_r <= 1'b0; n_ram_r <= 4'hF; vdp5_r <= 5'b00100; q_io_r <= 2'd0; io_cls_r <= 2'd0; end
            8'd17:   begin rom512_r <= 1'b0; n_ram_r <= 4'hF; vdp5_r <= 5'b00010; q_io_r <= 2'd0; io_cls_r <= 2'd0; end
            8'd18, 8'd19: begin rom512_r <= 1'b0; n_ram_r <= 4'hF; vdp5_r <= 5'b00100; q_io_r <= 2'd0; io_cls_r <= 2'd0; end      // family F: VDP 0x200000, RAM 0xF00000
            8'd22:   begin rom512_r <= 1'b1; n_ram_r <= 4'hF; vdp5_r <= 5'b00010; q_io_r <= 2'd0; io_cls_r <= 2'd0; c_in_q <= 4'h2; c_dsw_q <= 4'h3; c_ymf_q <= 4'h4; end      // msgogo_map: VDP 0x100000, IN 0x200000, DSW 0x300000, YMF 0x400000
            8'd23:   begin rom512_r <= 1'b1; n_ram_r <= 4'hF; vdp5_r <= 5'b01100; q_io_r <= 2'd0; io_cls_r <= 2'd0; c_in_q <= 4'h5; c_dsw_q <= 4'h4; c_ymf_q <= 4'h3; end      // balcube_map: YMF 0x300000, DSW 0x400000, IN 0x500000, VDP 0x600000
            8'd24:   begin rom512_r <= 1'b1; n_ram_r <= 4'hF; vdp5_r <= 5'b00010; q_io_r <= 2'd0; io_cls_r <= 2'd0; c_in_q <= 4'h2; c_dsw_q <= 4'h3; c_ymf_q <= 4'h4; end      // daitoa_map: VDP 0x100000, IN 0x200000, DSW 0x300000, YMF 0x400000
            8'd25:   begin rom512_r <= 1'b1; n_ram_r <= 4'hF; vdp5_r <= 5'b11100; q_io_r <= 2'd0; io_cls_r <= 2'd0; c_in_q <= 4'hD; c_dsw_q <= 4'hC; c_ymf_q <= 4'hB; end      // bangball_map: YMF 0xB00000, DSW 0xC00000, IN 0xD00000, VDP 0xE00000
            8'd26:   begin rom512_r <= 1'b0; n_ram_r <= 4'hF; vdp5_r <= 5'b00010; q_io_r <= 2'd0; io_cls_r <= 2'd0; c_in_q <= 4'h2; c_dsw_q <= 4'h3; c_ymf_q <= 4'h4; end      // batlbubl_map (1 MB program): VDP 0x100000, IN1 / DSW0 / IN0 / IN2 0x200000, DSW matrix 0x300000, YMF 0x400000
            8'd20:   begin rom512_r <= 1'b1; n_ram_r <= 4'hF; vdp5_r <= 5'b00100; q_io_r <= 2'd0; io_cls_r <= 2'd0; end      // gakusai: ROM 512 K, VDP 0x200000, RAM 0xF00000 (metro.cpp gakusai_map)
            8'd21:   begin rom512_r <= 1'b1; n_ram_r <= 4'hF; vdp5_r <= 5'b01100; q_io_r <= 2'd0; io_cls_r <= 2'd0; end      // gakusai2: ROM 512 K, VDP 0x600000, RAM 0xF00000 (gakusai2_map)
            default: begin rom512_r <= 1'b0; n_ram_r <= 4'h4; vdp5_r <= 5'b10000; q_io_r <= 2'd3; io_cls_r <= 2'd0; end   // 1: dharma
        endcase
        i4100_r <= (i_board >= 8'd7 && i_board <= 8'd12);
        wide_r  <= (i_board >= 8'd8 && i_board <= 8'd12);
        tall_r  <= (i_board == 8'd7 || i_board == 8'd13 || i_board == 8'd20 || i_board == 8'd21);          // Gakuensai: 320 x 240 (i4300_config_320x240)
        fam_d_r <= (i_board == 8'd14 || i_board == 8'd15 || i_board == 8'd16 || i_board == 8'd20 || i_board == 8'd21);
        mouja_r <= (i_board == 8'd15);
        dsp_r   <= (i_board == 8'd16);
        fam_c_r <= (i_board == 8'd22 || i_board == 8'd23 || i_board == 8'd24 || i_board == 8'd25 || i_board == 8'd26);
        bl_r    <= (i_board == 8'd26);
        msgogo_r <= (i_board == 8'd22);
        gk1_r   <= (i_board == 8'd20);
        gk2_r   <= (i_board == 8'd21);
        vm_r    <= (i_board == 8'd17);
        rom1m_r <= (i_board == 8'd17 || i_board == 8'd26);
`ifdef D_BUILD
        f_r     <= 1'b0;
`else
        f_r     <= (i_board == 8'd18 || i_board == 8'd19);
`endif
        bt_r    <= (i_board == 8'd18);
        early_r <= (i_board == 8'd5 || i_board == 8'd6);
        scan_r  <= (i_board == 8'd5 || i_board == 8'd6 || i_board == 8'd25 || i_board == 8'd26);
        ext5_r  <= (i_board == 8'd7 || i_board == 8'd11 || i_board == 8'd13 || i_board == 8'd18 || i_board == 8'd19);
        tdx_r   <= (i_board == 8'd4 || i_board == 8'd5 || i_board == 8'd6 || (i_board >= 8'd22 && i_board <= 8'd26));
        tdx1_r  <= (i_board == 8'd19);
        rom2m_r <= (i_board == 8'd18 || i_board == 8'd19);
        snd_w_r <= {vdp5_r, 18'd0} + 23'h03C454;
    end
    wire sel_rom = rom2m_r ? (ba[23:21] == 3'h0) : rom1m_r ? (ba[23:20] == 4'h0) : rom512_r ? (ba[23:19] == 5'h00) : (ba[23:18] == 6'h00);
    wire sel_ram = ba[23:20] == n_ram_r;
    wire sel_vdp = ba[23:19] == vdp5_r;
    wire sel_snd = !f_r && eab[23:1] == snd_w_r;                                            // the word at VDP base + 0x788A8; the command is its odd byte
    wire sel_io  = !fam_d_r && !vm_r && !f_r && !fam_c_r && ba[23:22] == q_io_r && ba[21:4] == 18'h00000;
    // family C: IN0 (word 0) and IN1 (word 1), the DIP switch matrix (balcube_dsw_r, as Varia Metal's), the YMF278B (ports 0 .. 5 are the word offsets, the data is the low byte)
    wire c_in       = fam_c_r && ba[23:20] == c_in_q && ba[19:4] == 16'h0000;
    wire c_dsw      = fam_c_r && ba[23:20] == c_dsw_q && ba[19:17] == 3'b000;
    wire c_ymf      = fam_c_r && ba[23:20] == c_ymf_q && ba[19:4] == 16'h0000;
    // Battle Bubble's own order (batlbubl_map): IN1 (the joysticks), DSW0 (as a word), IN0 (the coins), IN2
    wire [15:0] c_in_mux = bl_r ? ((ba[3:1] == 3'd0) ? in1 : (ba[3:1] == 3'd1) ? dsw0 : (ba[3:1] == 3'd2) ? in0 : (ba[3:1] == 3'd3) ? in2 : 16'h0000)
                                : ((ba[3:1] == 3'd0) ? in0 : (ba[3:1] == 3'd1) ? in1 : 16'h0000);
    // family F (metro.cpp blzntrnd_state::main_map): 0xE00000 DSW0, 0xE00002 DSW1 (a write: the sound command, upper byte), 0xE00004 IN0, 0xE00006 IN1, 0xE00008 IN2;
    // the 053936: 0x400000..43FFFF tile map RAM (256 KB), 0x500000..500FFF line RAM (write), 0x600000..60001F control (write)
    wire f_io       = f_r && ba[23:4] == 20'hE0000;
    wire f_roz_ram  = f_r && ba[23:18] == 6'b010000;
    wire f_roz_line = f_r && ba[23:12] == 12'h500;
    wire f_roz_ctl  = f_r && ba[23:5] == 19'h30000;
    assign fam_d_o = fam_d_r;

    // family D: the ports sit inside the video chip's window (VDP + 0x78880), the sound chips and OKI banks at 0xC00000 / 0xD00000 / 0x800000 / 0xA00000 (metro.cpp dokyusei_map, mouja main_map)
    wire d_io_sel   = fam_d_r && sel_vdp && ba[18:4] == 15'h7888;
    wire d_tmr_sel  = mouja_r && sel_vdp && ba[18:1] == 18'h3C41A;                       // VDP + 0x78834: the interrupt timer
    wire d_ym_sel   = fam_d_r && ((dsp_r || gk1_r) ? ba[23:2] == 22'h180000 : ba[23:2] == 22'h300000);   // 0xC00000..3 (dokyusp 0x600000..3), odd bytes: YM2413 register / data
    wire vm_io      = vm_r && ba[23:4] == 20'h20000;                                     // Varia Metal 0x200000..F: P1_P2 (word 0), SYSTEM (word 1); the control register is the byte at 0x200001
    wire vm_dsw     = vm_r && ba[23:17] == 7'h18;                                        // 0x300000..0x31FFFF: the DIP switches, one bit a read (balcube_dsw_r)
    wire vm_oki     = vm_r && ba[23:2] == 22'h100000;                                    // 0x400000..3: the OKI M6295 (0x400001 read / write, 0x400003 write)
    wire vm_es      = vm_r && ba[23:4] == 20'h50000;                                     // 0x500000..F: the ES8712 (odd bytes: registers 0..6; the even byte at 0x500000: reset)
    wire [15:0] vm_io_mux = (ba[3:1] == 3'd0) ? in1 : (ba[3:1] == 3'd1) ? in0 : 16'h0000;
    logic [15:0] vm_dsw_val;
    always_comb begin
        vm_dsw_val = 16'hFFFF;                                                           // balcube_dsw_r: bit 6 = DSW0 bit b, bit 7 = IN2 bit b for every address bit b (word offset) that is 0
        for (int b = 0; b < 16; b++) if (!ba[b + 1]) vm_dsw_val = vm_dsw_val & {8'h00, in2[b], dsw0[b], 6'h00};
    end
    wire d_oki_sel  = vm_oki || fam_d_r && ((dsp_r || gk1_r) ? ba[23:1] == 23'h380000 : gk2_r ? ba[23:1] == 23'h580000 : ba[23:1] == 23'h680000);   // gakusai2: 0xB00000 / 1   // 0xD00000 / 1 (dokyusp 0x700000 / 1): OKI M6295
    wire d_bank_a   = (fam_d_r && !dsp_r && !gk1_r && !gk2_r && ba[23:1] == 23'h400000) || (gk1_r && ba[23:1] == 23'h680000) || (gk2_r && ba[23:1] == 23'h500000);   // gakusai: OKI bank high at 0xD00001, gakusai2 0xA00001                       // 0x800001: dokyusei: OKI bank high, mouja: OKI bank
    wire d_bank_b   = fam_d_r && !mouja_r && ((dsp_r || gk1_r) ? ba[23:1] == 23'h280000 : gk2_r ? ba[23:1] == 23'h480000 : ba[23:1] == 23'h500000);   // gakusai 0x500001, gakusai2 0x900001: OKI bank low   // 0xA00001: dokyusei: OKI bank low (dokyusp 0x500001: its only bank register)
    wire d_ee_rst   = dsp_r && ba[23:1] == 23'h600000;                                   // 0xC00001: dokyusp's EEPROM chip select (bit 0)
    wire d_gk_ee    = (gk1_r && ba[23:1] == 23'h600000) || (gk2_r && ba[23:1] == 23'h700000);          // gakusai_eeprom_r / w at 0xC00001 / 0xE00001: DI = bit 0, CLK = bit 1 (a level), CS = bit 2; read: DO in bit 0
    wire d_ee_dat   = dsp_r && ba[23:1] == 23'h680000;                                   // 0xD00001: its data bit (write: DI + a clock edge; read: a clock edge, then DO)

    // ------------------------------------------------------------------ work RAM
    logic        we;                                      // one-cycle write strobe
    wire  [1:0]  be = {~UDSn, ~LDSn};
    logic [15:0] q_ram;
    metro_dpram #(.AW(15), .DW(16), .SLICED(1)) u_ram (
        .clk(clk), .addr_a(eab[15:1]), .d_a(oEdb), .we_a(we && sel_ram), .be_a(be), .q_a(q_ram),
        .addr_b(15'd0), .q_b());

    // ------------------------------------------------------------------ video chip
    logic        vdp_cs, vdp_ack;
    logic [15:0] vdp_ovr;
    logic [255:0] vdp_st, roz_st;
    logic [15:0] vdp_rdata;
`ifdef F_VLOG
    localparam bit P_VLOG_ON = 1'b1;                  // family F: the layer RAM changes at the copy instant, not while the beam is drawing (metro_vdp.sv P_VLOG)
`else
    localparam bit P_VLOG_ON = 1'b0;
`endif
    metro_vdp #(.GFX_AW(GFX_AW), .P_PIXDIV(P_PIXDIV), .P_SPR_BUFFERED(1'b0), .P_VLOG(P_VLOG_ON),
                .P_H_TOTAL(P_H_TOTAL), .P_VLAST(P_VLAST), .P_HS_BEG(P_HS_BEG), .P_HS_END(P_HS_END),
                .P_VS_BEG(P_VS_BEG), .P_VS_END(P_VS_END),
                .P_IRQ_MODEL(1), .P_VBL_LINE(224), .P_TICK_LINES(32), .P_TICK_CLKS(200000)) u_vdp (
        .clk(clk), .rst_n(~reset),
        .i_tim_rst(1'b0), .o_tim_evt(),
        .i_cs(vdp_cs), .i_addr({eab[18:1], 1'b0}), .i_rnw(eRWn), .i_be(be),
        .i_wdata(oEdb), .o_rdata(vdp_rdata), .o_ack(vdp_ack),
        .o_hs(hs), .o_vs(vs), .o_de(de), .o_hblank(hblank), .o_vblank(vblank), .o_ce_pix(ce_pix),
        .o_r(r5), .o_g(g5), .o_b(b5),
        .o_irq(irq), .o_vbl_pulse(vbl_o),
        .o_rom_req(gfx_req), .o_rom_addr(gfx_addr), .o_rom_len(gfx_len),
        .i_rom_data(gfx_data), .i_rom_valid(gfx_valid),
        .i_gfx_size(gfx_size),
        .i_compat60(1'b0), .i_win_mame(win_mame), .i_flip_force(flip_force), .i_pal_latch(pal_latch), .i_spr_early(early_r), .i_tick_slow(msgogo_r), .i_tmap_dx(tdx_r ? 4'd2 : 4'd0), .i_tmap_dx1(tdx1_r ? 4'd8 : 4'd0),
        .i_roz_en(f_r), .i_vlog_en(!i_vlog_off), .i_roz_prio(i_roz_prio), .i_no_hold(i_no_hold), .o_roz_frame(rz_frame), .o_roz_used(rz_used), .i_roz_done(rz_done), .o_roz_bank(rz_bank), .o_roz_x(rz_x), .i_roz_pen(rz_pen), .i_roz_op(rz_op),
        .i_roz_req(rz_rq_req), .i_roz_addr(rz_rq_addr), .i_roz_len(rz_rq_len), .o_roz_wr(rz_wr), .o_roz_idx(rz_idx), .o_roz_data(rz_data), .o_roz_ack(rz_ack), .i_w304(vm_r || f_r), .i_w384(dsp_r), .i_wide(wide_r), .i_tall(tall_r), .i_i4100(i4100_r), .i_ext5(ext5_r), .i_scan_irq(scan_r), .i_irq_line_mask(8'hFF),
        .i_i4300(fam_d_r), .i_vbl_bit(3'd1), .i_blit_bit(mouja_r ? 3'd2 : 3'd3), .i_irq0_pulse(tmr_fire), .i_vec_idx(eab[3:1]), .o_irq_lvl(vdp_lvl), .o_vec(vdp_vec),
        .o_dbg_vdp_write(), .o_dbg_line_start(), .o_dbg_rnd_done(), .o_dbg_lb_nonzero(), .o_dbg_palw(), .o_dbg_ovr(vdp_ovr),
        .o_dbg_rend_sx2_0(), .o_dbg_rend_sx2_1(), .o_dbg_rend_sx2_2(),
        .o_dbg_disp_sx2_0(), .o_dbg_disp_sx2_1(), .o_dbg_disp_sx2_2(),
        .o_dbg_topflags(),
        .o_st(vdp_st)
    );
    assign gfx_overrun = |vdp_ovr;                     // sticky: the count of render kicks dropped since reset

    // ------------------------------------------------------------------ bus cycle
    logic        rdy;                                     // DTACK
    logic [2:0]  cnt;
    logic        wr_seen;
    assign DTACKn = ~rdy;

    logic [15:0] io_mux;
    always_comb begin
        io_mux = 16'h0000;
        unique case (io_cls_r)
            2'd1: unique case (ba[3:1])
                3'd0:    io_mux = {8'h00, 7'd0, ~snd_busy};
                3'd2:    io_mux = in0;
                3'd3:    io_mux = {8'h00, in1[7:0]};
                3'd4:    io_mux = {8'h00, in1[15:8]};
                3'd5:    io_mux = dsw0;
                3'd6:    io_mux = dsw1;
                3'd7:    io_mux = 16'hFFFF;
                default: io_mux = 16'h0000;
            endcase
            2'd2: unique case (ba[3:1])
                3'd0:    io_mux = {8'h00, 7'd0, ~snd_busy};
                3'd1:    io_mux = {8'h00, in1[15:8]};
                3'd2:    io_mux = in0;
                3'd3:    io_mux = dsw0;
                3'd5:    io_mux = dsw1;
                3'd6:    io_mux = {8'h00, in1[7:0]};
                default: io_mux = 16'h0000;
            endcase
            default: unique case (ba[3:1])
                3'd0:    io_mux = {in0[15:8], snd_busy, in0[6:0]};
                3'd1:    io_mux = in1;
                3'd2:    io_mux = dsw0;
                3'd3:    io_mux = in2;
                default: io_mux = 16'h0000;
            endcase
        endcase
    end

    assign rom_addr = eab[20:1];

    logic [15:0] f_io_mux;
    always_comb begin
        f_io_mux = 16'hFFFF;
        unique case (ba[3:1])
            3'd0:    f_io_mux = dsw0;
            3'd1:    f_io_mux = dsw1;
            3'd2:    f_io_mux = in0;
            3'd3:    f_io_mux = in1;
            3'd4:    f_io_mux = in2;
            default: f_io_mux = 16'hFFFF;
        endcase
    end
    logic        rz_frame, rz_rq_req, rz_wr, rz_ack, rz_op;
    logic [GFX_AW:0] rz_rq_addr;
    logic  [6:0] rz_rq_len;
    logic [15:0] rz_data, rz_li_q;
    logic  [4:0] rz_idx;
    logic [10:0] rz_li_addr;
    logic  [8:0] rz_used, rz_done, rz_x;
    logic  [2:0] rz_bank;
    logic [11:0] rz_pen;
    logic        rz_par;
    // the tile map RAM is in the SDRAM and written by the 68000 through this client (word accesses, one at a time); the plane engine reads it in 64-byte windows through
    // the video chip's graphics stream (metro_roz.sv: the same SDRAM words, by their byte address in the stream's space)
    logic        cpu_sr_req, cpu_sr_done, sr_busy, cpu_arm;
    wire         rz_inval = i_sr3_ack && sr_busy && o_sr3_we;          // the 68000's write to the map has landed: the plane's cached window of it goes
    logic [15:0] cpu_sr_rdata;
`ifdef F_POSTW
    logic        sr_post;
    // Posted writes (METRO, 20261011h): the 68000's writes to the map end at once, like the board's static RAM (the cycle waited for the SDRAM's acknowledge: ~30 clocks
    // longer each, 600 words a frame in Blazing Tornado's continue screen: a game that clears and refills a stretch of the map in the visible part of the frame was
    // caught half way by the beam: the flickering band).  The writes queue (16 deep) and go to the SDRAM in order behind the CPU's back; a read of the map waits for the queue.
    logic [34:0] pw_q [0:15];
    logic  [4:0] pw_wp, pw_rp;
    logic        pw_push;
    logic [34:0] pw_pd;
    wire         pw_empty = (pw_wp == pw_rp);
    wire         pw_full  = (pw_wp[3:0] == pw_rp[3:0]) && (pw_wp[4] != pw_rp[4]);
    always_ff @(posedge clk) begin
        cpu_sr_done <= 1'b0;
        if (reset) begin
            sr_busy <= 1'b0; o_sr3_req <= 1'b0; cpu_arm <= 1'b1; sr_post <= 1'b0; pw_wp <= 5'd0; pw_rp <= 5'd0;
        end else begin
            if (pw_push) begin pw_q[pw_wp[3:0]] <= pw_pd; pw_wp <= pw_wp + 5'd1; end
            if (!cpu_sr_req) cpu_arm <= 1'b1;
            if (!sr_busy) begin
                if (!pw_empty) begin
                    sr_busy <= 1'b1; sr_post <= 1'b1;
                    o_sr3_req <= 1'b1; o_sr3_we <= 1'b1;
                    o_sr3_addr <= pw_q[pw_rp[3:0]][34:18]; o_sr3_wdata <= pw_q[pw_rp[3:0]][17:2]; o_sr3_be <= pw_q[pw_rp[3:0]][1:0];
                    pw_rp <= pw_rp + 5'd1;
                end else if (cpu_sr_req && cpu_arm) begin
                    sr_busy <= 1'b1; sr_post <= 1'b0; cpu_arm <= 1'b0;
                    o_sr3_req <= 1'b1; o_sr3_we <= !eRWn; o_sr3_addr <= eab[17:1]; o_sr3_wdata <= oEdb; o_sr3_be <= be;
                end
            end else if (i_sr3_ack) begin
                sr_busy <= 1'b0; o_sr3_req <= 1'b0;
                cpu_sr_rdata <= i_sr3_rdata; cpu_sr_done <= !sr_post;
            end
        end
    end
`else
    always_ff @(posedge clk) begin
        cpu_sr_done <= 1'b0;
        if (reset) begin
            sr_busy <= 1'b0; o_sr3_req <= 1'b0; cpu_arm <= 1'b1;
        end else begin
            if (!cpu_sr_req) cpu_arm <= 1'b1;
            if (!sr_busy) begin
                if (cpu_sr_req && cpu_arm) begin
                    sr_busy <= 1'b1; cpu_arm <= 1'b0;
                    o_sr3_req <= 1'b1; o_sr3_we <= !eRWn; o_sr3_addr <= eab[17:1]; o_sr3_wdata <= oEdb; o_sr3_be <= be;
                end
            end else if (i_sr3_ack) begin
                sr_busy <= 1'b0; o_sr3_req <= 1'b0;
                cpu_sr_rdata <= i_sr3_rdata; cpu_sr_done <= 1'b1;
            end
        end
    end
`endif
`ifdef F_BUILD
    (* ramstyle = "M10K" *) logic [7:0] rz_line_h [0:2047];
    (* ramstyle = "M10K" *) logic [7:0] rz_line_l [0:2047];
`else
    (* ramstyle = "MLAB" *) logic [7:0] rz_line_h [0:2047];            // the line RAM: MLABs (the M10K blocks of the device are used up)
    (* ramstyle = "MLAB" *) logic [7:0] rz_line_l [0:2047];
`endif
    always_ff @(posedge clk) begin
        if (we && f_roz_line && be[1]) rz_line_h[eab[11:1]] <= oEdb[15:8];
        if (we && f_roz_line && be[0]) rz_line_l[eab[11:1]] <= oEdb[7:0];
        rz_li_q <= {rz_line_h[rz_li_addr], rz_line_l[rz_li_addr]};
    end
    // the plane's tile ROM: the graphics stream's address space after the graphics (Metro.sv, tools/metro_rom.py layout: the program 2 MB, the Z80 128 KB, then the tiles)
    wire [GFX_AW:0] rz_gfx_base = (GFX_AW+1)'(gfx_size) + (GFX_AW+1)'(32'h0220000);
    // the tile map RAM (metro_sdram.sv SR3_WBASE: word 0xE00000 = byte 28 MB, the F64 build 60 MB) in the graphics stream's space (the graphics start 1 MB into the SDRAM)
`ifdef F64
    wire [GFX_AW:0] rz_map_base = (GFX_AW+1)'(32'h3B00000);
`else
    wire [GFX_AW:0] rz_map_base = (GFX_AW+1)'(32'h1B00000);
`endif
    wire f_bt = bt_r;                    // Blazing Tornado: 8 x 8 tiles of 64 bytes
    // VIS_H 240: the video chip draws chip lines up to v_vis + crtc_vfirst - 1 (234 with the game's CRTC window of 11, 238 at most) and waits for the plane's row of each of them; with 224 rows
    // the last 11 lines never came, were drawn late at the start of the next frame (the kick FIFO overran) and showed the background pen: hardware test of 20261010 / 20261011a
`ifdef D_BUILD
    // the 64 MB family D build (Mahjong Gakuensai): no 053936 plane
    assign rz_li_addr = 11'd0;
    assign rz_rq_req = 1'b0;
    assign rz_rq_addr = '0;
    assign rz_rq_len = 7'd0;
    assign rz_done = 9'd0;
    assign rz_par = 1'b0;
    assign rz_pen = 12'd0;
    assign rz_op = 1'b0;
    assign roz_st = 256'd0;
`else
    metro_roz #(.XOFF(-77), .YOFF(-19), .VIS_W(304), .VIS_H(240), .AW(GFX_AW + 1)) u_roz (
        .clk(clk), .reset(reset), .i_en(f_r), .i_bt(f_bt), .i_frame(rz_frame), .i_ctrl(o_roz_ctrl),
        .o_li_addr(rz_li_addr), .i_li_q(rz_li_q),
        .o_rq_req(rz_rq_req), .o_rq_addr(rz_rq_addr), .o_rq_len(rz_rq_len), .i_rq_wr(rz_wr), .i_rq_idx(rz_idx), .i_rq_data(rz_data), .i_rq_ack(rz_ack),
        .i_map_base(rz_map_base), .i_gfx2_base(rz_gfx_base),
        .i_inval(rz_inval), .i_inval_addr(o_sr3_addr), .i_rows_used(rz_used), .o_rows_done(rz_done), .o_par(rz_par),
        .i_rd_bank(rz_bank), .i_rd_x(rz_x), .o_pen(rz_pen), .o_op(rz_op), .o_st(roz_st));
`endif
    assign o_hud_st = {roz_st, vdp_st};
    assign o_hud_frame = rz_frame;
    always_ff @(posedge clk) begin
        if (reset) for (int i = 0; i < 16; i++) o_roz_ctrl[i] <= 16'd0;
        else if (we && f_roz_ctl) begin
            if (be[1]) o_roz_ctrl[eab[4:1]][15:8] <= oEdb[15:8];
            if (be[0]) o_roz_ctrl[eab[4:1]][7:0]  <= oEdb[7:0];
        end
    end

    // ------------------------------------------------------------------ family D: inputs, OKI banking, Mouja's interrupt timer
    logic [15:0] in_sel = 16'hFFFF;                // the mahjong matrix row selects (written at VDP + 0x78888)
    logic [2:0]  bank_lo = 3'd0, bank_m = 3'd0;
    logic        bank_hi = 1'b0;
    wire  [5:0]  mj_res = (in_sel[1] ? 6'h3F : i_mj[5:0]) & (in_sel[2] ? 6'h3F : i_mj[11:6]) & (in_sel[3] ? 6'h3F : i_mj[17:12]) & (in_sel[4] ? 6'h3F : i_mj[23:18]);
    wire  [15:0] mj_word = {9'd0, mj_res, 1'b0} | 16'hFF81;      // gakusai_state::input_r: (result << 1) | 0xff81
    logic [15:0] d_io_mux;
    always_comb begin
        d_io_mux = 16'h0000;
        unique case (ba[3:1])
            3'd0:    d_io_mux = mouja_r ? in0 : mj_word;
            3'd1:    d_io_mux = mouja_r ? in1 : in0;
            3'd2:    d_io_mux = dsw0;
            3'd3:    d_io_mux = mouja_r ? in2 : dsw1;
            default: d_io_mux = 16'h0000;
        endcase
    end
    // OKI sample ROM address: dokyusei: 256 KB banks (bank = low 3 bits + 8 * high bit, the region is 1 MB: 4 banks); mouja: the first 128 KB fixed, the upper 128 KB of the
    // 256 KB window banked (8 banks of 128 KB, metro.cpp mouja_state::oki_map / sound_rombank_w); the other boards: the address as it is
    wire [3:0] dk_bank = {bank_hi, bank_lo};
    always_comb begin
        if (!fam_d_r)      oki_a22 = {4'd0, oki_a};
        else if (mouja_r)  oki_a22 = oki_a[17] ? {1'b0, bank_m, oki_a[16:0]} : {5'd0, oki_a[16:0]};
        else if (gk1_r || gk2_r) oki_a22 = {dk_bank, oki_a};                                       // Gakuensai: 4 MB, 16 banks of 256 KB (oki_bank_set: low 3 bits + 8 * the high bit)
        else               oki_a22 = {1'b0, dsp_r ? bank_lo : {1'b0, bank_lo[1:0]}, oki_a};      // dokyusp: 2 MB, 8 banks of 256 KB
    end
    // Mouja's timer (irq_timer_ctrl_w): the first interrupt at once, then every 96 MHz / (58 + (0xff - data) / 2.2 Hz) clocks
    function automatic logic [21:0] mj_period(input logic [7:0] d);
        case (d)
            8'd0: mj_period = 22'd552013;
            8'd1: mj_period = 22'd553459;
            8'd2: mj_period = 22'd554913;
            8'd3: mj_period = 22'd556375;
            8'd4: mj_period = 22'd557845;
            8'd5: mj_period = 22'd559322;
            8'd6: mj_period = 22'd560807;
            8'd7: mj_period = 22'd562300;
            8'd8: mj_period = 22'd563801;
            8'd9: mj_period = 22'd565310;
            8'd10: mj_period = 22'd566828;
            8'd11: mj_period = 22'd568353;
            8'd12: mj_period = 22'd569887;
            8'd13: mj_period = 22'd571429;
            8'd14: mj_period = 22'd572979;
            8'd15: mj_period = 22'd574538;
            8'd16: mj_period = 22'd576105;
            8'd17: mj_period = 22'd577681;
            8'd18: mj_period = 22'd579265;
            8'd19: mj_period = 22'd580858;
            8'd20: mj_period = 22'd582460;
            8'd21: mj_period = 22'd584071;
            8'd22: mj_period = 22'd585691;
            8'd23: mj_period = 22'd587319;
            8'd24: mj_period = 22'd588957;
            8'd25: mj_period = 22'd590604;
            8'd26: mj_period = 22'd592260;
            8'd27: mj_period = 22'd593926;
            8'd28: mj_period = 22'd595601;
            8'd29: mj_period = 22'd597285;
            8'd30: mj_period = 22'd598979;
            8'd31: mj_period = 22'd600683;
            8'd32: mj_period = 22'd602396;
            8'd33: mj_period = 22'd604119;
            8'd34: mj_period = 22'd605852;
            8'd35: mj_period = 22'd607595;
            8'd36: mj_period = 22'd609348;
            8'd37: mj_period = 22'd611111;
            8'd38: mj_period = 22'd612885;
            8'd39: mj_period = 22'd614668;
            8'd40: mj_period = 22'd616462;
            8'd41: mj_period = 22'd618267;
            8'd42: mj_period = 22'd620082;
            8'd43: mj_period = 22'd621908;
            8'd44: mj_period = 22'd623745;
            8'd45: mj_period = 22'd625592;
            8'd46: mj_period = 22'd627451;
            8'd47: mj_period = 22'd629321;
            8'd48: mj_period = 22'd631201;
            8'd49: mj_period = 22'd633094;
            8'd50: mj_period = 22'd634997;
            8'd51: mj_period = 22'd636912;
            8'd52: mj_period = 22'd638838;
            8'd53: mj_period = 22'd640777;
            8'd54: mj_period = 22'd642727;
            8'd55: mj_period = 22'd644689;
            8'd56: mj_period = 22'd646663;
            8'd57: mj_period = 22'd648649;
            8'd58: mj_period = 22'd650647;
            8'd59: mj_period = 22'd652658;
            8'd60: mj_period = 22'd654681;
            8'd61: mj_period = 22'd656716;
            8'd62: mj_period = 22'd658765;
            8'd63: mj_period = 22'd660826;
            8'd64: mj_period = 22'd662900;
            8'd65: mj_period = 22'd664987;
            8'd66: mj_period = 22'd667088;
            8'd67: mj_period = 22'd669202;
            8'd68: mj_period = 22'd671329;
            8'd69: mj_period = 22'd673469;
            8'd70: mj_period = 22'd675624;
            8'd71: mj_period = 22'd677792;
            8'd72: mj_period = 22'd679974;
            8'd73: mj_period = 22'd682171;
            8'd74: mj_period = 22'd684381;
            8'd75: mj_period = 22'd686606;
            8'd76: mj_period = 22'd688845;
            8'd77: mj_period = 22'd691099;
            8'd78: mj_period = 22'd693368;
            8'd79: mj_period = 22'd695652;
            8'd80: mj_period = 22'd697951;
            8'd81: mj_period = 22'd700265;
            8'd82: mj_period = 22'd702595;
            8'd83: mj_period = 22'd704940;
            8'd84: mj_period = 22'd707301;
            8'd85: mj_period = 22'd709677;
            8'd86: mj_period = 22'd712070;
            8'd87: mj_period = 22'd714479;
            8'd88: mj_period = 22'd716904;
            8'd89: mj_period = 22'd719346;
            8'd90: mj_period = 22'd721805;
            8'd91: mj_period = 22'd724280;
            8'd92: mj_period = 22'd726772;
            8'd93: mj_period = 22'd729282;
            8'd94: mj_period = 22'd731809;
            8'd95: mj_period = 22'd734353;
            8'd96: mj_period = 22'd736916;
            8'd97: mj_period = 22'd739496;
            8'd98: mj_period = 22'd742094;
            8'd99: mj_period = 22'd744711;
            8'd100: mj_period = 22'd747346;
            8'd101: mj_period = 22'd750000;
            8'd102: mj_period = 22'd752673;
            8'd103: mj_period = 22'd755365;
            8'd104: mj_period = 22'd758076;
            8'd105: mj_period = 22'd760807;
            8'd106: mj_period = 22'd763557;
            8'd107: mj_period = 22'd766328;
            8'd108: mj_period = 22'd769119;
            8'd109: mj_period = 22'd771930;
            8'd110: mj_period = 22'd774762;
            8'd111: mj_period = 22'd777614;
            8'd112: mj_period = 22'd780488;
            8'd113: mj_period = 22'd783383;
            8'd114: mj_period = 22'd786299;
            8'd115: mj_period = 22'd789238;
            8'd116: mj_period = 22'd792198;
            8'd117: mj_period = 22'd795181;
            8'd118: mj_period = 22'd798186;
            8'd119: mj_period = 22'd801214;
            8'd120: mj_period = 22'd804265;
            8'd121: mj_period = 22'd807339;
            8'd122: mj_period = 22'd810437;
            8'd123: mj_period = 22'd813559;
            8'd124: mj_period = 22'd816705;
            8'd125: mj_period = 22'd819876;
            8'd126: mj_period = 22'd823071;
            8'd127: mj_period = 22'd826291;
            8'd128: mj_period = 22'd829537;
            8'd129: mj_period = 22'd832808;
            8'd130: mj_period = 22'd836105;
            8'd131: mj_period = 22'd839428;
            8'd132: mj_period = 22'd842777;
            8'd133: mj_period = 22'd846154;
            8'd134: mj_period = 22'd849558;
            8'd135: mj_period = 22'd852989;
            8'd136: mj_period = 22'd856448;
            8'd137: mj_period = 22'd859935;
            8'd138: mj_period = 22'd863451;
            8'd139: mj_period = 22'd866995;
            8'd140: mj_period = 22'd870569;
            8'd141: mj_period = 22'd874172;
            8'd142: mj_period = 22'd877805;
            8'd143: mj_period = 22'd881469;
            8'd144: mj_period = 22'd885163;
            8'd145: mj_period = 22'd888889;
            8'd146: mj_period = 22'd892646;
            8'd147: mj_period = 22'd896435;
            8'd148: mj_period = 22'd900256;
            8'd149: mj_period = 22'd904110;
            8'd150: mj_period = 22'd907997;
            8'd151: mj_period = 22'd911917;
            8'd152: mj_period = 22'd915872;
            8'd153: mj_period = 22'd919861;
            8'd154: mj_period = 22'd923885;
            8'd155: mj_period = 22'd927944;
            8'd156: mj_period = 22'd932039;
            8'd157: mj_period = 22'd936170;
            8'd158: mj_period = 22'd940338;
            8'd159: mj_period = 22'd944544;
            8'd160: mj_period = 22'd948787;
            8'd161: mj_period = 22'd953069;
            8'd162: mj_period = 22'd957389;
            8'd163: mj_period = 22'd961749;
            8'd164: mj_period = 22'd966148;
            8'd165: mj_period = 22'd970588;
            8'd166: mj_period = 22'd975069;
            8'd167: mj_period = 22'd979592;
            8'd168: mj_period = 22'd984157;
            8'd169: mj_period = 22'd988764;
            8'd170: mj_period = 22'd993415;
            8'd171: mj_period = 22'd998110;
            8'd172: mj_period = 22'd1002849;
            8'd173: mj_period = 22'd1007634;
            8'd174: mj_period = 22'd1012464;
            8'd175: mj_period = 22'd1017341;
            8'd176: mj_period = 22'd1022265;
            8'd177: mj_period = 22'd1027237;
            8'd178: mj_period = 22'd1032258;
            8'd179: mj_period = 22'd1037328;
            8'd180: mj_period = 22'd1042448;
            8'd181: mj_period = 22'd1047619;
            8'd182: mj_period = 22'd1052841;
            8'd183: mj_period = 22'd1058116;
            8'd184: mj_period = 22'd1063444;
            8'd185: mj_period = 22'd1068826;
            8'd186: mj_period = 22'd1074262;
            8'd187: mj_period = 22'd1079755;
            8'd188: mj_period = 22'd1085303;
            8'd189: mj_period = 22'd1090909;
            8'd190: mj_period = 22'd1096573;
            8'd191: mj_period = 22'd1102296;
            8'd192: mj_period = 22'd1108080;
            8'd193: mj_period = 22'd1113924;
            8'd194: mj_period = 22'd1119830;
            8'd195: mj_period = 22'd1125800;
            8'd196: mj_period = 22'd1131833;
            8'd197: mj_period = 22'd1137931;
            8'd198: mj_period = 22'd1144095;
            8'd199: mj_period = 22'd1150327;
            8'd200: mj_period = 22'd1156627;
            8'd201: mj_period = 22'd1162996;
            8'd202: mj_period = 22'd1169435;
            8'd203: mj_period = 22'd1175947;
            8'd204: mj_period = 22'd1182531;
            8'd205: mj_period = 22'd1189189;
            8'd206: mj_period = 22'd1195923;
            8'd207: mj_period = 22'd1202733;
            8'd208: mj_period = 22'd1209622;
            8'd209: mj_period = 22'd1216590;
            8'd210: mj_period = 22'd1223638;
            8'd211: mj_period = 22'd1230769;
            8'd212: mj_period = 22'd1237984;
            8'd213: mj_period = 22'd1245283;
            8'd214: mj_period = 22'd1252669;
            8'd215: mj_period = 22'd1260143;
            8'd216: mj_period = 22'd1267707;
            8'd217: mj_period = 22'd1275362;
            8'd218: mj_period = 22'd1283111;
            8'd219: mj_period = 22'd1290954;
            8'd220: mj_period = 22'd1298893;
            8'd221: mj_period = 22'd1306931;
            8'd222: mj_period = 22'd1315068;
            8'd223: mj_period = 22'd1323308;
            8'd224: mj_period = 22'd1331652;
            8'd225: mj_period = 22'd1340102;
            8'd226: mj_period = 22'd1348659;
            8'd227: mj_period = 22'd1357326;
            8'd228: mj_period = 22'd1366106;
            8'd229: mj_period = 22'd1375000;
            8'd230: mj_period = 22'd1384010;
            8'd231: mj_period = 22'd1393140;
            8'd232: mj_period = 22'd1402390;
            8'd233: mj_period = 22'd1411765;
            8'd234: mj_period = 22'd1421265;
            8'd235: mj_period = 22'd1430894;
            8'd236: mj_period = 22'd1440655;
            8'd237: mj_period = 22'd1450549;
            8'd238: mj_period = 22'd1460581;
            8'd239: mj_period = 22'd1470752;
            8'd240: mj_period = 22'd1481066;
            8'd241: mj_period = 22'd1491525;
            8'd242: mj_period = 22'd1502134;
            8'd243: mj_period = 22'd1512894;
            8'd244: mj_period = 22'd1523810;
            8'd245: mj_period = 22'd1534884;
            8'd246: mj_period = 22'd1546120;
            8'd247: mj_period = 22'd1557522;
            8'd248: mj_period = 22'd1569094;
            8'd249: mj_period = 22'd1580838;
            8'd250: mj_period = 22'd1592760;
            8'd251: mj_period = 22'd1604863;
            8'd252: mj_period = 22'd1617152;
            8'd253: mj_period = 22'd1629630;
            8'd254: mj_period = 22'd1642302;
            8'd255: mj_period = 22'd1655172;
            default: mj_period = 22'd1655172;
        endcase
    endfunction
    logic [21:0] tmr_period = 22'd1655172, tmr_cnt = 22'd0;
    logic        tmr_on = 1'b0, tmr_wr = 1'b0;
    logic [7:0]  tmr_wd = 8'd0;
    always_ff @(posedge clk) begin
        tmr_fire <= 1'b0;
        if (reset) begin tmr_on <= 1'b0; tmr_cnt <= 22'd0; end
        else if (tmr_wr) begin tmr_period <= mj_period(tmr_wd); tmr_cnt <= 22'd0; tmr_on <= 1'b1; end
        else if (tmr_on) begin
            if (tmr_cnt == 22'd0) begin tmr_fire <= 1'b1; tmr_cnt <= tmr_period - 22'd1; end
            else tmr_cnt <= tmr_cnt - 22'd1;
        end
    end

    // Doukyuusei Special's 93C46 (rtl/metro_eeprom.sv): CS is a latch at 0xC00001, every access to 0xD00001 gives the chip one clock edge
    logic ee_cs = 1'b0, ee_di = 1'b0, ee_clk = 1'b0, ee_clkl = 1'b0;                    // ee_clkl: the level of Gakuensai's clock bit (the chip clocks on its rising edge)
    wire  ee_do;
    metro_eeprom u_eeprom (.clk(clk), .i_cs(ee_cs), .i_clk(ee_clk), .i_di(ee_di), .o_do(ee_do),
                           .i_ld_wr(i_ee_ld_wr), .i_ld_addr(i_ee_ld_addr), .i_ld_data(i_ee_ld_data));

    // Varia Metal's control register (0x200001): bit 4 the ES8712 sample ROM bank, bit 6 the gate of its interrupt (clearing it drops the level 3 request; the line follows the ES8712's
    // output only while the gate is open, and only when the output changes, as vmetal_state::es8712_irq does)
    logic [7:0] vm_ctl = 8'd0;
    logic       vm_ctl_wr = 1'b0, vm_gate = 1'b0, es_irq_q = 1'b0;
    assign o_es_bank = vm_ctl[4];
    always_ff @(posedge clk) begin
        es_irq_q <= i_es_irq;
        if (reset) begin vm_gate <= 1'b0; irq3 <= 1'b0; end
        else begin
            if (i_es_irq != es_irq_q && vm_gate) irq3 <= i_es_irq;
            if (vm_ctl_wr) begin
                vm_gate <= vm_ctl[6];
                if (!vm_ctl[6]) irq3 <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        we         <= 1'b0;
        ee_clk     <= 1'b0;
        vm_ctl_wr  <= 1'b0;
        o_es_wr    <= 1'b0;
        o_es_rst   <= 1'b0;
        snd_cmd_wr <= 1'b0;
        trc_stb    <= 1'b0;
        d_ym_wr    <= 1'b0;
        d_oki_wr   <= 1'b0;
        o_ymf_wr   <= 1'b0;
        o_ymf_rd   <= 1'b0;
        tmr_wr     <= 1'b0;
`ifdef F_POSTW
        pw_push    <= 1'b0;
`endif
        if (reset || ASn) begin
            rdy     <= 1'b0;
            cnt     <= 3'd0;
            wr_seen <= 1'b0;
            rom_req <= 1'b0;
            vdp_cs  <= 1'b0;
            cpu_sr_req <= 1'b0;
        end else if (iack && fam_d_r && !rdy) begin
            iEdb <= {8'h00, vdp_vec};                       // vectored interrupt acknowledge: the chip's vector of the level being served
            rdy  <= 1'b1;
        end else if (!iack && !rdy) begin
            if (sel_vdp && !(sel_snd && !eRWn) && !d_io_sel && !d_tmr_sel) begin
                // video chip: hold cs with stable address/data until it acknowledges (writes wait for the strobes like the others)
                if (be != 2'b00) begin
                    vdp_cs <= 1'b1;
                    if (vdp_cs && vdp_ack) begin
                        vdp_cs <= 1'b0;
                        iEdb   <= vdp_rdata;
                        rdy    <= 1'b1;
                        trc_stb <= 1'b1; trc_addr <= eab; trc_rw <= eRWn; trc_data <= eRWn ? vdp_rdata : oEdb; trc_be <= be;
                    end
                end
            end else if (f_roz_ram) begin
`ifdef F_POSTW
                // the 053936's tile map RAM in the SDRAM: a write is posted (queued, the cycle ends at once), a read holds the cycle until its access is done
                if (be != 2'b00) begin
                    if (!eRWn) begin
                        if (!wr_seen) wr_seen <= 1'b1;                   // the data strobes (and the data) arrive a clock after AS
                        else if (!pw_full) begin
                            pw_push <= 1'b1; pw_pd <= {eab[17:1], oEdb, be};
                            rdy <= 1'b1;
                        end
                    end else begin
                        cpu_sr_req <= 1'b1;
                        if (cpu_sr_req && cpu_sr_done) begin
                            cpu_sr_req <= 1'b0;
                            iEdb <= cpu_sr_rdata;
                            rdy  <= 1'b1;
                        end
                    end
                end
`else
                // the 053936's tile map RAM in the SDRAM: hold the cycle until its access is done
                if (be != 2'b00) begin
                    cpu_sr_req <= 1'b1;
                    if (cpu_sr_req && cpu_sr_done) begin
                        cpu_sr_req <= 1'b0;
                        iEdb <= cpu_sr_rdata;
                        rdy  <= 1'b1;
                    end
                end
`endif
            end else if (!eRWn) begin
                // write: the data strobes (and the data) arrive a clock after AS
                if (!wr_seen) begin
                    if (be != 2'b00) begin
                        wr_seen <= 1'b1;
                        we      <= 1'b1;
                        if (sel_snd && be[0]) begin snd_cmd <= oEdb[7:0]; snd_cmd_wr <= 1'b1; end
                        if (f_io && ba[3:1] == 3'd1 && be[1]) begin snd_cmd <= oEdb[15:8]; snd_cmd_wr <= 1'b1; end
                        if (d_ym_sel && be[0]) begin d_ym_wr <= 1'b1; d_ym_a0 <= ba[1]; d_data <= oEdb[7:0]; end
                        if (d_oki_sel && be != 2'b00) begin d_oki_wr <= 1'b1; d_data <= be[0] ? oEdb[7:0] : oEdb[15:8]; end
                        if (c_ymf && be[0]) begin o_ymf_wr <= 1'b1; o_ymf_a <= ba[3:1]; o_ymf_d <= oEdb[7:0]; end
                        if (d_bank_a && be[0]) begin if (mouja_r) bank_m <= oEdb[5:3]; else bank_hi <= oEdb[0]; end
                        if (d_bank_b && be[0]) bank_lo <= oEdb[2:0];
                        if (d_ee_rst && be[0]) ee_cs <= oEdb[0];
                        if (d_ee_dat && be[0]) begin ee_di <= oEdb[0]; ee_clk <= 1'b1; end
                        if (d_gk_ee && be[0]) begin ee_di <= oEdb[0]; ee_cs <= oEdb[2]; ee_clkl <= oEdb[1]; if (oEdb[1] && !ee_clkl) ee_clk <= 1'b1; end
                        if (vm_io && ba[3:1] == 3'd0 && be[0]) begin vm_ctl <= oEdb[7:0]; vm_ctl_wr <= 1'b1; end
                        if (vm_es && be[0]) begin o_es_wr <= 1'b1; o_es_a <= ba[3:1]; o_es_d <= oEdb[7:0]; end
                        if (vm_es && ba[3:1] == 3'd0 && be[1]) o_es_rst <= 1'b1;
                        if (d_io_sel && ba[3:1] == 3'd4 && !mouja_r) in_sel <= oEdb;
                        if (d_tmr_sel && be[0]) begin tmr_wr <= 1'b1; tmr_wd <= oEdb[7:0]; end
                        trc_stb <= 1'b1; trc_addr <= eab; trc_rw <= 1'b0; trc_data <= oEdb; trc_be <= be;
                    end
                end else begin
                    rdy <= 1'b1;
                end
            end else if (sel_rom) begin
                rom_req <= 1'b1;
                if (rom_ack) begin
                    iEdb    <= rom_data;
                    rom_req <= 1'b0;
                    rdy     <= 1'b1;
                    trc_stb <= 1'b1; trc_addr <= eab; trc_rw <= 1'b1; trc_data <= rom_data; trc_be <= be;
                end
            end else begin
                cnt <= cnt + 3'd1;
                if (cnt == 3'd0 && d_ee_dat) ee_clk <= 1'b1;
                if (cnt == 3'd3) begin
                    if (c_ymf) o_ymf_rd <= 1'b1;                                   // the status has been taken: the chip's read strobe (the first status read returns the chip ID)
                    iEdb <= sel_ram ? q_ram : f_io ? f_io_mux : sel_io ? io_mux : d_io_sel ? d_io_mux : vm_io ? vm_io_mux : (vm_dsw || c_dsw) ? vm_dsw_val : c_in ? c_in_mux : c_ymf ? {8'h00, i_ymf_status} : (d_ee_dat || d_gk_ee) ? {15'd0, ee_do} : d_oki_sel ? {8'h00, d_oki_status} : 16'h0000;
                    rdy  <= 1'b1;
                    trc_stb <= 1'b1; trc_addr <= eab; trc_rw <= 1'b1; trc_data <= sel_ram ? q_ram : f_io ? f_io_mux : sel_io ? io_mux : d_io_sel ? d_io_mux : vm_io ? vm_io_mux : (vm_dsw || c_dsw) ? vm_dsw_val : c_in ? c_in_mux : c_ymf ? {8'h00, i_ymf_status} : (d_ee_dat || d_gk_ee) ? {15'd0, ee_do} : d_oki_sel ? {8'h00, d_oki_status} : 16'h0000; trc_be <= be;
                end
            end
        end
    end
endmodule
`default_nettype wire

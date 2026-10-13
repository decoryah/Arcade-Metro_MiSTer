//============================================================================
//
//  Metro (Imagetek I4100/I4220/I4300 boards) for MiSTer: Dharma Doujou first (see README / docs/status.md).
//
//  Written for MiSTer from MAME 0.289's driver (src/mame/metro/metro.cpp, src/devices/video/imagetek_i4100.cpp). The video chip is
//  derived from searchsolved/Arcade-HyperDuel_MiSTer (the first RTL implementation of the I4220), the 68000 is fx68k (Jorge Cwik), and
//  the platform layer follows the owner's other cores (Taito L, MCatAdv) and Hyper Duel's SDRAM arbiter.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign FB_FORCE_BLANK = 0;                      // the rotated picture's framebuffer is driven by screen_rotate (DDRAM and FB_*)

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;       // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire         rot_none;                                   // the game is not a vertical one: hides the Rotate screen option
wire         vid_wide;                                   // the game has a 360 / 384-pixel picture: re-timed for a CRT (rtl/metro_vout.sv)
wire  [21:0] gamma_bus;

wire  [1:0] ar = status[122:121];

`include "build_id.v"

// The hardware test switches (OSD "SDRAM read capture", "Debug overlay", "Plane fetch priority", "CPU sprite write hold", "Sound board", "Tile RAM frame sync") exist only in a
// build with VERILOG_MACRO METRO_DEBUG.  A release build has no such OSD entries and every one of them at the setting that was tested on the boards: SDRAM read capture
// normal, no overlay, plane fetch priority low, the 68000's sprite writes held for the list copy, the sound board on, the frame-synchronous tile RAM on (family F).
`ifdef METRO_DEBUG
`define DBG_BIT(b) status[b]
`define DBG_OVL    status[22:21]
`else
`define DBG_BIT(b) 1'b0
`define DBG_OVL    2'd0
`endif
localparam CONF_STR = {
	"Metro;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[7],Display window,Game's CRTC,MAME;",
	"H1O[2],Rotate screen,On,Off;",
	"P1,CRT Adjust;",
	"P1O[101],CRT Adjust,Off,On;",
	"H3P1O[100:96],H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3P1O[85:79],H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3P1O[78:74],V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"DIP;",
	"-;",
	"O[9:8],Volume,Normal,-6 dB,-12 dB,+6 dB;",
`ifdef METRO_DEBUG
	"O[20],SDRAM read capture,Normal,Late;",
	"O[22:21],Debug overlay,Off,Small,Large;",
`ifndef D_BUILD
	"O[23],Plane fetch priority,Low,High;",
	"O[24],CPU sprite write hold,On,Off;",
	"O[25],Sound board,On,Off (test);",
	"O[26],Tile RAM frame sync,On,Off;",
`endif
`endif
	"-;",
	"R0,Reset;",
	"J1,Button 1,Button 2,Start,Coin;",
	"jn,A,B,Start,Select;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;           // 96 MHz: the machine (68000 /8 = 12 MHz, dots /16 = 6.0 MHz)
wire clk_sdram;         // 96 MHz, shifted: the SDRAM chip's clock pin
wire clk_snd;           // 48 MHz, in phase with clk_sys: the YM2610 of family F
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(clk_snd),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram;

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire         dl_busy;

wire  [31:0] joystick_0, joystick_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask({12'd0, ~status[101], 1'b0, rot_none, direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(dl_busy),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

///////////////////////   DIP SWITCHES (from the MRA)   ///////////////////////

// MAME's DSW0 is one 16-bit port: byte 0 = SW1 (bits 0-7), byte 1 = SW2 (bits 8-15), ioctl index 254, bit 0 first, a 1 = MAME's default.
// The boards with a second DIP port (DSW1: Karate Tournament, Pang Pom's, Sky Alert, Last Fortress ...) have it in bytes 2 and 3.
reg [7:0] sw[4];
initial begin sw[0] = 8'hFF; sw[1] = 8'hFF; sw[2] = 8'hFF; sw[3] = 8'hFF; end
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index[7:0] == 8'd254) && !ioctl_addr[26:2]) sw[ioctl_addr[1:0]] <= ioctl_dout;
end

///////////////////////   CONTROLS   ///////////////////////

// keyboard: 1/2 start, 5/6 coin, 9 service (MAME's defaults)
reg key_start1, key_start2, key_coin1, key_coin2, key_service;
// the mahjong panel (family D): letters A-N, Kan = Left Ctrl, Reach = Left Shift, Chi = Space, Pon = Left Alt, Ron = Z (MAME's defaults); 1 = start
reg [13:0] mj_ltr;                                  // A..N
reg        mj_kan, mj_reach, mj_chi, mj_pon, mj_ron;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h016: key_start1  <= ps2_key[9];
			9'h01E: key_start2  <= ps2_key[9];
			9'h02E: key_coin1   <= ps2_key[9];
			9'h036: key_coin2   <= ps2_key[9];
			9'h046: key_service <= ps2_key[9];
			9'h01C: mj_ltr[0]   <= ps2_key[9];      // A
			9'h032: mj_ltr[1]   <= ps2_key[9];      // B
			9'h021: mj_ltr[2]   <= ps2_key[9];      // C
			9'h023: mj_ltr[3]   <= ps2_key[9];      // D
			9'h024: mj_ltr[4]   <= ps2_key[9];      // E
			9'h02B: mj_ltr[5]   <= ps2_key[9];      // F
			9'h034: mj_ltr[6]   <= ps2_key[9];      // G
			9'h033: mj_ltr[7]   <= ps2_key[9];      // H
			9'h043: mj_ltr[8]   <= ps2_key[9];      // I
			9'h03B: mj_ltr[9]   <= ps2_key[9];      // J
			9'h042: mj_ltr[10]  <= ps2_key[9];      // K
			9'h04B: mj_ltr[11]  <= ps2_key[9];      // L
			9'h03A: mj_ltr[12]  <= ps2_key[9];      // M
			9'h031: mj_ltr[13]  <= ps2_key[9];      // N
			9'h014: mj_kan      <= ps2_key[9];      // Left Ctrl
			9'h012: mj_reach    <= ps2_key[9];      // Left Shift
			9'h029: mj_chi      <= ps2_key[9];      // Space
			9'h011: mj_pon      <= ps2_key[9];      // Left Alt
			9'h01A: mj_ron      <= ps2_key[9];      // Z
			default: ;
		endcase
	end
end

// joystick bits: 0 right, 1 left, 2 down, 3 up, 4-5 buttons 1-2, 6 start, 7 coin, 8-9 buttons 3-4 (the MRA's <buttons> list fixes them; family F uses the fourth)
wire j1_r = joystick_0[0], j1_l = joystick_0[1], j1_d = joystick_0[2], j1_u = joystick_0[3], j1_b1 = joystick_0[4], j1_b2 = joystick_0[5], j1_b3 = joystick_0[8], j1_b4 = joystick_0[9];
wire j2_r = joystick_1[0], j2_l = joystick_1[1], j2_d = joystick_1[2], j2_u = joystick_1[3], j2_b1 = joystick_1[4], j2_b2 = joystick_1[5], j2_b3 = joystick_1[8], j2_b4 = joystick_1[9];
wire start1 = joystick_0[6] | key_start1, coin1 = joystick_0[7] | key_coin1;
wire start2 = joystick_1[6] | key_start2, coin2 = joystick_1[7] | key_coin2;

// metro.cpp `dharma`: IN0 (0xC00000) bit 0 service1, 1 tilt, 2 coin1, 3 coin2, 4 start1, 5 start2 (active low), bit 7 = sound busy (set in the core);
// IN1 (0xC00002) P1 in the low byte, P2 in the high byte: up, down, left, right, button 1, button 2 (button 2/3: Dharma test mode only, Gun Master uses all three), active low;
// IN2 (0xC00006) unused. The DIP port comes from the MRA.
wire [15:0] in0 = {8'h00, 1'b0, 1'b0, ~start2, ~start1, ~coin2, ~coin1, 1'b1, ~key_service};
wire [15:0] in1 = ~{1'b0, j2_b3, j2_b2, j2_b1, j2_r, j2_l, j2_d, j2_u,
                    1'b0, j1_b3, j1_b2, j1_b1, j1_r, j1_l, j1_d, j1_u};
wire [15:0] in2 = (cfg_board == 8'd17) ? {8'h00, sw[2]} : 16'hFFFF;

// family D.  Mahjong Doukyuusei (board 14): IN0 (VDP + 0x78882) bit 1 coin 1, bit 2 service 1 (active low); the panel is a 5 x 6 matrix (gakusai_state::input_r), rows 0..3 below (bit 5 of row 0 = start 1).
// Mouja (board 15): IN0 = P1 / P2 joysticks (bit 1 up, 2 down, 3 left, 4 right, 5-7 buttons 1-3; P2 the same from bit 9), IN1 bit 2 start 1, 3 start 2, 4 coin 1, 5 coin 2, 6 service 1, IN2 unused.
wire [15:0] dk_in0 = {12'hFFF, 1'b1, ~key_service, ~coin1, 1'b1};
wire [23:0] mj_rows = ~{ 2'b00, mj_pon, mj_ltr[11], mj_ltr[7], mj_ltr[3],                   // row 3: D H L Pon
                         1'b0, mj_ron, mj_chi, mj_ltr[10], mj_ltr[6], mj_ltr[2],             // row 2: C G K Chi Ron
                         1'b0, mj_reach, mj_ltr[13], mj_ltr[9], mj_ltr[5], mj_ltr[1],        // row 1: B F J N Reach
                         start1, mj_kan, mj_ltr[12], mj_ltr[8], mj_ltr[4], mj_ltr[0] };      // row 0: A E I M Kan Start
wire [15:0] mo_in0 = ~{j2_b3, j2_b2, j2_b1, j2_r, j2_l, j2_d, j2_u, 1'b0, j1_b3, j1_b2, j1_b1, j1_r, j1_l, j1_d, j1_u, 1'b0};
wire [15:0] mo_in1 = ~{8'h00, 1'b0, key_service, coin2, coin1, start2, start1, 2'b00};
// Varia Metal (board 17): P1_P2 (0x200000): P2 in the low byte, P1 in the high byte: up, down, left, right, buttons 1-3, start; SYSTEM (0x200002): bit 0 coin 1, 1 coin 2, 2 tilt, 3 service 1, 4 service 2
wire [15:0] vm_in1 = ~{start1, j1_b3, j1_b2, j1_b1, j1_r, j1_l, j1_d, j1_u, start2, j2_b3, j2_b2, j2_b1, j2_r, j2_l, j2_d, j2_u};
wire [15:0] vm_in0 = {11'h7FF, 1'b1, ~key_service, 1'b1, ~coin2, ~coin1};
wire [15:0] d_in0  = fam_f ? f_in0 : (cfg_board == 8'd15) ? mo_in0 : (cfg_board == 8'd14 || cfg_board == 8'd16 || cfg_board == 8'd20 || cfg_board == 8'd21) ? dk_in0 : (cfg_board == 8'd17) ? vm_in0 : in0;
wire [15:0] d_in1  = (cfg_board == 8'd15) ? mo_in1 : (cfg_board == 8'd17) ? vm_in1 : in1;
wire        fam_c  = (cfg_board == 8'd22) || (cfg_board == 8'd23) || (cfg_board == 8'd24) || (cfg_board == 8'd25) || (cfg_board == 8'd26);      // family C: Mouse Shooter GoGo, Bal Cube, Daitoride (YMF278B version), Bang Bang Ball, Battle Bubble
wire        fam_d  = (cfg_board == 8'd14) || (cfg_board == 8'd15) || (cfg_board == 8'd16) || (cfg_board == 8'd20) || (cfg_board == 8'd21);      // 20 / 21: Mahjong Gakuensai 1 / 2
// family F (18 Blazing Tornado, 19 Grand Striker 2): IN0 = P1 low byte / P2 high byte (up, down, left, right, buttons 1-3), IN1 unused, IN2 bit 0 service 1, 2 coin 1, 3 coin 2, 4 start 1, 5 start 2
wire        fam_f  = (cfg_board == 8'd18) || (cfg_board == 8'd19);
wire [15:0] f_in0  = ~{j2_b4, j2_b3, j2_b2, j2_b1, j2_r, j2_l, j2_d, j2_u, j1_b4, j1_b3, j1_b2, j1_b1, j1_r, j1_l, j1_d, j1_u};
wire [15:0] f_in2  = {10'h3FF, ~start2, ~start1, ~coin2, ~coin1, 1'b1, ~key_service};

///////////////////////   MEMORY   ///////////////////////

// the ROM image: MRA index 0
wire        rom_dl = ioctl_download && (ioctl_index[7:0] == 8'd0);

wire        o_wr_ld;
wire [25:0] o_addr_ld;
wire  [7:0] o_data_ld;
wire  [7:0] cfg_board;
wire        ee_ld_wr;                                    // Doukyuusei Special's EEPROM contents from the loader
wire  [6:0] ee_ld_addr;
wire  [7:0] ee_ld_data;
wire  [1:0] cfg_rot, cfg_scramble;
assign rot_none = (cfg_rot == 2'd0) || (cfg_rot == 2'd2);
assign vid_wide = ((cfg_board >= 8'd8) && (cfg_board <= 8'd12)) || (cfg_board == 8'd16);          // 8 Pang Pom's, 9 Sky Alert, 10 / 11 Last Fortress, 12 Poitto, 16 Doukyuusei Special (384 pixels)
wire [31:0] cfg_gfxsize;

metro_loader u_loader
(
	.clk(clk_sys),
	.dl_wr(ioctl_wr && rom_dl), .dl_addr(ioctl_addr[25:0]), .dl_data(ioctl_dout),
	.o_wr(o_wr_ld), .o_addr(o_addr_ld), .o_data(o_data_ld),
	.cfg_board(cfg_board), .cfg_rot(cfg_rot), .cfg_scramble(cfg_scramble), .cfg_gfxsize(cfg_gfxsize),
	.ee_wr(ee_ld_wr), .ee_addr(ee_ld_addr), .ee_data(ee_ld_data)
);

wire        mrom_rd, mrom_valid, rom_req, rom_ack;                 // metro_sdram's main-ROM client
wire [20:0] mrom_addr;
wire [15:0] mrom_data, rom_data;
wire        rd68, valid68, snd_rom_rd, snd_rom_valid;                 // the two requesters: the 68000's romif and the sound CPU
wire [20:0] raddr68;
wire [18:0] snd_rom_addr;
wire [15:0] snd_rom_data;
wire [17:0] oki_addr;
// family F: the Z80's program reads (the 68000's ROM client, port B of its arbiter), the YM2610's sample addresses / bytes and their one OKI-style SDRAM client
wire        zr_rd;
wire [20:0] zr_addr;
wire [21:0] pa_addr;
wire [20:0] pb_addr;
wire  [7:0] pa_data, pb_data;
wire [22:0] yp_addr;
wire [24:0] mrom_wbase = (cfg_board == 8'd17 || cfg_board == 8'd26 || fam_f) ? (25'h080000 + 25'(cfg_gfxsize[25:1])) : 25'h008000;      // the 68000's program: byte 0x10000 of the image, Varia Metal's 1 MB after its graphics
wire [24:0] oki_wbase = fam_f ? (25'h290000 + 25'(cfg_gfxsize[25:1])) : (cfg_board == 8'd17 || cfg_board == 8'd26) ? (25'h100000 + 25'(cfg_gfxsize[25:1])) : (cfg_board >= 8'd14) ? (25'h080000 + 25'(cfg_gfxsize[25:1])) : 25'h058000;   // the OKI samples: after the GFX ROM on the boards of family D, else at 0xB0000
wire  [7:0] oki_data;
wire        oki_ok, oki_sd_ok;
wire [21:0] oki_sd_addr, oki_a22;
// Varia Metal's ES8712 + MSM6585 (rtl/metro_es8712.sv): its sample ROM (2 MB, after the OKI's 512 KB in the SDRAM) shares the OKI's SDRAM client (rtl/metro_okimux.sv)
wire        es_wr, es_rst, es_bank, es_irq, es_ok;
wire  [2:0] es_a;
wire  [7:0] es_d, es_data;
wire [20:0] es_addr;
wire signed [15:0] es_audio;
wire [20:1] rom_addr;
wire        sr3_req, sr3_we, sr3_ack;                           // family F: the 053936's tile map RAM in the SDRAM
wire [16:0] sr3_addr;
wire [15:0] sr3_wdata, sr3_rdata;
wire  [1:0] sr3_be;
wire        gfx_req, gfx_valid;
`ifdef F64
localparam int GAW = 25;      // the F64 build (Blazing Tornado: 24 MB of graphics): the video chip's graphics address is 25 bits, the stream above it 26
`else
localparam int GAW = 24;
`endif
wire [GAW:0] gfx_addr;
wire  [6:0] gfx_len;
wire [15:0] gfx_data;
wire        mem_ready;
wire        mc_rst;

`ifdef F_BUILD
// the dedicated family F build (Metro.qsf variant with VERILOG_MACRO F_BUILD): the uPD78C10 board, the ES8712 and their SDRAM client are not built
assign oki_sd_addr = 22'd0;
assign oki_ok = 1'b0;
assign es_data = 8'd0;
assign es_ok = 1'b0;
`else
metro_okimux u_okimux
(
	.clk(clk_sys), .rst(mc_rst), .i_en(cfg_board == 8'd17), .i_oki_addr(oki_a22), .i_es_addr(es_addr), .i_es_off(22'h080000),
	.o_addr(oki_sd_addr), .i_data(oki_data), .i_ok(oki_sd_ok), .o_oki_ok(oki_ok), .o_es_data(es_data), .o_es_ok(es_ok)
);
`endif

`ifdef F_BUILD
// the dedicated family F build (Metro.qsf variant with VERILOG_MACRO F_BUILD): the uPD78C10 board, the ES8712 and their SDRAM client are not built
assign es_irq = 1'b0;
assign es_addr = 21'd0;
assign es_audio = 16'sd0;
`else
metro_es8712 u_es
(
	.clk(clk_sys), .rst(mc_rst || cfg_board != 8'd17), .i_wr(es_wr), .i_a(es_a), .i_d(es_d), .i_reset_w(es_rst), .i_bank(es_bank), .o_irq(es_irq),
	.o_addr(es_addr), .i_data(es_data), .i_ok(es_ok), .o_audio(es_audio)
);
`endif

metro_romif u_romif
(
	.clk(clk_sys), .rst(mc_rst), .req(rom_req), .addr(rom_addr), .ack(rom_ack), .data(rom_data),
	.rd(rd68), .raddr(raddr68), .valid(valid68), .rdata(mrom_data)
);

metro_mrom_arb u_arb
(
	.clk(clk_sys), .rst(~mem_ready),
	.rd_a(rd68), .addr_a(raddr68), .valid_a(valid68),
	.rd_b(fam_f ? zr_rd : snd_rom_rd), .addr_b(fam_f ? zr_addr : {2'b00, snd_rom_addr}), .valid_b(snd_rom_valid),
	.rdata(),
	.rd(mrom_rd), .raddr(mrom_addr), .valid(mrom_valid), .sdata(mrom_data)
);

metro_sdram sdram
(
	.clk(clk_sys), .rst_n(pll_locked), .o_ready(mem_ready), .i_rd_late(`DBG_BIT(20)),

	.i_gfx_req(gfx_req), .i_gfx_addr(26'(gfx_addr)), .i_gfx_len(gfx_len), .o_gfx_data(gfx_data), .o_gfx_valid(gfx_valid),
	.i_mrom_wbase(mrom_wbase), .i_mrom_rd(mrom_rd), .i_mrom_addr(mrom_addr), .o_mrom_data(mrom_data), .o_mrom_valid(mrom_valid),
	.i_oki_wbase(oki_wbase), .i_oki_addr(fam_f ? yp_addr : fam_c ? {1'b0, ymf_addr} : {1'b0, oki_sd_addr}), .o_oki_data(oki_data), .o_oki_ok(oki_sd_ok),
	.i_sr3_req(sr3_req), .i_sr3_we(sr3_we), .i_sr3_addr(sr3_addr), .i_sr3_wdata(sr3_wdata), .i_sr3_be(sr3_be), .o_sr3_rdata(sr3_rdata), .o_sr3_ack(sr3_ack),

	.i_dl_wr(o_wr_ld), .i_dl_addr(o_addr_ld), .i_dl_data(o_data_ld), .o_dl_busy(dl_busy), .i_dl_active(ioctl_download),

	.SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),

	.dbg_dl_saw(), .dbg_dl_byte0(), .dbg_dl_byte1(), .dbg_dl_count(), .dbg_selftest(), .dbg_postdl(),
	.dbg_dl_written(), .dbg_dl_dropped(), .dbg_fsm_info(), .dbg_sums(), .dbg_sumb1(), .dbg_sumb2(), .o_st(sdr_st)
);

///////////////////////   THE MACHINE   ///////////////////////

wire        reset_sw = RESET | status[0] | buttons[1];
// the machine is held while a ROM loads and until the memory is up; registered, it fans out to the whole core
reg         mc_rst_r = 1'b1;
always @(posedge clk_sys) mc_rst_r <= reset_sw | rom_dl | dl_busy | ~mem_ready | ~pll_locked;
assign mc_rst = mc_rst_r;

wire        cen_phi1, cen_phi2;
metro_cen u_cen (.clk(clk_sys), .fast((cfg_board >= 8'd4 && cfg_board <= 8'd6) || fam_d || cfg_board == 8'd17 || fam_f || fam_c), .mid13(cfg_board == 8'd20 || cfg_board == 8'd21), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2));

// the sound board: uPD78C10 + YM2413 + OKI M6295 (rtl/metro_sound.sv); IN0 bit 7 is its busy flag
wire [7:0]  snd_cmd;
wire        snd_cmd_wr;
wire        snd_busy, snd_illegal;
wire        d_ym_wr, d_ym_a0, d_oki_wr, fam_d_o;
wire  [7:0] d_data, d_oki_status;
wire signed [15:0] snd_audio;

`ifdef F_BUILD
// the dedicated family F build (Metro.qsf variant with VERILOG_MACRO F_BUILD): the uPD78C10 board, the ES8712 and their SDRAM client are not built
assign snd_busy = 1'b0;
assign snd_illegal = 1'b0;
assign snd_rom_rd = 1'b0;
assign snd_rom_addr = 19'd0;
assign oki_addr = 18'd0;
assign snd_audio = 16'sd0;
assign d_oki_status = 8'd0;
`else
metro_sound u_snd
(
	.clk(clk_sys), .rst(mc_rst || fam_f), .i_gain(status[9:8]), .i_ym2151(cfg_board >= 8'd3 && cfg_board <= 8'd6), .i_oki_ss(cfg_board != 8'd9 && cfg_board != 8'd10),     // OKI pin 7 low (/165) on Sky Alert and Last Fortress (VG420), high (/132) on the others
	.cmd(snd_cmd), .cmd_wr(snd_cmd_wr), .busy(snd_busy),
	.i_direct(fam_d || cfg_board == 8'd17), .i_aux(es_audio), .i_loud(cfg_board == 8'd17), .i_oki_vm(cfg_board == 8'd17), .d_ym_wr(d_ym_wr), .d_ym_a0(d_ym_a0), .d_oki_wr(d_oki_wr), .d_data(d_data), .i_oki_hi(fam_d), .i_ym_hi(cfg_board == 8'd20 || cfg_board == 8'd21), .i_oki_clk((cfg_board == 8'd14) ? 3'd1 : (cfg_board == 8'd15) ? 3'd2 : (cfg_board == 8'd16 || cfg_board == 8'd20 || cfg_board == 8'd21) ? 3'd3 : (cfg_board == 8'd17) ? 3'd4 : 3'd0), .d_oki_status(d_oki_status),
	.rom_rd(snd_rom_rd), .rom_addr(snd_rom_addr), .rom_valid(snd_rom_valid), .rom_data(mrom_data),
	.oki_addr(oki_addr), .oki_data(oki_data), .oki_ok(oki_ok),
	.audio(snd_audio), .dbg_ym(), .dbg_oki(), .dbg_illegal(snd_illegal)
);
`endif

// family C (Mouse Shooter GoGo, Bal Cube, Daitoride's YMF278B version): the YMF278B on the 68000's bus (rtl/metro_ymf.sv); its wave ROM (the image's `oki` slot) rides the OKI-style client
wire        ymf_wr, ymf_rd, ymf_irq, ymf_stall;
wire  [2:0] ymf_a;
wire  [7:0] ymf_d, ymf_status;
wire [21:0] ymf_addr;
wire signed [15:0] ymf_audio;
`ifdef NO_YMF
// builds without family C (VERILOG_MACRO NO_YMF: the 32 MB core `metro` and the family F core): the YMF278B is not built
assign ymf_status = 8'd0;
assign ymf_irq    = 1'b0;
assign ymf_addr   = 22'd0;
assign ymf_audio  = 16'sd0;
assign ymf_stall  = 1'b0;
`else
metro_ymf u_ymf
(
	.clk(clk_sys), .rst(mc_rst || !fam_c), .i_wr(ymf_wr), .i_a(ymf_a), .i_d(ymf_d), .i_rd(ymf_rd), .o_status(ymf_status), .o_irq(ymf_irq),
	.o_addr(ymf_addr), .i_data(oki_data), .i_ok(oki_sd_ok), .o_audio(ymf_audio), .o_stall(ymf_stall)
);
`endif

// family F (Blazing Tornado, Grand Striker 2): Z80 + YM2610 (rtl/metro_sndf.sv); its program rides the 68000's ROM client (metro_mrom_arb port B), its samples the OKI-style client
wire signed [15:0] f_snd_l, f_snd_r;
wire        f_snd_v;
logic [3:0] zdiv = 4'd0;
logic       cen_z80 = 1'b0;
reg         fam_f_r = 1'b0;                                                       // the board is static: a register in front of the resets of the YM2610 board
always @(posedge clk_sys) fam_f_r <= fam_f;
always @(posedge clk_sys) begin zdiv <= (zdiv == 4'd11) ? 4'd0 : zdiv + 4'd1; cen_z80 <= (zdiv == 4'd11); end        // 8 MHz
`ifdef D_BUILD
// the 64 MB family D build (Mahjong Gakuensai): no YM2610 board
assign f_snd_l = ymf_audio;                            // family C: the YMF278B's mono mix (the F audio path below)
assign f_snd_r = ymf_audio;
assign f_snd_v = 1'b0;
assign zr_rd = 1'b0;
assign zr_addr = 19'd0;
assign pa_addr = 22'd0;
assign pb_addr = 21'd0;
assign yp_addr = 23'd0;
`else
metro_sndf u_sndf
(
	.clk(clk_sys), .clk_snd(clk_snd), .rst(mc_rst || !fam_f_r || `DBG_BIT(25)), .cen_z80(cen_z80), .i_stereo(cfg_board == 8'd18), .cmd(snd_cmd), .cmd_wr(snd_cmd_wr),
	.zr_rd(zr_rd), .zr_addr(zr_addr), .zr_valid(snd_rom_valid), .zr_data(mrom_data),
	.pa_addr(pa_addr), .pb_addr(pb_addr), .pa_data(pa_data), .pb_data(pb_data),
	.snd_l(f_snd_l), .snd_r(f_snd_r), .snd_valid(f_snd_v), .dbg_z80_rd(), .dbg_ev()
);
metro_ympcm u_ympcm
(
	.clk(clk_sys), .rst(mc_rst || !fam_f_r || `DBG_BIT(25)), .i_a_addr(pa_addr), .i_b_addr(pb_addr), .i_a_off(23'h200000),
	.o_addr(yp_addr), .i_data(oki_data), .i_ok(oki_sd_ok), .o_a_data(pa_data), .o_b_data(pb_data)
);
`endif
// the OSD's volume steps (Normal / -6 / -12 / +6 dB) on MAME's own level
function automatic signed [15:0] f_vol(input signed [15:0] v, input [1:0] st);
	reg signed [16:0] g;
	begin
		g = (st == 2'd0) ? {v[15], v} : (st == 2'd1) ? {{2{v[15]}}, v[15:1]} : (st == 2'd2) ? {{3{v[15]}}, v[15:2]} : {v, 1'b0};
		f_vol = (g > 17'sd32767) ? 16'sd32767 : (g < -17'sd32768) ? -16'sd32768 : g[15:0];
	end
endfunction
wire signed [15:0] f_audio   = f_vol(f_snd_l, status[9:8]);
wire signed [15:0] f_audio_r = f_vol(f_snd_r, status[9:8]);

wire        ce_pix, hs, vs, de, hblank, vblank;
wire  [4:0] r5, g5, b5;
wire        irq_o, vbl_o, cpu_halted, gfx_overrun;
wire [511:0] hud_st;
wire        hud_frame;
wire [95:0]  sdr_st;

metro_main #(.GFX_AW(GAW)) u_main
(
	.clk(clk_sys), .reset(mc_rst), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .win_mame(status[7]), .flip_force((cfg_board <= 8'd6 || cfg_board == 8'd8 || cfg_board == 8'd9 || cfg_board == 8'd10 || cfg_board == 8'd12 || cfg_board == 8'd13) ? !sw[0][6] : (cfg_board == 8'd7 || cfg_board == 8'd11) ? !sw[2][6] : (cfg_board == 8'd17) ? !sw[0][4] : 1'b0), .pal_latch(1'b1), .i_board(cfg_board),
	.rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_data(rom_data),
	.gfx_req(gfx_req), .gfx_addr(gfx_addr), .gfx_len(gfx_len), .gfx_data(gfx_data), .gfx_valid(gfx_valid), .gfx_size(cfg_gfxsize),
	.in0(d_in0), .in1(d_in1), .dsw0({sw[1], sw[0]}), .dsw1({sw[3], sw[2]}), .in2(fam_f ? f_in2 : in2), .o_roz_ctrl(), .o_sr3_req(sr3_req), .o_sr3_we(sr3_we), .o_sr3_addr(sr3_addr), .o_sr3_wdata(sr3_wdata), .o_sr3_be(sr3_be), .i_sr3_rdata(sr3_rdata), .i_sr3_ack(sr3_ack),
	.i_mj(mj_rows), .i_ee_ld_wr(ee_ld_wr), .i_ee_ld_addr(ee_ld_addr), .i_ee_ld_data(ee_ld_data), .d_ym_wr(d_ym_wr), .d_ym_a0(d_ym_a0), .d_oki_wr(d_oki_wr), .d_data(d_data), .d_oki_status(d_oki_status), .oki_a(oki_addr), .oki_a22(oki_a22), .fam_d_o(fam_d_o),
	.o_es_wr(es_wr), .o_es_rst(es_rst), .o_es_a(es_a), .o_es_d(es_d), .o_es_bank(es_bank), .i_es_irq(es_irq),
	.snd_cmd(snd_cmd), .snd_cmd_wr(snd_cmd_wr), .snd_busy(snd_busy),
	.hs(hs), .vs(vs), .de(de), .hblank(hblank), .vblank(vblank), .ce_pix(ce_pix), .r5(r5), .g5(g5), .b5(b5),
	.irq_o(irq_o), .vbl_o(vbl_o), .cpu_halted(cpu_halted),
	.trc_stb(), .trc_addr(), .trc_rw(), .trc_data(), .trc_be(),
	.gfx_overrun(gfx_overrun),
	.o_hud_st(hud_st), .o_hud_frame(hud_frame), .i_roz_prio(`DBG_BIT(23)), .i_no_hold(`DBG_BIT(24)), .i_vlog_off(`DBG_BIT(26)),
	.o_ymf_wr(ymf_wr), .o_ymf_rd(ymf_rd), .o_ymf_a(ymf_a), .o_ymf_d(ymf_d), .i_ymf_status(ymf_status), .i_ymf_irq(ymf_irq)
);

///////////////////////   AUDIO   ///////////////////////

// family F: the YM2610 delivers 55.5 kHz samples; the framework takes the bus at 48 kHz, and a held 55.5 kHz stream sampled at 48 kHz folds its images back into the audible
// band (a "scratchy" sound).  The average over each 48 kHz period (2000 clocks) of the held stream is a box filter that takes most of that out.
reg  signed [27:0] fb_acc = 28'sd0, fb_acc_r = 28'sd0;
reg         [10:0] fb_n   = 11'd0;
reg  signed [15:0] fb_out = 16'sd0, fb_out_r = 16'sd0;
wire signed [27:0] fb_sum    = fb_acc   + {{12{f_audio[15]}},   f_audio};
wire signed [27:0] fb_sum_r  = fb_acc_r + {{12{f_audio_r[15]}}, f_audio_r};
wire signed [39:0] fb_prod   = fb_sum   * 12'sd524;             // / 2000 = * 524 / 2^20
wire signed [39:0] fb_prod_r = fb_sum_r * 12'sd524;
always @(posedge clk_sys) begin
	if (fb_n == 11'd1999) begin fb_n <= 11'd0; fb_acc <= 28'sd0; fb_acc_r <= 28'sd0; fb_out <= fb_prod[35:20]; fb_out_r <= fb_prod_r[35:20]; end
	else begin fb_n <= fb_n + 11'd1; fb_acc <= fb_sum; fb_acc_r <= fb_sum_r; end
end
// Grand Striker 2: the board's mono sound on both channels; Blazing Tornado: its two outputs
assign AUDIO_L = (fam_f || fam_c) ? fb_out : snd_audio;
assign AUDIO_R = (fam_f || fam_c) ? fb_out_r : snd_audio;

///////////////////////   VIDEO   ///////////////////////

// the 360-pixel boards (8 Pang Pom's, 9 Sky Alert, 10 / 11 Last Fortress, 12 Poitto) are re-timed for a CRT: 14 clocks per dot and 12.8 us of blanking instead of 5.3 (rtl/metro_vout.sv)
wire        vo_ce, vo_hblank, vo_vblank, vo_hs, vo_vs;
wire [14:0] vo_rgb;
wire  [4:0] vo_pdot;
// while the machine is held in reset (the image streaming in, the OSD's Reset) the video chip's raster does not run: a blank one of the same timing keeps the framework's OSD
// (its native "Loading" pop-up) alive (rtl/metro_standby.sv)
wire        sb_ce, sb_hblank, sb_vblank, sb_hs, sb_vs;
metro_standby u_standby (.clk(clk_sys), .o_ce(sb_ce), .o_hblank(sb_hblank), .o_vblank(sb_vblank), .o_hs(sb_hs), .o_vs(sb_vs));
reg         sb_on = 1'b1;
always @(posedge clk_sys) sb_on <= mc_rst;
metro_vout u_vout
(
	.clk(clk_sys), .i_wide(vid_wide), .i_narrow(1'b0), .i_w384(cfg_board == 8'd16),
	.i_ce(sb_on ? sb_ce : ce_pix), .i_hblank(sb_on ? sb_hblank : hblank), .i_vblank(sb_on ? sb_vblank : vblank), .i_hs(sb_on ? sb_hs : hs), .i_vs(sb_on ? sb_vs : vs),
	.i_rgb(sb_on ? 15'd0 : {r5, g5, b5}),
	.o_ce(vo_ce), .o_hblank(vo_hblank), .o_vblank(vo_vblank), .o_hs(vo_hs), .o_vs(vo_vs), .o_rgb(vo_rgb), .o_pdot(vo_pdot)
);

// the hardware test overlay (OSD "Debug overlay"): the plane engine's and the video chip's measurements of the last frame as text on the picture (rtl/metro_hud.sv)
`ifdef METRO_DEBUG
wire [14:0] hd_rgb;
metro_hud u_hud (.clk(clk_sys), .i_mode(`DBG_OVL), .i_ce(vo_ce), .i_hblank(vo_hblank), .i_vblank(vo_vblank), .i_rgb(vo_rgb), .i_frame(hud_frame), .i_st(hud_st), .i_sdr(sdr_st), .o_rgb(hd_rgb));
`else
wire [14:0] hd_rgb = vo_rgb;
`endif

// CRT Adjust (OSD page of the same name): H-Size, H-Position and V-Shift of the picture for every game, through rmonic79's line buffer (rtl/metro_crtadj.sv)
wire [23:0] vo_rgb24 = {hd_rgb[14:10], hd_rgb[14:12], hd_rgb[9:5], hd_rgb[9:7], hd_rgb[4:0], hd_rgb[4:2]};
wire        ca_ce, ca_hblank, ca_vblank, ca_hs, ca_vs, ca_de_osd;
wire [23:0] vid_rgb;
metro_crtadj u_crtadj
(
	.clk(clk_sys), .i_on(status[101]), .i_hsize_f(status[100:96]), .i_hpos_f(status[85:79]), .i_vshift_f(status[78:74]), .i_pdot(vo_pdot),
	.i_ce(vo_ce), .i_hblank(vo_hblank), .i_vblank(vo_vblank), .i_hs(vo_hs), .i_vs(vo_vs), .i_rgb(vo_rgb24),
	.o_ce(ca_ce), .o_hblank(ca_hblank), .o_vblank(ca_vblank), .o_hs(ca_hs), .o_vs(ca_vs), .o_rgb(vid_rgb), .o_de_osd(ca_de_osd)
);
wire        vga_de_mix;

arcade_video #(.WIDTH(384), .DW(24)) arcade_video
(
	.*,
	.clk_video(clk_sys),
	.ce_pix(ca_ce),
	.RGB_in(vid_rgb),
	.HBlank(ca_hblank),
	.VBlank(ca_vblank),
	.HSync(ca_hs),
	.VSync(ca_vs),
	.fx(status[5:3]),
	.VGA_DE(vga_de_mix)
);

// The vertical games (MAME ROT90: Lady Killer, Moeyo Gonta; ROT270: Sky Alert) are rotated through a framebuffer in DDR3 (screen_rotate, from the framework's
// arcade_video.v): the scaler then shows the framebuffer instead of the core's video.  ROT90 = rotate_ccw 0, ROT270 = rotate_ccw 1.
wire no_rotate  = status[2] | direct_video | rot_none;
wire rotate_ccw = (cfg_rot == 2'd3);
wire flip       = 1'b0;
wire video_rotated;
screen_rotate screen_rotate (.*);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(status[101] ? ca_de_osd : vga_de_mix),
	.ARX((ar == 2'd0) ? (no_rotate ? 12'd4 : 12'd3) : {10'd0, ar - 2'd1}),
	.ARY((ar == 2'd0) ? (no_rotate ? 12'd3 : 12'd4) : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(3'd0)
);

///////////////////////   LEDs   ///////////////////////

// user LED: blinks once per frame while the machine runs (stays on during a load), blinks fast on a GFX line-buffer overrun
reg led_vbl_toggle;
always @(posedge clk_sys) begin
	if (vbl_o) led_vbl_toggle <= ~led_vbl_toggle;
end
assign LED_USER = mc_rst ? 1'b1 : (led_vbl_toggle ^ gfx_overrun);

endmodule

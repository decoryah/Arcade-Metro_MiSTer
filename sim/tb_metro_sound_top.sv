// Sound-board bench: metro_sound (uPD78C10 + YM2413 + OKI + glue) with the real memory path -- the MRA image is streamed through metro_loader into
// metro_sdram + a behavioural SDRAM model, the program ROM is read through metro_mrom_arb, the OKI samples through the OKI client -- and the board's mono
// output.  The C++ driver (tb_metro_sound.cpp) plays the sound commands of a recorded game session and writes the audio as a WAV file for comparison with
// MAME's own (tools/audio_cmp.py).
`timescale 1ns/1ps
module tb_metro_sound_top (
    input  logic        clk,
    input  logic        reset,
    input  logic        ioctl_download,
    input  logic        ioctl_wr,
    input  logic [26:0] ioctl_addr,
    input  logic [7:0]  ioctl_dout,
    input  logic        cmd_wr,
    input  logic [7:0]  cmd,
    output logic        sdr_ready,
    output logic        snd_rst,
    output logic        dl_busy_o,
    output logic signed [15:0] audio,
    output logic signed [15:0] dbg_ym,
    output logic signed [15:0] dbg_oki,
    output logic        busy,
    output logic        dbg_illegal
);
    wire [7:0]  cfg_board;
    wire [1:0]  cfg_rot, cfg_scr;
    wire [31:0] cfg_gfxsize;
    wire        ldr_wr, dl_busy;
    wire [24:0] ldr_addr;
    wire [7:0]  ldr_data;
    metro_loader u_ldr (
        .clk(clk), .dl_wr(ioctl_wr && ioctl_download), .dl_addr(ioctl_addr), .dl_data(ioctl_dout),
        .o_wr(ldr_wr), .o_addr(ldr_addr), .o_data(ldr_data),
        .cfg_board(cfg_board), .cfg_rot(cfg_rot), .cfg_scramble(cfg_scr), .cfg_gfxsize(cfg_gfxsize));

    logic rst_r = 1'b1;
    always_ff @(posedge clk) rst_r <= reset | ioctl_download | dl_busy | ~sdr_ready;
    assign snd_rst = rst_r;
    assign dl_busy_o = dl_busy;

    wire        mrom_rd, mrom_valid, snd_rom_rd, snd_rom_valid;
    wire [18:0] mrom_addr, snd_rom_addr;
    wire [15:0] mrom_data;
    wire [17:0] oki_addr;
    wire  [7:0] oki_data;
    wire        oki_ok;

    metro_mrom_arb u_arb (
        .clk(clk), .rst(~sdr_ready),
        .rd_a(1'b0), .addr_a(19'd0), .valid_a(),
        .rd_b(snd_rom_rd), .addr_b(snd_rom_addr), .valid_b(snd_rom_valid),
        .rdata(),
        .rd(mrom_rd), .raddr(mrom_addr), .valid(mrom_valid), .sdata(mrom_data));

    wire [12:0] sd_a;  wire [1:0] sd_ba;  tri [15:0] sd_dq;
    wire sd_dqml, sd_dqmh, sd_ncs, sd_nras, sd_ncas, sd_nwe, sd_cke;
    metro_sdram #(.P_SHORT_INIT(1'b0), .P_RET(3)) u_sdram (
        .clk(clk), .rst_n(~reset), .o_ready(sdr_ready), .i_rd_late(1'b0),
        .i_gfx_req(1'b0), .i_gfx_addr(24'd0), .i_gfx_len(7'd0), .o_gfx_data(), .o_gfx_valid(),
        .i_mrom_rd(mrom_rd), .i_mrom_addr(mrom_addr), .o_mrom_data(mrom_data), .o_mrom_valid(mrom_valid),
        .i_oki_wbase(24'h058000), .i_oki_addr({4'd0, oki_addr}), .o_oki_data(oki_data), .o_oki_ok(oki_ok),
        .i_sr3_req(1'b0), .i_sr3_we(1'b0), .i_sr3_addr(17'd0), .i_sr3_wdata(16'd0), .i_sr3_be(2'd0), .o_sr3_rdata(), .o_sr3_ack(),
        .i_dl_wr(ldr_wr), .i_dl_addr(ldr_addr), .i_dl_data(ldr_data), .o_dl_busy(dl_busy), .i_dl_active(ioctl_download),
        .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_DQ(sd_dq), .SDRAM_DQML(sd_dqml), .SDRAM_DQMH(sd_dqmh),
        .SDRAM_nCS(sd_ncs), .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas), .SDRAM_nWE(sd_nwe), .SDRAM_CKE(sd_cke),
        .dbg_dl_saw(), .dbg_dl_byte0(), .dbg_dl_byte1(), .dbg_dl_count(), .dbg_selftest(), .dbg_postdl(),
        .dbg_dl_written(), .dbg_dl_dropped(), .dbg_fsm_info(), .dbg_sums(), .dbg_sumb1(), .dbg_sumb2());
    sdram_model u_sdram_model (.clk(clk), .A(sd_a), .BA(sd_ba), .DQ(sd_dq), .DQML(sd_dqml), .DQMH(sd_dqmh),
        .nCS(sd_ncs), .nRAS(sd_nras), .nCAS(sd_ncas), .nWE(sd_nwe), .CKE(sd_cke));

    metro_sound u_snd (
        .clk(clk), .rst(rst_r), .i_ym2151(cfg_board >= 8'd3 && cfg_board <= 8'd6), .i_oki_ss(1'b1), .i_direct(1'b0), .d_ym_wr(1'b0), .d_ym_a0(1'b0), .d_oki_wr(1'b0), .d_data(8'd0), .i_oki_hi(1'b0), .i_oki_clk(2'd0), .d_oki_status(), .i_gain((cfg_board >= 8'd3 && cfg_board <= 8'd6) ? 2'd3 : 2'd2), .cmd(cmd), .cmd_wr(cmd_wr), .busy(busy),
        .rom_rd(snd_rom_rd), .rom_addr(snd_rom_addr), .rom_valid(snd_rom_valid), .rom_data(mrom_data),
        .oki_addr(oki_addr), .oki_data(oki_data), .oki_ok(oki_ok),
        .audio(audio), .dbg_ym(dbg_ym), .dbg_oki(dbg_oki), .dbg_illegal(dbg_illegal));
    // debug: every instruction of the first part of the run after the last reset release (T PC), in the model's trace format subset
    logic ill_q = 1'b0, rst_q = 1'b1;
    int inst_n = 0;
    logic dl_seen = 1'b0;
    always_ff @(posedge clk) begin
        rst_q <= rst_r;
        if (ioctl_download) dl_seen <= 1'b1;
        if (rst_r) inst_n <= 0;
        ill_q <= dbg_illegal;
        if (dbg_illegal && !ill_q) $display("ILLEGAL pc=%04h op=%02h op2=%02h", u_snd.u_cpu.r_pc, u_snd.u_cpu.r_op, u_snd.u_cpu.r_op2);
        if (dl_seen && !rst_r && u_snd.u_cpu.trc_stb && inst_n < 400) begin
            inst_n <= inst_n + 1;
            $display("I %0d %04h", u_snd.u_cpu.dbg_t, u_snd.u_cpu.dbg_pc);
        end
    end
endmodule

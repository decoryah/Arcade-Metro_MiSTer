// System bench top for rtl/metro_main.sv (driven by tb_metro_sys.cpp): the Metro board, a stand-in for the sound CPU's busy flag, and a dump
// task that writes the VDP's memories/registers for comparison with MAME (tools/metro_syscmp.py).
//
// Two ways to feed the ROMs:
//   default      behavioural program and GFX ROMs read from flat files (+PROG=<maincpu.bin> +GFX=<gfx.bin>), 2-clock program reads
//   -DSDR        the real memory path: the MRA image (+IMAGE= in the C++ driver, tools/metro_rom.py build --out) is streamed through
//                metro_loader (config capture, GFX descramble) into metro_sdram and a behavioural SDRAM model; the board's program reads and
//                the video chip's GFX stream are served by the arbiter with its real latencies
//   +DUMPPFX=<path prefix>
`default_nettype none
module tb_metro_sys_top (
    input  logic        clk,
    input  logic        reset,
    input  logic        win_mame,
    input  logic        flip_force,
    input  logic        pal_latch,
    input  logic [15:0] in0, in1, dsw0, dsw1, in2,
    input  logic [31:0] gfx_size,              // behavioural-ROM mode only (SDR mode takes it from the image's config block)
    input  logic        ioctl_download,        // SDR mode: the MRA image stream
    input  logic        ioctl_wr,
    input  logic [25:0] ioctl_addr,
    input  logic [7:0]  ioctl_dout,
    input  logic        rd_late,
    input  logic        dump,
    input  logic [31:0] dump_tag,
    output logic        dl_busy,
    output logic        sdr_ready,
    output logic        ce_pix, de, vs,
    output logic [4:0]  r5, g5, b5,
    output logic        vout_wide,
    output logic        vbl_o,
    output logic        irq_o,
    output logic        cpu_halted,
    output logic        gfx_overrun,
    output logic        snd_cmd_wr,
    output logic [7:0]  snd_cmd,
    output logic        trc_stb,
    output logic [23:1] trc_addr,
    output logic        trc_rw,
    output logic [15:0] trc_data,
    output logic [1:0]  trc_be
);
`ifdef F64
    localparam int GFX_AW = 25;
`else
    localparam int GFX_AW = 24;
`endif
    string dpfx;
    initial if (!$value$plusargs("DUMPPFX=%s", dpfx)) dpfx = "dump";

    logic cen_phi1, cen_phi2;

    logic        rom_req, rom_ack;
    logic [20:1] rom_addr;
    logic [7:0]  board_sel;                    // SDR mode: the image's config byte 0; behavioural-ROM mode: Dharma
    metro_cen u_cen (.clk(clk), .fast((board_sel >= 8'd4 && board_sel <= 8'd6) || board_sel == 8'd14 || board_sel == 8'd15 || board_sel == 8'd16 || board_sel == 8'd17 || ($test$plusargs("FASTCPU") && board_sel == 8'd7)), .mid13(board_sel == 8'd20 || board_sel == 8'd21), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2));   // +FASTCPU: 16 MHz instead of 12 on board 7 (an experiment)
    logic [15:0] rom_data;
    logic              gfx_req, gfx_valid;
    logic [GFX_AW:0]   gfx_addr;
    logic [6:0]        gfx_len;
    logic [15:0]       gfx_data;
    logic              snd_busy;
    logic              hs, hblank, vblank;
    logic              ce_pix_m, de_m, vs_m;                  // the chip's own video; the outputs ce_pix / de / vs / r5.. are the re-timed ones with +VOUT (rtl/metro_vout.sv)
    logic [4:0]        r5_m, g5_m, b5_m;
    logic [31:0]       gfx_size_i;
    logic              core_rst;
    wire               ee_ld_wr;                   // the EEPROM's initial contents (Doukyuusei Special), from the loader
    wire        [6:0]  ee_ld_addr;
    wire        [7:0]  ee_ld_data;
    wire [21:0] oki_a22_t;                      // family D: the OKI's ROM address (metro_main) and the sound module's side of it
    wire [17:0] oki_a_t;
    wire  [7:0] oki_data_t, oki_status_t;
    wire        oki_ok_t;
    wire [21:0] oki_sd_addr_t;                  // Varia Metal: the OKI and the ES8712 share the SDRAM's OKI client (metro_okimux), as in Metro.sv
    wire        oki_sd_ok_t;
    wire        es_wr_t, es_rst_t, es_bank_t, es_irq_t, es_ok_t;
    wire  [2:0] es_a_t;
    wire  [7:0] es_d_t, es_data_t;
    wire [20:0] es_addr_t;
    wire signed [15:0] es_audio_t;

`ifdef SDR
    // ---------------------------------------------------------------- real memory path
    wire [7:0]  cfg_board;
    wire [1:0]  cfg_rot, cfg_scr;
    wire [31:0] cfg_gfxsize;
    wire        ldr_wr;
    wire [25:0] ldr_addr;
    wire [7:0]  ldr_data;
    metro_loader u_ldr (
        .clk(clk), .dl_wr(ioctl_wr && ioctl_download), .dl_addr(ioctl_addr[25:0]), .dl_data(ioctl_dout),
        .o_wr(ldr_wr), .o_addr(ldr_addr), .o_data(ldr_data),
        .cfg_board(cfg_board), .cfg_rot(cfg_rot), .cfg_scramble(cfg_scr), .cfg_gfxsize(cfg_gfxsize),
        .ee_wr(ee_ld_wr), .ee_addr(ee_ld_addr), .ee_data(ee_ld_data));
    assign gfx_size_i = cfg_gfxsize;
    assign board_sel  = cfg_board;

    wire        mrom_rd, mrom_valid;
    wire [20:0] mrom_addr;
    wire [15:0] mrom_data;
    wire        sr3_req, sr3_we, sr3_ack;
    wire [16:0] sr3_addr;
    wire [15:0] sr3_wdata, sr3_rdata;
    wire  [1:0] sr3_be;
    wire        sd_mrom_rd, sd_mrom_valid;                      // what metro_sdram sees (the Z80's program reads join the 68000's in family F's bench)
    wire [20:0] sd_mrom_addr;
    wire [22:0] sd_oki_addr;
    // family C (boards 22 .. 24): the YMF278B on the 68000's bus; its wave ROM rides the OKI client
    wire        ymf_wr_t, ymf_rd_t, ymf_irq_t;
    wire  [2:0] ymf_a_t;
    wire  [7:0] ymf_d_t, ymf_st_t;
    wire [21:0] ymf_addr_t;
    wire signed [15:0] ymf_audio_t;
    wire        fam_c_t = (board_sel >= 8'd22 && board_sel <= 8'd26);
`ifndef TB_SOUND_F
    assign sd_oki_addr = fam_c_t ? {1'b0, ymf_addr_t} : {1'b0, oki_sd_addr_t};
`endif
`ifdef TB_SOUND_F
    wire        zr_rd, zr_valid, arb_va;
    wire [20:0] zr_addr;
    wire [15:0] zr_data;
    metro_mrom_arb u_arb_t (
        .clk(clk), .rst(~sdr_ready), .rd_a(mrom_rd), .addr_a(mrom_addr), .valid_a(arb_va), .rd_b(zr_rd), .addr_b(zr_addr), .valid_b(zr_valid), .rdata(),
        .rd(sd_mrom_rd), .raddr(sd_mrom_addr), .valid(sd_mrom_valid), .sdata(mrom_data));
    assign mrom_valid = arb_va;
    assign zr_data = mrom_data;
`else
    assign sd_mrom_rd = mrom_rd; assign sd_mrom_addr = mrom_addr; assign mrom_valid = sd_mrom_valid;
`endif
    metro_romif u_romif (
        .clk(clk), .rst(core_rst), .req(rom_req), .addr(rom_addr), .ack(rom_ack), .data(rom_data),
        .rd(mrom_rd), .raddr(mrom_addr), .valid(mrom_valid), .rdata(mrom_data));

    wire [12:0] sd_a;  wire [1:0] sd_ba;  tri [15:0] sd_dq;
    wire sd_dqml, sd_dqmh, sd_ncs, sd_nras, sd_ncas, sd_nwe, sd_cke;
    metro_sdram #(.P_SHORT_INIT(1'b0), .P_RET(3)) u_sdram (
        .clk(clk), .rst_n(~reset), .o_ready(sdr_ready), .i_rd_late(rd_late),
        .i_gfx_req(gfx_req), .i_gfx_addr(26'(gfx_addr)), .i_gfx_len(gfx_len), .o_gfx_data(gfx_data), .o_gfx_valid(gfx_valid),
        .i_mrom_wbase((cfg_board == 8'd17 || cfg_board == 8'd18 || cfg_board == 8'd19 || cfg_board == 8'd26) ? 25'h080000 + 25'(cfg_gfxsize[25:1]) : 25'h008000), .i_mrom_rd(sd_mrom_rd), .i_mrom_addr(sd_mrom_addr), .o_mrom_data(mrom_data), .o_mrom_valid(sd_mrom_valid),
        .i_oki_wbase((cfg_board == 8'd18 || cfg_board == 8'd19) ? 25'h290000 + 25'(cfg_gfxsize[25:1]) : (cfg_board == 8'd17 || cfg_board == 8'd26) ? 25'h100000 + 25'(cfg_gfxsize[25:1]) : cfg_board >= 8'd14 ? 25'h080000 + 25'(cfg_gfxsize[25:1]) : 25'h058000), .i_oki_addr(sd_oki_addr), .o_oki_data(oki_data_t), .o_oki_ok(oki_sd_ok_t),
        .i_sr3_req(sr3_req), .i_sr3_we(sr3_we), .i_sr3_addr(sr3_addr), .i_sr3_wdata(sr3_wdata), .i_sr3_be(sr3_be), .o_sr3_rdata(sr3_rdata), .o_sr3_ack(sr3_ack),
        .i_dl_wr(ldr_wr), .i_dl_addr(ldr_addr), .i_dl_data(ldr_data), .o_dl_busy(dl_busy), .i_dl_active(ioctl_download),
        .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_DQ(sd_dq), .SDRAM_DQML(sd_dqml), .SDRAM_DQMH(sd_dqmh),
        .SDRAM_nCS(sd_ncs), .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas), .SDRAM_nWE(sd_nwe), .SDRAM_CKE(sd_cke),
        .dbg_dl_saw(), .dbg_dl_byte0(), .dbg_dl_byte1(), .dbg_dl_count(), .dbg_selftest(), .dbg_postdl(),
        .dbg_dl_written(), .dbg_dl_dropped(), .dbg_fsm_info(), .dbg_sums(), .dbg_sumb1(), .dbg_sumb2());
    sdram_model u_sdram_model (.clk(clk), .A(sd_a), .BA(sd_ba), .DQ(sd_dq), .DQML(sd_dqml), .DQMH(sd_dqmh),
        .nCS(sd_ncs), .nRAS(sd_nras), .nCAS(sd_ncas), .nWE(sd_nwe), .CKE(sd_cke));

    assign core_rst = reset | ioctl_download | ~sdr_ready;
`else
    // ---------------------------------------------------------------- behavioural ROMs
    logic [7:0] progb [0:524287];
    logic [7:0] gfxrom [0:(1<<GFX_AW)-1];
    initial begin : load_roms
        string p;
        int fd, n;
        if ($value$plusargs("PROG=%s", p)) begin
            fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
            n = $fread(progb, fd); $fclose(fd);
            $display("tb_metro_sys_top: program %0d bytes", n);
        end
        if ($value$plusargs("GFX=%s", p)) begin
            fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
            n = $fread(gfxrom, fd); $fclose(fd);
            $display("tb_metro_sys_top: gfx rom %0d bytes", n);
        end
    end
    assign gfx_size_i = gfx_size;
    assign board_sel  = 8'd1;
    assign ee_ld_wr = 1'b0; assign ee_ld_addr = 7'd0; assign ee_ld_data = 8'd0;
    assign dl_busy = 1'b0;
    assign sdr_ready = 1'b1;
    assign core_rst = reset;

    // program ROM: the 68000 reads big-endian words, the region dump is in byte order
    always_ff @(posedge clk) begin
        rom_ack  <= rom_req && !rom_ack;
        rom_data <= {progb[{rom_addr, 1'b0}], progb[{rom_addr, 1'b1}]};
    end

    // GFX ROM stream server (pulse req -> latency -> len bytes with a gap), as in tb_metro_vdp_top.sv
    logic [GFX_AW-1:0] srv_addr;
    logic [6:0]        srv_left;
    int                srv_wait;
    logic              srv_active;
    always_ff @(posedge clk) begin
        if (reset) begin
            srv_active <= 1'b0;
            gfx_valid  <= 1'b0;
        end else begin
            gfx_valid <= 1'b0;
            if (!srv_active) begin
                if (gfx_req) begin
                    srv_active <= 1'b1;
                    srv_addr   <= gfx_addr;
                    srv_left   <= gfx_len;
                    srv_wait   <= int'(gfx_addr[1:0]) + 1;
                end
            end else if (srv_wait > 0) begin
                srv_wait <= srv_wait - 1;
            end else if (!srv_addr[0] && !srv_left[0]) begin
                gfx_valid <= 1'b1;
                gfx_data  <= {gfxrom[srv_addr], gfxrom[srv_addr + 1]};
                srv_addr  <= srv_addr + 22'd2;
                if (srv_left == 7'd2) srv_active <= 1'b0;
                else begin
                    srv_left <= srv_left - 7'd2;
                    if (srv_addr[3:0] == 4'd4) srv_wait <= 2;
                end
            end else begin
                gfx_valid <= 1'b1;
                gfx_data  <= {8'd0, gfxrom[srv_addr]};
                srv_addr  <= srv_addr + 1'b1;
                if (srv_left == 7'd1) srv_active <= 1'b0;
                else begin
                    srv_left <= srv_left - 7'd1;
                    if (srv_addr[2:0] == 3'd4) srv_wait <= 2;
                end
            end
        end
    end
`endif

    logic tb_ymw, tb_yma0, tb_okiw;
    logic [7:0] tb_dd;
    int snd_n = 0;
    always_ff @(posedge clk) begin
        if (tb_ymw || tb_okiw) begin
            if ($test$plusargs("SNDLOG") && snd_n < 100000) $display("SNDW %s %02x", tb_ymw ? (tb_yma0 ? "YMD" : "YMA") : "OKI", tb_dd);
            snd_n <= snd_n + 1;
        end
    end

`ifdef TB_SOUND_F
    // family F: the Z80 + YM2610 board (+AUDFILE as below)
    wire [21:0] pa_addr;
    wire [20:0] pb_addr;
    wire  [7:0] pa_data, pb_data;
    wire [22:0] yp_addr;
    logic       clk_snd = 1'b0;
    always_ff @(posedge clk) clk_snd <= ~clk_snd;
    logic [3:0] zdiv = 4'd0;
    logic       cen_z80 = 1'b0;
    always_ff @(posedge clk) begin zdiv <= (zdiv == 4'd11) ? 4'd0 : zdiv + 4'd1; cen_z80 <= (zdiv == 4'd11); end
    wire signed [15:0] snd_l_f, snd_r_f;
    wire        snd_v_f;
    metro_sndf u_sndf_t (
        .clk(clk), .clk_snd(clk_snd), .rst(core_rst || !(board_sel == 8'd18 || board_sel == 8'd19)), .cen_z80(cen_z80),
        .cmd(snd_cmd), .cmd_wr(snd_cmd_wr),
        .zr_rd(zr_rd), .zr_addr(zr_addr), .zr_valid(zr_valid && 1'b1), .zr_data(zr_data),
        .pa_addr(pa_addr), .pb_addr(pb_addr), .pa_data(pa_data), .pb_data(pb_data),
        .snd_l(snd_l_f), .snd_r(snd_r_f), .snd_valid(snd_v_f), .dbg_z80_rd(), .dbg_ev());
    metro_ympcm u_ympcm_t (
        .clk(clk), .rst(core_rst), .i_a_addr(pa_addr), .i_b_addr(pb_addr), .i_a_off(23'h200000),
        .o_addr(yp_addr), .i_data(oki_data_t), .i_ok(oki_sd_ok_t), .o_a_data(pa_data), .o_b_data(pb_data));
    assign sd_oki_addr = (board_sel == 8'd18 || board_sel == 8'd19) ? yp_addr : {1'b0, oki_sd_addr_t};
    wire signed [15:0] snd_audio_t = snd_l_f;
    int aud_div = 0;
    int aud_fd = 0;
    string aud_name;
    initial begin
        if (!$value$plusargs("AUDFILE=%s", aud_name)) aud_name = "audio_dump.txt";
        aud_fd = $fopen(aud_name, "w");
    end
    always_ff @(posedge clk) begin
        aud_div <= (aud_div == 1999) ? 0 : aud_div + 1;
        if (aud_div == 0 && !core_rst) $fdisplay(aud_fd, "%0d", snd_audio_t);
    end
`elsif TB_SOUND
    // the real sound module in family D's direct mode (+AUDFILE=<file>: one sample per line at 48 kHz, +SNDLOG on)
    logic signed [15:0] snd_audio_t;
    metro_sound u_snd_t (
        .clk(clk), .rst(core_rst), .i_ym2151(1'b0), .i_oki_ss(1'b1), .i_direct(1'b1), .d_ym_wr(tb_ymw), .d_ym_a0(tb_yma0), .d_oki_wr(tb_okiw), .d_data(tb_dd),
        .i_oki_hi(1'b1), .i_ym_hi(board_sel == 8'd20 || board_sel == 8'd21), .i_oki_clk(board_sel == 8'd17 ? 3'd4 : board_sel == 8'd14 ? 3'd1 : (board_sel == 8'd16 || board_sel == 8'd20 || board_sel == 8'd21) ? 3'd3 : 3'd2), .i_aux(es_audio_t), .i_loud(board_sel == 8'd17), .i_oki_vm(board_sel == 8'd17), .d_oki_status(oki_status_t), .i_gain(2'd2), .cmd(8'd0), .cmd_wr(1'b0), .busy(),
        .rom_rd(), .rom_addr(), .rom_valid(1'b0), .rom_data(16'd0), .oki_addr(oki_a_t), .oki_data(oki_data_t), .oki_ok(oki_ok_t),
        .audio(snd_audio_t), .dbg_ym(), .dbg_oki(), .dbg_illegal());
    int aud_div = 0;
    int aud_fd = 0;
    string aud_name;
    initial begin
        if (!$value$plusargs("AUDFILE=%s", aud_name)) aud_name = "audio_dump.txt";
        aud_fd = $fopen(aud_name, "w");
    end
    always_ff @(posedge clk) begin
        aud_div <= (aud_div == 1999) ? 0 : aud_div + 1;
        if (aud_div == 0 && !core_rst) $fdisplay(aud_fd, "%0d", snd_audio_t);
    end
`else
    assign oki_status_t = 8'd0;
    assign oki_a_t = 18'd0;
`endif

    // +YMFROM=<file>: the wave ROM from a file, instantly (separates the engine from the SDRAM path)
    reg  [7:0] ymf_rom [0:2621439];
    int        ymf_ideal = 0;
    initial begin
        string yr;
        int fdr;
        if ($value$plusargs("YMFROM=%s", yr)) begin
            fdr = $fopen(yr, "rb");
            if (fdr != 0) begin
                void'($fread(ymf_rom, fdr));
                $fclose(fdr);
                ymf_ideal = 1;
            end
        end
        // +YMFCHK=<file>: the wave ROM as the reference only: every byte the engine samples from the SDRAM path is compared with it
        if ($value$plusargs("YMFCHK=%s", yr)) begin
            fdr = $fopen(yr, "rb");
            if (fdr != 0) begin
                void'($fread(ymf_rom, fdr));
                $fclose(fdr);
                ymf_ideal = 2;
            end
        end
    end
    wire       ymf_stall_t;
    longint    ymf_clks = 0;
    wire [7:0] ymf_i_data = (ymf_ideal == 1) ? ((ymf_addr_t < 22'h280000) ? ymf_rom[ymf_addr_t] : 8'h00) : oki_data_t;
    wire       ymf_i_ok   = (ymf_ideal == 1) ? 1'b1 : oki_sd_ok_t;
    int        ymf_bad = 0, ymf_good = 0;
    always_ff @(posedge clk) begin
        // the byte the engine takes: its enable runs while it samples (cap_next with a read asserted)
        if (ymf_ideal == 2 && fam_c_t && u_ymf_t.ce && u_ymf_t.cap_next && !u_ymf_t.mrd_n && u_ymf_t.ma < 22'h280000) begin
            if (u_ymf_t.mdi !== ymf_rom[u_ymf_t.ma]) begin
                ymf_bad <= ymf_bad + 1;
                if (ymf_bad < 40) $display("YMFBAD ma=%06x got %02x want %02x ok=%0d t=%0d", u_ymf_t.ma, u_ymf_t.mdi, ymf_rom[u_ymf_t.ma], ymf_i_ok, ymf_clks);
            end else ymf_good <= ymf_good + 1;
        end
        if (ymf_ideal == 2 && fam_c_t && ymf_clks[23:0] == 24'hFFFFFF) $display("YMFCHK good=%0d bad=%0d", ymf_good, ymf_bad);
    end
    metro_ymf u_ymf_t (.clk(clk), .rst(core_rst || !fam_c_t), .i_wr(ymf_wr_t), .i_a(ymf_a_t), .i_d(ymf_d_t), .i_rd(ymf_rd_t), .o_status(ymf_st_t), .o_irq(ymf_irq_t),
        .o_addr(ymf_addr_t), .i_data(ymf_i_data), .i_ok(ymf_i_ok), .o_audio(ymf_audio_t), .o_stall(ymf_stall_t));
    int ymf_stall_cnt = 0;
    always_ff @(posedge clk) begin
        if (ymf_stall_t) ymf_stall_cnt <= ymf_stall_cnt + 1;
    end
    int ymf_div = 0;
    int ymf_fd = 0;
    int ymf_lfd = 0;
    initial begin
        string yn;
        if ($value$plusargs("YMFAUD=%s", yn)) ymf_fd = $fopen(yn, "w");
        if ($value$plusargs("YMFLOG=%s", yn)) ymf_lfd = $fopen(yn, "w");
    end
    // the 68000's writes to the chip (machine clocks since the start of the run, port, data)
    always_ff @(posedge clk) begin
        ymf_clks <= ymf_clks + 1;
        if (fam_c_t && ymf_clks[23:0] == 24'hFFFFFF) $display("YMFSTALL clk=%0d stalled=%0d", ymf_clks, ymf_stall_cnt);
        if (ymf_lfd != 0 && ymf_wr_t && fam_c_t) $fdisplay(ymf_lfd, "%0d %0d %02x", ymf_clks, ymf_a_t, ymf_d_t);
    end
    always_ff @(posedge clk) begin
        ymf_div <= (ymf_div == 1999) ? 0 : ymf_div + 1;
        if (ymf_fd != 0 && ymf_div == 0 && !core_rst && fam_c_t) $fdisplay(ymf_fd, "%0d", ymf_audio_t);
    end
    metro_okimux u_okimux_t (.clk(clk), .rst(core_rst), .i_en(board_sel == 8'd17), .i_oki_addr(oki_a22_t), .i_es_addr(es_addr_t), .i_es_off(22'h080000),
        .o_addr(oki_sd_addr_t), .i_data(oki_data_t), .i_ok(oki_sd_ok_t), .o_oki_ok(oki_ok_t), .o_es_data(es_data_t), .o_es_ok(es_ok_t));
    metro_es8712 u_es_t (.clk(clk), .rst(core_rst || board_sel != 8'd17), .i_wr(es_wr_t), .i_a(es_a_t), .i_d(es_d_t), .i_reset_w(es_rst_t), .i_bank(es_bank_t), .o_irq(es_irq_t),
        .o_addr(es_addr_t), .i_data(es_data_t), .i_ok(es_ok_t), .o_audio(es_audio_t));
    always_ff @(posedge clk) if ($test$plusargs("SNDLOG")) begin
        if (es_wr_t)  $display("SNDW ES%0d %02x", es_a_t, es_d_t);
        if (es_rst_t) $display("SNDW ESRESET");
    end

    // family D's input layouts: the C++ side presses Dharma's coin (IN0 bit 2) and start (bit 4); here they become the I4300 boards' own bits
    wire coin_p = !in0[2], start_p = !in0[4];
    wire [15:0] in0_x = (board_sel == 8'd18 || board_sel == 8'd19) ? 16'hFFFF : (board_sel == 8'd17) ? {15'h7FFF, ~coin_p} : (board_sel == 8'd14 || board_sel == 8'd16) ? {12'hFFF, 1'b1, 1'b1, ~coin_p, 1'b1} : (board_sel == 8'd15) ? 16'hFFFF : in0;
    wire [15:0] in2_x = (board_sel == 8'd17) ? {8'h00, dsw1[7:0]} : (board_sel == 8'd18 || board_sel == 8'd19) ? ~{11'd0, start_p, 1'b0, coin_p, 2'b00} : in2;                  // Varia Metal: IN2 = its second DIP bank (the MRA's byte 2)
    wire [15:0] in1_x = (board_sel == 8'd17) ? {~start_p, 15'h7FFF} : (board_sel == 8'd15) ? ~{8'h00, 1'b0, 1'b0, 1'b0, coin_p, 1'b0, start_p, 2'b00} : in1;
    wire [23:0] mj_x  = {18'h3FFFF, ~start_p, 5'h1F};

    logic [15:0] roz_ctrl_t [16];
    // ---------------------------------------------------------------- the board
    // the hardware test overlay's measurements of every frame (family F)
    wire [511:0] hud_st_t;
    wire         hud_fr_t;
    logic        hud_fr_d = 1'b0;
    int          hud_n = 0;
    always_ff @(posedge clk) begin
        hud_fr_d <= hud_fr_t;
        if (hud_fr_d && $test$plusargs("HUDST")) begin
            hud_n <= hud_n + 1;
            $display("HUDST %0d S: stale=%0d first=%0d last=%0d ovr=%0d | bmax=%0d bsum64=%0d kwait64=%0d kfmax=%0d | rows_done=%0d vf_vv=%04x | grr64=%0d grz64=%0d grc64=%0d spr=%0d lines=%0d per32=%0d", hud_n,
                hud_st_t[15:0], hud_st_t[31:16], hud_st_t[47:32], hud_st_t[63:48], hud_st_t[79:64], hud_st_t[95:80], hud_st_t[111:96], hud_st_t[127:112], hud_st_t[143:128], hud_st_t[159:144], hud_st_t[175:160], hud_st_t[191:176], hud_st_t[207:192], hud_st_t[223:208], hud_st_t[239:224], hud_st_t[255:240]);
            $display("HUDST %0d R: win=%0d line=%0d rlines_max=%0d wclk_max=%0d wsum64=%0d pwait64=%0d winwait64=%0d allocwait64=%0d latmax=%0d latsum64=%0d lw2_0=%04x lw3_0=%04x lw2_m=%04x lw3_m=%04x lw2_e=%04x lw3_e=%04x", hud_n,
                hud_st_t[256+15:256], hud_st_t[256+31:256+16], hud_st_t[256+47:256+32], hud_st_t[256+63:256+48], hud_st_t[256+79:256+64], hud_st_t[256+95:256+80], hud_st_t[256+111:256+96], hud_st_t[256+127:256+112], hud_st_t[256+143:256+128], hud_st_t[256+159:256+144], hud_st_t[256+175:256+160], hud_st_t[256+191:256+176], hud_st_t[256+207:256+192], hud_st_t[256+223:256+208], hud_st_t[256+239:256+224], hud_st_t[256+255:256+240]);
            $display("HUDST %0d D: sdram per 21.8ms: busy64=%0d gfx=%0d oki=%0d sr3=%0d mrom=%0d dl=%0d", hud_n, u_sdram.m_st[95:80], u_sdram.m_st[79:64], u_sdram.m_st[63:48], u_sdram.m_st[47:32], u_sdram.m_st[31:16], u_sdram.m_st[15:0]);
        end
    end
    metro_main #(.GFX_AW(GFX_AW)) dut (
        .clk(clk), .reset(core_rst), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .win_mame(win_mame), .flip_force(flip_force), .pal_latch(pal_latch), .i_board(board_sel),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_data(rom_data),
        .gfx_req(gfx_req), .gfx_addr(gfx_addr), .gfx_len(gfx_len), .gfx_data(gfx_data), .gfx_valid(gfx_valid), .gfx_size(gfx_size_i),
        .in0(in0_x), .in1(in1_x), .dsw0(dsw0), .dsw1(dsw1), .in2(in2_x), .o_roz_ctrl(roz_ctrl_t), .o_sr3_req(sr3_req), .o_sr3_we(sr3_we), .o_sr3_addr(sr3_addr), .o_sr3_wdata(sr3_wdata), .o_sr3_be(sr3_be), .i_sr3_rdata(sr3_rdata), .i_sr3_ack(sr3_ack),
        .i_mj(mj_x), .i_ee_ld_wr(ee_ld_wr), .i_ee_ld_addr(ee_ld_addr), .i_ee_ld_data(ee_ld_data), .d_ym_wr(tb_ymw), .d_ym_a0(tb_yma0), .d_oki_wr(tb_okiw), .d_data(tb_dd), .d_oki_status(oki_status_t), .oki_a(oki_a_t), .oki_a22(oki_a22_t), .fam_d_o(),
        .o_es_wr(es_wr_t), .o_es_rst(es_rst_t), .o_es_a(es_a_t), .o_es_d(es_d_t), .o_es_bank(es_bank_t), .i_es_irq(es_irq_t),
        .snd_cmd(snd_cmd), .snd_cmd_wr(snd_cmd_wr), .snd_busy(snd_busy),
        .hs(hs), .vs(vs_m), .de(de_m), .hblank(hblank), .vblank(vblank), .ce_pix(ce_pix_m), .r5(r5_m), .g5(g5_m), .b5(b5_m),
        .irq_o(irq_o), .vbl_o(vbl_o), .cpu_halted(cpu_halted),
        .trc_stb(trc_stb), .trc_addr(trc_addr), .trc_rw(trc_rw), .trc_data(trc_data), .trc_be(trc_be),
        .gfx_overrun(gfx_overrun), .o_hud_st(hud_st_t), .o_hud_frame(hud_fr_t), .i_roz_prio(1'b0), .i_no_hold(1'b0), .i_vlog_off(1'b0),
        .o_ymf_wr(ymf_wr_t), .o_ymf_rd(ymf_rd_t), .o_ymf_a(ymf_a_t), .o_ymf_d(ymf_d_t), .i_ymf_status(ymf_st_t), .i_ymf_irq(ymf_irq_t)
    );

    // the video re-timing of the 360-pixel boards (Metro.sv has the same instance); +VOUT puts it into the outputs the C++ side records
    logic              vout_en;
    initial vout_en = $test$plusargs("VOUT");
    wire               vr_ce, vr_hblank, vr_vblank, vr_hs, vr_vs;          // the re-timer's output
    wire        [14:0] vr_rgb;
    wire         [4:0] vr_pdot;
    wire               vo_ce, vo_hblank, vo_vblank, vo_hs, vo_vs;           // the final stream (after CRT Adjust, which passes it untouched unless +CRTON=1)
    wire        [14:0] vo_rgb;
    assign vout_wide = (board_sel >= 8'd8 && board_sel <= 8'd12) || board_sel == 8'd16;
    metro_vout u_vout (
        .clk(clk), .i_wide(vout_wide), .i_narrow($test$plusargs("VNARROW")), .i_w384(board_sel == 8'd16), .i_ce(ce_pix_m), .i_hblank(hblank), .i_vblank(vblank), .i_hs(hs), .i_vs(vs_m), .i_rgb({r5_m, g5_m, b5_m}),
        .o_ce(vr_ce), .o_hblank(vr_hblank), .o_vblank(vr_vblank), .o_hs(vr_hs), .o_vs(vr_vs), .o_rgb(vr_rgb), .o_pdot(vr_pdot));
    // CRT Adjust as in Metro.sv: +CRTON=1 +CRTH=<-16..15> +CRTP=<0..96, 49.. = negative> +CRTV=<-16..15>
    int crt_on = 0, crt_h = 0, crt_p = 0, crt_v = 0;
    initial begin
        if (!$value$plusargs("CRTON=%d", crt_on)) crt_on = 0;
        if (!$value$plusargs("CRTH=%d", crt_h)) crt_h = 0;
        if (!$value$plusargs("CRTP=%d", crt_p)) crt_p = 0;
        if (!$value$plusargs("CRTV=%d", crt_v)) crt_v = 0;
    end
    wire [23:0] vr_rgb24 = {vr_rgb[14:10], vr_rgb[14:12], vr_rgb[9:5], vr_rgb[9:7], vr_rgb[4:0], vr_rgb[4:2]};
    wire [23:0] ca_rgb24;
    metro_crtadj u_crtadj (
        .clk(clk), .i_on(crt_on != 0), .i_hsize_f(5'(crt_h)), .i_hpos_f(7'(crt_p)), .i_vshift_f(5'(crt_v)), .i_pdot(vr_pdot),
        .i_ce(vr_ce), .i_hblank(vr_hblank), .i_vblank(vr_vblank), .i_hs(vr_hs), .i_vs(vr_vs), .i_rgb(vr_rgb24),
        .o_ce(vo_ce), .o_hblank(vo_hblank), .o_vblank(vo_vblank), .o_hs(vo_hs), .o_vs(vo_vs), .o_rgb(ca_rgb24), .o_de_osd());
    assign vo_rgb = {ca_rgb24[23:19], ca_rgb24[15:11], ca_rgb24[7:3]};
    assign ce_pix = vout_en ? vo_ce : ce_pix_m;
    assign vs     = vout_en ? vo_vs : vs_m;
    assign de     = vout_en ? (!vo_hblank && !vo_vblank) : de_m;
    assign {r5, g5, b5} = vout_en ? vo_rgb : {r5_m, g5_m, b5_m};

    // timing of the re-timed stream, in clocks of the machine clock; printed at the end of the run (+VOUT)
    logic vt_hs_q, vt_vs_q;
    int   vt_t = 0, vt_hs_rise = -1, vt_hs_fall = -1, vt_lines = 0, vt_vs_lines = 0, vt_frame_lines = 0, vt_dots = 0, vt_first_dot = -1, vt_last_dot = -1;
    int   vt_line_min = 1 << 30, vt_line_max = 0, vt_hsw_min = 1 << 30, vt_hsw_max = 0, vt_dots_min = 1 << 30, vt_dots_max = 0, vt_vsl_min = 1 << 30, vt_vsl_max = 0;
    int   vt_fl_bad = 0, vt_fl_n = 0, vt_fl_bad_last = -1;
    int   vt_fl_min = 1 << 30, vt_fl_max = 0, vt_bp_min = 1 << 30, vt_bp_max = 0, vt_fp_min = 1 << 30, vt_fp_max = 0, vt_ce_gap_min = 1 << 30, vt_ce_gap_max = 0, vt_ce_last = -1;
    int vt_since_rst = 0;
    wire vt_ok = vt_since_rst > 6000000;
    always_ff @(posedge clk) if (vout_en) begin
        vt_since_rst <= core_rst ? 0 : vt_since_rst + 1;
        vt_t    <= vt_t + 1;
        vt_hs_q <= vo_hs;
        vt_vs_q <= vo_vs;
        if (vo_ce) begin
            if (vt_ce_last >= 0 && vt_ok) begin
                if (vt_t - vt_ce_last < vt_ce_gap_min) vt_ce_gap_min <= vt_t - vt_ce_last;
                if (vt_t - vt_ce_last > vt_ce_gap_max) vt_ce_gap_max <= vt_t - vt_ce_last;
            end
            vt_ce_last <= vt_t;
            if (!vo_hblank && !vo_vblank) begin
                vt_dots <= vt_dots + 1;
                if (vt_first_dot < 0) vt_first_dot <= vt_t;
                vt_last_dot <= vt_t;
            end
        end
        if (vo_hs && !vt_hs_q) begin
            vt_lines <= vt_lines + 1;
            if (vt_hs_rise >= 0 && vt_ok) begin
                if (vt_t - vt_hs_rise < vt_line_min) vt_line_min <= vt_t - vt_hs_rise;
                if (vt_t - vt_hs_rise > vt_line_max) vt_line_max <= vt_t - vt_hs_rise;
                if (vt_dots != 0) begin
                    if (vt_dots < vt_dots_min) vt_dots_min <= vt_dots;
                    if (vt_dots > vt_dots_max) vt_dots_max <= vt_dots;
                    // front porch: last dot to this sync rise; back porch: previous sync fall to the first dot (clocks)
                    if (vt_t - vt_last_dot < vt_fp_min) vt_fp_min <= vt_t - vt_last_dot;
                    if (vt_t - vt_last_dot > vt_fp_max) vt_fp_max <= vt_t - vt_last_dot;
                    if (vt_hs_fall >= 0) begin
                        if (vt_first_dot - vt_hs_fall < vt_bp_min) vt_bp_min <= vt_first_dot - vt_hs_fall;
                        if (vt_first_dot - vt_hs_fall > vt_bp_max) vt_bp_max <= vt_first_dot - vt_hs_fall;
                    end
                end
            end
            vt_dots <= 0; vt_first_dot <= -1;
            vt_hs_rise <= vt_t;
            vt_frame_lines <= vt_frame_lines + 1;
            if (vo_vs) vt_vs_lines <= vt_vs_lines + 1;
        end
        if (!vo_hs && vt_hs_q) begin
            vt_hs_fall <= vt_t;
            if (vt_ok) begin
                if (vt_t - vt_hs_rise < vt_hsw_min) vt_hsw_min <= vt_t - vt_hs_rise;
                if (vt_t - vt_hs_rise > vt_hsw_max) vt_hsw_max <= vt_t - vt_hs_rise;
            end
        end
        if (vo_vs && !vt_vs_q) begin
            if (vt_ok) begin
                vt_fl_n <= vt_fl_n + 1;
                if (vt_frame_lines != 263) begin vt_fl_bad <= vt_fl_bad + 1; vt_fl_bad_last <= vt_fl_n; if (vt_fl_bad < 8) $display("VOUT frame %0d has %0d lines", vt_fl_n, vt_frame_lines); end
                if (vt_frame_lines < vt_fl_min) vt_fl_min <= vt_frame_lines;
                if (vt_frame_lines > vt_fl_max) vt_fl_max <= vt_frame_lines;
            end
            vt_frame_lines <= (vo_hs && !vt_hs_q) ? 1 : 0; vt_vs_lines <= 0;      // (CRT Adjust moves the vertical sync onto the horizontal sync's edge: that line is the first of the new frame)
        end
        if (!vo_vs && vt_vs_q && vt_ok) begin
            if (vt_vs_lines < vt_vsl_min) vt_vsl_min <= vt_vs_lines;
            if (vt_vs_lines > vt_vsl_max) vt_vsl_max <= vt_vs_lines;
        end
    end
    final if (vout_en)
        $display("VOUT timing (clocks / lines): line %0d..%0d, hsync width %0d..%0d, dots per picture line %0d..%0d, front porch (last dot to hsync) %0d..%0d, back porch (hsync end to first dot) %0d..%0d, dot spacing %0d..%0d, lines per frame %0d..%0d (%0d of %0d frames not 263, the last one frame %0d), vsync lines %0d..%0d, wide=%0d",
                 vt_line_min, vt_line_max, vt_hsw_min, vt_hsw_max, vt_dots_min, vt_dots_max, vt_fp_min, vt_fp_max, vt_bp_min, vt_bp_max, vt_ce_gap_min, vt_ce_gap_max, vt_fl_min, vt_fl_max, vt_fl_bad, vt_fl_n, vt_fl_bad_last, vt_vsl_min, vt_vsl_max, vout_wide);

    // statistics: clocks the CPU's program-ROM read waits for rom_ack (one 68000 bus cycle is 32 clocks; every clock beyond what the bus cycle
    // needs anyway is a wait state the real board does not have). Printed at the end of the run.
    int rl_cur = 0, rl_max = 0;
    longint rl_n = 0, rl_sum = 0;
    int rl_hist [0:7];
    logic rl_done = 1'b0;
    initial for (int i = 0; i < 8; i++) rl_hist[i] = 0;
    always_ff @(posedge clk) begin
        if (!rom_req) begin rl_cur <= 0; rl_done <= 1'b0; end
        else if (!rom_ack) rl_cur <= rl_cur + 1;
        else if (!rl_done) begin
            rl_done <= 1'b1; rl_n <= rl_n + 1; rl_sum <= rl_sum + longint'(rl_cur);
            if (rl_cur > rl_max) rl_max <= rl_cur;
            rl_hist[rl_cur <= 8 ? 0 : rl_cur <= 12 ? 1 : rl_cur <= 16 ? 2 : rl_cur <= 20 ? 3 : rl_cur <= 24 ? 4 : rl_cur <= 32 ? 5 : rl_cur <= 64 ? 6 : 7]
                <= rl_hist[rl_cur <= 8 ? 0 : rl_cur <= 12 ? 1 : rl_cur <= 16 ? 2 : rl_cur <= 20 ? 3 : rl_cur <= 24 ? 4 : rl_cur <= 32 ? 5 : rl_cur <= 64 ? 6 : 7] + 1;
        end
    end
    final $display("ROM reads: %0d, mean wait %0d.%02d clocks, max %0d; histogram (<=8 <=12 <=16 <=20 <=24 <=32 <=64 more): %0d %0d %0d %0d %0d %0d %0d %0d",
        rl_n, rl_n == 0 ? 0 : int'(rl_sum / rl_n), rl_n == 0 ? 0 : int'((rl_sum * 100 / rl_n) % 100), rl_max,
        rl_hist[0], rl_hist[1], rl_hist[2], rl_hist[3], rl_hist[4], rl_hist[5], rl_hist[6], rl_hist[7]);

    // statistics: length of the CPU's bus cycles, clocks with AS low (a 68000 cycle without wait states: about 28; each wait state adds 8 clocks)
    int as_len = 0;
    longint as_hist [0:5];
    initial for (int i = 0; i < 6; i++) as_hist[i] = 0;
    always_ff @(posedge clk) begin
        if (!dut.ASn) as_len <= as_len + 1;
        else if (as_len != 0) begin
            as_hist[as_len <= 28 ? 0 : as_len <= 32 ? 1 : as_len <= 36 ? 2 : as_len <= 44 ? 3 : as_len <= 64 ? 4 : 5]
                <= as_hist[as_len <= 28 ? 0 : as_len <= 32 ? 1 : as_len <= 36 ? 2 : as_len <= 44 ? 3 : as_len <= 64 ? 4 : 5] + 1;
            as_len <= 0;
        end
    end
    // period between consecutive AS falls (a back-to-back 68000 cycle is 32 clocks), split by what the cycle that just ended addressed
    int per_len = 0;
    longint per_hist [0:2][0:5];       // [0] rom [1] ram/io [2] vdp; buckets <=32 <=40 <=48 <=64 <=128 more
    logic [1:0] per_kind = 2'd0;
    logic as_q2 = 1'b1;
    initial for (int k = 0; k < 3; k++) for (int i = 0; i < 6; i++) per_hist[k][i] = 0;
    always_ff @(posedge clk) begin
        as_q2 <= dut.ASn;
        per_len <= per_len + 1;
        if (as_q2 && !dut.ASn) begin
            if (per_len < 100000)
                per_hist[per_kind][per_len <= 32 ? 0 : per_len <= 40 ? 1 : per_len <= 48 ? 2 : per_len <= 64 ? 3 : per_len <= 128 ? 4 : 5]
                    <= per_hist[per_kind][per_len <= 32 ? 0 : per_len <= 40 ? 1 : per_len <= 48 ? 2 : per_len <= 64 ? 3 : per_len <= 128 ? 4 : 5] + 1;
            per_len <= 1;
            per_kind <= dut.sel_rom ? 2'd0 : dut.sel_vdp ? 2'd2 : 2'd1;
        end
    end
    final begin
        $display("AS-fall periods after a ROM cycle   (<=32 <=40 <=48 <=64 <=128 more): %0d %0d %0d %0d %0d %0d", per_hist[0][0], per_hist[0][1], per_hist[0][2], per_hist[0][3], per_hist[0][4], per_hist[0][5]);
        $display("AS-fall periods after a RAM/IO cycle (<=32 <=40 <=48 <=64 <=128 more): %0d %0d %0d %0d %0d %0d", per_hist[1][0], per_hist[1][1], per_hist[1][2], per_hist[1][3], per_hist[1][4], per_hist[1][5]);
        $display("AS-fall periods after a VDP cycle   (<=32 <=40 <=48 <=64 <=128 more): %0d %0d %0d %0d %0d %0d", per_hist[2][0], per_hist[2][1], per_hist[2][2], per_hist[2][3], per_hist[2][4], per_hist[2][5]);
    end

    // per-frame bus cycle counts, printed at each vblank (+FRAMESTAT)
    int as_frame = 0, as_frame_n = 0;
    longint clk_n = 0;
    logic as_q = 1'b1, vbl_q = 1'b0;
    always_ff @(posedge clk) begin
        clk_n <= clk_n + 1;
        as_q <= dut.ASn; vbl_q <= vbl_o;
        if (as_q && !dut.ASn) as_frame <= as_frame + 1;
        if (vbl_o && !vbl_q) begin
            $display("FS vblank %0d at clk %0d: %0d bus cycles, rst=%0d", as_frame_n, clk_n, as_frame, core_rst);
            as_frame_n <= as_frame_n + 1; as_frame <= 0;
        end
    end
    // +BLIT0=<frame> +BLIT1=<frame>: every blit (start line, clocks until the blitter is idle again, whether it ended on its STOP opcode)
    int bt0 = -1, bt1 = -1;
    initial begin if (!$value$plusargs("BLIT0=%d", bt0)) bt0 = -1; if (!$value$plusargs("BLIT1=%d", bt1)) bt1 = -1; end
    longint bt_clk = 0; int bt_line = 0; logic bt_run = 1'b0;
    always_ff @(posedge clk) if (bt0 >= 0) begin
        if (dut.u_vdp.bl_start && as_frame_n >= bt0 && as_frame_n <= bt1) begin bt_clk <= clk_n; bt_line <= int'(dut.u_vdp.vcnt); bt_run <= 1'b1; end
        if (bt_run && !dut.u_vdp.bl_busy && !dut.u_vdp.bl_start) begin
            $display("BLIT f%0d start line %0d, %0d clocks (%0d lines), done pulse %0d", as_frame_n, bt_line, clk_n - bt_clk, (clk_n - bt_clk) / 6272, dut.u_vdp.blit_done);
            bt_run <= 1'b0;
        end
    end
    // +KICK0=<frame> +KICK1=<frame>: for the lines kicked to the renderer (rows 0..95) the six scroll words each line renders with (sy2 sx2 sy1 sx1 sy0 sx0, window folded in)
    int kk0 = -1, kk1 = -1;
    initial begin if (!$value$plusargs("KICK0=%d", kk0)) kk0 = -1; if (!$value$plusargs("KICK1=%d", kk1)) kk1 = -1; end
    always_ff @(posedge clk) if (kk0 >= 0 && dut.u_vdp.rnd_start && as_frame_n >= kk0 && as_frame_n <= kk1 && dut.u_vdp.rnd_row < 8'd96)
        $display("KICK f%0d row %0d vcnt %0d : sy2 %04x sx2 %04x sy1 %04x sx1 %04x sy0 %04x sx0 %04x", as_frame_n, dut.u_vdp.rnd_row, dut.u_vdp.vcnt,
                 dut.u_vdp.pop_word[80 +: 16], dut.u_vdp.pop_word[64 +: 16], dut.u_vdp.pop_word[48 +: 16], dut.u_vdp.pop_word[32 +: 16], dut.u_vdp.pop_word[16 +: 16], dut.u_vdp.pop_word[0 +: 16]);
    // +LH0=<frame> +LH1=<frame>: per frame (vblank to vblank) the beam lines (vcnt) of the 68000's writes to the VDP: tile RAM, palette, sprite RAM, scroll (0x78870..), window (0x78860..), screen control
    int lh0 = -1, lh1 = -1;
    initial begin if (!$value$plusargs("LH0=%d", lh0)) lh0 = -1; if (!$value$plusargs("LH1=%d", lh1)) lh1 = -1; end
    int lh_n [7]; int lh_lo [7]; int lh_hi [7];
    initial for (int i = 0; i < 7; i++) begin lh_n[i] = 0; lh_lo[i] = 999; lh_hi[i] = -1; end
    wire [18:0] lh_a = dut.u_vdp.i_addr;
    always_ff @(posedge clk) if (lh0 >= 0) begin
        if (dut.u_vdp.cpu_wr_commit) begin
            int k;
            k = -1;
            if (lh_a < 19'h60000) k = 0;
            else if (lh_a >= 19'h72000 && lh_a < 19'h74000) k = 1;
            else if (lh_a >= 19'h74000 && lh_a < 19'h75000) k = 2;
            else if (lh_a >= 19'h78870 && lh_a < 19'h7887C) k = 3;
            else if (lh_a >= 19'h78860 && lh_a < 19'h7886C) k = 4;
            else if (lh_a == 19'h788AC) k = 5;
            else if (lh_a >= 19'h78000 && lh_a < 19'h78800) k = 6;
            if (lh_a >= 19'h79700 && lh_a < 19'h79720 && as_frame_n >= lh0 && as_frame_n <= lh1)       // the sprite / layer registers: every write
                $display("REGW f%0d v%0d %05x d=%04x", as_frame_n, int'(dut.u_vdp.vcnt), lh_a, dut.u_vdp.i_wdata);
            if (k >= 0) begin
                lh_n[k] <= lh_n[k] + 1;
                if (int'(dut.u_vdp.vcnt) < lh_lo[k]) lh_lo[k] <= int'(dut.u_vdp.vcnt);
                if (int'(dut.u_vdp.vcnt) > lh_hi[k]) lh_hi[k] <= int'(dut.u_vdp.vcnt);
            end
        end
        if (vbl_o && !vbl_q) begin
            if (as_frame_n >= lh0 && as_frame_n <= lh1)
                $display("LH %0d  vram %0d %0d..%0d  pal %0d %0d..%0d  spr %0d %0d..%0d  scroll %0d %0d..%0d  window %0d %0d..%0d  ctrl %0d %0d..%0d  ttab %0d %0d..%0d", as_frame_n,
                         lh_n[0], lh_lo[0], lh_hi[0], lh_n[1], lh_lo[1], lh_hi[1], lh_n[2], lh_lo[2], lh_hi[2], lh_n[3], lh_lo[3], lh_hi[3], lh_n[4], lh_lo[4], lh_hi[4], lh_n[5], lh_lo[5], lh_hi[5], lh_n[6], lh_lo[6], lh_hi[6]);
            for (int i = 0; i < 7; i++) begin lh_n[i] <= 0; lh_lo[i] <= 999; lh_hi[i] <= -1; end
        end
    end
    // +ASTRACE=n: print the first n bus cycles (address, direction, strobes) as they start
    int astr_n = 0, astr_max = 0, astr_from = 0;
    initial if (!$value$plusargs("ASTRACE=%d", astr_max)) astr_max = 0;
    initial if (!$value$plusargs("ASFRAME=%d", astr_from)) astr_from = 0;
    logic as_q3 = 1'b1;
    always_ff @(posedge clk) begin
        as_q3 <= dut.ASn;
        if (as_q3 && !dut.ASn && astr_n < astr_max && as_frame_n >= astr_from) begin
            astr_n <= astr_n + 1;
            $display("AS %0d at clk %0d: addr %06x rw=%0d rom=%0d ram=%0d vdp=%0d io=%0d", astr_n, clk_n, {dut.eab, 1'b0}, dut.eRWn, dut.sel_rom, dut.sel_ram, dut.sel_vdp, dut.sel_io);
        end
    end
    final $display("bus cycles by AS-low clocks (<=28 <=32 <=36 <=44 <=64 more): %0d %0d %0d %0d %0d %0d",
        as_hist[0], as_hist[1], as_hist[2], as_hist[3], as_hist[4], as_hist[5]);

    // sound CPU stand-in: busy from a command write until it "reads" it (the real uPD78C10 clears it from its port B: 601 states = 150 us for the usual command in
    // MAME's code on the YM2151 boards' program, measured in the lock-step trace; this stand-in used 60 us before and a fade was a frame off MAME's on Pururun)
    logic [15:0] busy_cnt = 16'd0;
    always_ff @(posedge clk) begin
        if (core_rst) busy_cnt <= 16'd0;
        else if (snd_cmd_wr) busy_cnt <= 16'd14424;
        else if (busy_cnt != 0) busy_cnt <= busy_cnt - 16'd1;
    end
    assign snd_busy = (busy_cnt != 0);

    // ---------------------------------------------------------------- state dump (hex text, same order as the MAME .mem files)
    task automatic dump_state(input int tag);
        string fn;
        int fd;
        fn = $sformatf("%s.%0d.hex", dpfx, tag);
        fd = $fopen(fn, "w");
        for (int i = 0; i < 65536; i++) $fwrite(fd, "%04x\n", {dut.u_vdp.u_vram0.g_sliced.s3.mem[i], dut.u_vdp.u_vram0.g_sliced.s2.mem[i], dut.u_vdp.u_vram0.g_sliced.s1.mem[i], dut.u_vdp.u_vram0.g_sliced.s0.mem[i]});
        for (int i = 0; i < 65536; i++) $fwrite(fd, "%04x\n", {dut.u_vdp.u_vram1.g_sliced.s3.mem[i], dut.u_vdp.u_vram1.g_sliced.s2.mem[i], dut.u_vdp.u_vram1.g_sliced.s1.mem[i], dut.u_vdp.u_vram1.g_sliced.s0.mem[i]});
        for (int i = 0; i < 65536; i++) $fwrite(fd, "%04x\n", {dut.u_vdp.u_vram2.g_sliced.s3.mem[i], dut.u_vdp.u_vram2.g_sliced.s2.mem[i], dut.u_vdp.u_vram2.g_sliced.s1.mem[i], dut.u_vdp.u_vram2.g_sliced.s0.mem[i]});
        for (int i = 0; i < 4096; i++)  $fwrite(fd, "%04x\n", dut.u_vdp.u_palette.g_plain.mem[i]);
        for (int i = 0; i < 2048; i++)  $fwrite(fd, "%04x\n", dut.u_vdp.u_spr_live.g_plain.mem[i]);
        for (int i = 0; i < 1024; i++)  $fwrite(fd, "%04x\n", dut.u_vdp.u_tiletable.g_plain.mem[i]);
        $fclose(fd);
        fn = $sformatf("%s.%0d.regs", dpfx, tag);
        fd = $fopen(fn, "w");
        $fwrite(fd, "79700 %04x\n", dut.u_vdp.r_spr_count);
        $fwrite(fd, "79702 %04x\n", dut.u_vdp.r_spr_pri);
        $fwrite(fd, "79704 %04x\n", dut.u_vdp.r_spr_yoff);
        $fwrite(fd, "79706 %04x\n", dut.u_vdp.r_spr_xoff);
        $fwrite(fd, "79708 %04x\n", dut.u_vdp.r_spr_color);
        $fwrite(fd, "79710 %04x\n", {10'd0, dut.u_vdp.r_layer_pri});
        $fwrite(fd, "79712 %04x\n", {4'd0, dut.u_vdp.r_bg});
        $fwrite(fd, "78850 %04x\n", dut.u_vdp.r_scr_yoff);
        $fwrite(fd, "78852 %04x\n", dut.u_vdp.r_scr_xoff);
        $fwrite(fd, "788ac %04x\n", dut.u_vdp.r_ctrl);
        for (int i = 0; i < 6; i++) $fwrite(fd, "%05x %04x\n", 20'h78860 + 2*i, dut.u_vdp.r_window[i]);
        for (int i = 0; i < 6; i++) $fwrite(fd, "%05x %04x\n", 20'h78870 + 2*i, dut.u_vdp.r_scroll[i]);
        $fwrite(fd, "788a4 %04x\n", {8'd0, dut.u_vdp.r_irq_enable});
        $fclose(fd);
        // the sprite RAM COPY the renderer works from (taken at the start of the last line of the previous frame): what the frame's image was drawn with
        fn = $sformatf("%s.%0d.spr", dpfx, tag);
        fd = $fopen(fn, "w");
        for (int i = 0; i < 2048; i++)  $fwrite(fd, "%04x\n", dut.u_vdp.u_spr_buf.g_plain.mem[i]);
        $fclose(fd);
    endtask


    // GFX stream latency probe: clocks from every request pulse to its first beat (histogram in 8-clock buckets, >= 120 in the last), printed at each state dump
    int lp_t, lp_n, lp_sum, lp_max;
    int lp_hist [0:15];
    logic lp_busy;
    initial begin lp_n = 0; lp_sum = 0; lp_max = 0; lp_busy = 1'b0; lp_t = 0; for (int i = 0; i < 16; i++) lp_hist[i] = 0; end
    always_ff @(posedge clk) begin
        if (gfx_req && !lp_busy) begin lp_busy <= 1'b1; lp_t <= 1; end
        else if (lp_busy) begin
            lp_t <= lp_t + 1;
            if (gfx_valid) begin
                lp_busy <= 1'b0;
                lp_n <= lp_n + 1; lp_sum <= lp_sum + lp_t;
                if (lp_t > lp_max) lp_max <= lp_t;
                lp_hist[(lp_t / 8 > 15) ? 15 : lp_t / 8] <= lp_hist[(lp_t / 8 > 15) ? 15 : lp_t / 8] + 1;
            end
        end
    end

    // stale-line probe: visible pixels read from a line the renderer had not finished (the scan-out shows the background pen there), counted per picture; printed when non-zero
    int st_px, st_frames, st_row, st_first, vs_frame;
    logic vs_q, de_q;
    initial begin st_px = 0; st_frames = 0; st_row = 0; st_first = -1; vs_frame = 0; vs_q = 1'b0; de_q = 1'b0; end
    always_ff @(posedge clk) if (ce_pix_m) begin
        vs_q <= vs_m; de_q <= de_m;
        if (vs_m && !vs_q) begin
            vs_frame <= vs_frame + 1;
            if (st_px > 0) $display("STALE picture %0d: %0d pixels, first row %0d", vs_frame, st_px, st_first);
            st_px <= 0; st_row <= 0; st_first <= -1;
        end else begin
            if (de_q && !de_m) st_row <= st_row + 1;
            if (de_m && dut.u_vdp.so_stale) begin st_px <= st_px + 1; if (st_first < 0) st_first <= st_row; end
        end
    end

    task automatic lat_report;
        $display("gfxlat: %0d requests, mean %0d.%0d clocks to the first beat, max %0d; hist(8-clock buckets): %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                 lp_n, (lp_n > 0) ? lp_sum / lp_n : 0, (lp_n > 0) ? ((lp_sum % lp_n) * 10) / lp_n : 0, lp_max,
                 lp_hist[0], lp_hist[1], lp_hist[2], lp_hist[3], lp_hist[4], lp_hist[5], lp_hist[6], lp_hist[7], lp_hist[8], lp_hist[9], lp_hist[10], lp_hist[11], lp_hist[12], lp_hist[13], lp_hist[14], lp_hist[15]);
    endtask

    always @(posedge clk) if (dump) begin lat_report(); dump_state(int'(dump_tag)); end
    // family F: the 053936's control block, line RAM and tile map RAM (in the SDRAM model: the shared-RAM client's words) as tools/lua/vstate.lua VS_ROZ=1 writes them
`ifdef F64
    localparam int ROZ_MAP_BYTE = 32'h3C00000;
`else
    localparam int ROZ_MAP_BYTE = 32'h1C00000;
`endif
    task automatic dump_roz(input int tag);
        int fd;
        string fn;
        $sformat(fn, "%s.%0d.roz", dpfx, tag);
        fd = $fopen(fn, "wb");
        for (int i = 0; i < 16; i++) $fwrite(fd, "%c%c", roz_ctrl_t[i][15:8], roz_ctrl_t[i][7:0]);
        for (int i = 0; i < 2048; i++) $fwrite(fd, "%c%c", dut.rz_line_h[i], dut.rz_line_l[i]);
        for (int i = 0; i < 131072; i++) $fwrite(fd, "%c%c", u_sdram_model.mem_b[ROZ_MAP_BYTE + 2*i], u_sdram_model.mem_b[ROZ_MAP_BYTE + 2*i + 1]);
        $fclose(fd);
    endtask
    always @(posedge clk) if (dump && (board_sel == 8'd18 || board_sel == 8'd19)) dump_roz(int'(dump_tag));
    // +MIDF=<frame> +MIDL=<line> [+MIDN=<count>]: dump the VDP state in the middle of a frame (as_frame_n = MIDF, chip line MIDL, then every 16 lines, MIDN times), tag 100000 + line
    int midf = -1, midl = 0, midn = 1, mid_done = 0;
    initial begin if (!$value$plusargs("MIDF=%d", midf)) midf = -1; if (!$value$plusargs("MIDL=%d", midl)) midl = 0; if (!$value$plusargs("MIDN=%d", midn)) midn = 1; end
    always @(posedge clk) if (midf >= 0 && as_frame_n == midf && mid_done < midn && int'(dut.u_vdp.vcnt) == midl + 16 * mid_done && dut.u_vdp.hcnt == 9'd10 && dut.u_vdp.ce_pix) begin
        dump_state(100000 + midl + 16 * mid_done);
        mid_done <= mid_done + 1;
    end
endmodule
`default_nettype wire

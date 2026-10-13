// Sound-board bench of family F: metro_sndf (Z80 + YM2610 + latch) with the real memory path -- the MRA image is streamed through metro_loader into metro_sdram + a
// behavioural SDRAM model, the Z80's program is read through metro_mrom_arb's B port, the samples through the OKI-style client (metro_ympcm) -- and the board's mono output.
// tb_sndf.cpp plays the sound commands of a recorded game session (tools/lua/fsnd.lua) and writes the audio as a WAV file for tools/audio_cmp.py.
`timescale 1ns/1ps
module tb_sndf_top (
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
    output logic signed [15:0] audio_r,
    output logic        audio_valid,
    output logic [4:0]  dbg_ev
);
    wire [7:0]  cfg_board;
    wire [1:0]  cfg_rot, cfg_scr;
    wire [31:0] cfg_gfxsize;
    wire        ldr_wr, dl_busy;
    wire [25:0] ldr_addr;
    wire [7:0]  ldr_data;
    metro_loader u_ldr (
        .clk(clk), .dl_wr(ioctl_wr && ioctl_download), .dl_addr(ioctl_addr[25:0]), .dl_data(ioctl_dout),
        .o_wr(ldr_wr), .o_addr(ldr_addr), .o_data(ldr_data),
        .cfg_board(cfg_board), .cfg_rot(cfg_rot), .cfg_scramble(cfg_scr), .cfg_gfxsize(cfg_gfxsize));

    logic rst_r = 1'b1;
    always_ff @(posedge clk) rst_r <= reset | ioctl_download | dl_busy | ~sdr_ready;
    assign snd_rst = rst_r;
    assign dl_busy_o = dl_busy;

    // the 8 MHz enable and the 48 MHz clock
    logic [3:0] zdiv = 4'd0;
    logic       cen_z80 = 1'b0;
    always_ff @(posedge clk) begin zdiv <= (zdiv == 4'd11) ? 4'd0 : zdiv + 4'd1; cen_z80 <= (zdiv == 4'd11); end
    logic clk_snd = 1'b0;
    always_ff @(posedge clk) clk_snd <= ~clk_snd;

    wire        mrom_rd, mrom_valid, zr_rd, zr_valid;
    wire [20:0] mrom_addr, zr_addr;
    wire [15:0] mrom_data;
    metro_mrom_arb u_arb (
        .clk(clk), .rst(~sdr_ready),
        .rd_a(1'b0), .addr_a(21'd0), .valid_a(),
        .rd_b(zr_rd), .addr_b(zr_addr), .valid_b(zr_valid),
        .rdata(),
        .rd(mrom_rd), .raddr(mrom_addr), .valid(mrom_valid), .sdata(mrom_data));

    wire [21:0] pa_addr;
    wire [20:0] pb_addr;
    wire  [7:0] pa_data, pb_data, oki_data;
    wire [22:0] yp_addr;
    wire        oki_ok;
    metro_ympcm u_ympcm (
        .clk(clk), .rst(rst_r), .i_a_addr(pa_addr), .i_b_addr(pb_addr), .i_a_off(23'h200000),
        .o_addr(yp_addr), .i_data(oki_data), .i_ok(oki_ok), .o_a_data(pa_data), .o_b_data(pb_data));

    wire [12:0] sd_a;  wire [1:0] sd_ba;  tri [15:0] sd_dq;
    wire sd_dqml, sd_dqmh, sd_ncs, sd_nras, sd_ncas, sd_nwe, sd_cke;
    metro_sdram #(.P_SHORT_INIT(1'b0), .P_RET(3)) u_sdram (
        .clk(clk), .rst_n(~reset), .o_ready(sdr_ready), .i_rd_late(1'b0),
        .i_gfx_req(1'b0), .i_gfx_addr(26'd0), .i_gfx_len(7'd0), .o_gfx_data(), .o_gfx_valid(),
        .i_mrom_wbase(25'h080000 + 25'(cfg_gfxsize[25:1])), .i_mrom_rd(mrom_rd), .i_mrom_addr(mrom_addr), .o_mrom_data(mrom_data), .o_mrom_valid(mrom_valid),
        .i_oki_wbase(25'h290000 + 25'(cfg_gfxsize[25:1])), .i_oki_addr(yp_addr), .o_oki_data(oki_data), .o_oki_ok(oki_ok),
        .i_sr3_req(1'b0), .i_sr3_we(1'b0), .i_sr3_addr(17'd0), .i_sr3_wdata(16'd0), .i_sr3_be(2'd0), .o_sr3_rdata(), .o_sr3_ack(),
        .i_dl_wr(ldr_wr), .i_dl_addr(ldr_addr), .i_dl_data(ldr_data), .o_dl_busy(dl_busy), .i_dl_active(ioctl_download),
        .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_DQ(sd_dq), .SDRAM_DQML(sd_dqml), .SDRAM_DQMH(sd_dqmh),
        .SDRAM_nCS(sd_ncs), .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas), .SDRAM_nWE(sd_nwe), .SDRAM_CKE(sd_cke),
        .dbg_dl_saw(), .dbg_dl_byte0(), .dbg_dl_byte1(), .dbg_dl_count(), .dbg_selftest(), .dbg_postdl(),
        .dbg_dl_written(), .dbg_dl_dropped(), .dbg_fsm_info(), .dbg_sums(), .dbg_sumb1(), .dbg_sumb2());
    sdram_model u_sdram_model (.clk(clk), .A(sd_a), .BA(sd_ba), .DQ(sd_dq), .DQML(sd_dqml), .DQMH(sd_dqmh),
        .nCS(sd_ncs), .nRAS(sd_nras), .nCAS(sd_ncas), .nWE(sd_nwe), .CKE(sd_cke));

    logic signed [15:0] snd_l, snd_r;
    logic snd_v;
`ifdef STEREO0
    wire stereo_sel = 1'b0;                 // the mono mix of Grand Striker 2 (A / B against the stereo one)
`else
    wire stereo_sel = (cfg_board == 8'd18);
`endif
    metro_sndf u_sndf (
        .clk(clk), .clk_snd(clk_snd), .rst(rst_r), .cen_z80(cen_z80), .i_stereo(stereo_sel), .cmd(cmd), .cmd_wr(cmd_wr),
        .zr_rd(zr_rd), .zr_addr(zr_addr), .zr_valid(zr_valid), .zr_data(mrom_data),
        .pa_addr(pa_addr), .pb_addr(pb_addr), .pa_data(pa_data), .pb_data(pb_data),
        .snd_l(snd_l), .snd_r(snd_r), .snd_valid(snd_v), .dbg_z80_rd(), .dbg_ev(dbg_ev));
    assign audio = snd_l;
    assign audio_r = snd_r;
`ifdef SNDF_DBG
    // debug: the Z80's first instruction fetches, every I/O write and the first Z80 ROM word reads
    int m1n = 0, iow = 0, zrn = 0;
    longint tcnt = 0;
    always_ff @(posedge clk) begin
        if (rst_r) tcnt <= 0; else tcnt <= tcnt + 1;
        if (!(u_sndf.iorq_n | u_sndf.wr_n) && u_sndf.cen_z80 && u_sndf.A[7:2] == 6'b100000 && tcnt >= 480000000 && tcnt < 672000000)
            $display("ZW %0d %02x %02x", tcnt, u_sndf.A[7:0], u_sndf.dout);
    end
    logic m1_d = 1'b1, iow_d = 1'b1;
    always_ff @(posedge clk) begin
        m1_d  <= u_sndf.m1_n | u_sndf.mreq_n | u_sndf.rd_n;
        iow_d <= u_sndf.iorq_n | u_sndf.wr_n;
        if (m1_d && !(u_sndf.m1_n | u_sndf.mreq_n | u_sndf.rd_n) && m1n < 40) begin m1n <= m1n + 1; $display("Z80 M1 A=%04x wait_n=%b", u_sndf.A, u_sndf.wait_n); end
        if (iow_d && !(u_sndf.iorq_n | u_sndf.wr_n) && iow < 80) begin iow <= iow + 1; $display("Z80 OUT port=%04x data=%02x", u_sndf.A, u_sndf.dout); end
        if (zr_rd && zrn < 12) begin zrn <= zrn + 1; $display("ZR req addr=%06x", zr_addr); end
        if (zr_valid && zrn < 14) $display("ZR valid data=%04x", mrom_data);
    end
`endif
`ifdef SNDF_YMLOG
    // every write of the Z80 to the YM2610 (clock since the board left reset, port, data), for the lock-step comparison with MAME's audiocpu trace (work/bt/snd2/ymlog.lua)
    int ym_fd;
    longint ym_t = 0;
    logic ym_wr_d = 1'b0;
    initial begin
        string fn;
        if (!$value$plusargs("YMFILE=%s", fn)) fn = "ym_rtl.txt";
        ym_fd = $fopen(fn, "w");
    end
    logic lat_d = 1'b0, ack_d = 1'b0, cmd_d = 1'b0, nmi_d2 = 1'b0;
    always_ff @(posedge clk) begin
        cmd_d <= cmd_wr; lat_d <= u_sndf.io_latch; ack_d <= (~u_sndf.iorq_n & ~u_sndf.m1_n); nmi_d2 <= u_sndf.nmi_pend;
        if (cmd_wr && !cmd_d) $fdisplay(ym_fd, "%0d C %02x", ym_t, cmd);
        if (u_sndf.io_latch && !lat_d) $fdisplay(ym_fd, "%0d L %02x", ym_t, u_sndf.cmd_l);
        if ((~u_sndf.iorq_n & ~u_sndf.m1_n) && !ack_d) $fdisplay(ym_fd, "%0d A 00", ym_t);
    end
    always_ff @(posedge clk) begin
        if (rst_r) ym_t <= 0; else ym_t <= ym_t + 1;
        ym_wr_d <= !(u_sndf.iorq_n | u_sndf.wr_n) && u_sndf.A[7:2] == 6'b100000;
        if (!(u_sndf.iorq_n | u_sndf.wr_n) && u_sndf.A[7:2] == 6'b100000 && !ym_wr_d)
            $fdisplay(ym_fd, "%0d %0d %02x", ym_t, u_sndf.A[1:0], u_sndf.dout);
    end
    // the Z80's reads of the YM2610, logged when the value of a port changes (the polling loops would be millions of lines): "<clock> R<port> <data>"
    logic       ym_rd_d = 1'b0;
    logic [7:0] ym_q_d = 8'h00, ym_last0 = 8'hxx, ym_last1 = 8'hxx, ym_last2 = 8'hxx, ym_last3 = 8'hxx;
    logic [1:0] ym_a_d = 2'd0;
    wire ym_rd_now = !(u_sndf.iorq_n | u_sndf.rd_n) && u_sndf.m1_n && u_sndf.A[7:2] == 6'b100000;
    always_ff @(posedge clk) begin
        ym_rd_d <= ym_rd_now;
        if (ym_rd_now) begin ym_q_d <= u_sndf.ym_q; ym_a_d <= u_sndf.A[1:0]; end
        if (ym_rd_d && !ym_rd_now) begin
            case (ym_a_d)
                2'd0: if (ym_q_d !== ym_last0) begin ym_last0 <= ym_q_d; $fdisplay(ym_fd, "%0d R0 %02x", ym_t, ym_q_d); end
                2'd1: if (ym_q_d !== ym_last1) begin ym_last1 <= ym_q_d; $fdisplay(ym_fd, "%0d R1 %02x", ym_t, ym_q_d); end
                2'd2: if (ym_q_d !== ym_last2) begin ym_last2 <= ym_q_d; $fdisplay(ym_fd, "%0d R2 %02x", ym_t, ym_q_d); end
                2'd3: if (ym_q_d !== ym_last3) begin ym_last3 <= ym_q_d; $fdisplay(ym_fd, "%0d R3 %02x", ym_t, ym_q_d); end
            endcase
        end
    end
`endif
    // the Z80's program ROM words fetched from the SDRAM
    longint zrn_all = 0;
    always_ff @(posedge clk) if (u_sndf.zr_rd) zrn_all <= zrn_all + 1;
    final $display("ZR reads (Z80 program words fetched from the SDRAM): %0d", zrn_all);
    longint oki_n = 0; logic oki_pend_d = 1'b0;
    always_ff @(posedge clk) begin oki_pend_d <= u_sdram.oki_pend; if (u_sdram.oki_pend && !oki_pend_d) oki_n <= oki_n + 1; end
    final $display("OKI reads (YM2610 sample bytes fetched from the SDRAM): %0d", oki_n);
    // the controller's own accounting of each 21.8 ms window (rtl/metro_sdram.sv o_st): busy/64 clocks and the activations per client
    logic [95:0] sdst_d = '0;
    always_ff @(posedge clk) begin
        sdst_d <= u_sdram.m_st;
        if (u_sdram.m_st != sdst_d && u_sdram.m_st != 96'd0)
            $display("SDST busy64=%0d gfx=%0d oki=%0d sr3=%0d mrom=%0d dl=%0d", u_sdram.m_st[95:80], u_sdram.m_st[79:64], u_sdram.m_st[63:48], u_sdram.m_st[47:32], u_sdram.m_st[31:16], u_sdram.m_st[15:0]);
    end

    assign audio_valid = snd_v;
endmodule

// End-to-end bench of the MiSTer top (Metro.sv): plays the HPS. It
//   * resets, waits for the PLL stand-in and the SDRAM,
//   * loads the ROM image (MRA index 0) either streamed through the ioctl port, a byte per STRIDE clocks and held off by ioctl_wait, or the way the MRA's address=
//     attribute does it (FAST=1: the image copied into the DDR3 model, then a download that has no data bytes, only a start address = the image's length), and
//     reports the clocks it took,
//   * sets OSD options (SCALE = status[34:32], AR = status[122:121]), runs frames and captures the picture as the scaler gets it (VGA_*),
//   * checks the size the core asks the scaler for (VIDEO_ARX / VIDEO_ARY) against the framework's integer scaling rule,
//   * dumps the SDRAM chip's first <image length> bytes (+SDRDUMP) so a streamed and a fast load can be compared byte for byte,
//   * the EEPROM's file (the MRA's <nvram index="4" size="128"/>): NVIN=<file> is sent as Main_MiSTer sends it, a download with index 4 after the ROM (with FAST=1 while the
//     image is still being replayed); after the frames the OSD is opened (NVSAVE=1: Save EEPROM, status[13], instead) and, if the core asks for an upload, the 128 bytes are
//     read back as Main_MiSTer reads them and written to NVOUT=<file> (NVEXPECT=<n>: the number of upload requests expected),
//   * TESTKEY=<f0>,<f1>: the keyboard's F2 (the test switch of the I4300 boards) held from frame f0 to frame f1 after the load.
//
//   tb_emu <image> <frames after load> <out-prefix>
#include "Vtb_emu_top.h"
#include "Vtb_emu_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vtb_emu_top *dut;
static unsigned long long cycles = 0;
#define HPSV(n) dut->rootp->tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__##n
static inline void tick() { dut->CLK_50M = 0; dut->eval(); dut->CLK_50M = 1; dut->eval(); cycles++; }

static const int MAXW = 512, MAXH = 320;
static std::vector<unsigned> frame_now(MAXW * MAXH), frame_last(MAXW * MAXH);
static int row = 0, col = 0, rows_now = 0, rows_last = 0, width_last = 0, width_now = 0;
static bool prev_vs = false, prev_de = false;
static int frames_done = 0;
static unsigned long long last_frame_cycle = 0, frame_period = 0;
static unsigned errors = 0;

static void video_watch() {
    bool vs = dut->VGA_VS, de = dut->VGA_DE;
    if (de && !prev_de) { col = 0; }
    if (!de && prev_de) { rows_now++; if (col > width_now) width_now = col; row++; }
    prev_de = de;
    if (vs && !prev_vs) {                       // a frame ends
        rows_last = rows_now; width_last = width_now;
        frame_last = frame_now;
        frame_period = cycles - last_frame_cycle; last_frame_cycle = cycles;
        rows_now = 0; row = 0; width_now = 0; frames_done++;
    }
    prev_vs = vs;
    if (dut->CE_PIXEL && de) {
        if (row < MAXH && col < MAXW) frame_now[row * MAXW + col] = ((unsigned)dut->VGA_R << 16) | ((unsigned)dut->VGA_G << 8) | dut->VGA_B;
        col++;
    }
}
static void run(long n) { while (n--) { tick(); video_watch(); } }

static void set_status(int bit, int v) {
    int w = bit / 32, b = bit % 32;
    unsigned x = HPSV(r_status)[w];
    HPSV(r_status)[w] = v ? (x | (1u << b)) : (x & ~(1u << b));
}
static void field(int lo, int w, int v) { for (int i = 0; i < w; i++) set_status(lo + i, (v >> i) & 1); }

// stream bytes of data[0..n) as one download of the given index; stride = clocks per byte
static void download(int index, const unsigned char *data, long n, int stride) {
    HPSV(r_index) = index; HPSV(r_download) = 1; HPSV(r_addr) = 0;
    run(8);
    for (long i = 0; i < n; i++) {
        long guard = 0;
        while (HPSV(r_wait_seen) && guard++ < 1000000) run(1);
        HPSV(r_addr) = i; HPSV(r_dout) = data[i]; HPSV(r_wr) = 1; run(1);
        HPSV(r_wr) = 0; run(stride - 1);
    }
    run(40);
    HPSV(r_download) = 0; HPSV(r_index) = 0;
    run(8);
}

// the EEPROM's file as Main_MiSTer sends it after the ROMs: a download with index 4
static void send_nv(const char *path, int stride) {
    unsigned char b[128]; FILE *f = fopen(path, "rb");
    if (!f || fread(b, 1, 128, f) != 128) { fprintf(stderr, "cannot read 128 bytes of %s\n", path); exit(1); }
    fclose(f);
    download(4, b, 128, stride);
}

static void write_ppm(const char *path, const std::vector<unsigned> &px, int w, int h) {
    FILE *f = fopen(path, "wb"); if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { unsigned v = px[y * MAXW + x]; fputc((v >> 16) & 255, f); fputc((v >> 8) & 255, f); fputc(v & 255, f); }
    fclose(f);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: %s <image> <frames> <out-prefix>\n", argv[0]); return 2; }
    int frames = atoi(argv[2]); const char *pre = argv[3];
    std::vector<unsigned char> img;
    {
        FILE *f = fopen(argv[1], "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        img.resize(n);
        if (fread(img.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short image\n"); return 1; } fclose(f);
    }
    const long IMG_LEN = (long)img.size();
    const bool fast = getenv("FAST") && atoi(getenv("FAST"));
    const int stride = getenv("STRIDE") ? atoi(getenv("STRIDE")) : 2;

    dut = new Vtb_emu_top;
    dut->HDMI_WIDTH  = getenv("HW") ? atoi(getenv("HW")) : 1920;
    dut->HDMI_HEIGHT = getenv("HH") ? atoi(getenv("HH")) : 1080;
    dut->dump_go = 0;
    dut->OSD_STATUS = 0;
    dut->RESET = 1; run(40); dut->RESET = 0;
    if (getenv("SCALE")) field(32, 3, atoi(getenv("SCALE")));
    if (getenv("AR")) field(121, 2, atoi(getenv("AR")));
    if (getenv("NOROT") && atoi(getenv("NOROT"))) set_status(2, 1);          // Rotate screen: Off
    if (getenv("FX")) field(3, 3, atoi(getenv("FX")));                         // Scandoubler Fx (status[5:3]: 0 None, 1 HQ2x, 2..4 CRT 25 / 50 / 75 %)
    if (getenv("FSD") && atoi(getenv("FSD"))) HPSV(r_fsd) = 1;                 // the framework's forced_scandoubler (MiSTer.ini)
    if (getenv("CRT") && atoi(getenv("CRT"))) {                                // CRT Adjust on (status[101]); HSIZE (status[100:96]), HPOS ([85:79]), VSHIFT ([78:74])
        set_status(101, 1);
        if (getenv("HSIZE")) field(96, 5, atoi(getenv("HSIZE")) & 31);
        if (getenv("HPOS")) field(79, 7, atoi(getenv("HPOS")) & 127);
        if (getenv("VSHIFT")) field(74, 5, atoi(getenv("VSHIFT")) & 31);
    }
    run(40000);                                  // SDRAM init
    printf("up after %llu clocks; loading %ld bytes %s\n", cycles, IMG_LEN, fast ? "(fast)" : "(streamed)");
    unsigned long long t0 = cycles;
    {   // the DIP defaults (index 254): MAME's defaults are all ones
        unsigned char sw[4] = {0xff, 0xff, 0xff, 0xff};
        download(254, sw, 4, 4);
        t0 = cycles;
    }
    if (fast) {
        // what Main_MiSTer does for address= on the MRA's index-0 <rom>: the whole assembled image is copied into the DDR3 at that address, between the start and the end of
        // a download that carries no bytes, only a start address (ioctl_addr) that is the image's length
        auto &dd = dut->rootp->tb_emu_top__DOT__ddr__DOT__mem;
        const size_t FLB = 0x400000;                 // beats in the client's window: byte 0x32000000
        for (size_t i = 0; i < (size_t)IMG_LEN / 8 + 1; i++) {
            unsigned long long v = 0;
            for (int b = 7; b >= 0; b--) { size_t a = i * 8 + b; v = (v << 8) | (a < (size_t)IMG_LEN ? img[a] : 0); }
            dd[FLB + i] = v;
        }
        HPSV(r_index) = 0; HPSV(r_addr) = IMG_LEN; HPSV(r_download) = 1; run(64);
        HPSV(r_addr) = IMG_LEN + 1; HPSV(r_download) = 0;
        unsigned long long t1 = cycles; long guard = 0;
        if (getenv("NVIN")) { run(2000); send_nv(getenv("NVIN"), stride); printf("nv: file sent during the replay (fast_dl %d)\n", (int)dut->rootp->tb_emu_top__DOT__u_emu__DOT__fast_dl); }
        const long GUARD = 600000000;
        while (dut->rootp->tb_emu_top__DOT__u_emu__DOT__fast_dl && guard++ < GUARD) run(1);
        printf("fast load: the image replayed from the DDR3 in %llu clocks (%.3f s at 96 MHz)\n", cycles - t1, (cycles - t1) / 96e6);
        if (guard >= GUARD) { printf("  FAIL: the replay did not finish\n"); errors++; }
        run(64);
    } else {
        download(0, img.data(), IMG_LEN, stride);
        printf("image streamed in %llu clocks (%.3f s at 96 MHz, %d clocks a byte)\n", cycles - t0, (cycles - t0) / 96e6, stride);
        if (getenv("NVIN")) { send_nv(getenv("NVIN"), stride); printf("nv: file sent after the image\n"); }
    }
    run(20000);                                  // the last words leave the loader's FIFO

    if (getenv("SDRDUMP")) {                     // the SDRAM chip's bytes, for comparing two loads
        dut->dump_go = 1; run(4); dut->dump_go = 0; run(4);
    }

    int start_frames = frames_done;
    unsigned long long guard = 0;
    int tk0 = -1, tk1 = -1;
    if (getenv("TESTKEY")) sscanf(getenv("TESTKEY"), "%d,%d", &tk0, &tk1);
    bool tk_on = false;
    while (frames_done < start_frames + frames && guard++ < 4000000000ull) {
        tick(), video_watch();
        const int fr = frames_done - start_frames;
        if (tk0 >= 0 && !tk_on && fr >= tk0 && fr < tk1) {         // F2 pressed: a new event (bit 10 toggles), bit 9 set, code 0x06
            HPSV(r_ps2) = ((~HPSV(r_ps2)) & 0x400) | 0x200 | 0x006; tk_on = true; printf("F2 pressed at frame %d\n", fr);
        } else if (tk_on && fr >= tk1) {
            HPSV(r_ps2) = ((~HPSV(r_ps2)) & 0x400) | 0x006; tk_on = false; tk0 = -1; printf("F2 released at frame %d\n", fr);
        }
    }
    printf("%d frames after the load; the last: %d rows of up to %d pixels, frame period %llu clocks\n", frames_done - start_frames, rows_last, width_last, frame_period);
    unsigned nonblack = 0; for (unsigned v : frame_last) if (v) nonblack++;
    printf("last captured frame: %u non-black pixels\n", nonblack);

    if (getenv("NVOUT")) {      // the EEPROM's save: the OSD opens (or Save EEPROM), the core asks for an upload of index 4, the HPS reads the 128 bytes
        const bool force = getenv("NVSAVE") && atoi(getenv("NVSAVE"));
        const int req0 = HPSV(upload_reqs);
        printf("nv: dirty %d before the %s\n", (int)dut->rootp->tb_emu_top__DOT__u_emu__DOT__nv_dirty, force ? "Save EEPROM" : "OSD opens");
        if (force) { set_status(13, 1); run(2000); set_status(13, 0); }
        else { dut->OSD_STATUS = 1; run(2000); }
        const int reqs = HPSV(upload_reqs) - req0;
        printf("nv: %d upload request(s)\n", reqs);
        if (reqs) {
            HPSV(r_index) = 4; HPSV(r_upload) = 1; run(8);
            unsigned char buf[128];
            for (int a = 0; a < 128; a++) { HPSV(r_addr) = a; run(6); buf[a] = HPSV(r_din_seen); }
            HPSV(r_upload) = 0; run(8);
            HPSV(r_index) = 0; HPSV(r_addr) = 0; run(64);
            printf("nv: dirty %d after the upload\n", (int)dut->rootp->tb_emu_top__DOT__u_emu__DOT__nv_dirty);
            FILE *f = fopen(getenv("NVOUT"), "wb"); if (f) { fwrite(buf, 1, 128, f); fclose(f); }
            printf("nv: saved to %s:", getenv("NVOUT")); for (int a = 0; a < 32; a++) printf(" %02x", buf[a]); printf(" ...\n");
        }
        dut->OSD_STATUS = 0; run(2000);
        if (getenv("NVEXPECT") && atoi(getenv("NVEXPECT")) != reqs) { printf("  FAIL: %d upload requests, expected %s\n", reqs, getenv("NVEXPECT")); errors++; }
    }

    {   // Scale: the size the core asks the scaler for, against the framework's documented rule: the picture is scaled up by the largest whole factor that fits the
        // scaler's height; its width follows the aspect ratio (V-Integer) or is a whole multiple of the pixel row (the HV modes: narrower = the multiple below the
        // aspect width, wider = the one above it, HV-Integer = whichever of the two is nearer, the wider one only if it still fits the width)
        const int menu = getenv("SCALE") ? atoi(getenv("SCALE")) : 0, ar = getenv("AR") ? atoi(getenv("AR")) : 0;
        const bool rotated = getenv("EXPECT_ROT") && atoi(getenv("EXPECT_ROT"));
        const int HW = dut->HDMI_WIDTH, HH = dut->HDMI_HEIGHT;
        const int rows = rows_last, w = width_last;
        static const int map[5] = {0, 1, 4, 2, 3};                    // the OSD's order -> video_freak's SCALE
        const int sel = rotated ? 0 : ((menu >= 0 && menu <= 4) ? map[menu] : 0);
        const bool fs_int = ar == 1 && sel != 0 && HW != 0 && HH != 0;
        const int base_x = rotated ? 3 : 4, base_y = rotated ? 4 : 3;
        const int arx_in = fs_int ? HW : (ar == 0 ? base_x : ar - 1), ary_in = fs_int ? HH : (ar == 0 ? base_y : 0);
        int ex = arx_in, ey = ary_in; bool eabs = false, checked = true;
        if (sel && !(!ary_in && arx_in) && HH / rows > 0) {
            int oh = rows * (HH / rows), ht = 0, hi, dn;
            if (!ary_in) {
                int m = HW / w ? HW / w : 1; hi = w * m; oh = rows * m; dn = HW; checked = false;
            } else {
                ht = (int)((long)oh * arx_in / ary_in); int m0 = ht / w ? ht / w : 1; hi = w * m0; dn = ht;
                if (hi > HW) { int m1 = HW / w ? HW / w : 1; hi = w * m1; oh = rows * m1; dn = HW; }
            }
            const int wide = hi + w;
            const bool narrow = (((ht - hi) & 0xfff) <= ((wide - ht) & 0xfff)) || wide > HW;
            const int wres = hi == ht ? hi : wide;
            switch (sel) {
                case 2: ex = hi; break;
                case 3: ex = wres > HW ? hi : wres; break;
                case 4: ex = narrow ? hi : wres; break;
                default: ex = dn;
            }
            ey = oh; eabs = true;
        }
        const int gx = dut->VIDEO_ARX & 0xfff, gy = dut->VIDEO_ARY & 0xfff, gax = (dut->VIDEO_ARX >> 12) & 1, gay = (dut->VIDEO_ARY >> 12) & 1;
        printf("scale: Scale %d (SCALE %d) Aspect %d, picture %d rows of %d pixels, scaler %d x %d: core asks for %s%d x %s%d; rule gives %s%d x %s%d%s\n",
               menu, sel, ar, rows, w, HW, HH, gax ? "" : "ratio ", gx, gay ? "" : "ratio ", gy, eabs ? "" : "ratio ", ex, eabs ? "" : "ratio ", ey,
               checked ? "" : " (not checked)");
        if (checked && (gx != ex || gy != ey || gax != (int)eabs || gay != (int)eabs)) { printf("  FAIL: the size asked of the scaler\n"); errors++; }
    }
    if (nonblack == 0 && !(getenv("ALLOWBLANK") && atoi(getenv("ALLOWBLANK")))) { printf("  FAIL: the picture is blank\n"); errors++; }
    write_ppm((std::string(pre) + "_scaler.ppm").c_str(), frame_last, width_last > 0 ? width_last : 1, rows_last > 0 ? rows_last : 1);
    printf("DDR3: reads %d, writes %d (rotate frame buffer %d), protocol errors %d; core FB_EN %d (%d x %d)\n",
           (int)dut->rootp->tb_emu_top__DOT__ddr__DOT__rd_cmds, (int)dut->rootp->tb_emu_top__DOT__ddr__DOT__wr_cmds,
           (int)dut->rootp->tb_emu_top__DOT__ddr__DOT__rot_writes, (int)dut->rootp->tb_emu_top__DOT__ddr__DOT__protocol_errors,
           (int)dut->FB_EN, (int)dut->FB_WIDTH, (int)dut->FB_HEIGHT);
    if (dut->rootp->tb_emu_top__DOT__ddr__DOT__protocol_errors) errors++;
    printf("%s: %u errors, %llu clocks\n", errors ? "FAIL" : "PASS", errors, cycles);
    delete dut; return errors ? 1 : 0;
}

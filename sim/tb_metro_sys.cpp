// C++ driver for tb_metro_sys_top: runs the Metro board (Dharma) from reset on its real ROMs, with scripted coin / start presses keyed to the frame
// count, and dumps the VDP state at chosen frames for comparison with MAME (tools/metro_syscmp.py).
//
//   Vtb_metro_sys_top +PROG=<maincpu.bin> +GFX=<gfx.bin> +GFXSIZE=<bytes> +FRAMES=<n> +DUMPS=<f1,f2,..> +DUMPPFX=<prefix> [+COIN=<f>] [+START=<f>]
//
// Frame k = the k-th vblank interrupt since reset, counted from 0: dumping at frame k matches MAME's frame_done with frame_number() == k
// (tools/lua/vstate.lua).  Inputs are applied at the vblank of the frame they are named for, like vstate.lua: coin for 2 frames (MAME's
// PORT_IMPULSE(2)), 1P start for 6 frames.  A frame image is written as <prefix>.<k>.ppm at the next frame boundary of the video output.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <set>
#include "Vtb_metro_sys_top.h"
#include "verilated.h"

static const int WIDTH = 384, HEIGHT = 256;           // capture buffer; the picture's real size is measured from DE (320 / 360 x 224 / 240)
static int pic_w, pic_h;
static Vtb_metro_sys_top* t;
static uint32_t frame_rgb[HEIGHT][WIDTH];
static int cap_x, cap_y, frames_seen;
static bool de_d, vs_d;
static int pending_ppm = -1;
static std::string prefix;

static const char* plusarg(int argc, char** argv, const char* key) {
    size_t k = strlen(key);
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], key, k)) return argv[i] + k;
    return nullptr;
}

static void write_ppm(int tag) {
    std::string fn = prefix + "." + std::to_string(tag) + ".ppm";
    FILE* f = fopen(fn.c_str(), "w");
    if (!f) return;
    fprintf(f, "P3\n%d %d\n255\n", pic_w, pic_h);
    for (int y = 0; y < pic_h; y++) {
        for (int x = 0; x < pic_w; x++) {
            uint32_t p = frame_rgb[y][x];
            fprintf(f, "%u %u %u ", (p >> 16) & 255, (p >> 8) & 255, p & 255);
        }
        fprintf(f, "\n");
    }
    fclose(f);
}

static void tick() {
    if (t->ce_pix) {
        bool de = t->de, vs = t->vs;
        if (vs && !vs_d) {
            frames_seen++;
            pic_h = cap_y;
            if (pending_ppm >= 0) { write_ppm(pending_ppm); pending_ppm = -1; }
            cap_x = 0; cap_y = 0;
        } else if (de) {
            if (cap_y < HEIGHT && cap_x < WIDTH) {
                uint32_t r = t->r5 & 31, g = t->g5 & 31, b = t->b5 & 31;
                frame_rgb[cap_y][cap_x] = ((r << 3 | r >> 2) << 16) | ((g << 3 | g >> 2) << 8) | (b << 3 | b >> 2);
            }
            cap_x++;
            if (cap_x > pic_w) pic_w = cap_x;
        } else if (de_d) { cap_x = 0; cap_y++; }
        de_d = de; vs_d = vs;
    }
    t->clk = 1; t->eval();
    t->clk = 0; t->eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* gsz = plusarg(argc, argv, "+GFXSIZE="); const char* frs = plusarg(argc, argv, "+FRAMES=");
    const char* dmp = plusarg(argc, argv, "+DUMPS="); const char* pfx = plusarg(argc, argv, "+DUMPPFX=");
    const char* coin = plusarg(argc, argv, "+COIN="); const char* start = plusarg(argc, argv, "+START=");
    int nframes = frs ? atoi(frs) : 100;
    int coin_f = coin ? atoi(coin) : -1, start_f = start ? atoi(start) : -1;
    prefix = pfx ? pfx : "dump";
    std::set<int> dumps;
    if (dmp) { std::string s = dmp; size_t i = 0; while (i < s.size()) { size_t j = s.find(',', i); if (j == std::string::npos) j = s.size(); if (j > i) dumps.insert(atoi(s.substr(i, j - i).c_str())); i = j + 1; } }

    t = new Vtb_metro_sys_top;
    t->gfx_size = gsz ? (uint32_t)strtoul(gsz, nullptr, 10) : (1u << 21);
    const char* dsw = plusarg(argc, argv, "+DSW0=");                  // DIP word in hex (default FFFF = MAME's defaults; FFBF = Flip Screen on)
    t->in0 = 0x003F; t->in1 = 0xFFFF; t->dsw0 = dsw ? (uint16_t)strtoul(dsw, nullptr, 16) : 0xFFFF; t->in2 = 0xFFFF;
    { const char* d1 = plusarg(argc, argv, "+DSW1="); t->dsw1 = d1 ? (uint16_t)strtoul(d1, nullptr, 16) : 0xFFFF; }
    t->dump = 0; t->dump_tag = 0;
    t->win_mame = plusarg(argc, argv, "+WINMAME=1") ? 1 : 0;      // show chip lines 0..223 like MAME (the CRTC window is the default)
    t->flip_force = plusarg(argc, argv, "+FLIPFORCE=1") ? 1 : 0;   // the Flip Screen DIP (forced flip)
    t->pal_latch = plusarg(argc, argv, "+PALLIVE=1") ? 0 : 1;      // the OSD palette option: latched per frame (default) or live
    t->ioctl_download = 0; t->ioctl_wr = 0; t->ioctl_addr = 0; t->ioctl_dout = 0;
    t->rd_late = plusarg(argc, argv, "+RDLATE=1") ? 1 : 0;           // SDR mode: capture SDRAM read data one cycle later
    const char* img = plusarg(argc, argv, "+IMAGE=");                // SDR mode: the MRA image (tools/metro_rom.py build --out)
    t->reset = 1; t->clk = 0; t->eval();
    for (int i = 0; i < 64; i++) tick();
    t->reset = 0;
    if (img) {                                                       // stream the image through the loader into the SDRAM, as the HPS would
        FILE* f = fopen(img, "rb");
        if (!f) { fprintf(stderr, "cannot open %s\n", img); return 1; }
        std::vector<unsigned char> buf;
        { unsigned char tmp[65536]; size_t n; while ((n = fread(tmp, 1, sizeof tmp, f)) > 0) buf.insert(buf.end(), tmp, tmp + n); }
        fclose(f);
        for (int i = 0; i < 100000 && !t->sdr_ready; i++) tick();
        printf("image: %zu bytes, SDRAM ready=%d\n", buf.size(), (int)t->sdr_ready); fflush(stdout);
        t->ioctl_download = 1;
        long long dl_cycles = 0;
        for (size_t a = 0; a < buf.size(); ) {
            if (!t->dl_busy) {
                t->ioctl_addr = (uint32_t)a; t->ioctl_dout = buf[a]; t->ioctl_wr = 1; tick(); t->ioctl_wr = 0; tick(); a++; dl_cycles += 2;
            } else { tick(); dl_cycles++; }
        }
        t->ioctl_download = 0;
        for (int i = 0; i < 200000; i++) tick();                     // let the download FIFO drain into the SDRAM
        printf("download done (%lld cycles)\n", dl_cycles); fflush(stdout);
    }

    const bool ppm_only = plusarg(argc, argv, "+PPMONLY=1") != nullptr;   // images only (no VDP memory/register dumps): for long frame-by-frame runs
    int vblc = 0;                 // frame index of the next vblank
    int coin_left = 0, start_left = 0;
    long long cycles = 0, last_report = 0;
    int dump_wait = 0;
    while (vblc <= nframes) {
        t->dump = 0;
        if (t->vbl_o) {
            int k = vblc;         // this is MAME's frame_done with frame_number() == k
            // inputs, as vstate.lua sets them at frame_done k
            if (k == coin_f) coin_left = 2;
            if (k >= start_f && start_f >= 0 && k < start_f + 6) start_left = 1; else start_left = 0;
            if (dumps.count(k)) { if (!ppm_only) { t->dump = 1; t->dump_tag = k; } pending_ppm = k; printf("frame %d: dump (cycle %lld, halted=%d)\n", k, cycles, (int)t->cpu_halted); fflush(stdout); }
            uint16_t in0 = 0x003F;
            if (coin_left > 0) { in0 &= ~(1 << 2); coin_left--; }
            if (start_left) in0 &= ~(1 << 4);
            t->in0 = in0;
            vblc++;
        }
        tick();
        cycles++;
        if (cycles - last_report >= 50000000LL) { last_report = cycles; printf("  ... %lld cycles, frame %d\n", cycles, vblc); fflush(stdout); }
    }
    t->dump = 0;                                                     // (left set, the last dump request would repeat on every tick)
    for (int i = 0; i < 2000000 && pending_ppm >= 0; i++) tick();   // let the last frame image be written
    printf("done: %d frames, %lld cycles, gfx overrun=%d, cpu halted=%d\n", vblc, cycles, (int)t->gfx_overrun, (int)t->cpu_halted);
    t->final();                                                      // runs the bench's `final` block (ROM wait statistics)
    delete t;
    return 0;
}

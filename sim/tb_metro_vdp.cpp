// C++ driver for tb_metro_vdp_top: reset, load a dumped state through the CPU bus, let the VDP free-run, capture one frame as PPM.
// Adapted from the initial block of searchsolved/Arcade-HyperDuel_MiSTer sim/tb/tb_vdp.sv (7f154f1, GPL-3.0-or-later).
//
//   Vtb_metro_vdp_top +SCENE=<dir> +GFX=<gfx.bin> +GFXSIZE=<bytes> +OUT=<file.ppm> [+FRAMES=<n>]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "Vtb_metro_vdp_top.h"
#include "verilated.h"

static const int WIDTH = 384, HEIGHT = 256;           // capture buffer; the picture's real size is measured from DE
static int pic_w, pic_h;
static Vtb_metro_vdp_top* t;
static uint32_t frame_rgb[HEIGHT][WIDTH];
static int cap_x, cap_y, frames_seen;
static bool de_d, vs_d;
static long long rt_cycles, rt_max, rt_line_of_max;
static bool rt_active;
static long long g_ticks;                       // clock ticks since the start (replay timing)
static const char* g_dump_pfx;                  // replay: write every completed frame as <pfx>.<n>.ppm
static int g_dump_n;
static bool g_dump_on;
static void dump_ppm(const char* pfx, int n) {
    char name[512]; snprintf(name, sizeof name, "%s.%d.ppm", pfx, n);
    FILE* f = fopen(name, "wb"); if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", pic_w, pic_h);
    for (int y = 0; y < pic_h; y++) for (int x = 0; x < pic_w; x++) { uint32_t p = frame_rgb[y][x]; unsigned char c[3] = { (unsigned char)(p >> 16), (unsigned char)(p >> 8), (unsigned char)p }; fwrite(c, 1, 3, f); }
    fclose(f);
}

// One clock: observe the outputs as they are just before the rising edge (what clocked logic sees), then pulse the clock.
static void tick() {
    if (t->ce_pix) {
        bool de = t->de, vs = t->vs;
        if (vs && !vs_d) { pic_h = cap_y; if (g_dump_on && g_dump_pfx) dump_ppm(g_dump_pfx, g_dump_n++); cap_x = 0; cap_y = 0; frames_seen++; }
        else if (de) {
            if (cap_y < HEIGHT && cap_x < WIDTH) {
                uint32_t r = t->r5 & 31, g = t->g5 & 31, b = t->b5 & 31;
                frame_rgb[cap_y][cap_x] = ((r << 3 | r >> 2) << 16) | ((g << 3 | g >> 2) << 8) | (b << 3 | b >> 2);
            }
            cap_x++;
            if (cap_x > pic_w) pic_w = cap_x;
        } else if (de_d) { cap_x = 0; cap_y++; }
        de_d = de; vs_d = vs;
    }
    if (t->rnd_start) { rt_active = true; rt_cycles = 0; }
    else if (rt_active) {
        rt_cycles++;
        if (t->rnd_done) { rt_active = false; if (rt_cycles > rt_max) { rt_max = rt_cycles; rt_line_of_max = t->rnd_line; } }
    }
    t->clk = 1; t->eval();
    t->clk = 0; t->eval();
    g_ticks++;
}

static uint16_t bus_read(uint32_t a) {
    tick();
    t->cs = 1; t->addr = a; t->rnw = 1; t->be = 3;
    do tick(); while (!t->ack);
    uint16_t v = t->rdata;
    t->cs = 0; t->rnw = 0;
    tick();
    return v;
}

static void bus_write(uint32_t a, uint32_t d) {
    tick();
    t->cs = 1; t->addr = a; t->rnw = 0; t->be = 3; t->wdata = d;
    do tick(); while (!t->ack);
    t->cs = 0;
    tick();
}

static std::vector<uint16_t> load_hex(const std::string& path, size_t n) {
    std::vector<uint16_t> v(n, 0);
    FILE* f = fopen(path.c_str(), "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", path.c_str()); exit(1); }
    char line[64]; size_t i = 0;
    while (i < n && fgets(line, sizeof line, f)) v[i++] = (uint16_t)strtoul(line, nullptr, 16);
    fclose(f);
    if (i != n) { fprintf(stderr, "%s: %zu words, expected %zu\n", path.c_str(), i, n); exit(1); }
    return v;
}

// IRQ model test: no state is loaded.  Writes the IRQ enable Dharma uses (0x0A), then plays a trivial service routine (read the cause byte,
// write it back to acknowledge) and prints, per frame, how often each cause bit was seen and on which line the first vblank arrived.
static int irq_test(int nframes) {
    t->cs = 0; t->addr = 0; t->rnw = 1; t->be = 3; t->wdata = 0; t->gfx_size = 1u << 21;
    t->rst_n = 0; t->clk = 0; t->eval();
    for (int i = 0; i < 8; i++) tick();
    t->rst_n = 1;
    for (int i = 0; i < 4; i++) tick();
    t->cs = 1; t->addr = 0x788A4; t->rnw = 0; t->be = 1; t->wdata = 0x0A;
    do tick(); while (!t->ack);
    t->cs = 0; tick();
    int f0 = frames_seen, last = -1, nvbl = 0, ntick = 0, nblit = 0, nother = 0, vbl_line = -1, irqs_high = 0;
    long long guard = 0;
    while (frames_seen < f0 + nframes + 1) {
        tick();
        if (++guard > 400000000LL) { fprintf(stderr, "timeout\n"); return 1; }
        if (t->irq) {
            int line = t->vcnt;
            t->cs = 1; t->addr = 0x788A2; t->rnw = 1; t->be = 3;
            do tick(); while (!t->ack);
            uint8_t cause = t->rdata & 255;
            t->cs = 0; tick();
            t->cs = 1; t->addr = 0x788A2; t->rnw = 0; t->be = 1; t->wdata = cause;
            do tick(); while (!t->ack);
            t->cs = 0; tick();
            irqs_high++;
            if (frames_seen > f0) {                // skip the partial first frame
                if (cause & 1) { nvbl++; if (vbl_line < 0) vbl_line = line; }
                if (cause & 16) ntick++;
                if (cause & 4) nblit++;
                if (cause & ~(1 | 4 | 16)) nother++;
            }
        }
        if (frames_seen != last) {
            if (last >= f0 + 1) printf("frame %d: vblank %d (first seen on line %d), tick %d, blit %d, other %d\n", last - f0, nvbl, vbl_line, ntick, nblit, nother);
            if (frames_seen > f0) { nvbl = ntick = nblit = nother = 0; vbl_line = -1; }
            last = frames_seen;
        }
    }
    return 0;
}

static const char* plusarg(int argc, char** argv, const char* key) {
    size_t k = strlen(key);
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], key, k)) return argv[i] + k;
    return nullptr;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* scene = plusarg(argc, argv, "+SCENE="); const char* out = plusarg(argc, argv, "+OUT=");
    const char* gsz = plusarg(argc, argv, "+GFXSIZE="); const char* frs = plusarg(argc, argv, "+FRAMES=");
    if (!plusarg(argc, argv, "+IRQTEST") && (!scene || !out)) { fprintf(stderr, "need +SCENE=<dir> +OUT=<file> (+GFX=<gfx.bin> is read by the SV side)\n"); return 2; }
    int nframes = frs ? atoi(frs) : 3;
    t = new Vtb_metro_vdp_top;
    if (plusarg(argc, argv, "+IRQTEST")) return irq_test(nframes);
    std::string sd = scene ? scene : "";
    auto vram0 = load_hex(sd + "/vram0.hex", 65536), vram1 = load_hex(sd + "/vram1.hex", 65536), vram2 = load_hex(sd + "/vram2.hex", 65536);
    auto tt = load_hex(sd + "/tiletable.hex", 1024), pal = load_hex(sd + "/palette.hex", 4096), spr = load_hex(sd + "/spriteram.hex", 2048);
    auto regs = load_hex(sd + "/regs.hex", 22);

    t->gfx_size = gsz ? (uint32_t)strtoul(gsz, nullptr, 10) : (1u << 22);
    t->cs = 0; t->addr = 0; t->rnw = 1; t->be = 3; t->wdata = 0;
    t->rst_n = 0; t->clk = 0; t->eval();
    for (int i = 0; i < 8; i++) tick();
    t->rst_n = 1;
    for (int i = 0; i < 4; i++) tick();

    // +CRTCV=<hex>: the game's CRTC vertical word (0x070b: the displayed window starts at chip line 11), written through the unlock register like the games do
    if (const char* cv = plusarg(argc, argv, "+CRTCV=")) {
        bus_write(0x788A0, 1); bus_write(0x78880, (uint32_t)strtoul(cv, nullptr, 16)); bus_write(0x788A0, 0);
    }
    // registers first (so rendering during the load is harmless), then the RAMs
    bus_write(0x79700, regs[0]);  bus_write(0x79702, regs[1]);  bus_write(0x79704, regs[2]);  bus_write(0x79706, regs[3]);
    bus_write(0x79708, regs[4]);  bus_write(0x79710, regs[5]);  bus_write(0x79712, regs[6]);
    bus_write(0x78852, regs[7]);  bus_write(0x78850, regs[8]);  bus_write(0x788AC, regs[9]);
    for (int i = 0; i < 6; i++) { bus_write(0x78860 + i * 2, regs[10 + i]); bus_write(0x78870 + i * 2, regs[16 + i]); }
    for (int i = 0; i < 1024; i++) bus_write(0x78000 + i * 2, tt[i]);
    for (int i = 0; i < 4096; i++) bus_write(0x72000 + i * 2, pal[i]);
    for (int i = 0; i < 2048; i++) bus_write(0x74000 + i * 2, spr[i]);
    for (int i = 0; i < 65536; i++) {
        bus_write(0x00000 + i * 2, vram0[i]);
        bus_write(0x20000 + i * 2, vram1[i]);
        bus_write(0x40000 + i * 2, vram2[i]);
    }
    printf("tb_metro_vdp: state loaded via bus (%d frames elapsed)\n", frames_seen);
    t->vlog_en = 1;                                                                           // P_VLOG: the layer RAM goes through the log from here on (a no-op without the parameter)
    if (const char* i43 = plusarg(argc, argv, "+I4300=")) t->i4300_en = atoi(i43) != 0;      // a replay of an I4300 game's own writes (family D: MAME's addresses are the chip's native ones)

    // +REPLAY=<events> +REPLAYPFX=<prefix> +REPLAYN=<pictures>: let the picture settle for two frames, align the raster to the start of line 224 (= the time of the state dump, MAME's
    // frame_done), then play MAME's timed CPU writes (cycle = clocks after the dump, from work/b2/vdpwr.lua) and write every completed picture as <prefix>.<n>.ppm (n = 0: the first picture
    // after the dump).  The 68000's reads and its blitter-done wait are not modelled: the writes are MAME's, at MAME's times.
    if (const char* rp = plusarg(argc, argv, "+REPLAY=")) {
        struct Ev { long long t; uint32_t a, d; int be; };
        std::vector<Ev> ev;
        FILE* ef = fopen(rp, "r"); if (!ef) { fprintf(stderr, "cannot open %s\n", rp); return 1; }
        long long tt; unsigned a, d, m;
        while (fscanf(ef, "%lld %x %x %x", &tt, &a, &d, &m) == 4) ev.push_back({tt, a, d, ((m & 0xff00) ? 2 : 0) | ((m & 0xff) ? 1 : 0)});
        fclose(ef);
        const char* pfx = plusarg(argc, argv, "+REPLAYPFX="); const char* rn = plusarg(argc, argv, "+REPLAYN=");
        int npic = rn ? atoi(rn) : 10;
        g_dump_pfx = pfx;
        long long guard2 = 0;
        int f2 = frames_seen; while (frames_seen < f2 + 2) { tick(); if (++guard2 > 400000000LL) return 1; }
        while (!(t->vcnt == 224 && t->hcnt_o == 0)) { tick(); if (++guard2 > 400000000LL) return 1; }
        long long t0 = g_ticks; size_t ei = 0; g_dump_on = true; g_dump_n = 0;
        printf("replay: %zu events, aligned at tick %lld\n", ev.size(), t0);
        while (g_dump_n < npic) {
            while (ei < ev.size() && ev[ei].t <= g_ticks - t0) {
                if (ev[ei].a >= 0x400000) {                                     // family F: the 053936's RAM / line RAM / control (absolute addresses)
                    t->rz_we = 1; t->rz_wa = ev[ei].a; t->rz_wd = ev[ei].d; t->rz_wm = ev[ei].be;
                    tick(); t->rz_we = 0; ei++;
                    continue;
                }
                t->cs = 1; t->addr = ev[ei].a; t->rnw = 0; t->be = ev[ei].be; t->wdata = ev[ei].d;
                tick(); do tick(); while (!t->ack);
                t->cs = 0; ei++;
            }
            tick();
            if (++guard2 > 4000000000LL) { fprintf(stderr, "replay timeout\n"); return 1; }
        }
        printf("replay: %d pictures, %zu of %zu events played\n", g_dump_n, ei, ev.size());
        return 0;
    }
    int start = frames_seen;
    long long guard = 0;
    while (frames_seen < start + nframes) {
        tick();
        if (++guard > 200000000LL) { fprintf(stderr, "timeout waiting for frames\n"); return 1; }
    }

    FILE* f = fopen(out, "w");
    if (!f) { fprintf(stderr, "cannot open %s\n", out); return 1; }
    fprintf(f, "P3\n%d %d\n255\n", pic_w, pic_h);
    for (int y = 0; y < pic_h; y++) {
        for (int x = 0; x < pic_w; x++) {
            uint32_t p = frame_rgb[y][x];
            fprintf(f, "%u %u %u ", (p >> 16) & 255, (p >> 8) & 255, p & 255);
        }
        fprintf(f, "\n");
    }
    fclose(f);
    printf("tb_metro_vdp: rendered %s -> %s\n", scene, out);
    printf("tb_metro_vdp: max line render = %lld cycles (line %lld), budget/line = %d, fifo overrun=%d\n",
           rt_max, rt_line_of_max, 424 * 32, (int)t->rnd_overrun);
    delete t;
    return 0;
}

// screen_rotate check: a 360 x 224 frame in the Metro raster (392 x 263, dot every 16 clocks) whose pixel (x, y) = R x, G y; the DDRAM writes are rebuilt into the framebuffer
#include "Vscreen_rotate.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <cstdint>
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int ccw = argc > 1 ? atoi(argv[1]) : 0;
    Vscreen_rotate* t = new Vscreen_rotate;
    const int W = 360, H = 224, HT = 392, VT = 263;
    t->no_rotate = 0; t->rotate_ccw = ccw; t->flip = 0; t->FB_VBL = 0; t->FB_LL = 0;
    std::vector<uint32_t> fb(1 << 22, 0xFFFFFFFF);       // by 64-bit slot index of the written 8 MB buffers
    uint64_t clk = 0;
    auto tick = [&]() {
        t->CLK_VIDEO = 0; t->eval();
        t->CLK_VIDEO = 1; t->eval();
        clk++;
    };
    int nwrites = 0;
    uint32_t maxaddr = 0;
    int stride = 0, fbw = 0, fbh = 0;
    for (int frame = 0; frame < 4; frame++) {
        for (int y = 0; y < VT; y++) {
            for (int x = 0; x < HT; x++) {
                for (int k = 0; k < 16; k++) {
                    t->CE_PIXEL = (k == 0);
                    bool de = (x < W) && (y < H);
                    t->VGA_DE = de;
                    t->VGA_HS = (x >= 364 && x < 388);
                    t->VGA_VS = (y >= 232 && y < 236);
                    t->VGA_R = de ? (x & 255) : 0; t->VGA_G = de ? (y & 255) : 0; t->VGA_B = de ? ((x >> 8) | ((y >> 8) << 1)) : 0;
                    tick();
                    if (t->DDRAM_WE) {
                        nwrites++;
                        uint32_t slot = t->DDRAM_ADDR & 0xFFFFF;           // 20 bits of 64-bit slot within the buffer
                        uint32_t buf = (t->DDRAM_ADDR >> 20) & 3;
                        uint64_t d = t->DDRAM_DIN;
                        uint32_t be = t->DDRAM_BE;
                        uint32_t px = (be & 0xF0) ? (uint32_t)(d >> 32) : (uint32_t)d;
                        uint32_t idx = (buf << 21) | (slot << 1) | ((be & 0xF0) ? 1 : 0);
                        if (frame == 3 && idx < fb.size()) fb[idx] = px;
                    }
                    stride = t->FB_STRIDE; fbw = t->FB_WIDTH; fbh = t->FB_HEIGHT;
                }
            }
        }
    }
    printf("rotate_ccw=%d: %d DDRAM writes, FB_WIDTH %d FB_HEIGHT %d stride %d bytes, FB_EN %d\n", ccw, nwrites, fbw, fbh, stride, (int)t->FB_EN);
    // find where source pixels landed: the buffer written in frame 2; locate (x=0,y=0), (x=359,y=0), (x=0,y=223), (x=359,y=223)
    int found = 0;
    for (size_t i = 0; i < fb.size(); i++) {
        uint32_t px = fb[i];
        if (px == 0xFFFFFFFF) continue;
        int r = px & 255, g = (px >> 8) & 255, b = (px >> 16) & 255;
        int sx = r | ((b & 1) << 8), sy = g | ((b >> 1) << 8);
        if ((sx == 0 || sx == 359) && (sy == 0 || sy == 223)) {
            uint32_t buf = i >> 21, off = (i & 0x1FFFFF) * 4;
            int row = off / (stride ? stride : 1), col = (off % (stride ? stride : 1)) / 4;
            printf("  source (%3d,%3d) -> buffer %u byte offset %u: row %d col %d\n", sx, sy, buf, off, row, col);
            found++;
        }
    }
    printf("  found %d corner pixels\n", found);
    delete t;
    return 0;
}

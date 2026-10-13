// Unit bench of rtl/metro_hud.sv: a 304 x 224 grey picture with the overlay of known words, written as a PPM (argv[1], mode argv[2] = 1 or 2).
#include "Vmetro_hud.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

int main(int argc, char** argv) {
    const char* out = argc > 1 ? argv[1] : "hud.ppm";
    const int mode = argc > 2 ? atoi(argv[2]) : 1;
    Verilated::commandArgs(argc, argv);
    Vmetro_hud* t = new Vmetro_hud;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    const int W = 304, H = 224, HB = 80, VB = 30, DIV = 14;
    std::vector<uint8_t> img(W * H * 3, 0);
    for (int w = 0; w < 3; w++) t->i_sdr[w] = 0x10001111u * (w + 1);
    t->i_mode = mode; t->i_ce = 0; t->i_hblank = 1; t->i_vblank = 1; t->i_rgb = 0x2108 | 0x1084; t->i_frame = 0;
    for (int w = 0; w < 32; w++) for (int b = 0; b < 16; b++) ((uint32_t*)t->i_st.data())[0] = 0;   // cleared below word by word
    for (int frame = 0; frame < 4; frame++) {
        // the words: word i of the video chip = 0x1000 + i * 0x111, of the plane = 0xA000 + i * 0x0101
        for (int i = 0; i < 16; i++) {
            uint16_t sv = 0x1000 + i * 0x111 + frame, rv = 0xA000 + i * 0x101 + frame;
            int bit = i * 16;
            ((uint32_t*)&t->i_st[0])[bit / 32] = (((uint32_t*)&t->i_st[0])[bit / 32] & ~(0xFFFFu << (bit % 32))) | ((uint32_t)sv << (bit % 32));
            bit = 256 + i * 16;
            ((uint32_t*)&t->i_st[0])[bit / 32] = (((uint32_t*)&t->i_st[0])[bit / 32] & ~(0xFFFFu << (bit % 32))) | ((uint32_t)rv << (bit % 32));
        }
        t->i_frame = 1; tick(); t->i_frame = 0; tick(); tick();
        for (int y = 0; y < H + VB; y++) {
            for (int x = 0; x < W + HB; x++) {
                t->i_hblank = !(x < W);
                t->i_vblank = !(y < H);
                for (int c = 0; c < DIV; c++) {
                    t->i_ce = (c == 0);
                    t->clk = 0; t->eval();
                    if (c == 0 && frame == 3 && x < W && y < H) {       // what the downstream stage samples at this edge
                        uint16_t p = t->o_rgb;
                        img[(y * W + x) * 3 + 0] = ((p >> 10) & 31) << 3;
                        img[(y * W + x) * 3 + 1] = ((p >> 5) & 31) << 3;
                        img[(y * W + x) * 3 + 2] = (p & 31) << 3;
                    }
                    t->clk = 1; t->eval();
                }
            }
        }
    }
    FILE* f = fopen(out, "wb");
    fprintf(f, "P6\n%d %d\n255\n", W, H);
    fwrite(img.data(), 1, img.size(), f);
    fclose(f);
    delete t;
    return 0;
}

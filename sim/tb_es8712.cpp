// Unit bench of rtl/metro_es8712.sv against a C++ transcription of MAME 0.289's es8712_device + msm6585 (run_es8712.sh).
// A pseudo-random 2 MB ROM, a few plays (normal end, a play started while playing, bank 1, start >= end), the audio and IRQ compared after every VCK (6000 clocks).
#include "Vmetro_es8712.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <cstdint>

static Vmetro_es8712* t;
static std::vector<uint8_t> rom;

// ---- reference model (MAME)
struct Ref {
    int diff[49 * 16];
    uint32_t start = 0, end = 0, base = 0; int playing = 0, trig = 0, msm_reset = 1, irq = 0, data = 0, signal = 0, step = 0;
    Ref() {
        static const int nbl2bit[16][4] = {{1,0,0,0},{1,0,0,1},{1,0,1,0},{1,0,1,1},{1,1,0,0},{1,1,0,1},{1,1,1,0},{1,1,1,1},
                                           {-1,0,0,0},{-1,0,0,1},{-1,0,1,0},{-1,0,1,1},{-1,1,0,0},{-1,1,0,1},{-1,1,1,0},{-1,1,1,1}};
        for (int s = 0; s <= 48; s++) {
            int sv = (int)floor(16.0 * pow(11.0 / 10.0, (double)s));
            for (int n = 0; n < 16; n++) diff[s * 16 + n] = nbl2bit[n][0] * (sv * nbl2bit[n][1] + sv / 2 * nbl2bit[n][2] + sv / 4 * nbl2bit[n][3] + sv / 8);
        }
    }
    void write(int off, int d) {
        if (off < 3) { int sh = off * 8; start &= ~(0xffu << sh); start |= (uint32_t)d << sh; start &= 0xfffff; }
        else if (off < 6) { int sh = (off - 3) * 8; end &= ~(0xffu << sh); end |= (uint32_t)d << sh; end &= 0xfffff; }
        else if (off == 6) play();
    }
    void play() {
        if (start < end) { if (!playing) { playing = 1; msm_reset = 0; irq = 0; base = start; } }
        else if (playing) { playing = 0; irq = 1; }
    }
    void reset() { playing = 0; msm_reset = 1; irq = 0; }
    void vck(int bank) {
        if (playing) {
            if (base >= 0x100000 || base > end) { playing = 0; msm_reset = 1; irq = 1; trig = 0; }
            else {
                int b = rom[(bank << 20) | base];
                data = trig ? (b & 15) : (b >> 4);
                trig ^= 1; if (trig == 0) base++;
            }
        }
        static const int shift[8] = {-1,-1,-1,-1,2,4,6,8};
        int ns;
        if (msm_reset) { ns = 0; step = 0; }
        else {
            ns = signal + diff[step * 16 + (data & 15)];
            if (ns > 2047) ns = 2047; else if (ns < -2048) ns = -2048;
            step += shift[data & 7]; if (step > 48) step = 48; else if (step < 0) step = 0;
        }
        signal = ns;
    }
};

static int bank = 0;
static void tick() {
    t->clk = 1; t->eval();
    // the ROM port: level style, one clock of latency
    uint32_t a = t->o_addr;
    t->i_data = rom[a & 0x1fffff]; t->i_ok = 1;
    t->clk = 0; t->eval();
}
static void wr(int a, int d) { t->i_wr = 1; t->i_a = a; t->i_d = d; tick(); t->i_wr = 0; }
static void clocks(int n) { for (int i = 0; i < n; i++) tick(); }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vmetro_es8712;
    rom.resize(2 << 20); uint32_t s = 12345;
    for (auto& b : rom) { s = s * 1664525u + 1013904223u; b = s >> 24; }
    Ref r; int errs = 0, n = 0;
    t->rst = 1; t->i_wr = 0; t->i_reset_w = 0; t->i_bank = 0; t->i_ok = 1; clocks(4); t->rst = 0;
    auto check = [&](const char* what) {
        int a = (int)(int16_t)t->o_audio >> 3;
        if (a != r.signal || (int)t->o_irq != r.irq) { if (errs++ < 8) printf("MISMATCH %s at vck %d: audio %d vs %d, irq %d vs %d\n", what, n, a, r.signal, t->o_irq, r.irq); }
    };
    // sequence of events at chosen VCKs
    for (n = 0; n < 6000; n++) {
        if (n == 5)    { auto w = [&](int o, int d) { wr(o, d); r.write(o, d); }; w(0, 0x34); w(1, 0x12); w(2, 0x00); w(3, 0x64); w(4, 0x12); w(5, 0x00); w(6, 0); }      // plays 0x1234 .. 0x1264
        if (n == 30)   { auto w = [&](int o, int d) { wr(o, d); r.write(o, d); }; w(6, 0); }                                                     // go while playing: ignored
        if (n == 200)  { auto w = [&](int o, int d) { wr(o, d); r.write(o, d); }; w(0, 0x00); w(1, 0x00); w(2, 0x01); w(3, 0xff); w(4, 0xff); w(5, 0x01); w(6, 0); }  // plays 0x10000 .. 0x1ffff
        if (n == 1500) { t->i_bank = 1; bank = 1; auto w = [&](int o, int d) { wr(o, d); r.write(o, d); }; w(0, 0x00); w(1, 0x00); w(2, 0x00); w(3, 0x10); w(4, 0x00); w(5, 0x00); w(6, 0); }
        if (n == 1900) { auto w = [&](int o, int d) { wr(o, d); r.write(o, d); }; w(6, 0); w(0, 0x10); w(3, 0x08); w(6, 0); }      // go (restart the same, if idle), then start >= end
        if (n == 2500) { t->i_reset_w = 1; tick(); t->i_reset_w = 0; r.reset(); }
        if (n == 3000) { auto w = [&](int o, int d) { wr(o, d); r.write(o, d); }; w(0, 0x00); w(1, 0x00); w(2, 0x0f); w(3, 0xff); w(4, 0xff); w(5, 0x0f); w(6, 0); }   // runs into the end of the bank
        clocks(6000 - 20 + 0);
        // the RTL's VCK is a free-running 6000-clock divider: sample after its tick
        r.vck(bank);
        clocks(0);
        // let the RTL finish the VCK step, then compare
        clocks(20);
        check("after vck");
    }
    printf("es8712 bench: %d VCKs, %d mismatches\n", n, errs);
    delete t;
    return errs ? 1 : 0;
}

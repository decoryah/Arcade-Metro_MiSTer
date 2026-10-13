// Unit bench of rtl/metro_roz.sv (the v2 engine): loads a frame of MAME's 053936 state (tools/lua/vstate.lua VS_ROZ=1: <prefix>.<frame>.roz = 16 control words, 2048 line RAM
// words, 131072 tile map RAM words, all big endian) and the 2 MB tile ROM, renders the 224 rows the way the video chip's renderer would ask for them and writes them as
// 224 x 304 uint16 palette indices (0xFFFF = not drawn) for tools/metro_roz.py's reference to be compared with.  The graphics stream is a model: one request at a time, a
// latency in clocks to the first word, then a word a clock.  Grand Striker 2's tile ROM is stored the way metro_loader.sv stores it (tile rows in raster order).
//
//   Vmetro_roz <frame.roz> <gfx2.bin> <out.bin> [latency [bt]]      (bt = 1: Blazing Tornado's plane; the engine's parameter i_bt is driven from it)
#include "Vmetro_roz.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <cstring>

static std::vector<uint8_t> readfile(const char* p) {
    FILE* f = fopen(p, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p); exit(2); }
    std::vector<uint8_t> v;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) v.insert(v.end(), buf, buf + n);
    fclose(f);
    return v;
}

int main(int argc, char** argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s frame.roz gfx2.bin out.bin [latency [bt]]\n", argv[0]); return 2; }
    const int lat = argc > 4 ? atoi(argv[4]) : 20;
    const int bt  = argc > 5 ? atoi(argv[5]) : 0;
    std::vector<uint8_t> roz = readfile(argv[1]);
    std::vector<uint8_t> raw = readfile(argv[2]);
    // the stream's memory: the tile ROM (permuted for Grand Striker 2) at GFX2, the map RAM at MAP
    const uint32_t GFX2 = 0x100000, MAP = 0x400000;
    std::vector<uint8_t> mem(0x600000, 0);
    for (size_t i = 0; i < raw.size() && i < 0x200000; i++) {
        size_t a = bt ? i : ((i & ~0xFFu) | (i & 0x80) | ((i >> 3 & 7) << 4) | ((i >> 6 & 1) << 3) | (i & 7));
        mem[GFX2 + a] = raw[i];
    }
    auto be16 = [&](size_t byteoff) { return (uint16_t)((roz[byteoff] << 8) | roz[byteoff + 1]); };
    uint16_t ctrl[16], line[2048];
    for (int i = 0; i < 16; i++) ctrl[i] = be16(i * 2);
    for (int i = 0; i < 2048; i++) line[i] = be16(32 + i * 2);
    for (int i = 0; i < 131072 * 2; i++) mem[MAP + i] = roz[32 + 4096 + i];

    Verilated::commandArgs(argc, argv);
    Vmetro_roz* t = new Vmetro_roz;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    for (int i = 0; i < 16; i++) t->i_ctrl[i] = ctrl[i];
    t->i_en = 1; t->i_bt = bt; t->reset = 1; t->i_frame = 0; t->i_rows_used = 0; t->i_rd_bank = 0; t->i_rd_x = 0;
    t->i_rq_wr = 0; t->i_rq_idx = 0; t->i_rq_data = 0; t->i_rq_ack = 0; t->i_li_q = 0;
    t->i_map_base = MAP; t->i_gfx2_base = GFX2; t->i_inval = 0; t->i_inval_addr = 0;
    for (int i = 0; i < 4; i++) tick();
    t->reset = 0;
    for (int i = 0; i < 4; i++) tick();
    t->i_frame = 1; tick(); t->i_frame = 0;

    std::vector<uint16_t> out(224 * 304, 0xFFFF);
    // the stream model
    int st_wait = -1, st_idx = -1, st_words = 0;
    uint32_t st_addr = 0;
    int rows_read = 0;
    long clocks = 0, reqs = 0, map_reqs = 0, busy = 0;
    auto stream = [&]() {
        t->i_rq_wr = 0; t->i_rq_ack = 0;
        if (t->o_rq_req) {
            busy++;
            if (st_idx < 0 && st_wait < 0) { st_wait = lat; st_addr = t->o_rq_addr; st_words = t->o_rq_len / 2; }
            if (st_idx < 0) {
                if (st_wait == 0) { st_idx = 0; st_wait = -1; reqs++; if (st_words == 32) map_reqs++; }
                else st_wait--;
            }
            if (st_idx >= 0) {
                if (st_idx < st_words) {
                    uint32_t a = st_addr + st_idx * 2;
                    t->i_rq_wr = 1; t->i_rq_idx = st_idx;
                    t->i_rq_data = (uint16_t)((mem[a] << 8) | mem[a + 1]);
                    if (st_idx == st_words - 1) { t->i_rq_ack = 1; st_idx = -1; }
                    else st_idx++;
                }
            }
        } else { st_idx = -1; st_wait = -1; }
    };
    while (rows_read < 224 && clocks < 200000000L) {
        t->i_li_q = line[t->o_li_addr & 0x7FF];             // line RAM: registered read of the address as of the last edge
        stream();
        t->i_rows_used = (uint16_t)rows_read;               // the renderer has started every row that is done (the engine runs up to six rows ahead of that)
        tick();
        clocks++;
        if (t->o_rows_done > rows_read) {                   // read a finished row's 304 pens
            int r = rows_read;
            t->i_rd_bank = r & 7;
            for (int x = 0; x < 304; x++) {
                t->i_rd_x = x;
                stream();
                t->i_li_q = line[t->o_li_addr & 0x7FF];
                tick();
                clocks++;
                out[r * 304 + x] = t->o_op ? (uint16_t)t->o_pen : 0xFFFF;      // the buffer's read is registered: the pen of i_rd_x is there after the edge
            }
            rows_read++;
        }
    }
    printf("rows %d, clocks %ld, stream requests %ld (map windows %ld), %.0f clocks a row\n", rows_read, clocks, reqs, map_reqs, rows_read ? (double)clocks / rows_read : 0.0);
    FILE* f = fopen(argv[3], "wb");
    fwrite(out.data(), 2, out.size(), f);
    fclose(f);
    delete t;
    return rows_read == 224 ? 0 : 1;
}

// Unit bench of rtl/metro_crtadj.sv (+ modules/crt_adjust/crt_adjust.sv): the video chip's raster (392 x 263 dots of 16 clocks, a 320 x 224 picture) goes in, the stream that comes out is measured
// (run_crtadj.sh).  Every picture dot carries its x (red, green bit 0) and its line (blue), so the content can be followed through the buffer.
//   off            : the output equals the input in every clock;
//   on, 0 / 0 / 0  : the same picture, every dot once and in order, one line later, the line length unchanged (6272 clocks), the horizontal sync as long as before;
//   H-Size n       : every dot lasts 16 + n/4 clocks, the picture is 320 dots wide and starts where it started (the sync comes 32 dots after the picture: a bigger picture than +6 would run into it);
//   H-Position n   : the picture starts n dots (of its own length) later / earlier;
//   V-Shift n      : the vertical sync comes n lines later / earlier;
//   the OSD window : starts where the native picture starts, whatever H-Position says.
#include "Vmetro_crtadj.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <cstdint>

static Vmetro_crtadj* t;
static long long clk_n = 0;

struct Cfg { int on, hsize, hpos, vshift; int pdot; };
struct Sample { long long clk; int ce, hb, vb, hs, vs, de, rgb; };

static const int HT = 392, VT = 263, PIX0 = 0, ACT = 320, VACT = 224;      // the chip's raster: picture dots 0..319, the sync at 352..383 (P_HS_BEG / P_HS_END)

// the input raster at clock n: dot / line from the counter
struct Raster {
    int dot = 0, line = 0, sub = 0;
    void step() { if (++sub == 16) { sub = 0; if (++dot == HT) { dot = 0; if (++line == VT) line = 0; } } }
    bool ce() const { return sub == 0; }
    bool hblank() const { return !(dot >= PIX0 && dot < PIX0 + ACT); }
    bool vblank() const { return line >= VACT; }
    bool hs() const { return dot >= 352 && dot < 384; }
    bool vs() const { return line >= 232 && line < 236; }
    int rgb() const { int a = dot - PIX0; return ((a & 0xFF) << 16) | (((a >> 8) & 1) << 8) | (line & 0xFF); }
};

static std::vector<Sample> run(const Cfg& c, int frames, bool check_off) {
    std::vector<Sample> out;
    Raster r;
    clk_n = 0;
    int bad = 0;
    t->i_on = c.on; t->i_hsize_f = c.hsize & 31; t->i_hpos_f = c.hpos >= 0 ? c.hpos : 97 + c.hpos; t->i_vshift_f = c.vshift & 31; t->i_pdot = c.pdot;
    long long total = (long long)frames * VT * HT * 16;
    for (long long n = 0; n < total; n++) {
        t->i_ce = r.ce(); t->i_hblank = r.hblank(); t->i_vblank = r.vblank(); t->i_hs = r.hs(); t->i_vs = r.vs(); t->i_rgb = r.rgb();
        t->clk = 0; t->eval();            // the outputs of this clock, before its edge: what a consumer's flip-flop captures at the edge (arcade_video samples like this)
        if (check_off) {
            if ((int)t->o_ce != (int)r.ce() || (int)t->o_hblank != (int)r.hblank() || (int)t->o_vblank != (int)r.vblank() || (int)t->o_hs != (int)r.hs() || (int)t->o_vs != (int)r.vs() ||
                (int)t->o_rgb != r.rgb()) bad++;
        }
        if (t->o_ce) out.push_back({clk_n, 1, t->o_hblank, t->o_vblank, t->o_hs, t->o_vs, t->o_de_osd, (int)t->o_rgb});
        t->clk = 1; t->eval();
        r.step(); clk_n++;
    }
    if (check_off) { Sample s{}; s.clk = bad; s.rgb = -1; out.push_back(s); }
    return out;
}

struct Meas {
    int lines = 0;                      // complete lines measured
    double line_clk = 0;                // clocks from one horizontal sync rise to the next
    double hs_clk = 0;                  // clocks the horizontal sync lasts
    int act = 0;                        // picture dots of a line (must be 320)
    double dot_clk = 0;                 // clocks per picture dot
    long long first_clk = 0;            // clocks from the horizontal sync rise to the first picture dot
    int order_ok = 1;                   // the picture dots of every line are 0 .. 319 in order and from one source line
    long long vs_clk = 0;               // clock of the first vertical sync rise after the frame 2 starts
    long long de_first = 0;             // clocks from the horizontal sync rise to the OSD window's rise
};

static Meas measure(const std::vector<Sample>& s) {
    Meas m;
    // find horizontal sync rises (in the o_ce sampled stream)
    std::vector<size_t> hsr;
    for (size_t i = 1; i < s.size(); i++) if (s[i].hs && !s[i - 1].hs) hsr.push_back(i);
    // use the lines well inside frame 3
    size_t lstart = 0;
    for (size_t k = 0; k + 1 < hsr.size(); k++) {
        long long c0 = s[hsr[k]].clk;
        if (c0 < 3LL * VT * HT * 16 + 40LL * HT * 16) continue;
        lstart = k; break;
    }
    int n = 0; double lsum = 0, hsum = 0, dsum = 0; long long fsum = 0, desum = 0; long long dcount = 0;
    for (size_t k = lstart; k + 1 < hsr.size() && n < 120; k++) {
        size_t a = hsr[k], b = hsr[k + 1];
        long long c0 = s[a].clk, c1 = s[b].clk;
        if (c1 - c0 != 6272 && !(c1 - c0 > 0)) continue;
        // active (in both blankings) samples between the two rises
        int cnt = 0; long long first = -1, last = -1; int expect = 0; int srcline = -1;
        long long de0 = -1;
        for (size_t i = a; i < b; i++) {
            if (s[i].de && de0 < 0) de0 = s[i].clk;
            if (!s[i].hb && !s[i].vb) {
                int x = ((s[i].rgb >> 16) & 0xFF) | (((s[i].rgb >> 8) & 1) << 8), ln = s[i].rgb & 0xFF;
                if (first < 0) { first = s[i].clk; if (x != 0) m.order_ok = 0; }
                if (x != expect) m.order_ok = 0;
                if (srcline < 0) srcline = ln; else if (ln != srcline) m.order_ok = 0;
                expect = x + 1; last = s[i].clk; cnt++;
            }
        }
        if (cnt == 0) continue;               // a blanked line
        n++; lsum += c1 - c0; hsum += 0; fsum += first - c0; desum += (de0 >= 0 ? de0 - c0 : -1);
        m.act = cnt; dsum += (double)(last - first) / (cnt - 1); dcount++;
        // horizontal sync length
        size_t j = a; while (j < b && s[j].hs) j++;
        hsum += (double)(s[j].clk - c0);
    }
    if (n) { m.lines = n; m.line_clk = lsum / n; m.hs_clk = hsum / n; m.dot_clk = dsum / dcount; m.first_clk = fsum / n; m.de_first = desum / n; }
    // vertical sync rise in frame 3 (relative to the frame's start)
    for (size_t i = 1; i < s.size(); i++) if (s[i].vs && !s[i - 1].vs && s[i].clk >= 3LL * VT * HT * 16) { m.vs_clk = s[i].clk - 3LL * VT * HT * 16; break; }
    return m;
}

static int fails = 0;
static void check(const char* what, bool ok, const char* fmt = "", double a = 0, double b = 0) {
    printf("  %-62s %s", what, ok ? "ok" : "FAIL");
    if (fmt[0]) printf("   ("), printf(fmt, a, b), printf(")");
    printf("\n");
    if (!ok) fails++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vmetro_crtadj;
    t->clk = 0;
    for (int i = 0; i < 4; i++) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
    const int F = 5;

    printf("off (bit-exact pass-through):\n");
    { auto s = run({0, 0, 0, 0, 16}, 2, true); check("every output equals its input in every clock", s.back().clk == 0, "%g mismatches", (double)s.back().clk); }

    printf("on, 0 / 0 / 0:\n");
    Meas b0;
    { auto s = run({1, 0, 0, 0, 16}, F, false); b0 = measure(s);
      check("line length 6272 clocks", b0.line_clk == 6272, "%g", b0.line_clk);
      check("320 picture dots, in order, from one source line", b0.act == 320 && b0.order_ok, "%d dots", b0.act);
      check("every dot lasts 16 clocks", b0.dot_clk == 16.0, "%g", b0.dot_clk);
      check("the horizontal sync is 32 dots long (512 clocks)", b0.hs_clk >= 512 - 16 && b0.hs_clk <= 512 + 16, "%g", b0.hs_clk);
      printf("    (measured: first dot %lld clocks after the sync rise, vertical sync %lld clocks into the frame, OSD window %lld)\n", b0.first_clk, b0.vs_clk, b0.de_first); }

    printf("H-Size:\n");
    for (int hs : {4, -8, -16}) {
        auto s = run({1, hs, 0, 0, 16}, F, false); Meas m = measure(s);
        char w[80]; snprintf(w, sizeof w, "H-Size %+d: 320 dots, every dot %.2f clocks, the line is still 6272", hs, 16 + hs / 4.0);
        double exp = 16 + hs / 4.0;
        check(w, m.act == 320 && m.order_ok && m.line_clk == 6272 && m.dot_clk > exp - 0.3 && m.dot_clk < exp + 0.3, "dot %.3f, line %g", m.dot_clk, m.line_clk);
        char w2[90]; snprintf(w2, sizeof w2, "H-Size %+d: the picture starts the same number of dots after the sync", hs);
        double exp0 = b0.first_clk / 16.0 * exp;
        check(w2, m.first_clk > exp0 - 24 && m.first_clk < exp0 + 24, "start %g clocks, expected %.0f", (double)m.first_clk, exp0);
    }

    printf("H-Position:\n");
    for (int hp : {16, 30, -4, -8}) {
        auto s = run({1, 0, hp, 0, 16}, F, false); Meas m = measure(s);
        char w[80]; snprintf(w, sizeof w, "H-Position %+d: starts %+d dots (%+d clocks) from where it started", hp, hp, hp * 16);
        check(w, m.act == 320 && m.order_ok && m.line_clk == 6272 && labs((m.first_clk - b0.first_clk) - hp * 16) <= 16, "moved %g clocks", (double)(m.first_clk - b0.first_clk));
        char w2[80]; snprintf(w2, sizeof w2, "H-Position %+d: the OSD window starts where it did", hp);
        check(w2, labs(m.de_first - b0.de_first) <= 16, "window %g, was %g", (double)m.de_first, (double)b0.de_first);
    }

    if (getenv("CRTDBG")) {
        auto s = run({1, 0, 0, 5, 16}, F, false);
        int k = 0;
        for (size_t i = 1; i < s.size() && k < 12; i++) if (s[i].vs != s[i - 1].vs) { printf("    vs %d at clk %lld (line %.2f of frame %lld)\n", s[i].vs, s[i].clk, (double)(s[i].clk % ((long long)VT * HT * 16)) / 6272.0, s[i].clk / ((long long)VT * HT * 16)); k++; }
    }
    printf("the frame:\n");
    for (auto cf : {Cfg{1, 0, 0, 0, 16}, Cfg{1, -6, 8, 3, 16}, Cfg{1, -12, -4, -2, 16}, Cfg{1, 0, 0, 23, 16}, Cfg{1, 0, 0, -8, 16}}) {
        auto s = run(cf, 7, false);
        std::vector<long long> vsr; std::vector<size_t> vsi; std::vector<int> hsn;
        int hsc = 0;
        for (size_t i = 1; i < s.size(); i++) {
            if (s[i].hs && !s[i - 1].hs) hsc++;
            if (s[i].vs && !s[i - 1].vs) { vsr.push_back(s[i].clk); hsn.push_back(hsc); hsc = 0; }
        }
        bool ok = vsr.size() >= 4; long long mn = 1LL << 60, mx = 0; int hmn = 1 << 30, hmx = 0;
        for (size_t k = 2; k + 1 < vsr.size(); k++) { long long p = vsr[k + 1] - vsr[k]; if (p < mn) mn = p; if (p > mx) mx = p; if (hsn[k + 1] < hmn) hmn = hsn[k + 1]; if (hsn[k + 1] > hmx) hmx = hsn[k + 1]; }
        char w[100]; snprintf(w, sizeof w, "H-Size %+d H-Position %+d V-Shift %+d: every frame is 263 lines of 6272 clocks", cf.hsize, cf.hpos, cf.vshift);
        ok = ok && mn == 263LL * 6272 && mx == 263LL * 6272 && hmn == 263 && hmx == 263;
        check(w, ok, "vertical sync period %g..%g clocks, %g horizontal syncs", (double)mn, (double)hmn);
    }
    printf("the picture lines of a frame (the vertical blanking changes at the first dot of a line, as the re-timer's does):\n");
    for (auto cf : {Cfg{1, 0, 0, 0, 16}, Cfg{1, -6, 8, 3, 16}, Cfg{1, 4, -4, -2, 16}}) {
        auto s = run(cf, 6, false);
        // lines = intervals between horizontal sync rises of frame 4; count the picture dots of each
        std::vector<int> per; int cnt = 0; bool started = false; long long f4 = 4LL * VT * HT * 16, f5 = 5LL * VT * HT * 16;
        for (size_t i = 1; i < s.size(); i++) {
            if (s[i].clk < f4 || s[i].clk >= f5) continue;
            if (s[i].hs && !s[i - 1].hs) { if (started) per.push_back(cnt); started = true; cnt = 0; }
            if (started && !s[i].hb && !s[i].vb) cnt++;
        }
        int full = 0, none = 0, part = 0, first_part = -1;
        for (size_t k = 0; k < per.size(); k++) { if (per[k] == 320) full++; else if (per[k] == 0) none++; else { part++; if (first_part < 0) first_part = per[k]; } }
        if (getenv("CRTDBG")) {
            std::vector<int> srcl; int last = -1;
            for (size_t i = 1; i < s.size(); i++) { if (s[i].clk < f4 || s[i].clk >= f5) continue; if (!s[i].hb && !s[i].vb) { int ln = s[i].rgb & 0xFF; if (ln != last) { srcl.push_back(ln); last = ln; } } }
            printf("    source lines shown (%zu): first %d %d %d ... last %d %d %d\n", srcl.size(), srcl.size() > 0 ? srcl[0] : -1, srcl.size() > 1 ? srcl[1] : -1, srcl.size() > 2 ? srcl[2] : -1,
                   srcl.size() > 2 ? srcl[srcl.size() - 3] : -1, srcl.size() > 1 ? srcl[srcl.size() - 2] : -1, srcl.size() > 0 ? srcl.back() : -1);
        }
        char w[100]; snprintf(w, sizeof w, "H-Size %+d H-Position %+d V-Shift %+d: 224 lines of 320 dots, the others empty", cf.hsize, cf.hpos, cf.vshift);
        check(w, full == 224 && part == 0 && none == (int)per.size() - 224, "%g full, partial %g", (double)full, (double)part);
    }
    printf("V-Shift:\n");
    for (int vs : {5, 15, 23, -5, -8}) {
        auto s = run({1, 0, 0, vs, 16}, F, false); Meas m = measure(s);
        char w[80]; snprintf(w, sizeof w, "V-Shift %+d: the vertical sync is %+d lines (%+d clocks) away", vs, vs, vs * 6272);
        long long d = m.vs_clk - b0.vs_clk;
        check(w, labs(d - (long long)vs * 6272) <= 16 && m.act == 320 && m.line_clk == 6272, "moved %g clocks", (double)d);
    }

    printf("the other dot lengths (the re-timed boards: 14 and 12 clocks):\n");
    for (int pd : {14, 12}) {
        // the raster of the bench is a 16-clock one, so the dot length of the read side is what is checked: base = 4 * pdot quarters
        auto s = run({1, 0, 0, 0, pd}, F, false); Meas m = measure(s);
        char w[80]; snprintf(w, sizeof w, "pdot %d, H-Size 0: every dot lasts %d clocks", pd, pd);
        check(w, m.act == 320 && m.order_ok && m.dot_clk > pd - 0.3 && m.dot_clk < pd + 0.3, "dot %g", m.dot_clk);
    }

    printf(fails ? "crtadj bench: %d FAILURES\n" : "crtadj bench: all ok (%d failures)\n", fails);
    delete t;
    return fails ? 1 : 0;
}

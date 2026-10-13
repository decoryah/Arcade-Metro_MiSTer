// C++ driver of tb_ymf_top: +LOG=<time port data lines> +OUT=<samples file> +SECONDS=<n> +LAT=<memory latency in clocks>
#include "Vtb_ymf_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
struct Ev { long long t; int port; int data; };
static const char* plusarg(int argc, char** argv, const char* key) {
    size_t n = strlen(key);
    for (int i = 1; i < argc; i++) if (strncmp(argv[i], key, n) == 0) return argv[i] + n;
    return nullptr;
}
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_ymf_top* t = new Vtb_ymf_top;
    const char* logf = plusarg(argc, argv, "+LOG=");
    const char* outf = plusarg(argc, argv, "+OUT=");
    const char* sec = plusarg(argc, argv, "+SECONDS=");
    const char* lat = plusarg(argc, argv, "+LAT=");
    double secs = sec ? atof(sec) : 30.0;
    t->lat = lat ? atoi(lat) : 12;
    std::vector<Ev> ev;
    if (logf) {
        FILE* f = fopen(logf, "r");
        if (!f) { fprintf(stderr, "no log\n"); return 1; }
        char line[256];
        while (fgets(line, sizeof line, f)) {
            for (char* p = line; *p; p++) if (*p == ',') *p = '.';
            double tm; int port, data;
            if (sscanf(line, "%lf %d %x", &tm, &port, &data) == 3) ev.push_back({(long long)(tm * 96e6), port, data});
        }
        fclose(f);
    }
    FILE* out = fopen(outf ? outf : "ymf_out.txt", "w");
    long long total = (long long)(secs * 96e6);
    t->clk = 0; t->rst = 1; t->wr = 0; t->rd = 0; t->a = 0; t->d = 0;
    for (int i = 0; i < 20; i++) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
    t->rst = 0;
    size_t ei = 0;
    double next_s = 0.0, per = 96e6 / 44100.0;
    long long stalls = 0;
    for (long long c = 0; c < total; c++) {
        t->wr = 0;
        if (ei < ev.size() && ev[ei].t <= c) { t->wr = 1; t->a = ev[ei].port; t->d = ev[ei].data; ei++; }
        t->clk = 0; t->eval(); t->clk = 1; t->eval();
        if (t->stall) stalls++;
        if ((double)c >= next_s) { fprintf(out, "%d\n", (int)(short)t->audio); next_s += per; }
    }
    fprintf(stderr, "done: %zu of %zu events, %lld stalled clocks (%.3f %%)\n", ei, ev.size(), stalls, 100.0 * stalls / total);
    fclose(out);
    delete t;
    return 0;
}

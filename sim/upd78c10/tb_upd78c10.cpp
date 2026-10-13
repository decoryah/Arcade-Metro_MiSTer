// Driver of tb_upd78c10_top: applies the scripted sound commands at instruction boundaries and stops after <max states>.
//   Vtb_upd78c10_top +ROM=<hex> +TRACE=<out> +EVENTS=<events.txt or -> +MAXSTATES=<n>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "Vtb_upd78c10_top.h"
#include "verilated.h"

static Vtb_upd78c10_top* t;
static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }

static const char* plusarg(int argc, char** argv, const char* key) {
    size_t k = strlen(key);
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], key, k)) return argv[i] + k;
    return nullptr;
}

struct Event { unsigned long long t; unsigned v; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* evf = plusarg(argc, argv, "+EVENTS=");
    const char* ms = plusarg(argc, argv, "+MAXSTATES=");
    unsigned long long max_states = ms ? strtoull(ms, nullptr, 10) : 1000000ULL;
    std::vector<Event> ev, irq;
    if (evf && strcmp(evf, "-")) {
        FILE* f = fopen(evf, "r");
        if (!f) { fprintf(stderr, "cannot open %s\n", evf); return 1; }
        char kind[16]; unsigned long long tt; unsigned v;
        while (fscanf(f, "%llu %15s %x", &tt, kind, &v) == 3) { if (!strcmp(kind, "cmd")) ev.push_back({tt, v}); else if (!strcmp(kind, "irq2")) irq.push_back({tt, v}); }
        fclose(f);
    }
    t = new Vtb_upd78c10_top;
    t->ym2151 = plusarg(argc, argv, "+YM2151") ? 1 : 0; t->ev_irq2_set = 0; t->ev_irq2_lvl = 0;
    t->ev_apply = 0; t->ev_data = 0; t->reset = 1; t->clk = 0; t->eval();
    for (int i = 0; i < 40; i++) tick();
    t->reset = 0;
    size_t next = 0, next_irq = 0;
    long long cycles = 0, last_report = 0;
    while (true) {
        t->ev_apply = 0; t->ev_irq2_set = 0;
        if (t->trc_stb) {
            if (t->dbg_t >= max_states) break;
            bool any = false; unsigned v = 0;
            while (next < ev.size() && t->dbg_t >= ev[next].t) { v = ev[next].v; any = true; next++; }
            if (any) { t->ev_apply = 1; t->ev_data = v; }
            if (next_irq < irq.size() && t->dbg_t >= irq[next_irq].t) { t->ev_irq2_set = 1; t->ev_irq2_lvl = irq[next_irq].v ? 1 : 0; next_irq++; }
        }
        tick();
        cycles++;
        if (cycles - last_report >= 50000000LL) { last_report = cycles; fprintf(stderr, "  ... %lld clocks, %llu states\n", cycles, (unsigned long long)t->dbg_t); }
    }
    fprintf(stderr, "done: %llu states, %lld clocks, illegal=%d\n", (unsigned long long)t->dbg_t, cycles, (int)t->dbg_illegal);
    t->final();
    delete t;
    return 0;
}

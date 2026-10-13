// Driver of tb_metro_sound_top: streams the MRA image through the loader, then plays the sound commands of a recorded session ("<state> cmd <byte>" lines, from tools/lua/ainput.lua's log
// of exact simulated times: T = seconds * 4e6; the sound CPU runs at 4 MHz = 24 clocks of the 96 MHz clock per state)
// and writes the board's mono output sampled at 48 kHz as a 16-bit WAV.
//   Vtb_metro_sound_top +IMAGE=<image> +EVENTS=<ainput log> +SECONDS=<n> +WAV=<out.wav>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "Vtb_metro_sound_top.h"
#include "verilated.h"

static Vtb_metro_sound_top* t;
static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
static const char* plusarg(int argc, char** argv, const char* key) {
    size_t k = strlen(key);
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], key, k)) return argv[i] + k;
    return nullptr;
}
struct Event { long long clk; unsigned v; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* img = plusarg(argc, argv, "+IMAGE="); const char* evf = plusarg(argc, argv, "+EVENTS=");
    const char* secs = plusarg(argc, argv, "+SECONDS="); const char* wavf = plusarg(argc, argv, "+WAV=");
    double seconds = secs ? atof(secs) : 10.0;
    if (!img || !wavf) { fprintf(stderr, "usage: +IMAGE= +EVENTS= +SECONDS= +WAV=\n"); return 2; }
    std::vector<Event> ev;
    if (evf) {
        FILE* f = fopen(evf, "r");
        if (!f) { fprintf(stderr, "cannot open %s\n", evf); return 1; }
        unsigned long long st; char kind[16]; unsigned v;
        while (fscanf(f, "%llu %15s %x", &st, kind, &v) == 3) if (!strcmp(kind, "cmd")) ev.push_back({(long long)(st * 24LL), v});   // T states -> clocks
        fclose(f);
    }
    FILE* fi = fopen(img, "rb");
    if (!fi) { fprintf(stderr, "cannot open %s\n", img); return 1; }
    std::vector<unsigned char> buf;
    { unsigned char tmp[65536]; size_t n; while ((n = fread(tmp, 1, sizeof tmp, fi)) > 0) buf.insert(buf.end(), tmp, tmp + n); }
    fclose(fi);

    t = new Vtb_metro_sound_top;
    t->cmd_wr = 0; t->cmd = 0; t->ioctl_download = 0; t->ioctl_wr = 0; t->ioctl_addr = 0; t->ioctl_dout = 0;
    t->reset = 1; t->clk = 0; t->eval();
    for (int i = 0; i < 64; i++) tick();
    t->reset = 0;
    for (int i = 0; i < 100000 && !t->sdr_ready; i++) tick();
    printf("SDRAM ready=%d, image %zu bytes\n", (int)t->sdr_ready, buf.size()); fflush(stdout);
    t->ioctl_download = 1;
    for (size_t a = 0; a < buf.size(); ) {
        if (!t->dl_busy_o) { t->ioctl_addr = (uint32_t)a; t->ioctl_dout = buf[a]; t->ioctl_wr = 1; tick(); t->ioctl_wr = 0; tick(); a++; }
        else tick();                                                // the controller's back-pressure, as hps_io honours it
    }
    t->ioctl_download = 0;
    for (int i = 0; i < 400000; i++) tick();
    printf("download done\n"); fflush(stdout);

    // time 0 of the session: the sound board leaves reset
    for (int i = 0; i < 2000000 && t->snd_rst; i++) tick();
    long long now = 0;
    long long total = (long long)(seconds * 96000000.0);
    std::vector<int16_t> pcm, pcm_ym, pcm_oki;
    size_t next = 0, late = 0;
    int div = 0;
    while (now < total) {
        t->cmd_wr = 0;
        // closed loop like the game: the 68000 polls IN0's busy bit and writes the next byte only when the sound CPU has cleared it, so a command waits for its
        // recorded time AND for busy low (open-loop replay desynchronised the message parser whenever this CPU was a little slower than MAME's in some phase)
        if (next < ev.size() && now >= ev[next].clk && !t->busy) { t->cmd_wr = 1; t->cmd = ev[next].v; next++; if (now > ev[next - 1].clk + 96000) late++; }
        tick(); now++;
        if (++div == 2000) { div = 0; pcm.push_back((int16_t)t->audio); pcm_ym.push_back((int16_t)t->dbg_ym); pcm_oki.push_back((int16_t)t->dbg_oki); }
        if (now % 200000000LL == 0) { printf("  ... %.1f s, illegal=%d\n", now / 96e6, (int)t->dbg_illegal); fflush(stdout); }
    }
    printf("done: %zu samples, %zu commands, illegal=%d\n", pcm.size(), next, (int)t->dbg_illegal);
    FILE* fo = fopen(wavf, "wb");
    unsigned dataBytes = (unsigned)(pcm.size() * 2), rate = 48000, byteRate = rate * 2, riff = 36 + dataBytes;
    unsigned short fmt = 1, ch = 1, align = 2, bits = 16; unsigned fmtLen = 16;
    fwrite("RIFF", 1, 4, fo); fwrite(&riff, 4, 1, fo); fwrite("WAVEfmt ", 1, 8, fo); fwrite(&fmtLen, 4, 1, fo);
    fwrite(&fmt, 2, 1, fo); fwrite(&ch, 2, 1, fo); fwrite(&rate, 4, 1, fo); fwrite(&byteRate, 4, 1, fo); fwrite(&align, 2, 1, fo); fwrite(&bits, 2, 1, fo);
    fwrite("data", 1, 4, fo); fwrite(&dataBytes, 4, 1, fo); fwrite(pcm.data(), 2, pcm.size(), fo);
    fclose(fo);
    // the unmixed chips as a stereo WAV (left = YM2413 accumulator, right = OKI), <out>.stems.wav
    std::string sf = std::string(wavf) + ".stems.wav";
    fo = fopen(sf.c_str(), "wb");
    {
        unsigned db = (unsigned)(pcm.size() * 4), br = rate * 4, rf = 36 + db; unsigned short c2 = 2, al = 4;
        fwrite("RIFF", 1, 4, fo); fwrite(&rf, 4, 1, fo); fwrite("WAVEfmt ", 1, 8, fo); fwrite(&fmtLen, 4, 1, fo);
        fwrite(&fmt, 2, 1, fo); fwrite(&c2, 2, 1, fo); fwrite(&rate, 4, 1, fo); fwrite(&br, 4, 1, fo); fwrite(&al, 2, 1, fo); fwrite(&bits, 2, 1, fo);
        fwrite("data", 1, 4, fo); fwrite(&db, 4, 1, fo);
        for (size_t i = 0; i < pcm.size(); i++) { fwrite(&pcm_ym[i], 2, 1, fo); fwrite(&pcm_oki[i], 2, 1, fo); }
    }
    fclose(fo);
    t->final();
    delete t;
    return 0;
}

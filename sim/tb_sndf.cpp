// Driver of tb_sndf_top: streams the image through the loader, then plays the sound commands of a recorded session (lines "frame n byte seconds", the seconds with
// a decimal comma or point; tools/lua/fsnd.lua) at their times (96 MHz clocks) and writes the board's mono output sampled at 48 kHz as a 16-bit WAV.
//   Vtb_sndf_top +IMAGE=<image> +EVENTS=<log> +SECONDS=<n> +WAV=<out.wav>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "Vtb_sndf_top.h"
#include "verilated.h"

static Vtb_sndf_top* t;
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
        char line[256];
        while (fgets(line, sizeof line, f)) {
            unsigned fr, n, v; char ts[64];
            if (sscanf(line, "%u %u %x %63s", &fr, &n, &v, ts) == 4) {
                for (char* p = ts; *p; p++) if (*p == ',') *p = '.';
                // MAME's time is the machine's (the Z80 starts at 0); here `now` starts 400,000 clocks after the board left reset (the drain wait below) and the Z80 itself starts
                // RST_EXTRA = 8191 clocks after that: a command at MAME time t is due at now = t - 400000 + 8191.  (Without this every command came 4.17 ms late: the first
                // difference from MAME's YM2610 writes of a Blazing Tornado session was a command landing after a timer interrupt instead of before it.)
                long long due = (long long)(atof(ts) * 96000000.0) - 400000 + 8191;
                if (due < 0) due = 0;
                ev.push_back({due, v});
            }
        }
        fclose(f);
    }
    FILE* fi = fopen(img, "rb");
    if (!fi) { fprintf(stderr, "cannot open %s\n", img); return 1; }
    std::vector<unsigned char> buf;
    { static unsigned char tmp[1 << 20]; size_t n; while ((n = fread(tmp, 1, sizeof tmp, fi)) > 0) buf.insert(buf.end(), tmp, tmp + n); }
    fclose(fi);

    t = new Vtb_sndf_top;
    t->cmd_wr = 0; t->cmd = 0; t->ioctl_download = 0; t->ioctl_wr = 0; t->ioctl_addr = 0; t->ioctl_dout = 0;
    t->reset = 1; t->clk = 0; t->eval();
    for (int i = 0; i < 64; i++) tick();
    t->reset = 0;
    for (int i = 0; i < 100000 && !t->sdr_ready; i++) tick();
    printf("SDRAM ready=%d, image %zu bytes, %zu commands\n", (int)t->sdr_ready, buf.size(), ev.size()); fflush(stdout);
    t->ioctl_download = 1;
    for (size_t a = 0; a < buf.size(); ) {
        if (!t->dl_busy_o) { t->ioctl_addr = (uint32_t)a; t->ioctl_dout = buf[a]; t->ioctl_wr = 1; tick(); t->ioctl_wr = 0; tick(); a++; }
        else tick();
    }
    t->ioctl_download = 0;
    for (int i = 0; i < 400000; i++) tick();
    printf("download done\n"); fflush(stdout);
    for (int i = 0; i < 2000000 && t->snd_rst; i++) tick();           // the board leaves reset: time 0 of the session
    long long now = 0, total = (long long)(seconds * 96000000.0);
    std::vector<int16_t> pcm;      // interleaved L, R
    size_t next = 0;
    int div = 0;
    long long ymn = 0;
    while (now < total) {
        t->cmd_wr = 0;
        if (next < ev.size() && now >= ev[next].clk) { t->cmd_wr = 1; t->cmd = ev[next].v; next++; }
        tick(); now++;
        if (++div == 2000) { div = 0; pcm.push_back((int16_t)t->audio); pcm.push_back((int16_t)t->audio_r); }      // 48 kHz
        if (t->audio_valid) ymn++;
        if (now % 96000000LL == 0) { printf("  ... %.0f s, %zu commands, ym samples %lld\n", now / 96e6, next, ymn); fflush(stdout); }
    }
    printf("done: %zu samples (L+R), %zu commands, ym samples %lld\n", pcm.size(), next, ymn);
    FILE* fo = fopen(wavf, "wb");
    unsigned dataBytes = (unsigned)(pcm.size() * 2), rate = 48000, byteRate = rate * 4, riff = 36 + dataBytes;
    unsigned short fmt = 1, ch = 2, align = 4, bits = 16; unsigned fmtLen = 16;
    fwrite("RIFF", 1, 4, fo); fwrite(&riff, 4, 1, fo); fwrite("WAVEfmt ", 1, 8, fo); fwrite(&fmtLen, 4, 1, fo);
    fwrite(&fmt, 2, 1, fo); fwrite(&ch, 2, 1, fo); fwrite(&rate, 4, 1, fo); fwrite(&byteRate, 4, 1, fo); fwrite(&align, 2, 1, fo); fwrite(&bits, 2, 1, fo);
    fwrite("data", 1, 4, fo); fwrite(&dataBytes, 4, 1, fo); fwrite(pcm.data(), 2, pcm.size(), fo);
    fclose(fo);
    t->final();
    delete t;
    return 0;
}

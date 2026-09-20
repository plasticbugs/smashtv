// sim/tb_sound.cpp - replay MAME's command stream into the sound board and
// write what it plays as a 48 kHz WAV.
//   Vtb_sound_top <image.rom> <snd_cmd.txt> <out.wav> <from-seconds> <to-seconds>
// Starting part-way is sound only where the main board resets the sound board
// (it does at 19.128 s in the standard capture): the run begins in reset.
#include "Vtb_sound_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <string>

static const double CLK = 96e6;
static const long SND_B = 0x040000, SND_N = 0x030000;

struct Ev { uint64_t clk; unsigned word; };

int main(int argc, char **argv) {
    if (argc < 6) { fprintf(stderr, "usage: %s rom cmds out.wav from to\n", argv[0]); return 2; }
    double from = atof(argv[4]), to = atof(argv[5]);
    Verilated::commandArgs(argc, argv);
    auto *t = new Vtb_sound_top;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };

    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    std::vector<uint8_t> img(SND_N);
    fseek(f, SND_B, SEEK_SET);
    if (fread(img.data(), 1, SND_N, f) != (size_t)SND_N) { fprintf(stderr, "short image\n"); return 2; }
    fclose(f);

    std::vector<Ev> evs;
    unsigned word = 0x0ff;                      // reset asserted until told otherwise
    f = fopen(argv[2], "r");
    if (!f) { perror(argv[2]); return 2; }
    double s; int frame; unsigned w;
    while (fscanf(f, "%lf %d %x", &s, &frame, &w) == 3) {
        if (s < from) { word = w & 0x3ff; continue; }
        evs.push_back({(uint64_t)((s - from) * CLK), w & 0x3ffu});
    }
    fclose(f);
    if (from > 0) word &= ~0x100u;               // begin held in reset

    t->rst = 1; t->word = word; t->ld_we = 0;
    for (int i = 0; i < 8; i++) tick();
    t->ld_we = 1;
    for (long i = 0; i < SND_N; i++) { t->ld_a = i; t->ld_d = img[i]; tick(); }
    t->ld_we = 0;
    for (int i = 0; i < 8; i++) tick();
    t->rst = 0;

    // Two recordings: `pcm` is what target/pocket/core_top.sv does - the
    // output as it stands every 2000th clock, held - and `avg` is the mean of
    // those 2000 clocks, which is what a recording with no aliasing looks
    // like.  The difference between them is the hand-over's own doing.
    // ROMLOG=<file>: every ROM read's address (u32), to size the cache in
    // front of the sound ROM from what the program really does
    FILE *romlog = getenv("ROMLOG") ? fopen(getenv("ROMLOG"), "wb") : nullptr;
    bool req_d = false;
    std::vector<int16_t> pcm, avg;
    long acc = 0;
    uint64_t total = (uint64_t)((to - from) * CLK);
    size_t e = 0;
    long peak = 0;
    for (uint64_t c = 0; c < total; c++) {
        while (e < evs.size() && evs[e].clk <= c) t->word = evs[e++].word;
        tick();
        if (romlog && t->rom_req_o && !req_d) { uint32_t a = t->rom_addr_o; fwrite(&a, 4, 1, romlog); }
        req_d = t->rom_req_o;
        acc += (int16_t)t->snd;
        if (c % 2000 == 1999) {
            int16_t v = (int16_t)t->snd;         // signed: Verilator hands it over unsigned
            pcm.push_back(v);
            avg.push_back((int16_t)(acc / 2000)); acc = 0;
            if (labs(v) > peak) peak = labs(v);
        }
        if (c % (uint64_t)(CLK * 2) == 0 && c)
            fprintf(stderr, "  %.0f s  pc %04x  peak %ld  stalls %u\n",
                    from + c / CLK, t->pc, peak, t->stalls);
    }
    printf("%zu commands applied, peak %ld, ROM stalls %u\n", e, peak, t->stalls);

    auto wav = [](const std::string &name, const std::vector<int16_t> &d) {
        FILE *f = fopen(name.c_str(), "wb");
        uint32_t n = d.size() * 2, v32; uint16_t v16;
        fwrite("RIFF", 1, 4, f); v32 = 36 + n; fwrite(&v32, 4, 1, f);
        fwrite("WAVEfmt ", 1, 8, f); v32 = 16; fwrite(&v32, 4, 1, f);
        v16 = 1; fwrite(&v16, 2, 1, f); v16 = 1; fwrite(&v16, 2, 1, f);
        v32 = 48000; fwrite(&v32, 4, 1, f); v32 = 96000; fwrite(&v32, 4, 1, f);
        v16 = 2; fwrite(&v16, 2, 1, f); v16 = 16; fwrite(&v16, 2, 1, f);
        fwrite("data", 1, 4, f); fwrite(&n, 4, 1, f);
        fwrite(d.data(), 2, d.size(), f);
        fclose(f);
    };
    std::string base = argv[3];
    wav(base, pcm);
    wav(base.substr(0, base.rfind('.')) + "_avg.wav", avg);
    if (romlog) fclose(romlog);
    delete t;
    return 0;
}

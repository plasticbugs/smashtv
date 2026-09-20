// The whole core on the real memory glue, from the download on.
//
//   obj_pocket/Vtb_pocket_top <image.rom> <outdir> <frames> [every] [-dlgap N]
//
// Writes the frames it draws (raw RGB, turned into PNGs by sim/run_pocket.sh),
// the core's own sound-command log in tools/snd_trace.lua's format, and what
// it played as a 48 kHz WAV sampled the way target/pocket/core_top.sv samples
// it.  DENSE="from to" writes every frame in that range.
#include "Vtb_pocket_top.h"
#include "Vtb_pocket_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vtb_pocket_top *dut;
static long cycles = 0;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); cycles++; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: %s <image.rom> <outdir> <frames> [every] [-dlgap N]\n", argv[0]); return 2; }
    std::string image = argv[1], out = argv[2];
    long nframes = atol(argv[3]); long every = 50; int gap = 8, hold = 4;
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "-dlgap") && i + 1 < argc) gap = atoi(argv[++i]);
        else every = atol(argv[i]);
    }

    std::vector<uint8_t> rom;
    { FILE *f = fopen(image.c_str(), "rb"); if (!f) return 2;
      fseek(f, 0, SEEK_END); rom.resize(ftell(f)); fseek(f, 0, SEEK_SET);
      if (fread(rom.data(), 1, rom.size(), f) != rom.size()) return 2; fclose(f); }

    dut = new Vtb_pocket_top;
    dut->reset = 1; dut->pause = 0; dut->in0 = dut->in1 = dut->dsw = 0xffff; dut->dl_we = 0;
    long t = 0; while (!dut->mem_ready && t++ < 400000) tick();
    if (!dut->mem_ready) { printf("FAIL  the SDRAM never came ready\n"); return 1; }
    printf("downloading %zu bytes, one per %d clocks, strobe held %d\n", rom.size(), gap, hold);
    for (uint32_t a = 0; a < rom.size(); a++) {
        dut->dl_addr = a; dut->dl_data = rom[a]; dut->dl_we = 1;
        for (int i = 0; i < hold; i++) tick();
        dut->dl_we = 0;
        for (int i = hold; i < gap; i++) tick();
    }
    for (int i = 0; i < 400; i++) tick();
    dut->reset = 0;
    cycles = 0;

    std::vector<uint8_t> fb(1024 * 512 * 3, 0);
    std::vector<int16_t> pcm;
    int x = 0, y = 0, maxx = 0; bool was_de = false, was_vb = true;
    // The power-up RAM test drives the frame buffer through the CPU harder than
    // anything else in the game, and this machine runs it a few percent slower
    // than MAME (its CPU steps one clock in three, and its memories are not
    // free), so the boot ends some frames later than MAME's and every frame
    // number after it is off by that much.  The game resets the sound board
    // when the tests are done - MAME's frame BOOT_END_MAME, empty NVRAM - and
    // from there on the bench counts, names its pictures and presses its
    // buttons in GAME frames: its own, less the difference at that moment.
    const long BOOT_END_MAME = 1046;
    long offset = 0; bool synced = false;
    long frame = 0;
    unsigned last_word = 0;
    uint32_t cyc0 = 0; long clk0 = 0;
    long acc = 0;
    FILE *sndlog = fopen((out + "/snd_cmd.txt").c_str(), "w");
    long dense0 = -1, dense1 = -1;
    if (const char *d = getenv("DENSE")) sscanf(d, "%ld %ld", &dense0, &dense1);

    while (frame < nframes) {
        tick();
        // the mean of each 2000 clocks, as target/pocket/core_top.sv hands it over
        acc += (int16_t)dut->snd;
        if (cycles % 2000 == 0) { pcm.push_back((int16_t)(acc / 2000)); acc = 0; }
        if (dut->snd_word != last_word) {
            last_word = dut->snd_word;
            if (!synced && frame > 500 && last_word == 0xfe00) {
                synced = true; offset = frame - BOOT_END_MAME;
                printf("boot ended at frame %ld, MAME's at %ld: game frames are this bench's less %ld\n", frame, BOOT_END_MAME, offset);
            }
            fprintf(sndlog, "%.9f %ld %04x\n", cycles / 96e6, frame - offset, last_word); fflush(sndlog);
        }
        if (dut->dbg_unimpl) { printf("STOP  unimplemented instruction near PC %08x, frame %ld\n", dut->dbg_pc, frame); break; }
        if (!dut->dot_ce) continue;
        if (dut->de) {
            if (x < 1024 && y < 512) { uint8_t *p = &fb[(y*1024 + x)*3]; uint32_t c = dut->rgb;
                p[0] = c >> 16; p[1] = c >> 8; p[2] = c; }
            x++; was_de = true;
        } else if (was_de) { if (x > maxx) maxx = x; x = 0; y++; was_de = false; }
        if (dut->vblank && !was_vb) {
            frame++;
            // The same script of inputs every MAME capture in this tree uses,
            // one frame later: what a Lua script sets at frame notifier N the
            // game can first read after notifier N+1 (measured: set at 1600,
            // IN1 reads FFFE from 1601 to 1611).
            uint16_t i0 = 0xffff, i1 = 0xffff;
            const long gf = frame - offset;        // the game's frame, as MAME numbers it
            const long f = gf - 1;
            if (f >= 1600 && f < 1610) i1 &= ~0x0001;                  // coin 1
            if (f >= 1700 && f < 1710) i1 &= ~0x0004;                  // start 1
            if (f > 1800) {
                if ((f / 30) % 2 == 0) i0 &= ~0x0080;                  // fire right
                if ((f / 47) % 2 == 0) i0 &= ~0x0001;                  // move up
            }
            dut->in0 = i0; dut->in1 = i1;
            if (y > 0 && (gf % every == 0 || frame == nframes || (gf >= dense0 && gf <= dense1))) {
                char name[512]; snprintf(name, sizeof(name), "%s/rtl_%05ld_%dx%d.rgb", out.c_str(), gf, maxx, y);
                FILE *f = fopen(name, "wb");
                for (int r = 0; r < y; r++) fwrite(&fb[r*1024*3], 1, maxx*3, f);
                fclose(f);
            }
            if (frame % every == 0) {
                // How fast the CPU really ran: MAME's gets 5,000,000 cycles a
                // second and is never idle, so the cycles this one was charged
                // per clock, against 5/96, is its speed relative to MAME's.
                uint32_t cyc = dut->rootp->tb_pocket_top__DOT__u_core__DOT__u_main__DOT__u_cpu__DOT__cyc_total;
                double speed = double(uint32_t(cyc - cyc0)) / (double(cycles - clk0) * 5.0 / 96.0);
                cyc0 = cyc; clk0 = cycles;
                printf("CPU at %.1f%% of MAME's speed.  ", 100.0 * speed);
                printf("frame %ld: %dx%d, PC %08x, ctrl %02x, snd word %04x, 6809 at %04x, "
                       "sound ROM stalls %u (cache misses %u), program cache misses %u, graphics windows thrown away %u\n",
                       frame, maxx, y, dut->dbg_pc, dut->dbg_ctrl, dut->snd_word, dut->snd_pc,
                       dut->snd_stalls, dut->srom_misses, dut->mrom_misses, dut->gfx_flushes);
                fflush(stdout);
            }
            y = 0; maxx = 0;
        }
        was_vb = dut->vblank;
    }
    fclose(sndlog);
    {
        FILE *f = fopen((out + "/rtl.wav").c_str(), "wb");
        uint32_t n = pcm.size() * 2, v32; uint16_t v16;
        fwrite("RIFF", 1, 4, f); v32 = 36 + n; fwrite(&v32, 4, 1, f);
        fwrite("WAVEfmt ", 1, 8, f); v32 = 16; fwrite(&v32, 4, 1, f);
        v16 = 1; fwrite(&v16, 2, 1, f); v16 = 1; fwrite(&v16, 2, 1, f);
        v32 = 48000; fwrite(&v32, 4, 1, f); v32 = 96000; fwrite(&v32, 4, 1, f);
        v16 = 2; fwrite(&v16, 2, 1, f); v16 = 16; fwrite(&v16, 2, 1, f);
        fwrite("data", 1, 4, f); fwrite(&n, 4, 1, f);
        fwrite(pcm.data(), 2, pcm.size(), f);
        fclose(f);
    }
    dut->final();
    delete dut;
    return 0;
}

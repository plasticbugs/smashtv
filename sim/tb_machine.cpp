// The whole main board from reset, on ideal memories, writing the frames it
// produces so they can be looked at and compared with MAME's.
//
//   obj_machine/Vtb_machine_top <image.rom> <outdir> <frames> [every]
//
// A frame is what comes between two rising edges of vertical blank, sampled a
// dot at a time while `de` is high; each is written as a raw RGB file with its
// width and height in the name, because the raster is the game's to program
// and is not known until it has.
#include "Vtb_machine_top.h"
#include "Vtb_machine_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static Vtb_machine_top *dut;
static long cycles = 0;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); cycles++; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: %s <image.rom> <outdir> <frames> [every]\n", argv[0]); return 2; }
    std::string image = argv[1], out = argv[2];
    long nframes = atol(argv[3]); long every = argc > 4 ? atol(argv[4]) : 50;

    std::vector<uint8_t> rom;
    { FILE *f = fopen(image.c_str(), "rb"); if (!f) return 2;
      fseek(f, 0, SEEK_END); rom.resize(ftell(f)); fseek(f, 0, SEEK_SET);
      if (fread(rom.data(), 1, rom.size(), f) != rom.size()) return 2; fclose(f); }

    dut = new Vtb_machine_top;
    dut->rst = 1; dut->in0 = dut->in1 = dut->dsw = 0xffff;
    dut->ld_prog_we = dut->ld_gfx_we = 0;
    for (int i = 0; i < 4; i++) tick();
    for (uint32_t w = 0; w < 0x20000; w++) {
        dut->ld_prog_a = w; dut->ld_prog_d = uint16_t((rom[2*w] << 8) | rom[2*w+1]);
        dut->ld_prog_we = 1; tick();
    }
    dut->ld_prog_we = 0;
    for (uint32_t w = 0; w < 0x60000; w++) {
        const uint8_t *p = &rom[0x070000 + 4*w];
        dut->ld_gfx_a = w; dut->ld_gfx_d = (uint32_t(p[0])<<24)|(uint32_t(p[1])<<16)|(uint32_t(p[2])<<8)|p[3];
        dut->ld_gfx_we = 1; tick();
    }
    dut->ld_gfx_we = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->rst = 0;
    cycles = 0;

    std::vector<uint8_t> fb(1024 * 512 * 3, 0);
    int x = 0, y = 0, maxx = 0; bool was_de = false, was_vb = true;
    long frame = 0; long snd = 0;
    FILE *sndlog = fopen((out + "/snd_cmd.txt").c_str(), "w");
    // DENSE="from to": every frame in that range is written as well
    long dense0 = -1, dense1 = -1;
    if (const char *d = getenv("DENSE")) sscanf(d, "%ld %ld", &dense0, &dense1);
    uint32_t last_pc = 0; long same = 0;
    while (frame < nframes) {
        tick();
        if (dut->snd_strobe) {
            // the core's own command log, in tools/snd_trace.lua's format, so
            // it can be held against MAME's and replayed into the sound bench
            // (METHODOLOGY 5.10)
            snd++;
            if (sndlog) { fprintf(sndlog, "%.9f %ld %04x\n", cycles / 96e6, frame, dut->snd_word); fflush(sndlog); }
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
            const long f = frame - 1;
            if (f >= 1600 && f < 1610) i1 &= ~0x0001;                  // coin 1
            if (f >= 1700 && f < 1710) i1 &= ~0x0004;                  // start 1
            if (f > 1800) {
                if ((f / 30) % 2 == 0) i0 &= ~0x0080;                  // fire right
                if ((f / 47) % 2 == 0) i0 &= ~0x0001;                  // move up
            }
            dut->in0 = i0; dut->in1 = i1;
            if (y > 0 && (frame % every == 0 || frame == nframes || (frame >= dense0 && frame <= dense1))) {
                char name[512]; snprintf(name, sizeof(name), "%s/rtl_%05ld_%dx%d.rgb", out.c_str(), frame, maxx, y);
                FILE *f = fopen(name, "wb");
                for (int r = 0; r < y; r++) fwrite(&fb[r*1024*3], 1, maxx*3, f);
                fclose(f);
            }
            if (frame % every == 0) { printf("frame %ld: %dx%d, PC %08x, ctrl %02x, %ld sound writes, %.1f M clocks\n",
                   frame, maxx, y, dut->dbg_pc, dut->dbg_ctrl, snd, cycles / 1e6); fflush(stdout); }
            y = 0; maxx = 0;
        }
        was_vb = dut->vblank;
        if (cycles > 40000000000L) break;
    }
    delete dut;
    return 0;
}

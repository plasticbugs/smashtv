// Pocket memory gate: push an image through smashtv_mem's download port at the
// APF loader's rate, then read every region back through the core's ports
// and compare.  Then the same for the SRAM.
//
//   obj_mem/Vtb_mem_top [rom] [-gap N] [-hold N] [-quick]
//
// With no rom a pseudo-random image is used, which is a harder test than a
// real one (no runs of equal words to hide a dropped or merged write) and
// needs nothing the repo may not hold.
//
// -gap   clocks between download bytes.  The loader delivers one per 8;
//        smaller is harder.  A core that passes at 12 and fails at 8 has the
//        fault that blacked out two first hardware runs.
// -hold  clocks the write strobe is held high.  The Pocket holds it for 4 with
//        address and data stable; anything that counts, sums or pushes on the
//        strobe's level rather than its edge fails here (METHODOLOGY 5.8).
//
// The layout constants must match target/pocket/smashtv_mem.sv.
#include "Vtb_mem_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vtb_mem_top *dut;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

static const uint32_t SND_B = 0x040000, GFX_B = 0x070000, IMG = 0x1F0000;
static const uint32_t PROG_WORDS = SND_B / 2, SND_BYTES = GFX_B - SND_B, GFX_WORDS = (IMG - GFX_B) / 4;

static std::vector<uint8_t> rom;
static uint16_t be16(uint32_t o) { return (uint16_t(rom[o]) << 8) | rom[o + 1]; }
static uint32_t be32(uint32_t o) { return (uint32_t(be16(o)) << 16) | be16(o + 2); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int gap = 8, hold = 4; bool quick = false; std::string path;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-gap" && i + 1 < argc) gap = atoi(argv[++i]);
        else if (a == "-hold" && i + 1 < argc) hold = atoi(argv[++i]);
        else if (a == "-quick") quick = true;
        else if (a[0] != '+' && a[0] != '-') path = a;
    }
    if (hold >= gap) hold = gap - 1;
    if (hold < 1) hold = 1;

    rom.resize(IMG);
    if (!path.empty()) {
        FILE *f = fopen(path.c_str(), "rb");
        if (!f || fread(rom.data(), 1, IMG, f) != IMG) { fprintf(stderr, "cannot read %u bytes from %s\n", IMG, path.c_str()); return 2; }
        fclose(f);
    } else {
        uint32_t x = 0x2545F491;
        for (auto &b : rom) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; b = uint8_t(x >> 11); }
    }

    dut = new Vtb_mem_top;
    dut->init = 1; dut->rd_late = 1; dut->burst_slow = 0;
    dut->dl_we = 0; dut->dl_active = 1;
    dut->mrom_req = dut->srom_req = dut->gfx_req = dut->xm_req = dut->ram_req = 0; dut->st_run = 0;
    for (int i = 0; i < 16; i++) tick();
    dut->init = 0;
    long t = 0; while (!dut->ready && t++ < 200000) tick();
    printf("sdram ready after %ld clocks\n", t);
    if (!dut->ready) { printf("FAIL  the controller never came ready\n"); return 1; }

    printf("downloading %u bytes, one per %d clocks, strobe held %d...\n", IMG, gap, hold);
    for (uint32_t a = 0; a < IMG; a++) {
        dut->dl_addr = a; dut->dl_data = rom[a]; dut->dl_we = 1;
        for (int i = 0; i < hold; i++) tick();
        dut->dl_we = 0;
        for (int i = hold; i < gap; i++) tick();
    }
    for (int i = 0; i < 400; i++) tick();
    dut->dl_active = 0;

    long bad = 0, checked = 0;
    auto fail = [&](const char *port, uint32_t idx, uint64_t got, uint64_t want) {
        if (bad < 12) printf("  %-5s [%06X] got %08llX want %08llX\n", port, idx,
                             (unsigned long long)got, (unsigned long long)want);
        bad++;
    };
    const uint32_t step = quick ? 61 : 1;       // a prime stride still visits every row

    for (uint32_t w = 0; w < PROG_WORDS; w += step) {
        dut->mrom_addr = w; dut->mrom_req = 1;
        int g = 0; while (!dut->mrom_ack && g++ < 4000) tick();
        dut->mrom_req = 0; tick();
        checked++; if (dut->mrom_q != be16(w * 2)) fail("prog", w, dut->mrom_q, be16(w * 2));
    }
    for (uint32_t b = 0; b < SND_BYTES; b += step) {
        dut->srom_addr = b; dut->srom_req = 1;
        int g = 0; while (!dut->srom_ack && g++ < 4000) tick();
        dut->srom_req = 0; tick();
        checked++; if (dut->srom_q != rom[SND_B + b]) fail("snd", b, dut->srom_q, rom[SND_B + b]);
    }
    // ---- the graphics port, which reads ahead.  Four ways of asking:
    auto gfx = [&](uint32_t r, long &waited) {
        dut->gfx_addr = r; dut->gfx_req = 1;
        int g = 0; while (!dut->gfx_ack && g++ < 4000) tick();
        waited += g;
        dut->gfx_req = 0; tick();
        checked++; if (dut->gfx_q != be32(GFX_B + r * 4)) fail("gfx", r, dut->gfx_q, be32(GFX_B + r * 4));
    };
    long w_seq = 0, w_skip = 0, w_jump = 0, n_seq = 0, n_skip = 0, n_jump = 0;
    // in order, as a blit reads a sprite: every word of the region, or a
    // long run from each of many places with -quick
    for (uint32_t r0 = 0; r0 < GFX_WORDS; r0 += (quick ? 40009 : GFX_WORDS)) {
        uint32_t n = quick ? 600 : GFX_WORDS;
        for (uint32_t r = r0; r < r0 + n && r < GFX_WORDS; r++) { gfx(r, w_seq); n_seq++; }
    }
    // forwards with gaps, as a clipped blit does: inside the window, and past it
    for (uint32_t r = 5, k = 0; r < GFX_WORDS && k < 4000; r += 1 + (k % 23), k++) { gfx(r, w_skip); n_skip++; }
    // anywhere at all, as the CPU's window reads do: every one a miss
    for (uint32_t r = 0, k = 0; k < 4000; r = (r + 99991) % GFX_WORDS, k++) { gfx(r, w_jump); n_jump++; }
    // backwards
    for (uint32_t r = 3000; r > 2900; r--) gfx(r, w_jump);
    printf("graphics read-ahead: %.1f clocks a word in order, %.1f skipping, %.1f at random; %u windows thrown away\n",
           double(w_seq) / n_seq, double(w_skip) / n_skip, double(w_jump) / n_jump, dut->gfx_flushes);

    // ---- everything at once: the blitter streaming, the CPU fetching, the
    // 6809 fetching and frame-buffer rows being written and read back, each
    // port with a request up the whole time.  This is where an ack that goes
    // to the wrong client shows (METHODOLOGY section 5.17).
    {
        uint32_t gr = 1000, pw = 7, sb = 11, xa = 0; int xphase = 0; long n = 0;
        uint16_t xwant = 0;
        dut->gfx_addr = gr; dut->gfx_req = 1;
        dut->mrom_addr = pw; dut->mrom_req = 1;
        dut->srom_addr = sb; dut->srom_req = 1;
        dut->xm_addr = xa; dut->xm_we = 1; dut->xm_d = 0x1357; dut->xm_be = 3; dut->xm_req = 1;
        for (long c = 0; c < (quick ? 400000 : 4000000); c++) {
            tick();
            if (dut->gfx_ack) {
                checked++; n++; if (dut->gfx_q != be32(GFX_B + gr * 4)) fail("gfx*", gr, dut->gfx_q, be32(GFX_B + gr * 4));
                gr = (n % 97 == 0) ? (gr * 7 + 13) % GFX_WORDS : gr + 1; if (gr >= GFX_WORDS) gr = 0;
                dut->gfx_addr = gr;
            }
            if (dut->mrom_ack) {
                checked++; if (dut->mrom_q != be16(pw * 2)) fail("prog*", pw, dut->mrom_q, be16(pw * 2));
                pw = (pw * 5 + 3) % PROG_WORDS; dut->mrom_addr = pw;
            }
            if (dut->srom_ack) {
                checked++; if (dut->srom_q != rom[SND_B + sb]) fail("snd*", sb, dut->srom_q, rom[SND_B + sb]);
                sb = (sb * 3 + 1) % SND_BYTES; dut->srom_addr = sb;
            }
            if (dut->xm_ack) {
                if (xphase == 0) { xwant = dut->xm_d; dut->xm_we = 0; xphase = 1; }
                else {
                    checked++; if (dut->xm_q != xwant) fail("xm*", xa, dut->xm_q, xwant);
                    xa = (xa * 9 + 5) & 0x1ffff; dut->xm_addr = xa; dut->xm_we = 1;
                    dut->xm_d = uint16_t(xa * 0x6A09 + 0x77); xphase = 0;
                }
            }
        }
        dut->gfx_req = dut->mrom_req = dut->srom_req = dut->xm_req = 0;
        for (int i = 0; i < 200; i++) tick();
    }
    // frame-buffer rows with byte enables, and the image still intact under them
    {
        auto xm = [&](bool we, uint32_t a, uint16_t d, int be) {
            dut->xm_we = we; dut->xm_addr = a; dut->xm_d = d; dut->xm_be = be; dut->xm_req = 1;
            int g = 0; while (!dut->xm_ack && g++ < 4000) tick();
            dut->xm_req = 0; tick();
            return (uint16_t)dut->xm_q;
        };
        xm(true, 0x1fffe, 0xFFFF, 3); xm(true, 0x1fffe, 0x12AB, 2);      // high byte only
        uint16_t v = xm(false, 0x1fffe, 0, 3);
        checked++; if (v != 0x12FF) fail("xm be", 0x1fffe, v, 0x12FF);
        long dummy = 0; gfx(0, dummy); gfx(GFX_WORDS - 1, dummy);
    }
    printf("SDRAM: %ld words checked through the core's ports, %ld wrong\n", checked, bad);

    // ---- SRAM: a pattern over everything the machine uses - main RAM at
    // 0x00000, CMOS at 0x10000, the palette copy at 0x14000 - which crosses
    // the 17th address bit no core before this one drove
    long sbad = 0;
    auto ram = [&](bool we, uint32_t a, uint16_t d, int ben) {
        dut->ram_we = we; dut->ram_addr = a; dut->ram_d = d; dut->ram_be = ben; dut->ram_req = 1;
        int g = 0; while (!dut->ram_ack && g++ < 4000) tick();
        dut->ram_req = 0; tick();
        return (uint16_t)dut->ram_q;
    };
    for (uint32_t a = 0; a < 0x16000; a += step) ram(true, a, uint16_t(a * 0x9E37 + 0x1234), 3);
    for (uint32_t a = 0; a < 0x16000; a += step) if (ram(false, a, 0, 3) != uint16_t(a * 0x9E37 + 0x1234)) sbad++;
    ram(true, 0x00005, 0x1111, 3); ram(true, 0x10005, 0x2222, 3);     // either side of A16
    if (ram(false, 0x00005, 0, 3) != 0x1111 || ram(false, 0x10005, 0, 3) != 0x2222) { sbad++; printf("  sram A16 aliases\n"); }
    ram(true, 5, 0xFFFF, 3); ram(true, 5, 0x00AB, 1);            // low byte only
    if (ram(false, 5, 0, 3) != 0xFFAB) { sbad++; printf("  sram byte enables: got %04X want FFAB\n", dut->ram_q); }
    // core_top's power-on test, on this port: it must read back its two
    // patterns, and it must leave both words as it found them - the second is
    // the first word of the game's CMOS, which survives a core reset.
    ram(true, 0x00000, 0xBEEF, 3); ram(true, 0x10000, 0x0022, 3);
    dut->st_run = 1;
    { int g = 0; while (!dut->st_done && g++ < 400000) tick(); }
    const uint16_t r0 = dut->st_rd0, r1 = dut->st_rd1;       // before st_run drops and clears them
    const bool st_pass = dut->st_done && r0 == 0xA55A && r1 == 0x5AA5;
    dut->st_run = 0; tick();
    const uint16_t k0 = ram(false, 0x00000, 0, 3), k1 = ram(false, 0x10000, 0, 3);
    printf("SRAM self-test: read back %04X %04X (want A55A 5AA5); left behind %04X %04X (want BEEF 0022)\n",
           r0, r1, k0, k1);
    if (!st_pass || k0 != 0xBEEF || k1 != 0x0022) sbad++;
    printf("SRAM:  %ld wrong\n", sbad);

    delete dut;
    if (bad || sbad) { printf("FAIL  what came back is not what was sent\n"); return 1; }
    printf("PASS  every region reads back byte-for-byte\n");
    return 0;
}

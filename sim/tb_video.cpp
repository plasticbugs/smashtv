// The frozen-state video gate: load a state into the RTL, replay the trace
// MAME's own frames were replayed from, and compare the palette indices the
// scanout produces with tools/render_model.py's.
//
//   obj_video/Vtb_video_top <window-dir> <image.rom> <idx-dir> [-gfxlat N] [-v]
//
// Indices, not colours: two pens can share a colour and hide a difference.
//
// The state goes in through the CPU's own frame-buffer port with the video
// bank set, which writes the pixel plane from the data and the palette plane
// from the blitter's palette register -- so one pass loads both planes and
// the load exercises the same path the game's RAM test uses.
//
// The replay walks the raster the way the window does: line 276 round to line
// 275, applying each line's events after the RTL has done that line's start.
// A blit trigger waits for the blitter to be idle first, because that is what
// the game does and what MAME's zero-time blitter hides: `drift` reports how
// many clocks that waiting cost, and any non-zero value means the RTL cannot
// keep up with the rate the game issues blits at.
#include "Vtb_video_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <dirent.h>

static const int VIS_W = 410, VIS_H = 256;
static const int FIRST_VIS_FWD = 20;
static const int FB_ROWS = 512, FB_COLS = 512;
static const int FIRST_VIS = FIRST_VIS_FWD, LAST_VIS = 275, VTOT = 288;
static const uint32_t GFX_BASE = 0x070000;

static Vtb_video_top *dut;
static long cycles = 0;

// The picture is sampled inside tick(), not in the line loop, because
// applying a line's events costs clocks -- thousands of them when a blit
// trigger has to wait for the blitter -- and any dot that goes by while the
// bench is busy elsewhere is a dot lost.  The first run of this bench lost
// exactly the lines whose events had waited, and reported them as differing
// pixels.  Position comes from the raster itself rather than a count: the
// output is one dot behind the counters, so a lit `de` at hdot h is
// x = h - 92 of row vline - 20 (the dot enable is sampled after the edge,
// so the counters have already moved on by one).
static std::vector<uint16_t> *cap = nullptr;
static long cap_dots = 0;

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    cycles++;
    if (cap && dut->dot_ce && dut->de) {
        int x = int(dut->hdot_o) - 92;
        int y = int(dut->vline) - FIRST_VIS;
        if (x >= 0 && x < VIS_W && y >= 0 && y < VIS_H) {
            (*cap)[y * VIS_W + x] = dut->pen;
            cap_dots++;
        }
    }
}

// ---------------------------------------------------------------- the state
struct State {
    uint32_t frame = 0;
    uint16_t ctrl = 0;
    uint16_t dma[16] = {0};
    std::vector<uint16_t> fb;       // FB_ROWS * FB_COLS entries
    std::vector<uint16_t> pen;      // 4096

    bool load(const std::string &path) {
        FILE *f = fopen(path.c_str(), "rb");
        if (!f) return false;
        char magic[4];
        uint32_t ver;
        if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "STVS", 4)) return false;
        if (fread(&ver, 4, 1, f) != 1 || ver != 3) return false;
        if (fread(&frame, 4, 1, f) != 1) return false;
        if (fread(&ctrl, 2, 1, f) != 1) return false;
        if (fread(dma, 2, 16, f) != 16) return false;
        fb.resize(FB_ROWS * FB_COLS);
        if (fread(fb.data(), 2, fb.size(), f) != fb.size()) return false;
        pen.resize(4096);
        if (fread(pen.data(), 2, pen.size(), f) != pen.size()) return false;
        fclose(f);
        return true;
    }
};

// ---------------------------------------------------------------- the trace
#pragma pack(push, 1)
struct Ev {
    uint32_t frame;
    uint16_t vpos, seq;
    uint8_t  kind, reg;
    uint32_t addr;
    uint16_t data, mask;
};
#pragma pack(pop)
static const int K_DMA = 0, K_FB = 1, K_PAL = 2, K_CTRL = 3;

// --------------------------------------------------------------- bench I/O
static void wait_cpu() {
    int g = 0;
    while (!dut->cpu_ack && g++ < 2000) tick();
    dut->cpu_req = 0;
    tick();
}

static void cpu_write(uint32_t word, uint16_t d, uint8_t be) {
    dut->cpu_word = word; dut->cpu_d = d; dut->cpu_be = be;
    dut->cpu_we = 1; dut->cpu_req = 1;
    wait_cpu();
}

static uint16_t cpu_read(uint32_t word) {
    dut->cpu_word = word; dut->cpu_we = 0; dut->cpu_be = 3; dut->cpu_req = 1;
    wait_cpu();
    return dut->cpu_q;
}

static void blit_reg(int a, uint16_t d, uint8_t be = 3) {
    dut->blit_a = a; dut->blit_d = d; dut->blit_be = be; dut->blit_we = 1;
    tick();
    dut->blit_we = 0;
}

static void pal_write(int a, uint16_t d, uint8_t be = 3) {
    dut->pal_a = a; dut->pal_d = d; dut->pal_be = be; dut->pal_we = 1;
    tick();
    dut->pal_we = 0;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string dir, image, idxdir, dumpdir;
    bool verbose = false;
    std::vector<std::string> pos;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-v") verbose = true;
        else if (a == "-dump" && i + 1 < argc) dumpdir = argv[++i];
        else if (a[0] != '+' && a[0] != '-') pos.push_back(a);
    }
    if (pos.size() < 3) {
        fprintf(stderr, "usage: %s <window-dir> <image.rom> <idx-dir> [-v]\n", argv[0]);
        return 2;
    }
    dir = pos[0]; image = pos[1]; idxdir = pos[2];

    // ---- the frozen state: the lowest-numbered state_*.bin in the window
    State st;
    {
        std::string best;
        DIR *d = opendir(dir.c_str());
        if (!d) { fprintf(stderr, "cannot open %s\n", dir.c_str()); return 2; }
        for (struct dirent *e; (e = readdir(d));) {
            std::string n = e->d_name;
            if (n.compare(0, 6, "state_") == 0 && (best.empty() || n < best)) best = n;
        }
        closedir(d);
        if (best.empty() || !st.load(dir + "/" + best)) {
            fprintf(stderr, "no usable state_*.bin in %s\n", dir.c_str());
            return 2;
        }
        printf("state %s: frame %u, ctrl %04x\n", best.c_str(), st.frame, st.ctrl);
    }

    // ---- the trace
    std::vector<Ev> tr;
    {
        FILE *f = fopen((dir + "/trace.bin").c_str(), "rb");
        if (!f) { fprintf(stderr, "no trace.bin in %s\n", dir.c_str()); return 2; }
        Ev e;
        while (fread(&e, sizeof(e), 1, f) == 1) tr.push_back(e);
        fclose(f);
        printf("trace: %zu events\n", tr.size());
    }

    // ---- the graphics region of the image, as 32-bit big-endian words
    std::vector<uint32_t> gfx;
    {
        FILE *f = fopen(image.c_str(), "rb");
        if (!f) { fprintf(stderr, "cannot read %s\n", image.c_str()); return 2; }
        fseek(f, 0, SEEK_END);
        long len = ftell(f);
        fseek(f, GFX_BASE, SEEK_SET);
        long n = (len - (long)GFX_BASE) / 4;
        std::vector<uint8_t> raw(n * 4);
        if (fread(raw.data(), 1, raw.size(), f) != raw.size()) {
            fprintf(stderr, "%s: short read\n", image.c_str()); return 2;
        }
        fclose(f);
        gfx.resize(n);
        for (long i = 0; i < n; i++)
            gfx[i] = (uint32_t(raw[4*i]) << 24) | (uint32_t(raw[4*i+1]) << 16)
                   | (uint32_t(raw[4*i+2]) << 8) | uint32_t(raw[4*i+3]);
        printf("graphics: %ld words of four pixels\n", n);
    }

    // ---- bring the RTL up
    dut = new Vtb_video_top;
    dut->rst = 1;
    dut->cpu_req = dut->cpu_we = dut->blit_we = dut->pal_we = 0;
    dut->vreg_we = dut->gfx_we = 0;
    dut->ctrl = 0x2c;
    for (int i = 0; i < 20; i++) tick();
    dut->rst = 0;
    for (int i = 0; i < 20; i++) tick();

    // ---- load the graphics
    for (size_t i = 0; i < gfx.size(); i++) {
        dut->gfx_wa = uint32_t(i); dut->gfx_wd = gfx[i]; dut->gfx_we = 1;
        tick();
    }
    dut->gfx_we = 0;
    tick();

    // ---- the CPU's port on its own, before it is trusted to load a state.
    // A different word in every location of a row in each kind of storage -
    // block RAM, the template rows (their own RAMs, their own port), and the
    // rows in SDRAM - written and read back through both planes.  The state
    // load's own read-back cannot see a read that returns the wrong COLUMN,
    // because the template rows of every captured state are one colour from
    // end to end; that is how a broken template read got past this gate once
    // (the game's RAM test found it: RAM CHIPS BAD).
    {
        const int rows[] = {0, 5, 255, 256, 300, 509, 510, 511};
        long bad = 0, n = 0;
        dut->ctrl = 0x30;                 // bank 1, autoerase off
        for (int r : rows)
            for (int c = 0; c < FB_COLS / 2; c++) {
                uint32_t w = uint32_t(r * (FB_COLS / 2) + c);
                uint16_t pix = uint16_t(w * 0x9E37u + 0x1234u), pal = uint16_t(w * 0x6A09u + 0x0777u);
                blit_reg(8, pal);
                cpu_write(w, pix, 3);
            }
        for (int pass = 0; pass < 2; pass++) {
            dut->ctrl = pass ? 0x10 : 0x30; tick();     // the palette plane, then... the pixel plane first
            for (int r : rows)
                for (int c = 0; c < FB_COLS / 2; c++) {
                    uint32_t w = uint32_t(r * (FB_COLS / 2) + c);
                    uint16_t want = pass ? uint16_t(w * 0x6A09u + 0x0777u) : uint16_t(w * 0x9E37u + 0x1234u);
                    uint16_t got = cpu_read(w);
                    n++;
                    if (got != want) {
                        if (bad < 8) printf("  port: row %d word %d %s got %04x want %04x\n", r, c,
                                            pass ? "palette" : "pixel", got, want);
                        bad++;
                    }
                }
        }
        printf("CPU port: %ld of %ld words wrong across block RAM, template and SDRAM rows\n", bad, n);
        if (bad) { printf("FAIL  the CPU's port into the frame buffer\n"); return 1; }
        dut->ctrl = 0x30; tick();
    }

    // ---- load the frame buffer, both planes at once, with the video bank set
    dut->ctrl = 0x30;                 // bank 1, autoerase off
    for (int w = 0; w < FB_ROWS * FB_COLS / 2; w++) {
        uint16_t e0 = st.fb[2 * w], e1 = st.fb[2 * w + 1];
        blit_reg(8, uint16_t((e1 & 0xff00) | (e0 >> 8)));      // the palette bytes
        cpu_write(uint32_t(w), uint16_t(((e1 & 0xff) << 8) | (e0 & 0xff)), 3);
    }
    printf("frame buffer loaded in %ld clocks\n", cycles);

    // Read a sample back through the same port, so a load fault is told apart
    // from a scanout fault before anything else is believed.  A prime stride
    // still visits every row.
    {
        long bad = 0, n = 0;
        for (int w = 0; w < FB_ROWS * FB_COLS / 2; w += 97) {
            // with the video bank set, a read returns the two pixel bytes
            uint16_t want = uint16_t(((st.fb[2*w+1] & 0xff) << 8) | (st.fb[2*w] & 0xff));
            uint16_t got = cpu_read(uint32_t(w));
            n++;
            if (got != want) {
                if (bad < 6)
                    printf("  load: word %d (row %d) got %04x want %04x\n",
                           w, (2*w) / FB_COLS, got, want);
                bad++;
            }
        }
        printf("load check: %ld of %ld sampled words wrong (pixel plane)\n", bad, n);

        // And the palette plane, which only the first replayed frame ever
        // shows: every later frame has had the blitter rewrite both planes,
        // so a bad palette-plane load looks like exactly one wrong frame.
        dut->ctrl = 0x10;                       // bank 0, autoerase off
        tick();
        long badp = 0;
        for (int w = 0; w < FB_ROWS * FB_COLS / 2; w += 97) {
            uint16_t want = uint16_t((st.fb[2*w+1] & 0xff00) | (st.fb[2*w] >> 8));
            uint16_t got = cpu_read(uint32_t(w));
            if (got != want) {
                if (badp < 6)
                    printf("  load: word %d (row %d) palette got %04x want %04x\n",
                           w, (2*w) / FB_COLS, got, want);
                badp++;
            }
        }
        printf("load check: %ld of %ld sampled words wrong (palette plane)\n", badp, n);
        dut->ctrl = 0x30;
        tick();
    }

    // ---- the palette, then the blitter's registers (never register 0: its
    // only live bit is "busy", and writing it would start a blit)
    for (int i = 0; i < 4096; i++) pal_write(i, st.pen[i], 3);
    for (int i = 1; i < 10; i++) blit_reg(i, st.dma[i], 3);
    // Autoerase stays off until the window starts.  The raster is running
    // while all this loads, so a frozen buffer left with autoerase enabled
    // would be wiped clean before the first replayed line -- which is what
    // the first run of this bench showed: every pen came out 0x03d, the
    // template's.
    dut->ctrl = (st.ctrl & 0xff) | 0x10;
    for (int i = 0; i < 40; i++) tick();

    // ---- the model's indices
    auto load_idx = [&](uint32_t frame, std::vector<uint16_t> &out) {
        char p[512];
        snprintf(p, sizeof(p), "%s/idx_%05u.bin", idxdir.c_str(), frame);
        FILE *f = fopen(p, "rb");
        if (!f) return false;
        out.resize(VIS_W * VIS_H);
        bool ok = fread(out.data(), 2, out.size(), f) == out.size();
        fclose(f);
        return ok;
    };

    // ---- the raster order of a window: line 276 round to line 275
    std::vector<int> order;
    for (int l = LAST_VIS + 1; l <= VTOT; l++) order.push_back(l);
    for (int l = 0; l <= LAST_VIS; l++) order.push_back(l);

    // run to the start of the first window
    // Already there is there: called with the raster exactly at the line it
    // asks for, this must not wait a whole frame for the next one.  The first
    // window is aligned before the loop, and every later window starts on the
    // line the previous one ended at, so without the guard the first frame of
    // each window captured two frames over each other -- 209,920 dots where
    // 104,960 were expected, and the second frame's picture on top of the
    // first's.
    auto at_line_start = [&](int line) {
        if (dut->vline == line && dut->hdot_o == 0 && dut->dot_ce) return true;
        long guard = 0;
        while (!(dut->vline == line && dut->hdot_o == 0 && dut->dot_ce)
               && guard++ < 4000000) tick();
        return guard < 4000000;
    };
    if (!at_line_start(order[0])) { printf("FAIL  the raster never started\n"); return 1; }
    // The load itself writes every row while the raster runs, so discount
    // the coincidences it causes: what matters is the ones the replay causes.
    const unsigned race0 = dut->race;
    // Set it, do not tick: a tick here steps off the line start the
    // alignment just reached, and the loop would then wait a whole frame for
    // the next one -- with the capture running, which is two frames of
    // picture written over each other.
    dut->ctrl = st.ctrl & 0xff;          // as the game left it, from here on

    long bad_frames = 0, worst = 0;
    long drift = 0, retrigger = 0, late = 0;
    size_t ei = 0;
    uint32_t f = st.frame;
    std::vector<uint16_t> want, got(VIS_W * VIS_H);

    // How many windows to replay: the number of model index files, so a
    // window whose trace is empty (romcheck draws nothing at all for eight
    // frames) is still checked rather than skipped.
    int nframes = 0;
    for (uint32_t k = st.frame + 1; ; k++) {
        std::vector<uint16_t> probe;
        if (!load_idx(k, probe)) break;
        nframes++;
    }
    printf("%d model frames to compare\n", nframes);

    int nwin = 0;
    for (int wi = 0; wi < nframes; wi++) {
        // the events tagged f compose the picture f+1
        std::fill(got.begin(), got.end(), 0xffff);
        cap = &got;
        cap_dots = 0;
        for (size_t oi = 0; oi < order.size(); oi++) {
            int line = order[oi];
            if (!at_line_start(line)) { printf("FAIL  lost the raster\n"); return 1; }
            // the line's events, after the RTL has done its start-of-line work
            while (ei < tr.size() && tr[ei].frame == f && tr[ei].vpos == line) {
                const Ev &e = tr[ei++];
                // MAME's accesses take no time; a real port's do.  An event
                // that has to be applied after the raster has moved on is a
                // statement about that difference, not about the RTL.
                if (dut->vline != line) late++;
                switch (e.kind) {
                case K_DMA:
                    if (e.reg == 0 && (e.data & 0x8000)) {
                        long t0 = cycles;
                        int guard = 0;
                        while (dut->blit_busy && guard++ < 2000000) tick();
                        if (dut->blit_busy) retrigger++;
                        drift += cycles - t0;
                    }
                    blit_reg(e.reg, e.data, uint8_t(((e.mask >> 8) & 1) << 1
                                                    | (e.mask & 1)));
                    break;
                case K_FB:
                    cpu_write(e.addr, e.data,
                              uint8_t(((e.mask >> 8) & 1) << 1 | (e.mask & 1)));
                    break;
                case K_PAL:
                    pal_write(e.addr & 0xfff, e.data,
                              uint8_t(((e.mask >> 8) & 1) << 1 | (e.mask & 1)));
                    break;
                case K_CTRL:
                    dut->ctrl = e.data & 0xff;
                    tick();
                    break;
                default: break;
                }
            }
            // run the line out; tick() samples the picture
            while (!(dut->hdot_o == 0 && dut->dot_ce && dut->vline != line)) {
                tick();
                if (cycles > 400000000L) { printf("FAIL  hung\n"); return 1; }
            }
        }
        cap = nullptr;
        if (cap_dots != long(VIS_W) * VIS_H)
            printf("  frame %u: %ld visible dots sampled, expected %d\n",
                   f + 1, cap_dots, VIS_W * VIS_H);
        // compare
        if (!dumpdir.empty()) {
            char p[512];
            snprintf(p, sizeof(p), "%s/rtl_%05u.bin", dumpdir.c_str(), f + 1);
            FILE *o = fopen(p, "wb");
            if (o) { fwrite(got.data(), 2, got.size(), o); fclose(o); }
        }
        if (load_idx(f + 1, want)) {
            long n = 0;
            int firstx = -1, firsty = -1;
            for (int i = 0; i < VIS_W * VIS_H; i++)
                if (got[i] != want[i]) {
                    if (!n) { firstx = i % VIS_W; firsty = i / VIS_W; }
                    n++;
                }
            if (n > worst) worst = n;
            if (n) {
                bad_frames++;
                printf("  frame %u: %6ld of %d indices differ, first at (%d,%d) "
                       "rtl %03x model %03x\n", f + 1, n, VIS_W * VIS_H,
                       firstx, firsty, got[firsty * VIS_W + firstx],
                       want[firsty * VIS_W + firstx]);
            } else {
                printf("  frame %u: %6d of %d indices differ\n", f + 1, 0,
                       VIS_W * VIS_H);
            }
            nwin++;
        }
        f++;
        while (ei < tr.size() && tr[ei].frame < f) ei++;
    }

    printf("%d frames compared, %ld differ; worst %ld indices\n", nwin, bad_frames, worst);
    printf("blitter: %u source pixels, %u clocks of graphics stall, "
           "%ld clocks of drift waiting for it, %ld re-triggers\n",
           (unsigned)dut->px_drawn, (unsigned)dut->gfx_stall, drift, retrigger);
    printf("replay: %ld of %zu events landed on a later raster line than MAME "
           "had them\n", late, tr.size());
    if (dut->px_drawn) {
        double cpp = double(dut->busy_clocks) / double(dut->px_drawn);
        printf("blitter rate: %.3f clocks per source pixel against the board's "
               "3.936 (41 ns at 96 MHz), %.1f%% of a frame at the heaviest\n",
               cpp, 100.0 * double(dut->busy_clocks) / double(nframes)
                    / 1754784.0);
    }
    printf("frame buffer: %u writes held off because the display was fetching "
           "that row (%u more during the load)\n",
           (unsigned)dut->race - race0, race0);

    bool fail = bad_frames || retrigger || nwin == 0;
    delete dut;
    if (fail) {
        printf("FAIL  the RTL does not match the reference renderer\n");
        return 1;
    }
    printf("PASS  every index matches the reference renderer\n");
    return 0;
}

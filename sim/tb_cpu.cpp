// Hold rtl/tms34010.sv to MAME, one instruction and one bus transaction at a
// time (METHODOLOGY section 4).
//
//   obj_cpu/Vtb_cpu_top <trace-dir> <image.rom> [-n instructions] [-v]
//
// The trace directory is what tools/cpu_trace.sh wrote:
//
//   trace_bus.bin   every transaction MAME's TMS34010 made.  It is both the
//                   check and the stimulus: each transaction the RTL makes
//                   must be the next one in the file, and each read is
//                   answered with the data MAME's CPU was given -- so the RTL
//                   sees the same vertical counter, the same blitter busy
//                   bit, the same inputs, whatever the program polls.
//   trace_reg.txt   the register file before every instruction.  Compared at
//                   every instruction start, so a wrong flag is caught at the
//                   instruction that set it and not at the branch, thousands
//                   of instructions later, that finally uses it.
//
// Interrupts are asynchronous in MAME and have to be replayed: when the
// register trace shows the next instruction is the first of a handler, the
// bench raises that interrupt one instruction earlier, and the RTL must then
// enter it at the same boundary MAME did.
//
// The bus trace starts after reset -- MAME reads the reset vector inside
// device_reset(), before a script can install a tap -- so the vector read is
// answered from the ROM image and the comparison starts at the first fetch.
#include "Vtb_cpu_top.h"
#include "Vtb_cpu_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#pragma pack(push, 1)
struct Tx { uint32_t idx, addr; uint16_t data, mask; uint8_t write, region; uint16_t pad; };
#pragma pack(pop)

struct Insn { uint32_t pc; uint32_t r[32]; char text[48]; };   // r: ST A0-14 B0-14 SP

static Vtb_cpu_top *dut;
static long cycles = 0;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); cycles++; }

static const char *RN[32] = {"ST","A0","A1","A2","A3","A4","A5","A6","A7","A8","A9","A10",
    "A11","A12","A13","A14","B0","B1","B2","B3","B4","B5","B6","B7","B8","B9","B10","B11",
    "B12","B13","B14","SP"};

static uint32_t rtl_reg(int i) {
    auto *r = dut->rootp;
    if (i == 0)  return r->tb_cpu_top__DOT__u_cpu__DOT__st;
    if (i == 31) return r->tb_cpu_top__DOT__u_cpu__DOT__sp;
    if (i <= 15) return r->tb_cpu_top__DOT__u_cpu__DOT__ra[i - 1];
    return r->tb_cpu_top__DOT__u_cpu__DOT__rb[i - 16];
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::vector<std::string> pos;
    long limit = 0; bool verbose = false;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-n" && i + 1 < argc) limit = atol(argv[++i]);
        else if (a == "-v") verbose = true;
        else if (a[0] != '+' && a[0] != '-') pos.push_back(a);
    }
    if (pos.size() < 2) { fprintf(stderr, "usage: %s <trace-dir> <image.rom> [-n N]\n", argv[0]); return 2; }

    // ---- the program ROM, for the reset vector only
    std::vector<uint8_t> rom(0x40000);
    { FILE *f = fopen(pos[1].c_str(), "rb");
      if (!f || fread(rom.data(), 1, rom.size(), f) != rom.size()) { fprintf(stderr, "cannot read %s\n", pos[1].c_str()); return 2; }
      fclose(f); }
    auto rom_word = [&](uint32_t bitaddr) -> uint16_t {
        uint32_t w = ((bitaddr - 0xffe00000u) >> 4) & 0x1ffff;
        return uint16_t((rom[2 * w] << 8) | rom[2 * w + 1]);
    };

    // ---- the bus trace
    std::vector<Tx> tx;
    { FILE *f = fopen((pos[0] + "/trace_bus.bin").c_str(), "rb");
      if (!f) { fprintf(stderr, "no trace_bus.bin\n"); return 2; }
      Tx t; while (fread(&t, sizeof(t), 1, f) == 1) tx.push_back(t);
      fclose(f); }

    // ---- the register trace
    std::vector<Insn> ins;
    { FILE *f = fopen((pos[0] + "/trace_reg.txt").c_str(), "r");
      if (!f) { fprintf(stderr, "no trace_reg.txt\n"); return 2; }
      char line[1024]; Insn cur; bool have = false;
      while (fgets(line, sizeof(line), f)) {
          if (line[0] == '=') {
              char *p = line + 1;
              for (int i = 0; i < 32; i++) cur.r[i] = uint32_t(strtoul(p, &p, 16));
              have = true;
          } else if (have && strlen(line) > 9 && line[8] == ':') {
              cur.pc = uint32_t(strtoul(line, nullptr, 16));
              strncpy(cur.text, line + 10, sizeof(cur.text) - 1);
              cur.text[sizeof(cur.text) - 1] = 0;
              char *nl = strchr(cur.text, '\n'); if (nl) *nl = 0;
              ins.push_back(cur); have = false;
              if (limit && long(ins.size()) > limit + 8) break;
          }
      }
      fclose(f); }
    printf("%zu transactions, %zu instructions from MAME\n", tx.size(), ins.size());

    // ---- interrupt entry points: the handler addresses, from the vectors
    auto rom_long = [&](uint32_t a) { return uint32_t(rom_word(a)) | (uint32_t(rom_word(a + 16)) << 16); };
    const uint32_t h_di = rom_long(0xfffffea0) & ~0xfu, h_x1 = rom_long(0xffffffc0) & ~0xfu,
                   h_x2 = rom_long(0xffffffa0) & ~0xfu;
    printf("handlers: display %08x, external-1 %08x, external-2 %08x\n", h_di, h_x1, h_x2);

    dut = new Vtb_cpu_top;
    dut->rst = 1; dut->bus_ack = 0; dut->int1 = dut->int2 = dut->dpyint = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->rst = 0;

    size_t ti = 0, ii = 0;
    long irqs = 0;
    std::deque<std::string> recent;
    bool pending_ack = false;
    int  fail = 0;

    auto context = [&]() {
        printf("  the last instructions MAME executed:\n");
        for (auto &s : recent) printf("    %s\n", s.c_str());
    };

    while (!fail) {
        tick();
        if (cycles > 4000000000L) { printf("FAIL  ran away\n"); fail = 1; break; }
        if (dut->unimpl) {
            printf("STOP  the RTL met an instruction it does not implement, at instruction %zu\n", ii);
            context(); fail = 2; break;
        }

        // ---- an instruction is starting: the registers must be MAME's
        if (dut->insn_start) {
            if (ii >= ins.size() || (limit && long(ii) >= limit)) break;
            const Insn &m = ins[ii];
            bool bad = (dut->dbg_pc != m.pc);
            for (int i = 0; i < 32 && !bad; i++) if (rtl_reg(i) != m.r[i]) bad = true;
            if (bad) {
                printf("FAIL  at instruction %zu the RTL's state is not MAME's\n", ii);
                if (dut->dbg_pc != m.pc) printf("    PC   rtl %08x  MAME %08x\n", dut->dbg_pc, m.pc);
                for (int i = 0; i < 32; i++)
                    if (rtl_reg(i) != m.r[i])
                        printf("    %-4s rtl %08x  MAME %08x\n", RN[i], rtl_reg(i), m.r[i]);
                context(); fail = 1; break;
            }
            char b[96]; snprintf(b, sizeof(b), "%8zu  %08X: %s", ii, m.pc, m.text);
            recent.push_back(b); if (recent.size() > 12) recent.pop_front();

            // is MAME about to enter an interrupt after this instruction?
            if (ii + 1 < ins.size()) {
                uint32_t np = ins[ii + 1].pc;
                bool is_h = (np == h_di || np == h_x1 || np == h_x2);
                // a handler entered by an interrupt: ST was reset to 0x10
                if (is_h && ins[ii + 1].r[0] == 0x00000010 && strncmp(m.text, "TRAP", 4) != 0) {
                    if (np == h_di) dut->dpyint = 1;
                    else if (np == h_x1) dut->int1 = 1;
                    else dut->int2 = 1;
                    irqs++;
                }
            }
            ii++;
        } else {
            dut->dpyint = 0;
        }
        if (dut->irq_taken) { dut->int1 = 0; dut->int2 = 0; }

        // ---- the bus
        if (pending_ack) { dut->bus_ack = 0; pending_ack = false; continue; }
        if (dut->bus_req && !dut->bus_ack) {
            uint32_t a = dut->bus_addr;
            if (ii == 0) {                       // the reset vector, before the trace begins
                dut->bus_rdata = rom_word(a);
            } else {
                if (ti >= tx.size()) break;
                const Tx &t = tx[ti];
                bool ok = (t.addr == a) && (bool(t.write) == bool(dut->bus_we))
                       && (!dut->bus_we || t.data == dut->bus_wdata);
                if (!ok) {
                    printf("FAIL  bus transaction %zu, during instruction %zu\n", ti, ii - 1);
                    printf("    rtl  %s %08x %04x\n", dut->bus_we ? "W" : "R", a,
                           dut->bus_we ? dut->bus_wdata : 0);
                    printf("    MAME %s %08x %04x\n", t.write ? "W" : "R", t.addr, t.data);
                    context(); fail = 1; break;
                }
                dut->bus_rdata = t.data;
                ti++;
            }
            dut->bus_ack = 1; pending_ack = true;
        }
    }

    printf("%zu instructions and %zu transactions matched MAME; %ld interrupts replayed\n",
           ii, ti, irqs);
    delete dut;
    if (fail == 1) return 1;
    if (fail == 2) return 3;
    printf("PASS  every register and every transaction is MAME's\n");
    return 0;
}

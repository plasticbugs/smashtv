// Bench wrapper for target/pocket/smashtv_mem.sv: the Pocket memory subsystem
// with behavioural chips behind the pins.  sim/tb_mem.cpp pushes an image in
// through the download port at the APF loader's rate and reads every region
// back through the core's ports.
//
// This is the gate two cores shipped without (METHODOLOGY section 5.16): a
// whole-machine bench that answers the CPUs from arrays never exercises the
// controller, the arbiter, or the download path that fills it.
`default_nettype none
module tb_mem_top (
    input  logic        clk,
    input  logic        init,
    output logic        ready,
    input  logic        rd_late, burst_slow,
    input  logic        dl_we, input logic [24:0] dl_addr, input logic [7:0] dl_data,
    input  logic        dl_active,
    input  logic        mrom_req, input  logic [16:0] mrom_addr,
    output logic        mrom_ack, output logic [15:0] mrom_q,
    input  logic        srom_req, input  logic [17:0] srom_addr,
    output logic        srom_ack, output logic  [7:0] srom_q,
    input  logic        gfx_req,  input  logic [18:0] gfx_addr,
    output logic        gfx_ack,  output logic [31:0] gfx_q,
    input  logic        xm_req,   input  logic        xm_we,
    input  logic [16:0] xm_addr,  input  logic [15:0] xm_d,
    input  logic  [1:0] xm_be,
    output logic        xm_ack,   output logic [15:0] xm_q,
    input  logic        ram_req,  input  logic        ram_we,
    input  logic [16:0] ram_addr, input  logic [15:0] ram_d,
    input  logic  [1:0] ram_be,
    output logic        ram_ack,  output logic [15:0] ram_q,
    output logic [15:0] gfx_flushes, srom_misses, mrom_misses,
    // core_top's power-on SRAM test, on the same port, when st_run is high
    input  logic        st_run,
    output logic        st_done,
    output logic [15:0] st_rd0, st_rd1
);
    wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    wire        SDRAM_CKE, SDRAM_CLK;
    wire [16:0] sram_a; wire [15:0] sram_dq;
    wire        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;

    logic t_req, t_we; logic [16:0] t_addr; logic [15:0] t_d;
    sram_selftest u_st (
        .clk(clk), .hold(!st_run),
        .req(t_req), .we(t_we), .addr(t_addr), .d(t_d), .ack(ram_ack), .q(ram_q),
        .done(st_done), .rd0(st_rd0), .rd1(st_rd1)
    );

    smashtv_mem dut (
        .clk(clk), .clk_sdram(clk), .init(init), .ready(ready),
        .rd_late(rd_late), .burst_slow(burst_slow), .sram_slow(1'b0), .sram_slow_wr(1'b0),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_active(dl_active),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_q(mrom_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .gfx_req(gfx_req), .gfx_addr(gfx_addr), .gfx_ack(gfx_ack), .gfx_q(gfx_q),
        .xm_req(xm_req), .xm_we(xm_we), .xm_addr(xm_addr), .xm_d(xm_d), .xm_be(xm_be),
        .xm_ack(xm_ack), .xm_q(xm_q),
        .ram_req(st_run ? t_req : ram_req), .ram_we(st_run ? t_we : ram_we),
        .ram_addr(st_run ? t_addr : ram_addr), .ram_d(st_run ? t_d : ram_d), .ram_be(st_run ? 2'b11 : ram_be),
        .ram_ack(ram_ack), .ram_q(ram_q),
        .gfx_flushes(gfx_flushes), .srom_misses(srom_misses), .mrom_misses(mrom_misses),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n), .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    sdram_model #(.AW(24)) chip (
        .clk(clk), .dq(SDRAM_DQ), .a(SDRAM_A), .ba(SDRAM_BA),
        .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH), .cs_n(SDRAM_nCS),
        .ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS), .we_n(SDRAM_nWE), .cke(SDRAM_CKE)
    );
    sram_model sram (.clk(clk), .a(sram_a), .dq(sram_dq), .oe_n(sram_oe_n), .we_n(sram_we_n),
                     .ub_n(sram_ub_n), .lb_n(sram_lb_n));
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{SDRAM_CLK};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire

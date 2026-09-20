// The whole core on the Pocket's real memory glue (CLAUDE.md step 7):
// rtl/smashtv_core.sv against target/pocket/smashtv_mem.sv, sdram_ctrl and
// sram_port, with behavioural chips on the far side of the pins.  The fast
// bench (tb_machine_top) answers every port from an array in one clock, which
// is why it says nothing about the arbiter, the read-ahead, the download or
// how fast the CPU really runs; this does.  The image goes in through the
// download port, as the Pocket sends it.
`default_nettype none
module tb_pocket_top #(
    // The Pocket's video clock, in system clocks: 96 MHz / PLL outclk_1.  The
    // bench makes pix_sync from it the way core_top does and hands the driver
    // the pixel the Pocket would sample, so a PLL that disagrees with the
    // core's dot divider garbles these pictures as it garbles the real one.
    // (It did, on the first build to reach hardware: VID_DIV was 14, the
    // divider 12, and every bench had pix_sync tied to 0.)  sim/lint.sh checks
    // the PLL against the divider; run this with -GVID_DIV=14 to see the static.
    parameter int VID_DIV = 12
) (
    input  logic        clk,
    input  logic        reset,            // the Pocket's part: high through power-up and download
    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    input  logic [15:0] in0, in1, dsw,
    input  logic        pause,
    output logic [23:0] rgb,
    output logic        de, dot_ce, vblank,
    output logic        de_pad,           // the enable as the Pocket gets it, after rtl/stv_pad.sv
    output logic [23:0] rgb_pad,
    output logic signed [15:0] snd,
    output logic [31:0] dbg_pc,
    output logic        dbg_unimpl,
    output logic  [7:0] dbg_ctrl,
    output logic [15:0] snd_pc, snd_stalls, snd_word, gfx_flushes, srom_misses, mrom_misses,
    output logic        mem_ready
);
    logic        mrom_req, mrom_ack;  logic [16:0] mrom_addr;  logic [15:0] mrom_q;
    logic        srom_req, srom_ack;  logic [17:0] srom_addr;  logic  [7:0] srom_q;
    logic        gfx_req,  gfx_ack;   logic [18:0] gfx_addr;   logic [31:0] gfx_q;
    logic        xm_req, xm_we, xm_ack;   logic [16:0] xm_addr;  logic [15:0] xm_d, xm_q;  logic [1:0] xm_be;
    logic        ram_req, ram_we, ram_ack; logic [16:0] ram_addr; logic [15:0] ram_d, ram_q;

    wire [15:0] dram_dq;  wire [12:0] dram_a;  wire [1:0] dram_ba;
    wire        dram_dqml, dram_dqmh, dram_clk, dram_cke, dram_cs_n, dram_ras_n, dram_cas_n, dram_we_n;
    wire [16:0] sram_a;   wire [15:0] sram_dq;
    wire        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;

    // The SDRAM must initialise before the download, so it is released by its
    // own short power-up count; the driver raises `reset` first.
    logic [7:0] por;
    logic       seen_reset;
    always_ff @(posedge clk) begin
        if (reset && !seen_reset) begin seen_reset <= 1'b1; por <= '0; end
        else if (!(&por)) por <= por + 8'd1;
    end
    wire mem_init = !seen_reset || !(&por);

    smashtv_mem u_mem (
        .clk(clk), .clk_sdram(clk), .init(mem_init), .ready(mem_ready),
        .rd_late(1'b1), .burst_slow(1'b0), .sram_slow(1'b0), .sram_slow_wr(1'b0),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_active(reset),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_q(mrom_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .gfx_req(gfx_req), .gfx_addr(gfx_addr), .gfx_ack(gfx_ack), .gfx_q(gfx_q),
        .xm_req(xm_req), .xm_we(xm_we), .xm_addr(xm_addr), .xm_d(xm_d), .xm_be(xm_be),
        .xm_ack(xm_ack), .xm_q(xm_q),
        .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_d(ram_d), .ram_be(2'b11),
        .ram_ack(ram_ack), .ram_q(ram_q),
        .gfx_flushes(gfx_flushes), .srom_misses(srom_misses), .mrom_misses(mrom_misses),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_BA(dram_ba),
        .SDRAM_DQML(dram_dqml), .SDRAM_DQMH(dram_dqmh),
        .SDRAM_nCS(dram_cs_n), .SDRAM_nWE(dram_we_n), .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n), .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    sdram_model #(.AW(24)) chip (
        .clk(clk), .dq(dram_dq), .a(dram_a), .ba(dram_ba), .dqml(dram_dqml), .dqmh(dram_dqmh),
        .cs_n(dram_cs_n), .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n), .cke(dram_cke)
    );
    sram_model sram (.clk(clk), .a(sram_a), .dq(sram_dq), .oe_n(sram_oe_n), .we_n(sram_we_n),
                     .ub_n(sram_ub_n), .lb_n(sram_lb_n));

    // clk_vid rises half a system clock after the edge that ends vcnt == 0;
    // core_top sees its toggle one edge later and pulses pix_sync for the
    // clock after that.  The Pocket samples what the core holds in vcnt == 0.
    logic [3:0] vcnt;
    always_ff @(posedge clk) vcnt <= (vcnt == 4'(VID_DIV - 1)) ? 4'd0 : vcnt + 4'd1;
    wire pix_sync = (vcnt == 4'd2);
    assign dot_ce = (vcnt == 4'd1);     // the driver samples after the edge, so one on

    smashtv_core u_core (
        .clk(clk), .rst(reset | ~mem_ready), .pause(pause), .pix_sync(pix_sync),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_q(mrom_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .gfx_req(gfx_req), .gfx_addr(gfx_addr), .gfx_ack(gfx_ack), .gfx_q(gfx_q),
        .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_d(ram_d),
        .ram_ack(ram_ack), .ram_q(ram_q),
        .xm_req(xm_req), .xm_we(xm_we), .xm_addr(xm_addr), .xm_d(xm_d), .xm_be(xm_be),
        .xm_ack(xm_ack), .xm_q(xm_q),
        .in0(in0), .in1(in1), .dsw(dsw),
        .rgb(rgb), .hsync(), .vsync(), .hblank(), .vblank(vblank), .pix_ce(), .de(de),
        .snd(snd),
        .dbg_pc(dbg_pc), .dbg_unimpl(dbg_unimpl), .dbg_ctrl(dbg_ctrl),
        .dbg_snd_pc(snd_pc), .dbg_snd_stalls(snd_stalls), .dbg_snd_word(snd_word)
    );

    // what core_top puts between the core and the Pocket
    stv_pad u_pad (
        .clk(clk), .cen_dot(u_core.pix_ce),
        .rgb_i(rgb), .de_i(de), .hs_i(1'b0), .vs_i(1'b0), .hb_i(1'b0), .vb_i(vblank),
        .rgb_o(rgb_pad), .de_o(de_pad), .hs_o(), .vs_o(), .hb_o(), .vb_o()
    );

    // Two requests' acks that coincide with another client's rising request
    // on a shared port are what METHODOLOGY section 5.17 is about.  The
    // graphics port is the shared one here (the blitter and the CPU's
    // window); count the coincidences so that "it survived them" is a
    // statement about something that happened.
    int gfx_races;
    logic cg_req_d;
    always_ff @(posedge clk) begin
        cg_req_d <= u_core.u_main.cg_req;
        if (reset) gfx_races <= 0;
        else if (gfx_ack && u_core.u_main.cg_req && !cg_req_d) gfx_races <= gfx_races + 1;
    end
    final $display("graphics-port ack/request coincidences: %0d", gfx_races);

    // what the bring-up panel's row 2 will show (docs/bringup.md)
    logic seen_p, seen_s, seen_g;
    always_ff @(posedge clk) begin
        if (reset) begin seen_p <= 1'b0; seen_s <= 1'b0; seen_g <= 1'b0; end
        else begin
            if (mrom_ack && !seen_p) begin seen_p <= 1'b1; $display("first program ROM word fetched: %04x", mrom_q); end
            if (srom_ack && !seen_s) begin seen_s <= 1'b1; $display("first sound ROM byte fetched: %02x", srom_q); end
            if (gfx_ack  && !seen_g) begin seen_g <= 1'b1; $display("first graphics word fetched: %08x (address %05x)", gfx_q, gfx_addr); end
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{dram_clk};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire

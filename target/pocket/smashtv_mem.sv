//------------------------------------------------------------------------------
// The Pocket's memories behind the core's ports (docs/core-design.md section 2).
//
//              region              size     image at    SDRAM word
//   SDRAM   TMS34010 program       256 KB   0x000000    0x000000   131072 words
//           MC6809E sound          192 KB   0x040000    0x020000    98304 words
//           graphics               1.5 MB   0x070000    0x100000   786432 words
//           frame-buffer rows 256-509  (not in the image)  0x400000   131072 words
//   SRAM    main RAM 0x00000, CMOS 0x10000, palette read-back 0x14000 (words)
//
// The image arrives from the Pocket as a stream of bytes in the order
// smashtv.mra builds it, and is written into SDRAM a word at a time through
// the same controller the core reads it back through.  The bases are powers
// of two and every region fits inside its own, so the offsets go in with an
// OR and cost no adder.
//
// Who reads what, and how:
//
//   random access, one word, nine clocks: the download, the TMS34010's
//     program fetches and the 6809's ROM (each behind a rom_cache.sv), and
//     frame-buffer rows 256-509;
//   the burst port, one word every two clocks: the graphics ROM, READ AHEAD.
//     The blitter walks a sprite's pixels forwards, four to a 32-bit image
//     word, and wants a word every sixteen clocks; asked for one at a time
//     that is a nine-clock access per word with the CPU's fetches queued
//     behind every one.  So the port keeps a window of the next words in a
//     32-entry FIFO, refilled eight image words to a burst, and a request
//     is answered from it; one outside the window throws it away and starts
//     again there.  The CPU's own reads of the graphics ROM come through the
//     same port (rtl/stv_main.sv latches whose turn it is) and cost the
//     blitter a refill, which at 479 words a frame (measured) is nothing.
//------------------------------------------------------------------------------
`default_nettype none

module smashtv_mem (
    input  logic        clk,            // 96 MHz
    input  logic        clk_sdram,      // 96 MHz, phase shifted, drives the pin
    input  logic        init,           // hold to (re)initialise the SDRAM
    output logic        ready,

    input  logic        rd_late,        // SDRAM diagnostics, from the Pocket menu
    input  logic        burst_slow,
    input  logic        sram_slow,
    input  logic        sram_slow_wr,

    // the ROM image arriving from the Pocket
    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    input  logic        dl_active,

    // core ports: level request, one-clock ack with the data
    input  logic        mrom_req,  input  logic [16:0] mrom_addr,
    output logic        mrom_ack,  output logic [15:0] mrom_q,

    input  logic        srom_req,  input  logic [17:0] srom_addr,
    output logic        srom_ack,  output logic  [7:0] srom_q,

    input  logic        gfx_req,   input  logic [18:0] gfx_addr,
    output logic        gfx_ack,   output logic [31:0] gfx_q,

    input  logic        xm_req,    input  logic        xm_we,
    input  logic [16:0] xm_addr,   input  logic [15:0] xm_d,
    input  logic  [1:0] xm_be,
    output logic        xm_ack,    output logic [15:0] xm_q,

    input  logic        ram_req,   input  logic        ram_we,
    input  logic [16:0] ram_addr,  input  logic [15:0] ram_d,
    input  logic  [1:0] ram_be,
    output logic        ram_ack,   output logic [15:0] ram_q,

    // what the read-ahead is doing, for the benches and the bring-up panel
    output logic [15:0] gfx_flushes,    // windows thrown away
    output logic [15:0] srom_misses,    // sound ROM reads that had to go to the SDRAM
    output logic [15:0] mrom_misses,    // program fetches that had to

    // SDRAM pins
    inout  wire  [15:0] SDRAM_DQ,
    output logic [12:0] SDRAM_A,
    output logic        SDRAM_DQML, SDRAM_DQMH,
    output logic  [1:0] SDRAM_BA,
    output logic        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS,
    output logic        SDRAM_CKE, SDRAM_CLK,

    // SRAM pins
    output logic [16:0] sram_a,
    inout  wire  [15:0] sram_dq,
    output logic        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n
);
    // Where each region starts, as an SDRAM word address, and where it starts
    // in the image, as a byte offset.  Both are in smashtv.mra's comment and
    // in sim/tb_mem.cpp, and tools/verify_rom.py checks the image against
    // MAME; change one and all four have to change together.
    localparam logic [24:1] PROG_W = 24'h000000;   // 0x00000..0x1FFFF
    localparam logic [24:1] SND_W  = 24'h020000;   // 0x20000..0x37FFF
    localparam logic [24:1] GFX_W  = 24'h100000;   // 0x100000..0x1BFFFF
    localparam logic [24:1] XM_W   = 24'h400000;   // 0x400000..0x41FFFF, SDRAM bank 1
    localparam logic [24:0] SND_B  = 25'h040000;
    localparam logic [24:0] GFX_B  = 25'h070000;

    // ------------------------------------------------------------ download
    // A byte at a time from the Pocket, paired into a 16-bit word because the
    // image is big-endian throughout.  The loader cannot be told to wait --
    // it sends a byte every eight clocks whatever the SDRAM is doing -- so
    // the words go into a FIFO deep enough to ride out a refresh or a row
    // change.  Nothing here may ever drop or alter a word.
    //
    // This was a single pending word, and it was wrong the way Cadash's was
    // before it: the even byte of the next word landed in the pending word's
    // high half while that word was still waiting for its write, so what
    // finally went out was this word's low byte under the next word's high
    // one.  The first words of every region read back right, which is what
    // the panel showed, and the image behind them was peppered with bad
    // words; the CPU of the core this was found in reached one within a few
    // frames and never came back -- a black screen on the first hardware run.
    // The ideal-memory bench cannot see it.  sim/run_pocket.sh, at the
    // loader's rate, can: it crashed the same way before this and boots now.
    // Each byte is also taken once, on the rising edge of the strobe, which
    // the Pocket holds for several clocks.
    localparam int DLQ = 64;
    logic [39:0] dlq [DLQ];             // {word address [24:1], data [15:0]}
    logic  [6:0] dlq_wp, dlq_rp;
    logic  [7:0] dl_hi;
    logic        dl_we_d;
    wire         dlq_empty = (dlq_wp == dlq_rp);
    wire  [39:0] dlq_head  = dlq[dlq_rp[5:0]];
    wire         nb        = dl_we && !dl_we_d;   // one byte, once

    wire [24:1] dl_target = (dl_addr >= GFX_B) ? (GFX_W | 24'((dl_addr - GFX_B) >> 1))
                          : (dl_addr >= SND_B) ? (SND_W | 24'((dl_addr - SND_B) >> 1))
                                               : (PROG_W | 24'(dl_addr >> 1));

    always_ff @(posedge clk) begin
        dl_we_d <= dl_we;
        if (init) begin
            dlq_wp <= '0;
            dlq_rp <= '0;
        end else begin
            if (nb) begin
                if (!dl_addr[0]) dl_hi <= dl_data;
                else begin
                    dlq[dlq_wp[5:0]] <= {dl_target, dl_hi, dl_data};
                    dlq_wp <= dlq_wp + 7'd1;
                end
            end
            if (!dlq_empty && dl_ack) dlq_rp <= dlq_rp + 7'd1;
        end
    end

    // ---------------------------------------------------- SDRAM clients
    // 0 download (writes), 1 the TMS34010's program, 2 the 6809's ROM,
    // 3 frame-buffer rows 256-509.  The controller serves them round-robin
    // and lets one in after every 32-word chunk of a burst.
    localparam int NCLI = 4;
    logic [24:1] c_addr  [NCLI];
    logic        c_req   [NCLI];
    logic        c_we    [NCLI];
    logic [15:0] c_wdata [NCLI];
    logic  [1:0] c_be    [NCLI];
    logic        c_ack   [NCLI];
    logic [15:0] rdata;

    wire dl_ack = c_ack[0];
    assign c_addr[0]  = dlq_head[39:16];
    assign c_req[0]   = !dlq_empty;
    assign c_we[0]    = 1'b1;
    assign c_wdata[0] = dlq_head[15:0];
    assign c_be[0]    = 2'b11;

    // The TMS34010's program, through the same kind of cache as the sound
    // ROM.  Its state machine steps one clock in three so that it can be
    // timed, and an opcode fetch that takes an SDRAM access on top of that
    // leaves a one-cycle instruction no time: measured, play ran at 90-94% of
    // MAME's CPU speed without this.  A hit is three clocks.
    logic        pc_req, pc_ack;
    logic [16:0] pc_addr;
    logic [15:0] pc_q;
    rom_cache #(.AW(17), .IDX(11)) u_pcache (
        .clk(clk), .flush(init || dl_active),
        .req(mrom_req), .addr(mrom_addr), .ack(mrom_ack), .q(mrom_q),
        .m_req(pc_req), .m_addr(pc_addr), .m_ack(pc_ack), .m_q(pc_q),
        .misses(mrom_misses)
    );
    assign c_addr[1]  = PROG_W | {7'd0, pc_addr};
    assign c_req[1]   = pc_req && !pc_ack;
    assign c_we[1]    = 1'b0;
    assign c_wdata[1] = 16'd0;
    assign c_be[1]    = 2'b11;
    always_ff @(posedge clk) begin
        pc_ack <= c_ack[1];
        if (c_ack[1]) pc_q <= rdata;
    end

    // The 6809 reads bytes; the SDRAM holds them two to a word, high byte
    // first.  It reads them through a cache, because it cannot wait
    // (rom_cache.sv says why).
    logic        sc_req, sc_ack;
    logic [16:0] sc_addr;
    logic [15:0] sc_q, srom_w;
    rom_cache #(.AW(17), .IDX(11)) u_scache (
        .clk(clk), .flush(init || dl_active),
        .req(srom_req), .addr(srom_addr[17:1]), .ack(srom_ack), .q(srom_w),
        .m_req(sc_req), .m_addr(sc_addr), .m_ack(sc_ack), .m_q(sc_q),
        .misses(srom_misses)
    );
    assign srom_q = srom_addr[0] ? srom_w[7:0] : srom_w[15:8];

    assign c_addr[2]  = SND_W | {7'd0, sc_addr};
    assign c_req[2]   = sc_req && !sc_ack;
    assign c_we[2]    = 1'b0;
    assign c_wdata[2] = 16'd0;
    assign c_be[2]    = 2'b11;
    always_ff @(posedge clk) begin
        sc_ack <= c_ack[2];
        if (c_ack[2]) sc_q <= rdata;
    end

    // Frame-buffer rows 256-509.  The request is registered here: it comes
    // straight out of the blitter's pixel logic (source word -> transparency
    // -> row test -> request), and unregistered that ran on through the
    // arbiter to the SDRAM's address pins, -1.9 ns in the sixth compile.
    logic        xq_req, xq_we;
    logic [16:0] xq_addr;
    logic [15:0] xq_d;
    logic  [1:0] xq_be;
    always_ff @(posedge clk) begin
        xq_req  <= xm_req && !xm_ack && !c_ack[3] && !init;
        xq_we   <= xm_we; xq_addr <= xm_addr; xq_d <= xm_d; xq_be <= xm_be;
    end
    assign c_addr[3]  = XM_W | {7'd0, xq_addr};
    assign c_req[3]   = xq_req && !xm_ack;
    assign c_we[3]    = xq_we;
    assign c_wdata[3] = xq_d;
    assign c_be[3]    = xq_be;
    always_ff @(posedge clk) begin
        xm_ack <= c_ack[3];
        if (c_ack[3]) xm_q <= rdata;
    end

    // ------------------------------------------- the graphics read-ahead
    // `ra_base` is the image word at the head of the FIFO and `ra_cnt` how
    // many are in it; `ra_fill` is the next one the burst will deliver.  A
    // request for the head is answered and popped; one further into the
    // window (a clipped blit skips words) pops until it is the head; one the
    // running burst is about to deliver waits for it; anything else throws
    // the window away and starts a burst at the request.  The controller
    // wants b_req low for a clock between bursts (R_GAP).
    localparam int RA_N = 32;                       // FIFO entries
    // Eight image words to a burst.  It was sixteen, a whole 32-word chunk of
    // the controller's, and a 6809 ROM miss that arrived behind one waited
    // seventy clocks of the forty-four it has (sim/run_pocket.sh: 5 stretched
    // 6809 cycles a frame in play).  Eight still delivers a word every five
    // clocks against the blitter's sixteen.
    localparam logic [9:0] RA_BURST = 10'd16;       // SDRAM words: 8 image words
    typedef enum logic [1:0] { R_IDLE, R_RUN, R_KILL, R_GAP } rst_t;
    rst_t        rs;
    logic [31:0] ra_mem [RA_N];
    logic  [4:0] ra_rp, ra_wp;
    logic  [5:0] ra_cnt;
    logic [18:0] ra_base, ra_fill, ra_stop;
    logic        ra_valid;                          // the window means something
    logic [15:0] ra_hi;
    logic        b_wr, b_done;
    logic  [9:0] b_idx;
    logic [15:0] b_data;
    logic [18:0] b_start;

    // The request is registered on the way in (it comes from the far side of
    // the chip, and the window arithmetic below is deep enough without the
    // journey).  `serve` keeps the registered copy from outliving its answer
    // by a clock, when the head has already moved on.
    logic        want;
    logic [18:0] g_addr;
    wire         serve;
    always_ff @(posedge clk) begin
        want   <= gfx_req && !gfx_ack && !serve && !init;
        g_addr <= gfx_addr;
    end
    wire  [18:0] ahead   = g_addr - ra_base;        // how far past the head
    wire         in_fifo = ra_valid && (ahead < {13'd0, ra_cnt});
    // ...or on its way: the running burst stops at ra_stop
    wire         coming  = ra_valid && (rs == R_RUN) && (ahead < (ra_stop - ra_base));
    wire         miss    = want && !in_fifo && !coming;
    wire         push    = b_wr && b_idx[0] && (rs == R_RUN);
    wire         pop     = want && in_fifo;         // serve the head or skip it
    assign       serve   = pop && (ahead == 19'd0);

    always_ff @(posedge clk) begin
        gfx_ack <= 1'b0;
        if (b_wr && !b_idx[0]) ra_hi <= b_data;
        if (init) begin
            rs <= R_IDLE; ra_valid <= 1'b0; ra_cnt <= '0; ra_rp <= '0; ra_wp <= '0;
            ra_base <= '0; ra_fill <= '0; ra_stop <= '0; gfx_flushes <= '0;
        end else begin
            if (push) begin
                ra_mem[ra_wp] <= {ra_hi, b_data};
                ra_wp   <= ra_wp + 5'd1;
                ra_fill <= ra_fill + 19'd1;
            end
            if (pop) begin
                if (serve) begin gfx_q <= ra_mem[ra_rp]; gfx_ack <= 1'b1; end
                ra_rp   <= ra_rp + 5'd1;
                ra_base <= ra_base + 19'd1;
            end
            ra_cnt <= ra_cnt + {5'd0, push} - {5'd0, pop};

            case (rs)
                R_IDLE: begin
                    if (miss) begin
                        // start again at the request
                        ra_valid <= 1'b1; ra_cnt <= '0; ra_rp <= '0; ra_wp <= '0;
                        ra_base <= g_addr; ra_fill <= g_addr;
                        b_start <= g_addr; ra_stop <= g_addr + 19'd8;
                        rs <= R_RUN;
                    end else if (ra_valid && ra_cnt <= 6'd24 && !dl_active) begin
                        b_start <= ra_fill; ra_stop <= ra_fill + 19'd8;
                        rs <= R_RUN;
                    end
                end
                R_RUN:  if (b_done)    rs <= R_GAP;
                        else if (miss) begin
                            rs <= R_KILL;
                            if (!(&gfx_flushes)) gfx_flushes <= gfx_flushes + 16'd1;
                        end
                // cut the burst short; what it still delivers is not pushed
                R_KILL: if (b_done) begin ra_valid <= 1'b0; ra_cnt <= '0; rs <= R_GAP; end
                default: rs <= R_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------- SDRAM
    sdram_ctrl #(.NCLI(NCLI)) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init),
        .rd_late(rd_late), .burst_slow(burst_slow), .ready(ready),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata),
        .c_be(c_be), .c_ack(c_ack), .rdata(rdata),
        .b_addr(GFX_W | {4'd0, b_start, 1'b0}), .b_len(RA_BURST),
        .b_req(rs == R_RUN || rs == R_KILL), .b_abort(rs == R_KILL),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(1'b0), .b_wdata(16'd0), .b_be(2'b00), .b_widx()
    );

    // -------------------------------------------------------------- SRAM
    sram_port u_sram (
        .clk(clk), .reset(init), .slow(sram_slow), .slow_wr(sram_slow_wr),
        .req(ram_req && !dl_active), .we(ram_we), .addr(ram_addr),
        .be(ram_be), .wdata(ram_d), .ack(ram_ack), .q(ram_q),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );
endmodule

`default_nettype wire

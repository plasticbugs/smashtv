//------------------------------------------------------------------------------
// The Williams DMA blitter (docs/hardware.md section 7.3).
//
// Ten 16-bit registers; writing register 0 with bit 15 set starts a blit.  The
// draw order below is the numbered list in docs/hardware.md section 7.3, which
// is `dma_w` then `dma_draw` in ref/mame/mame/midway/midyunit_v.cpp, and
// tools/render_model.py is the same arithmetic in Python, checked against MAME
// on 76 frames.
//
// Two things about it are worth knowing before reading the code:
//
//   * it never reads its destination.  All sixteen commands decide from the
//     source pixel alone, so there is no read-modify-write path and
//     transparency is a write enable.
//   * the source always runs forwards.  Flip x walks the *destination*
//     backwards and adjusts the start and the row stride; the graphics
//     address only ever increments, which is why one 32-bit fetch can serve
//     four pixels whichever way the blit runs.
//
// It is rate limited to the board's one pixel per `cen` -- 41 ns -- rather
// than run as fast as the memory allows (docs/core-design.md section 3).
// MAME draws the whole blit in an instant and reports it finished 41 ns x
// width x height later; real silicon, and this, draw progressively.  The
// game leaves a wide margin: measured, it draws rows 134-251 in vertical
// blank and rows 1-133 at the mid-frame interrupt, in both cases at least a
// hundred raster lines away from the row being scanned out.  stv_vram's
// `race` counter is what checks that, and is meant to read zero.
//------------------------------------------------------------------------------
`default_nettype none

module stv_blit (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen,            // one source pixel per pulse: 41 ns

    // ---------------- registers, as the CPU sees them at 0x01A80000
    input  logic        reg_we,
    input  logic  [3:0] reg_a,
    input  logic [15:0] reg_d,
    input  logic  [1:0] reg_be,
    output logic [15:0] reg_q,

    // ---------------- graphics source: one 32-bit word is four pixels.
    // The window is 8 M pixels; the nine EPROMs fill the first 1,572,864 and
    // the rest reads as zero in MAME, so the core returns zero above it.
    // Measured over 3,831 blits in eight windows, the highest source pixel
    // this game asks for is 1,369,087 -- inside the real data, never past it.
    output logic        gfx_req,
    output logic [20:0] gfx_addr,
    input  logic        gfx_ack,
    input  logic [31:0] gfx_q,

    // ---------------- frame buffer
    output logic        fb_req,
    output logic  [8:0] fb_row,
    output logic  [8:0] fb_col,
    output logic  [7:0] fb_pix,
    output logic  [7:0] fb_pal,
    input  logic        fb_gnt,

    // ---------------- to the CPU
    output logic        busy,           // command bit 15, as the game polls it
    output logic        irq,            // INT1: set when a blit finishes
    // ---------------- instrumentation
    output logic [31:0] px_drawn,       // source pixels since reset
    output logic [31:0] gfx_stall,      // clocks the source fetch held up
    output logic [31:0] busy_clocks     // clocks not idle, for the budget
);
    // The register file.  Only 0..9 exist; docs/hardware.md 7.3 names them.
    localparam int R_CMD = 0, R_ROWB = 1, R_OFFL = 2, R_OFFH = 3, R_XST = 4,
                   R_YST = 5, R_WID = 6, R_HGT = 7, R_PAL = 8, R_COL = 9;
    logic [15:0] regs [16];

    // ------------------------------------------------------------ the blit
    typedef enum logic [3:0] {
        B_IDLE, B_S1, B_S2, B_S3, B_S4, B_S5, B_ROW, B_FETCH, B_PIX, B_END
    } bst_t;
    bst_t bst;

    logic signed [17:0] rb;             // row stride, in pixels, signed
    logic signed [17:0] w, h;           // after clipping; may go negative
    logic signed [17:0] xs, ys;         // after clipping
    logic        [31:0] off;            // source bit address
    logic        [31:0] clipoff;        // bits the clipping skips
    logic        [22:0] src;            // source pixel index for this row
    logic        [22:0] o;              // running source pixel index
    logic signed [17:0] n;              // pixels left in the row
    logic        [17:0] ycnt;
    logic          [8:0] ty, tx;
    logic          [7:0] pal, col;
    logic          [3:0] op;
    logic                flipx;
    logic         [15:0] cmd;

    // The source word the pixel loop is using, and the next one, prefetched.
    // Without the prefetch the loop paid the fetch latency every fourth
    // pixel: measured at eight clocks of latency it ran at 5.9 clocks a pixel
    // against the board's 3.936, and the game's blits arrived faster than it
    // could finish them -- 204,000 clocks a frame of the bench waiting.  With
    // it the only stall is one per row, where the source address jumps.
    logic [31:0] gword, gpre;
    logic [20:0] gidx, gpidx;
    logic        gvalid, gpvalid;
    logic        greq;                  // a fetch is outstanding
    logic        gfor_pre;              // ...and it is for the prefetch slot

    wire [20:0] want = o[22:2];
    wire        hit  = gvalid && (gidx == want);
    wire        phit = gpvalid && (gpidx == want);
    // the two bits of this pixel, out of each of the three plane bytes
    wire  [1:0] sh   = o[1:0];
    wire  [7:0] c0   = gword[31:24], c1 = gword[23:16], c2 = gword[15:8];
    wire  [1:0] b0   = c0[2*sh +: 2];
    wire  [1:0] b1   = c1[2*sh +: 2];
    wire  [1:0] b2   = c2[2*sh +: 2];
    wire  [7:0] spix = {2'b00, b2, b1, b0};

    // what the command does with that pixel (docs/hardware.md 7.3)
    logic       pwe;
    logic [7:0] pval;
    always_comb begin
        pwe  = 1'b1;
        pval = spix;
        unique case (op)
            4'h0:                      pwe = 1'b0;
            4'h1:                      pwe = (spix == 8'd0);
            4'h2:                      pwe = (spix != 8'd0);
            4'h3:                      ;
            4'h4, 4'h5: begin          pwe = (spix == 8'd0); pval = col; end
            4'h6, 4'h7:                pval = (spix == 8'd0) ? col : spix;
            4'h8, 4'hA: begin          pwe = (spix != 8'd0); pval = col; end
            4'h9, 4'hB:                pval = (spix != 8'd0) ? col : 8'd0;
            default:                   pval = col;              // C, D, E, F
        endcase
    end

    // (-ys * rb) << 3, the bits the y clipping skips.  One multiply, used
    // once per blit; the operands are widened first so the product is not an
    // 18-bit one silently assigned to 36 bits.
    logic signed [17:0] nys;
    logic signed [35:0] yskip;
    always_comb begin
        nys   = -ys;
        yskip = 36'(nys) * 36'(rb);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            bst      <= B_IDLE;
            irq      <= 1'b0;
            px_drawn <= '0;
            gfx_stall<= '0;
            busy_clocks <= '0;
            for (int i = 0; i < 16; i++) regs[i] <= '0;
        end else begin
            // ---- register writes
            if (reg_we) begin
                if (reg_be[0]) regs[reg_a][7:0]  <= reg_d[7:0];
                if (reg_be[1]) regs[reg_a][15:8] <= reg_d[15:8];
                if (reg_a == 4'd0) begin
                    irq <= 1'b0;                 // any write to 0 clears INT1
                    if (reg_d[15] && reg_be[1]) begin
                        cmd <= reg_d;
                        bst <= B_S1;
                    end
                end
            end

            if (bst != B_IDLE) busy_clocks <= busy_clocks + 32'd1;

            case (bst)
                B_IDLE: ;

                // 1. latch the parameters
                B_S1: begin
                    rb   <= 18'(signed'({{2{regs[R_ROWB][15]}}, regs[R_ROWB]}));
                    w    <= 18'(signed'({2'b00, regs[R_WID]}));
                    h    <= 18'(signed'({2'b00, regs[R_HGT]}));
                    xs   <= 18'(signed'({{2{regs[R_XST][15]}}, regs[R_XST]}));
                    ys   <= 18'(signed'({{2{regs[R_YST][15]}}, regs[R_YST]}));
                    pal  <= regs[R_PAL][7:0];
                    col  <= regs[R_COL][7:0];
                    off  <= {regs[R_OFFH], regs[R_OFFL]};
                    op   <= cmd[3:0];
                    flipx<= cmd[4];
                    clipoff <= '0;
                    bst  <= B_S2;
                end

                // 3. the flip-x adjustment, or the plain row stride
                B_S2: begin
                    if (flipx) begin
                        off <= off - (32'(w - 18'sd1) << 3);
                        rb  <= (rb - w + 18'sd3) & ~18'sd3;
                        xs  <= xs + w - 18'sd1;
                    end else begin
                        rb  <= (rb + w + 18'sd3) & ~18'sd3;
                    end
                    bst <= B_S3;
                end

                // 4. clip in y
                B_S3: begin
                    if (ys < 0) begin
                        h       <= h + ys;
                        clipoff <= clipoff + 32'(yskip[31:0] <<< 3);
                        ys      <= '0;
                    end else if (ys + h > 18'sd512) begin
                        h       <= 18'sd512 - ys;
                    end
                    bst <= B_S4;
                end

                // 5. clip in x, in whichever direction the blit runs
                B_S4: begin
                    if (!flipx) begin
                        if (xs < 0) begin
                            w       <= w + xs;
                            clipoff <= clipoff + (32'(-xs) << 3);
                            xs      <= '0;
                        end else if (xs + w > 18'sd512) begin
                            w       <= 18'sd512 - xs;
                        end
                    end else begin
                        if (xs >= 18'sd512) begin
                            w       <= w - (xs - 18'sd511);
                            clipoff <= clipoff + (32'(xs - 18'sd511) << 3);
                            xs      <= 18'sd511;
                        end else if (xs - w < 0) begin
                            w       <= xs;
                        end
                    end
                    bst <= B_S5;
                end

                // 6./7. turn the source address into a pixel index.  A
                // separate state because it needs the clipping's own
                // contribution to `clipoff`, which B_S3 and B_S4 only have
                // written by now.  `off` is a bit address in the graphics
                // window; below the window's base MAME adds the base, which
                // makes the subtraction that follows a no-op.
                B_S5: begin
                    src  <= 23'(((off >= 32'h0200_0000 ? off - 32'h0200_0000 : off)
                                 + clipoff) >> 3);
                    ycnt <= '0;
                    bst  <= B_ROW;
                end

                // 8. one row at a time
                B_ROW: begin
                    if (h <= 0 || w <= 0 || 18'(ycnt) >= h) begin
                        bst <= B_END;
                    end else begin
                        ty  <= 9'(ys + 18'(ycnt));
                        tx  <= xs[8:0];
                        o   <= src;
                        n   <= w;
                        bst <= B_FETCH;
                    end
                end

                // Take the word from whichever slot holds it.  The slots
                // themselves belong to the fetcher below, which does the
                // promotion this same clock; a miss in both is a stall and
                // the fetcher throws the stale slots away.
                B_FETCH: if (hit || phit) bst <= B_PIX;
                         else              gfx_stall <= gfx_stall + 32'd1;

                B_PIX: if (cen) begin
                    if (!pwe || fb_gnt) begin
                        px_drawn <= px_drawn + 32'd1;
                        o  <= o + 23'd1;
                        tx <= flipx ? (tx - 9'd1) : (tx + 9'd1);
                        n  <= n - 18'sd1;
                        if (n <= 18'sd1) begin
                            src  <= src + {{5{rb[17]}}, rb};
                            ycnt <= ycnt + 18'd1;
                            bst  <= B_ROW;
                        end else begin
                            bst <= B_FETCH;
                        end
                    end
                end

                B_END: begin
                    irq <= 1'b1;
                    bst <= B_IDLE;
                end

                default: bst <= B_IDLE;
            endcase
        end
    end

    // Bit 15 of the command register reads back as "busy", which is what the
    // game polls; the chip clears it when the blit finishes.  It is also a
    // port, because reading it through reg_q only works while the address
    // presented happens to be 0 -- which cost this bench its first run: the
    // blitter looked idle, every trigger landed mid-blit and restarted it,
    // and 41% of the pixels were never drawn.
    assign busy = (bst != B_IDLE);
    assign reg_q = (reg_a == 4'd0) ? {busy, regs[R_CMD][14:0]} : regs[reg_a];

    // ---------------------------------------------------------- the fetcher
    // Fills the current slot with `want`, then keeps the next slot one word
    // ahead of it.  The source address only ever increments inside a row, so
    // "one ahead" is always the right guess there.
    // A flush counts as "the current slot is needed" in the same clock it is
    // asserted, or the fetch would be aimed at gidx+1 for a slot that is
    // about to be thrown away -- and, worse, blocking the fetch while the
    // flush is up deadlocks: no fetch, no hit, so the flush never lifts.
    // That is what hung the first run of this bench.
    wire        flushing = sl_flush || sl_end;
    wire        need_cur = !gvalid || flushing;
    wire        need_pre = !need_cur && !gpvalid;
    wire [20:0] fetch_at = need_cur ? want : (gidx + 21'd1);

    // What the pixel loop asks of the slots, combinationally from its state:
    // promote the prefetch, or throw both away and start again at `want`.
    wire sl_take  = (bst == B_FETCH) && !hit && phit;
    wire sl_flush = (bst == B_FETCH) && !hit && !phit;
    wire sl_end   = (bst == B_END);

    always_ff @(posedge clk) begin
        if (rst) begin
            greq <= 1'b0; gvalid <= 1'b0; gpvalid <= 1'b0;
        end else begin
            // 1. what the pixel loop wants of the slots
            if (sl_take) begin
                gword   <= gpre;
                gidx    <= gpidx;
                gvalid  <= 1'b1;
                gpvalid <= 1'b0;
            end else if (sl_flush || sl_end) begin
                gvalid  <= 1'b0;
                gpvalid <= 1'b0;
            end
            // 2. the fetch itself, which wins on the clock its data arrives
            if (!greq) begin
                if ((bst != B_IDLE) && (need_cur || need_pre)) begin
                    greq     <= 1'b1;
                    gfx_addr <= fetch_at;
                    gfor_pre <= !need_cur;
                end
            end else if (gfx_ack) begin
                greq <= 1'b0;
                if (gfor_pre && !sl_flush && !sl_end) begin
                    gpre    <= gfx_q;
                    gpidx   <= gfx_addr;
                    gpvalid <= 1'b1;
                end else if (!gfor_pre) begin
                    gword  <= gfx_q;
                    gidx   <= gfx_addr;
                    gvalid <= 1'b1;
                end
            end
        end
    end
    assign gfx_req = greq;

    assign fb_req = (bst == B_PIX) && cen && pwe;
    assign fb_row = ty;
    assign fb_col = tx;
    assign fb_pix = pval;
    assign fb_pal = pal;
endmodule

`default_nettype wire

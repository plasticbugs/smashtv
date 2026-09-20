// Bench wrapper for the video RTL: rtl/stv_video.sv, rtl/stv_vram.sv and
// rtl/stv_blit.sv wired together the way rtl/smashtv_core.sv will wire them,
// with behavioural memories beyond the ports.
//
// sim/tb_video.cpp loads a frozen state through the CPU's own frame-buffer
// port, replays the same trace of register writes MAME's was taken from, and
// compares the palette indices coming out with tools/render_model.py's.
// Indices, not colours: two pens can share a colour and hide a difference.
//
// What is behavioural here, so that no number out of this bench is mistaken
// for a statement about the real memory path (METHODOLOGY 5.22):
//
//   * the graphics ROM answers in GFX_LAT clocks with no contention, where
//     the real one is an SDRAM burst sharing a controller;
//   * rows 256-509 of the frame buffer answer in one clock;
//   * nothing else is in the way -- no CPU fetching code, no download.
//
// The frame buffer, the blitter, the arbitration between them and the whole
// scanout path are the real RTL.
`default_nettype none

module tb_video_top #(
    parameter int GFX_LAT = 8           // clocks from gfx_req to gfx_ack
) (
    input  logic        clk,
    input  logic        rst,

    // ---- the CPU side, driven by the bench
    input  logic        cpu_req,
    input  logic        cpu_we,
    input  logic [16:0] cpu_word,
    input  logic [15:0] cpu_d,
    input  logic  [1:0] cpu_be,
    output logic        cpu_ack,
    output logic [15:0] cpu_q,

    input  logic        blit_we,
    input  logic  [3:0] blit_a,
    input  logic [15:0] blit_d,
    input  logic  [1:0] blit_be,

    input  logic        pal_we,
    input  logic [11:0] pal_a,
    input  logic [15:0] pal_d,
    input  logic  [1:0] pal_be,

    input  logic        vreg_we,
    input  logic  [4:0] vreg_a,
    input  logic [15:0] vreg_d,

    input  logic  [7:0] ctrl,           // the system control register's low byte

    // ---- the graphics ROM, byte-addressed as the image holds it
    input  logic        gfx_we,
    input  logic [20:0] gfx_wa,         // 32-bit word index
    input  logic [31:0] gfx_wd,

    // ---- what the bench watches
    output logic [11:0] pen,
    output logic        de,
    output logic        hsync, vsync, hblank, vblank,
    output logic  [8:0] vline,
    output logic  [9:0] hdot_o,
    output logic        dot_ce,
    output logic        dpyint,
    output logic        blit_busy,
    output logic [31:0] px_drawn,
    output logic [15:0] gfx_stall,
    output logic [15:0] race,
    output logic [31:0] busy_clocks
);
    // 96 MHz / 12 = the board's 8 MHz dot clock, exactly
    logic [3:0] dotdiv;
    logic       cen_dot;
    always_ff @(posedge clk) begin
        if (rst) begin
            dotdiv <= '0;
        end else begin
            dotdiv <= (dotdiv == 4'd11) ? 4'd0 : (dotdiv + 4'd1);
        end
    end
    assign cen_dot = (dotdiv == 4'd0);

    // One source pixel per 41 ns: 96 MHz / 24.390 MHz = 3.936 clocks, so a
    // fractional accumulator.  256 * 24.390 / 96 = 65.04 -> 65/256.
    logic [7:0] blitacc;
    logic       cen_blit;
    always_ff @(posedge clk) begin
        if (rst) begin
            blitacc <= '0; cen_blit <= 1'b0;
        end else begin
            cen_blit <= (blitacc + 8'd65) < blitacc;    // carry out
            blitacc  <= blitacc + 8'd65;
        end
    end

    // ---- graphics ROM, behavioural
    logic [31:0] gfx [1 << 19];
    logic        gfx_req, gfx_ack;
    logic [20:0] gfx_addr;
    logic [31:0] gfx_q;
    logic  [3:0] gfx_cnt;
    always_ff @(posedge clk) begin
        if (gfx_we) gfx[gfx_wa[18:0]] <= gfx_wd;
        gfx_ack <= 1'b0;
        if (rst) begin
            gfx_cnt <= '0;
        end else if (gfx_req && !gfx_ack) begin
            if (gfx_cnt == 4'(GFX_LAT - 1)) begin
                gfx_cnt <= '0;
                gfx_ack <= 1'b1;
                // above the nine EPROMs the region reads as zero in MAME
                gfx_q   <= (gfx_addr < 21'h60000) ? gfx[gfx_addr[18:0]] : 32'd0;
            end else begin
                gfx_cnt <= gfx_cnt + 4'd1;
            end
        end else begin
            gfx_cnt <= '0;
        end
    end

    // ---- frame-buffer rows 256..509, behavioural, one clock
    logic [15:0] xmem [1 << 17];
    logic        xm_req, xm_we, xm_ack;
    logic [16:0] xm_addr;
    logic [15:0] xm_d, xm_q;
    logic  [1:0] xm_be;
    always_ff @(posedge clk) begin
        xm_ack <= 1'b0;
        if (xm_req && !xm_ack) begin
            if (xm_we) begin
                if (xm_be[0]) xmem[xm_addr][7:0]  <= xm_d[7:0];
                if (xm_be[1]) xmem[xm_addr][15:8] <= xm_d[15:8];
            end
            xm_q   <= xmem[xm_addr];
            xm_ack <= 1'b1;
        end
    end

    // ---- the machine's video side
    logic        rf_start, rf_valid, rf_busy, ae_start, ae_busy;
    logic  [8:0] rf_row, rf_col, ae_row;
    logic  [7:0] rf_pix, rf_pal;
    logic        bl_req, bl_gnt;
    logic  [8:0] bl_row, bl_col;
    logic  [7:0] bl_pix, bl_pal;
    logic [15:0] blit_q;
    logic [15:0] hcount_q, vcount_q;
    logic [23:0] rgb;

    stv_vram u_vram (
        .clk(clk), .rst(rst),
        .bl_req(bl_req), .bl_row(bl_row), .bl_col(bl_col),
        .bl_pix(bl_pix), .bl_pal(bl_pal), .bl_gnt(bl_gnt),
        .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_word(cpu_word),
        .cpu_d(cpu_d), .cpu_be(cpu_be), .cpu_srt(1'b0), .cpu_bank(ctrl[5]),
        .cpu_dpal(blit_q_pal), .cpu_ack(cpu_ack), .cpu_q(cpu_q),
        .rf_start(rf_start), .rf_row(rf_row), .rf_valid(rf_valid),
        .rf_col(rf_col), .rf_pix(rf_pix), .rf_pal(rf_pal), .rf_busy(rf_busy),
        .ae_start(ae_start), .ae_row(ae_row), .ae_busy(ae_busy),
        .xm_req(xm_req), .xm_we(xm_we), .xm_addr(xm_addr), .xm_d(xm_d),
        .xm_be(xm_be), .xm_ack(xm_ack), .xm_q(xm_q),
        .race(race)
    );

    // The blitter's palette register is what a CPU frame-buffer write takes
    // its palette byte from, so the bench shadows it the way the core will.
    logic [15:0] blit_q_pal;
    always_ff @(posedge clk) begin
        if (rst) blit_q_pal <= '0;
        else if (blit_we && blit_a == 4'd8) begin
            if (blit_be[0]) blit_q_pal[7:0]  <= blit_d[7:0];
            if (blit_be[1]) blit_q_pal[15:8] <= blit_d[15:8];
        end
    end

    stv_blit u_blit (
        .clk(clk), .rst(rst), .cen(cen_blit),
        .reg_we(blit_we), .reg_a(blit_a), .reg_d(blit_d), .reg_be(blit_be),
        .reg_q(blit_q),
        .gfx_req(gfx_req), .gfx_addr(gfx_addr), .gfx_ack(gfx_ack), .gfx_q(gfx_q),
        .fb_req(bl_req), .fb_row(bl_row), .fb_col(bl_col),
        .fb_pix(bl_pix), .fb_pal(bl_pal), .fb_gnt(bl_gnt),
        .busy(blit_busy), .irq(), .px_drawn(px_drawn), .gfx_stall(gfx_stall),
        .busy_clocks(busy_clocks)
    );

    stv_video u_video (
        .clk(clk), .rst(rst), .cen_dot(cen_dot),
        .vreg_we(vreg_we), .vreg_a(vreg_a), .vreg_d(vreg_d), .vreg_q(),
        .hcount_q(hcount_q), .vcount_q(vcount_q),
        .pal_we(pal_we), .pal_a(pal_a), .pal_d(pal_d), .pal_be(pal_be),
        .autoerase(~ctrl[4]),
        .rf_start(rf_start), .rf_row(rf_row), .rf_valid(rf_valid),
        .rf_col(rf_col), .rf_pix(rf_pix), .rf_pal(rf_pal), .rf_busy(rf_busy),
        .ae_start(ae_start), .ae_row(ae_row), .ae_busy(ae_busy),
        .rgb(rgb), .hsync(hsync), .vsync(vsync), .hblank(hblank),
        .vblank(vblank), .de(de), .pen(pen), .dpyint(dpyint), .hdot_o(hdot_o)
    );
    assign vline  = vcount_q[8:0];
    assign dot_ce = cen_dot;

    wire _unused = &{1'b0, hcount_q, rgb, 1'b0};
endmodule

`default_nettype wire

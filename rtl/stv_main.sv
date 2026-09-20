//------------------------------------------------------------------------------
// The Y-unit main board: the TMS34010, its address decode, the blitter, the
// frame buffer and the video, wired the way docs/hardware.md section 2 maps
// them.  Everything that is a memory chip on the board is a port here --
// program ROM, graphics ROM, the RAM that holds main RAM, CMOS and the palette's
// read-back copy, and the frame buffer's cold rows -- so the same module sits
// on ideal memories in the fast bench and on target/pocket/smashtv_mem.sv in
// the core.
//
// One bus transaction at a time: the CPU raises bus_req, the decoder hands it
// to one target, the target's ack comes back as the CPU's.  The graphics ROM
// port is shared by the CPU's window and the blitter's fetcher, and its owner
// is latched at grant (METHODOLOGY section 5.17).
//------------------------------------------------------------------------------
`default_nettype none

module stv_main (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_cpu,        // 5 MHz machine cycles
    input  logic        cen_dot,        // 8 MHz dots
    input  logic        cen_blit,       // one blitter pixel, 41 ns

    // ---------------- program ROM: 131072 words from 0xFFE00000
    output logic        mrom_req,
    output logic [16:0] mrom_addr,
    input  logic        mrom_ack,
    input  logic [15:0] mrom_q,

    // ---------------- graphics ROM: 32-bit words of four pixels
    output logic        gfx_req,
    output logic [20:0] gfx_addr,
    input  logic        gfx_ack,
    input  logic [31:0] gfx_q,

    // ---------------- RAM: main RAM at word 0x00000, CMOS at 0x10000, the
    // palette's read-back copy at 0x14000
    output logic        ram_req,
    output logic        ram_we,
    output logic [16:0] ram_addr,
    output logic [15:0] ram_d,
    input  logic        ram_ack,
    input  logic [15:0] ram_q,

    // ---------------- frame-buffer rows 256..509
    output logic        xm_req,
    output logic        xm_we,
    output logic [16:0] xm_addr,
    output logic [15:0] xm_d,
    output logic  [1:0] xm_be,
    input  logic        xm_ack,
    input  logic [15:0] xm_q,

    // ---------------- the cabinet, active low
    input  logic [15:0] in0, in1, dsw,

    // ---------------- to the sound board: the word written to 0x01E00000
    output logic [15:0] snd_word,
    output logic        snd_strobe,

    // ---------------- picture
    output logic [23:0] rgb,
    output logic        hsync, vsync, hblank, vblank, de,

    // ---------------- bring-up
    output logic [31:0] dbg_pc,
    output logic        dbg_unimpl,
    output logic  [7:0] dbg_ctrl
);
    // ------------------------------------------------------------ the CPU
    logic        c_req, c_we, c_ack, c_srt;
    logic [31:4] c_a;
    logic [15:0] c_wd, c_rd;
    logic        blit_irq, dpyint;

    tms34010 u_cpu (
        .clk(clk), .rst(rst), .cen(cen_cpu),
        .bus_req(c_req), .bus_we(c_we), .bus_addr(c_a), .bus_wdata(c_wd),
        .bus_rdata(c_rd), .bus_ack(c_ack), .bus_srt(c_srt),
        .int1(blit_irq), .int2(1'b0), .dpyint(dpyint),
        .insn_start(), .irq_taken(), .dbg_pc(dbg_pc), .unimpl(dbg_unimpl)
    );
    wire [31:0] A = {c_a, 4'd0};

    // ------------------------------------------------------------ decode
    typedef enum logic [3:0] {
        T_NONE, T_VRAM, T_RAM, T_CMOS, T_PAL, T_BLIT, T_IN, T_SND, T_CTRL,
        T_GFX, T_IO, T_ROM, T_ZERO
    } tgt_t;
    tgt_t tgt;
    always_comb begin
        if      (A[31:21] == 11'd0)                      tgt = T_VRAM;   // 0x0000_0000 2 Mbit
        else if (A[31:20] == 12'h010)                    tgt = T_RAM;
        else if (A[31:16] == 16'h0140)                   tgt = T_CMOS;
        else if (A[31:17] == 15'h00c0)                   tgt = T_PAL;    // 0x0180_0000
        else if (A[31:20] == 12'h01a && A[18:8] == '0)   tgt = T_BLIT;   // and its mirror
        else if (A[31:8]  == 24'h01c000)                 tgt = T_IN;
        else if (A[31:8]  == 24'h01e000)                 tgt = T_SND;
        else if (A[31:8]  == 24'h01f000)                 tgt = T_CTRL;
        else if (A >= 32'h0200_0000 && A < 32'h0600_0000) tgt = T_GFX;
        else if (A[31:9]  == 23'h600000)                 tgt = T_IO;
        else if (A[31:21] == 11'h7ff)                    tgt = T_ROM;    // 0xFFE0_0000
        else                                             tgt = T_ZERO;
    end

    // ------------------------------------------------------------ registers
    logic  [7:0] ctrl;                  // system control, docs/hardware.md 7.5
    logic [15:0] blit_pal;              // shadow of blitter register 8
    assign dbg_ctrl = ctrl;

    // ------------------------------------------------------------ the parts
    logic        v_req, v_ack;   logic [15:0] v_q;
    logic        bl_req, bl_gnt; logic [8:0] bl_row, bl_col; logic [7:0] bl_pix, bl_pal;
    logic        rf_start, rf_valid, rf_busy, ae_start, ae_busy;
    logic  [8:0] rf_row, rf_col, ae_row;
    logic  [7:0] rf_pix, rf_pal;
    logic        blit_we, vreg_we, pal_we;
    logic [15:0] blit_q, vreg_q;
    logic        bg_req, bg_ack;  logic [20:0] bg_addr;
    logic [31:0] bg_q;

    stv_vram u_vram (
        .clk(clk), .rst(rst),
        .bl_req(bl_req), .bl_row(bl_row), .bl_col(bl_col), .bl_pix(bl_pix),
        .bl_pal(bl_pal), .bl_gnt(bl_gnt),
        .cpu_req(v_req), .cpu_we(c_we), .cpu_word(A[20:4]), .cpu_d(c_wd), .cpu_be(2'b11),
        .cpu_srt(c_srt), .cpu_bank(ctrl[5]), .cpu_dpal(blit_pal),
        .cpu_ack(v_ack), .cpu_q(v_q),
        .rf_start(rf_start), .rf_row(rf_row), .rf_valid(rf_valid), .rf_col(rf_col),
        .rf_pix(rf_pix), .rf_pal(rf_pal), .rf_busy(rf_busy),
        .ae_start(ae_start), .ae_row(ae_row), .ae_busy(ae_busy),
        .xm_req(xm_req), .xm_we(xm_we), .xm_addr(xm_addr), .xm_d(xm_d), .xm_be(xm_be),
        .xm_ack(xm_ack), .xm_q(xm_q),
        .race()
    );

    stv_blit u_blit (
        .clk(clk), .rst(rst), .cen(cen_blit),
        .reg_we(blit_we), .reg_a(A[7:4]), .reg_d(c_wd), .reg_be(2'b11), .reg_q(blit_q),
        .gfx_req(bg_req), .gfx_addr(bg_addr), .gfx_ack(bg_ack), .gfx_q(bg_q),
        .fb_req(bl_req), .fb_row(bl_row), .fb_col(bl_col), .fb_pix(bl_pix),
        .fb_pal(bl_pal), .fb_gnt(bl_gnt),
        .busy(), .irq(blit_irq), .px_drawn(), .gfx_stall(), .busy_clocks()
    );

    stv_video #(.RESET_TO_GAME(1'b0)) u_video (
        .clk(clk), .rst(rst), .cen_dot(cen_dot),
        .vreg_we(vreg_we), .vreg_a(A[8:4]), .vreg_d(c_wd), .vreg_q(vreg_q),
        .hcount_q(), .vcount_q(),
        .pal_we(pal_we), .pal_a(A[15:4]), .pal_d(c_wd), .pal_be(2'b11),
        .autoerase(~ctrl[4]),
        .rf_start(rf_start), .rf_row(rf_row), .rf_valid(rf_valid), .rf_col(rf_col),
        .rf_pix(rf_pix), .rf_pal(rf_pal), .rf_busy(rf_busy),
        .ae_start(ae_start), .ae_row(ae_row), .ae_busy(ae_busy),
        .rgb(rgb), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
        .de(de), .pen(), .dpyint(dpyint), .hdot_o()
    );

    // ---------------------------------------------- the graphics ROM port
    // The blitter's fetcher and the CPU's window.  Whoever is granted keeps
    // the port until its ack, and the ack goes to whoever was granted.
    typedef enum logic [1:0] { G_FREE, G_BLIT, G_CPU } gown_t;
    gown_t gown;
    logic  cg_req;                      // the CPU wants a graphics word
    logic  cg_ack;
    // the CPU's word is two pixels, 2w and 2w+1, of image word w >> 1
    wire [21:0] cg_w    = A[25:4] - 22'h200000;                // word offset in the window
    wire [20:0] cg_addr = cg_w[21:1];
    always_ff @(posedge clk) begin
        if (rst) begin
            gown <= G_FREE; gfx_req <= 1'b0;
        end else case (gown)
            G_FREE: if (bg_req && !bg_ack) begin
                        gown <= G_BLIT; gfx_req <= 1'b1; gfx_addr <= bg_addr;
                    end else if (cg_req && !cg_ack) begin
                        gown <= G_CPU;  gfx_req <= 1'b1; gfx_addr <= cg_addr;
                    end
            default: if (gfx_ack) begin gfx_req <= 1'b0; gown <= G_FREE; end
        endcase
    end
    // above the nine EPROMs the region reads as zero in MAME
    wire [31:0] gfx_qz = (gfx_addr < 21'h60000) ? gfx_q : 32'd0;
    assign bg_ack = gfx_ack && (gown == G_BLIT);
    assign bg_q   = gfx_qz;
    assign cg_ack = gfx_ack && (gown == G_CPU);

    function automatic logic [7:0] gpix(input logic [31:0] w, input logic [1:0] f);
        return {2'b00, w[8  + 2*f +: 2], w[16 + 2*f +: 2], w[24 + 2*f +: 2]};
    endfunction
    wire [1:0]  cg_f  = {cg_w[0], 1'b0};
    wire [15:0] cg_rd = {gpix(gfx_qz, cg_f | 2'd1), gpix(gfx_qz, cg_f)};

    // ------------------------------------------------------------ the bus
    typedef enum logic [1:0] { B_IDLE, B_WAIT, B_DONE } bst_t;
    bst_t bst;
    tgt_t tl;                           // the target this transaction went to

    always_ff @(posedge clk) begin
        c_ack      <= 1'b0;
        blit_we    <= 1'b0;
        vreg_we    <= 1'b0;
        pal_we     <= 1'b0;
        snd_strobe <= 1'b0;
        if (rst) begin
            bst <= B_IDLE; ctrl <= 8'h10; blit_pal <= '0; snd_word <= 16'h0000;
            v_req <= 1'b0; ram_req <= 1'b0; mrom_req <= 1'b0; cg_req <= 1'b0;
        end else case (bst)
            B_IDLE: if (c_req) begin
                tl  <= tgt;
                bst <= B_WAIT;
                case (tgt)
                    T_VRAM: v_req <= 1'b1;
                    T_RAM:  begin ram_req <= 1'b1; ram_we <= c_we; ram_d <= c_wd;
                                  ram_addr <= {1'b0, A[19:4]}; end
                    T_CMOS: begin ram_req <= 1'b1; ram_we <= c_we; ram_d <= c_wd;
                                  ram_addr <= {3'b100, ctrl[7:6], A[15:4]}; end
                    T_PAL:  begin ram_req <= 1'b1; ram_we <= c_we; ram_d <= c_wd;
                                  ram_addr <= {4'b1010, A[16:4]};
                                  pal_we <= c_we; end
                    T_BLIT: begin
                        blit_we <= c_we;
                        if (c_we && A[7:4] == 4'd8) blit_pal <= c_wd;
                    end
                    T_SND:  if (c_we && A[7:4] == 4'd0) begin
                                snd_word <= c_wd; snd_strobe <= 1'b1;
                            end
                    T_CTRL: if (c_we) ctrl <= c_wd[7:0];
                    T_GFX:  cg_req <= 1'b1;
                    T_IO:   vreg_we <= c_we;
                    T_ROM:  begin mrom_req <= 1'b1; mrom_addr <= A[20:4]; end
                    default: ;
                endcase
            end
            B_WAIT: begin
                case (tl)
                    T_VRAM: if (v_ack)    begin v_req <= 1'b0;    c_rd <= v_q;    c_ack <= 1'b1; bst <= B_DONE; end
                    T_RAM, T_CMOS, T_PAL:
                            if (ram_ack)  begin ram_req <= 1'b0;  c_rd <= ram_q;  c_ack <= 1'b1; bst <= B_DONE; end
                    T_GFX:  if (cg_ack)   begin cg_req <= 1'b0;   c_rd <= cg_rd;  c_ack <= 1'b1; bst <= B_DONE; end
                    T_ROM:  if (mrom_ack) begin mrom_req <= 1'b0; c_rd <= mrom_q; c_ack <= 1'b1; bst <= B_DONE; end
                    T_BLIT: begin c_rd <= blit_q; c_ack <= 1'b1; bst <= B_DONE; end
                    T_IO:   begin c_rd <= vreg_q; c_ack <= 1'b1; bst <= B_DONE; end
                    T_IN:   begin
                        case (A[7:4])
                            4'd0:    c_rd <= in0;
                            4'd1:    c_rd <= in1;
                            4'd3:    c_rd <= dsw;
                            4'd6, 4'd7: c_rd <= 16'h0000;   // the protection PLD: unused here
                            default: c_rd <= 16'hffff;
                        endcase
                        c_ack <= 1'b1; bst <= B_DONE;
                    end
                    default: begin c_rd <= 16'h0000; c_ack <= 1'b1; bst <= B_DONE; end
                endcase
            end
            // the CPU drops its request the clock after it sees the ack; do
            // not take that same request for a new one
            default: if (!c_req) bst <= B_IDLE;
        endcase
    end
endmodule

`default_nettype wire

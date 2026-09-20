//------------------------------------------------------------------------------
// Smash T.V. -- the machine, platform-agnostic.
//
// The Y-unit main board (rtl/stv_main.sv: TMS34010, blitter, frame buffer,
// video) and the Williams CVSD sound board (rtl/stv_sound.sv), joined by the
// one latch that joins them on the real thing, with the enables they run on.
// Every memory chip that is not block RAM is a port, and the port list is the
// contract with target/pocket/core_top.sv, target/pocket/smashtv_mem.sv and
// the benches in sim/:
//
//   mrom   the program ROM, 16-bit words, index from 0xFFE00000     SDRAM
//   srom   the three sound EPROMs, bytes, {chip, A15, A14..0}       SDRAM
//   gfx    the graphics ROMs, 32-bit words of four pixels           SDRAM, read ahead
//   ram    main RAM, CMOS and the palette's read-back copy          the Pocket's SRAM
//   xm     frame-buffer rows 256-509, which the game barely uses    SDRAM
//------------------------------------------------------------------------------
`default_nettype none

module smashtv_core (
    input  logic        clk,            // 96 MHz
    input  logic        rst,
    input  logic        pause,          // freeze the machine, keep the picture
    input  logic        pix_sync,       // see clk_enables.sv

    output logic        mrom_req,  output logic [16:0] mrom_addr,
    input  logic        mrom_ack,  input  logic [15:0] mrom_q,
    output logic        srom_req,  output logic [17:0] srom_addr,
    input  logic        srom_ack,  input  logic  [7:0] srom_q,
    output logic        gfx_req,   output logic [18:0] gfx_addr,
    input  logic        gfx_ack,   input  logic [31:0] gfx_q,
    output logic        ram_req,   output logic        ram_we,
    output logic [16:0] ram_addr,  output logic [15:0] ram_d,
    input  logic        ram_ack,   input  logic [15:0] ram_q,
    output logic        xm_req,    output logic        xm_we,
    output logic [16:0] xm_addr,   output logic [15:0] xm_d,
    output logic  [1:0] xm_be,
    input  logic        xm_ack,    input  logic [15:0] xm_q,

    // ---------------- the cabinet, active low, in the board's own bit order
    // (docs/hardware.md section 3)
    input  logic [15:0] in0, in1, dsw,

    // ---------------- video, one pixel per pix_ce in the clk domain
    output logic [23:0] rgb,
    output logic        hsync, vsync, hblank, vblank,
    output logic        pix_ce, de,

    output logic signed [15:0] snd,

    // ---------------- bring-up (the panel in core_top, docs/bringup.md)
    output logic [31:0] dbg_pc,         // the TMS34010's program counter
    output logic        dbg_unimpl,     // it met an instruction the RTL does not build
    output logic  [7:0] dbg_ctrl,       // the control latch at 0x01F00000
    output logic [15:0] dbg_snd_pc,     // the 6809's address bus
    output logic [15:0] dbg_snd_stalls, // E cycles the sound ROM stretched
    output logic [15:0] dbg_snd_word    // the last word sent to the sound board
);
    logic cen_cpu, cen_blit, cen_dot;
    clk_enables u_cen (
        .clk(clk), .rst(rst), .pix_sync(pix_sync), .pause(pause),
        .cen_cpu(cen_cpu), .cen_blit(cen_blit), .cen_dot(cen_dot)
    );
    assign pix_ce = cen_dot;

    logic [20:0] gfx_a21;
    logic [15:0] snd_word;
    // the image holds 0x60000 words and stv_main answers the rest itself
    assign gfx_addr = gfx_a21[18:0];

    stv_main u_main (
        .clk(clk), .rst(rst), .cen_cpu(cen_cpu), .cen_dot(cen_dot), .cen_blit(cen_blit),
        .pause(pause),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_q(mrom_q),
        .gfx_req(gfx_req), .gfx_addr(gfx_a21), .gfx_ack(gfx_ack), .gfx_q(gfx_q),
        .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_d(ram_d),
        .ram_ack(ram_ack), .ram_q(ram_q),
        .xm_req(xm_req), .xm_we(xm_we), .xm_addr(xm_addr), .xm_d(xm_d), .xm_be(xm_be),
        .xm_ack(xm_ack), .xm_q(xm_q),
        .in0(in0), .in1(in1), .dsw(dsw),
        .snd_word(snd_word), .snd_strobe(),
        .rgb(rgb), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
        .dbg_pc(dbg_pc), .dbg_unimpl(dbg_unimpl), .dbg_ctrl(dbg_ctrl)
    );
    assign dbg_snd_word = snd_word;

    // The latch at 0x01E00000: bits 7-0 the command, bit 8 the sound board's
    // reset (low holds it), bit 9 the strobe.  It resets to zero, so the sound
    // board is held until the program lets it go - as on the board.
    stv_sound u_snd (
        .clk(clk), .rst(rst), .pause(pause),
        .cmd(snd_word[7:0]), .cmd_reset_n(snd_word[8]), .cmd_strobe(snd_word[9]),
        .rom_addr(srom_addr), .rom_req(srom_req), .rom_q(srom_q), .rom_ack(srom_ack),
        .snd(snd), .stalls(dbg_snd_stalls), .dbg_pc(dbg_snd_pc)
    );
endmodule

`default_nettype wire

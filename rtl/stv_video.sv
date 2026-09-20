//------------------------------------------------------------------------------
// The raster, the display address, the scanout and the palette
// (docs/hardware.md sections 1, 7.4 and 7.6).
//
// The timing registers here belong to the TMS34010, not to the board: the CPU
// programs HESYNC..VTOTAL, DPYCTL, DPYSTRT, DPYTAP and DPYINT, and the chip
// generates the raster from them.  They are registers with the values the game
// actually writes as their reset defaults, so this module is right before
// there is a CPU and stays right after one arrives.
//
// One dot per `cen_dot`, which is 96 MHz / 12 = 8.000 MHz -- the board's dot
// clock exactly, and the same clock the Pocket's RGB pins are driven from
// (docs/core-design.md section 1).  So the raster is the board's: 506 dots by
// 289 lines, 410 x 256 visible, 54.7069 Hz.
//
// Per line, in the order MAME's scanline callback does it:
//
//   1. at dot 0: if this is VSBLNK, load DPYADR from DPYSTRT
//   2. latch the row this line shows, from DPYADR before it moves
//   3. start the 512-entry row fetch -- the board loads its VRAM shift
//      registers here, so the whole row is sampled at one instant
//   4. when the fetch is done, autoerase the row one behind, if enabled
//   5. from dot 90 to 499, look each entry up through the 6-bit pen map and
//      the palette
//   6. at the end of a visible line, move DPYADR on
//------------------------------------------------------------------------------
`default_nettype none

module stv_video #(
    // 1: the registers reset to the values Smash T.V. programs, so the raster
    //    runs with no CPU (the video bench).  0: they reset to zero as the
    //    chip's do, and the picture is off until the game turns it on.
    parameter bit RESET_TO_GAME = 1'b1
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_dot,        // 8 MHz

    // ---------------- the TMS34010's video registers
    input  logic        vreg_we,
    input  logic  [4:0] vreg_a,
    input  logic [15:0] vreg_d,
    output logic [15:0] vreg_q,         // read-back of register vreg_a
    output logic [15:0] hcount_q,
    output logic [15:0] vcount_q,

    // ---------------- palette RAM at 0x01800000, pen = offset & 0xfff
    input  logic        pal_we,
    input  logic [11:0] pal_a,
    input  logic [15:0] pal_d,
    input  logic  [1:0] pal_be,

    // ---------------- the control register's autoerase enable (bit 4 low)
    input  logic        autoerase,

    // ---------------- frame buffer
    output logic        rf_start,
    output logic  [8:0] rf_row,
    input  logic        rf_valid,
    input  logic  [8:0] rf_col,
    input  logic  [7:0] rf_pix,
    input  logic  [7:0] rf_pal,
    input  logic        rf_busy,
    output logic        ae_start,
    output logic  [8:0] ae_row,
    input  logic        ae_busy,

    // ---------------- picture
    output logic [23:0] rgb,
    output logic        hsync, vsync, hblank, vblank, de,
    output logic [11:0] pen,            // the palette index, aligned with rgb

    // ---------------- interrupt
    output logic        dpyint,         // one pulse when VCOUNT == DPYINT
    // ---------------- for the bench: where in the line we are
    output logic  [9:0] hdot_o
);
    // Register indexes, from ref/mame/devices/cpu/tms34010/tms34010.h
    localparam int RI_HESYNC = 0, RI_HEBLNK = 1, RI_HSBLNK = 2, RI_HTOTAL = 3,
                   RI_VESYNC = 4, RI_VEBLNK = 5, RI_VSBLNK = 6, RI_VTOTAL = 7,
                   RI_DPYCTL = 8, RI_DPYSTRT = 9, RI_DPYINT = 10, RI_DPYTAP = 27;

    // The values Smash T.V. writes, measured at frames 2, 60, 200 and 400 of
    // a headless run and identical at every sample (docs/hardware.md 1).
    logic [15:0] hesync, heblnk, hsblnk, htotal;
    logic [15:0] vesync, veblnk, vsblnk, vtotal;
    logic [15:0] dpyctl, dpystrt, dpyintr, dpytap;

    always_ff @(posedge clk) begin
        if (rst) begin
            hesync <= RESET_TO_GAME ? 16'h0015 : 16'h0; heblnk <= RESET_TO_GAME ? 16'h002d : 16'h0;
            hsblnk <= RESET_TO_GAME ? 16'h00fa : 16'h0; htotal <= RESET_TO_GAME ? 16'h00fc : 16'h0;
            vesync <= RESET_TO_GAME ? 16'h0003 : 16'h0; veblnk <= RESET_TO_GAME ? 16'h0014 : 16'h0;
            vsblnk <= RESET_TO_GAME ? 16'h0114 : 16'h0; vtotal <= RESET_TO_GAME ? 16'h0120 : 16'h0;
            dpyctl <= RESET_TO_GAME ? 16'hf010 : 16'h0; dpystrt <= RESET_TO_GAME ? 16'hfffc : 16'h0;
            dpyintr<= RESET_TO_GAME ? 16'h009a : 16'h0; dpytap  <= 16'h0000;
        end else if (vreg_we) begin
            unique case (vreg_a)
                5'(RI_HESYNC):  hesync  <= vreg_d;
                5'(RI_HEBLNK):  heblnk  <= vreg_d;
                5'(RI_HSBLNK):  hsblnk  <= vreg_d;
                5'(RI_HTOTAL):  htotal  <= vreg_d;
                5'(RI_VESYNC):  vesync  <= vreg_d;
                5'(RI_VEBLNK):  veblnk  <= vreg_d;
                5'(RI_VSBLNK):  vsblnk  <= vreg_d;
                5'(RI_VTOTAL):  vtotal  <= vreg_d;
                5'(RI_DPYCTL):  dpyctl  <= vreg_d;
                5'(RI_DPYSTRT): dpystrt <= vreg_d;
                5'(RI_DPYINT):  dpyintr <= vreg_d;
                5'(RI_DPYTAP):  dpytap  <= vreg_d;
                default: ;
            endcase
        end
    end

    // Read-back, for the registers that live here.  HCOUNT, VCOUNT and DPYADR
    // are the moving ones, and the game polls VCOUNT.
    always_comb begin
        unique case (vreg_a)
            5'(RI_HESYNC):  vreg_q = hesync;
            5'(RI_HEBLNK):  vreg_q = heblnk;
            5'(RI_HSBLNK):  vreg_q = hsblnk;
            5'(RI_HTOTAL):  vreg_q = htotal;
            5'(RI_VESYNC):  vreg_q = vesync;
            5'(RI_VEBLNK):  vreg_q = veblnk;
            5'(RI_VSBLNK):  vreg_q = vsblnk;
            5'(RI_VTOTAL):  vreg_q = vtotal;
            5'(RI_DPYCTL):  vreg_q = dpyctl;
            5'(RI_DPYSTRT): vreg_q = dpystrt;
            5'(RI_DPYINT):  vreg_q = dpyintr;
            5'(RI_DPYTAP):  vreg_q = dpytap;
            5'd28:          vreg_q = hcount_q;
            5'd29:          vreg_q = vcount_q;
            5'd30:          vreg_q = dpyadr;
            default:        vreg_q = 16'd0;
        endcase
    end

    // ------------------------------------------------------------- raster
    // Dots, so the horizontal registers count in pairs.
    logic [9:0] hdot;
    logic [8:0] vline;
    wire [9:0] hlast   = {htotal[8:0], 1'b1};        // (HTOTAL+1)*2 - 1
    wire [9:0] hsy_end = {hesync[8:0], 1'b1};
    wire [9:0] hbl_end = {heblnk[8:0], 1'b0};
    wire [9:0] hbl_sta = {hsblnk[8:0], 1'b0};
    wire [8:0] vlast   = vtotal[8:0];
    wire       eol     = cen_dot && (hdot == hlast);
    wire       sol     = cen_dot && (hdot == 10'd0);

    always_ff @(posedge clk) begin
        if (rst) begin
            hdot <= '0; vline <= '0;
        end else if (cen_dot) begin
            if (hdot == hlast) begin
                hdot  <= '0;
                vline <= (vline == vlast) ? 9'd0 : (vline + 9'd1);
            end else begin
                hdot <= hdot + 10'd1;
            end
        end
    end
    // What HCOUNT reads back: MAME scales the dot position into HTOTAL units
    // -- which at two dots per pixel clock is a halving -- adds HEBLNK and
    // wraps (io_register_r in tms34010.cpp).
    wire [16:0] hc_raw = {8'd0, hdot[9:1]} + {1'b0, heblnk};
    // registered: an add, a compare and a subtract on the way to the CPU's
    // read multiplexer was a failing path, and a value that moves every
    // twelve clocks loses nothing by being one clock old
    always_ff @(posedge clk)
        hcount_q <= (hc_raw > {1'b0, htotal} + 17'd1)
                  ? 16'(hc_raw - {1'b0, htotal} - 17'd1) : 16'(hc_raw);
    assign vcount_q = {7'd0, vline};

    assign hdot_o = hdot;

    wire vis_y = (vline >= veblnk[8:0]) && (vline < vsblnk[8:0]);
    wire vis_x = (hdot >= hbl_end) && (hdot < hbl_sta);

    // ------------------------------------------------- the display address
    logic [15:0] dpyadr;
    logic  [8:0] row_l, col_l;
    wire  [15:0] da = dpyctl[10] ? dpyadr : (dpyadr ^ 16'hfffc);

    // At the start of every line, before DPYADR moves: which row this line
    // shows, and where in it to start.  `col` works out to zero on this game
    // -- (da & 0x7c) << 5 is always a multiple of 512 -- but the arithmetic
    // is here in full so a game that uses DPYTAP would still be right.
    wire [8:0] row_now = da[12:4];
    wire [8:0] col_now = 9'({dpytap[13:0], 1'b0});

    always_ff @(posedge clk) begin
        if (rst) begin
            dpyadr <= 16'hfffc;
            row_l  <= '0;
            col_l  <= '0;
        end else begin
            if (sol) begin
                if (vline == vsblnk[8:0]) dpyadr <= dpystrt;
                row_l <= row_now;
                col_l <= col_now;
            end
            // 6. move it on at the end of a visible line
            if (eol && (vline >= veblnk[8:0]) && (vline < vsblnk[8:0])) begin
                if (dpyadr[1:0] == 2'b00)
                    dpyadr <= ((dpyadr & 16'hfffc) - (dpyctl & 16'h03fc))
                            | {14'd0, dpystrt[1:0]};
                else
                    dpyadr <= (dpyadr & 16'hfffc) | {14'd0, (dpyadr[1:0] - 2'd1)};
            end
        end
    end

    // --------------------------------------------- fetch, then autoerase
    // The fetch is started at dot 0 and takes 512 clocks of a line's 6,072,
    // so it is long finished when the first visible dot arrives at dot 90
    // (1,080 clocks in).  The autoerase follows it, on the row one behind,
    // exactly as MAME's scanline update calls autoerase_line(rowaddr - 1)
    // and its end-of-frame timer clears the last one at VSBLNK.
    // The autoerase starts at a fixed dot rather than "when the fetch is
    // done": the fetch's own busy flag does not rise until two clocks after
    // rf_start, so a !rf_busy test fires before the fetch has begun.  Dot 64
    // is 768 clocks into the line, the fetch takes 512 and nothing can hold
    // it up, and the autoerase then has 5,300 clocks to write 512 entries.
    localparam logic [9:0] AE_DOT = 10'd64;
    logic ae_wait;

    // rf_start is combinational on `sol`, not registered off it.  Registered,
    // it rose one clock after the line began, and a CPU frame-buffer write
    // presented on exactly that clock was accepted before the frame buffer
    // knew a fetch was coming -- one word a line, which put one pixel a frame
    // on the screen during the power-up RAM test.  Combinational, the door in
    // stv_vram sees it on the same edge the request arrives.
    // vis_y is two nine-bit compares; registered, because rf_start goes on
    // through the frame buffer's row lock and port arbitration to a write
    // enable, and with the compares in front that was -5.0 ns.  vline only
    // changes at the end of a line, twelve clocks before `sol`, so the
    // registered copy is the same value whenever rf_start can be true.
    logic vis_y_q;
    always_ff @(posedge clk) vis_y_q <= vis_y;
    assign rf_start = sol && vis_y_q && dpyctl[15];
    assign rf_row   = row_now;

    always_ff @(posedge clk) begin
        ae_start <= 1'b0;
        if (rst) begin
            ae_wait <= 1'b0;
        end else begin
            if (sol) begin
                ae_wait <= autoerase && (vline > veblnk[8:0])
                                     && (vline <= vsblnk[8:0]);
                ae_row  <= 9'(vline - veblnk[8:0] - 9'd1);
            end
            if (ae_wait && cen_dot && (hdot == AE_DOT)) begin
                ae_wait  <= 1'b0;
                ae_start <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------- line buffer
    // 512 entries of { palette byte, pixel byte }, filled by the fetch and
    // read a dot at a time.  One M10K block, one dimension, a power of two.
    logic [15:0] lbuf [512];
    logic  [8:0] rd_col;
    logic [15:0] lb_q;

    always_ff @(posedge clk) begin
        if (rf_valid) lbuf[rf_col] <= {rf_pal, rf_pix};
        lb_q <= lbuf[rd_col];
    end

    // the entry for the dot two clocks from now, so the palette lookup and
    // the output register both have a clock
    wire [8:0] dot_x = 9'(hdot - hbl_end);
    always_ff @(posedge clk) begin
        if (cen_dot) rd_col <= 9'(col_l + dot_x);
    end

    // -------------------------------------------------- pen and palette
    // pen = { palette[3:0], palette[7:6], pixel[5:0] } (docs/hardware.md 7.1)
    logic [15:0] pal_ram [4096];
    wire  [11:0] pen_w = {lb_q[11:8], lb_q[15:14], lb_q[5:0]};
    logic [15:0] pal_q;

    always_ff @(posedge clk) begin
        if (pal_we) begin
            if (pal_be[0]) pal_ram[pal_a][7:0]  <= pal_d[7:0];
            if (pal_be[1]) pal_ram[pal_a][15:8] <= pal_d[15:8];
        end
        pal_q <= pal_ram[pen_w];
    end

    // 5 bits to 8 by bit replication, which is MAME's pal5bit
    function automatic logic [7:0] pal5(input logic [4:0] v);
        return {v, v[4:2]};
    endfunction

    // ------------------------------------------------------------ output
    // One dot of pipeline: the address for dot n is issued at dot n, the
    // line buffer answers a clock later and the palette a clock after that,
    // both inside dot n's twelve clocks, so dot n's colour is registered out
    // at dot n+1.  Everything that goes with it -- the enables, the blanking
    // and the pen the bench compares -- is delayed by the same dot, so the
    // picture and the sync are consistent.
    logic vis_p, hbl_p, hsy_p;
    always_ff @(posedge clk) begin
        if (cen_dot) begin
            rgb    <= vis_p ? {pal5(pal_q[14:10]), pal5(pal_q[9:5]), pal5(pal_q[4:0])}
                            : 24'h000000;
            de     <= vis_p;
            hblank <= hbl_p;
            hsync  <= hsy_p;
            pen    <= pen_w;
            vis_p  <= vis_x && vis_y && dpyctl[15];
            hbl_p  <= !((hdot >= hbl_end) && (hdot < hbl_sta));
            hsy_p  <= (hdot <= hsy_end);
        end
    end
    assign vblank = !vis_y;
    assign vsync  = (vline <= vesync[8:0]);

    // --------------------------------------------------------- interrupt
    assign dpyint = sol && dpyctl[15] && (vline == dpyintr[8:0]);
endmodule

`default_nettype wire

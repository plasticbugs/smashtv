//------------------------------------------------------------------------------
// The Y-unit frame buffer (docs/hardware.md section 7.1, docs/core-design.md
// section 3).
//
// 512 rows of 512 pixels, each pixel a palette byte and a pixel byte in two
// planes.  The planes are two byte-wide RAMs here for the same reason they are
// two banks of chips on the board: the CPU writes one plane without touching
// the other, and separate RAMs make that a plain write instead of a
// read-modify-write.
//
//   rows 0-255      block RAM, 2 x 131072 x 8.  Everything the blitter draws
//                   and everything the display shows -- measured over a
//                   90-second run, the blitter wrote rows 0-255 11,859,046
//                   times and row 257 exactly once.
//   rows 510-511    block RAM, 2 x 1024 x 8, on their own read port.  The two
//                   autoerase templates.
//   rows 256-509    out through xm_*, one 16-bit word per pixel, which the
//                   core points at SDRAM.  Only the power-up RAM test goes
//                   there, and it has to work or the game fails its own
//                   memory test.
//
// Addresses are {row[7:0], col[8:0]}: one dimension, a power of two deep,
// built by concatenation, because a synthesiser must not have to interpret
// anything (METHODOLOGY section 5.18).
//
// Three ports, and nothing shares one without the owner being latched at
// grant and the response routed by that latch (METHODOLOGY section 5.17):
//
//   W   written by the blitter, the CPU and the autoerase
//   R   read by the display fetch and the CPU
//   T   the template rows, read by the autoerase alone
//
// `race` counts the one coincidence that cannot be arbitrated away: the
// display fetching a row the blitter is writing.  The bench is meant to find
// zero, and finding zero is the reading, not the assumption.
//------------------------------------------------------------------------------
`default_nettype none

module stv_vram (
    input  logic        clk,
    input  logic        rst,

    // ---------------- blitter: one entry per granted request
    input  logic        bl_req,
    input  logic  [8:0] bl_row,
    input  logic  [8:0] bl_col,
    input  logic  [7:0] bl_pix,
    input  logic  [7:0] bl_pal,
    output logic        bl_gnt,

    // ---------------- the CPU's VRAM window (docs/hardware.md 7.2)
    // cpu_word is the bit address >> 4, so it covers two pixels.
    input  logic        cpu_req,
    input  logic        cpu_we,
    input  logic [16:0] cpu_word,
    input  logic [15:0] cpu_d,
    input  logic  [1:0] cpu_be,
    input  logic        cpu_srt,        // a shift-register transfer: read the entry
    input  logic        cpu_bank,       // control register bit 5
    input  logic [15:0] cpu_dpal,       // the blitter's palette register
    output logic        cpu_ack,
    output logic [15:0] cpu_q,

    // ---------------- display fetch: rf_valid for each of 512 entries
    input  logic        rf_start,
    input  logic  [8:0] rf_row,
    output logic        rf_valid,
    output logic  [8:0] rf_col,
    output logic  [7:0] rf_pix,
    output logic  [7:0] rf_pal,
    output logic        rf_busy,

    // ---------------- autoerase: template row 510 + (row & 1) over `row`
    input  logic        ae_start,
    input  logic  [8:0] ae_row,
    output logic        ae_busy,

    // ---------------- rows 256-509, in SDRAM: one word per pixel
    output logic        xm_req,
    output logic        xm_we,
    output logic [16:0] xm_addr,        // {row[7:0], col[8:0]}, row 256..509
    output logic [15:0] xm_d,           // { palette byte, pixel byte }
    output logic  [1:0] xm_be,          // which plane: the CPU writes one
    input  logic        xm_ack,
    input  logic [15:0] xm_q,

    // ---------------- instrumentation
    output logic [15:0] race
);
    localparam logic [1:0] OWN_NONE = 2'd0, OWN_DISP = 2'd1,
                           OWN_BLIT = 2'd2, OWN_CPU = 2'd3;
    localparam logic [1:0] OWN_AE = OWN_DISP;   // W port: the display never writes

    logic [1:0] r_own, w_own;

    // ------------------------------------------------------------ storage
    logic [7:0] pix_ram [131072];
    logic [7:0] pal_ram [131072];
    logic [7:0] pix_tpl [1024];
    logic [7:0] pal_tpl [1024];

    logic [16:0] w_addr;
    logic        w_pix_en, w_pal_en, w_tpl;
    logic  [7:0] w_pix, w_pal;
    logic [16:0] r_addr;
    logic  [7:0] r_pix, r_pal;
    logic  [9:0] t_addr;
    logic  [7:0] t_pix, t_pal;

    always_ff @(posedge clk) begin
        if (w_pix_en) begin
            if (w_tpl) pix_tpl[w_addr[9:0]] <= w_pix;
            else       pix_ram[w_addr]      <= w_pix;
        end
        if (w_pal_en) begin
            if (w_tpl) pal_tpl[w_addr[9:0]] <= w_pal;
            else       pal_ram[w_addr]      <= w_pal;
        end
        r_pix <= pix_ram[r_addr];
        r_pal <= pal_ram[r_addr];
        t_pix <= pix_tpl[t_addr];
        t_pal <= pal_tpl[t_addr];
    end

    function automatic logic is_tpl(input logic [8:0] row);
        return row[8] && (row[7:1] == 7'h7f);           // 510 or 511
    endfunction
    function automatic logic here(input logic [8:0] row);
        return !row[8] || is_tpl(row);
    endfunction

    // ------------------------------------------------------- display fetch
    // 512 entries, one a clock, off port R.  Started in horizontal blanking,
    // which is when the board loads its VRAM shift registers, so the row is
    // sampled at one instant the way MAME's scanline callback samples it.
    logic  [9:0] rf_cnt;
    logic  [8:0] rf_row_l, rf_col_d;
    logic        rf_run, rf_iss, rf_iss_d;

    always_ff @(posedge clk) begin
        if (rst) begin
            rf_run <= 1'b0; rf_cnt <= '0; rf_iss <= 1'b0; rf_iss_d <= 1'b0;
        end else begin
            rf_iss_d <= rf_iss;
            rf_iss   <= 1'b0;
            rf_col_d <= rf_cnt[8:0];
            if (rf_start) begin
                rf_run <= 1'b1; rf_cnt <= '0; rf_row_l <= rf_row;
            end else if (rf_run) begin
                if (rf_cnt == 10'd512) rf_run <= 1'b0;
                else begin rf_cnt <= rf_cnt + 10'd1; rf_iss <= 1'b1; end
            end
        end
    end
    assign rf_busy  = rf_run;
    assign rf_valid = rf_iss_d;
    assign rf_col   = rf_col_d;
    assign rf_pix   = r_pix;
    assign rf_pal   = r_pal;

    // ---------------------------------------------------------- autoerase
    // Reads the template on its own port and writes the row on port W one
    // clock behind.  The write can be held off, so the read stalls with it.
    logic  [9:0] ae_cnt;
    logic  [8:0] ae_row_l, ae_col_d;
    logic        ae_run, ae_pend;
    wire         ae_hold = ae_pend && (w_own != OWN_AE);

    always_ff @(posedge clk) begin
        if (rst) begin
            ae_run <= 1'b0; ae_cnt <= '0; ae_pend <= 1'b0;
        end else if (ae_start) begin
            ae_run <= 1'b1; ae_cnt <= '0; ae_row_l <= ae_row; ae_pend <= 1'b0;
        end else if (!ae_hold) begin
            ae_pend <= 1'b0;
            if (ae_run) begin
                if (ae_cnt == 10'd512) ae_run <= 1'b0;
                else begin
                    ae_cnt   <= ae_cnt + 10'd1;
                    ae_col_d <= ae_cnt[8:0];
                    ae_pend  <= 1'b1;
                end
            end
        end
    end
    assign ae_busy = ae_run || ae_pend;

    // The T port: the autoerase owns it while it runs, the CPU reads the
    // template rows through it the rest of the time.
    logic [1:0] t_own;
    always_comb begin
        if      (ae_run && !ae_cnt[9]) t_own = OWN_AE;
        else if (cpu_rd_t)             t_own = OWN_CPU;
        else                           t_own = OWN_NONE;
    end
    always_comb begin
        unique case (t_own)
            OWN_AE:  t_addr = {ae_row_l[0], ae_cnt[8:0]};
            OWN_CPU: t_addr = cpu_pix[9:0];
            default: t_addr = '0;
        endcase
    end

    // ------------------------------------------------------------- the CPU
    // One CPU word is two pixels, so this walks them: phase 0 then phase 1,
    // each either a local access or one through xm_*.  Nothing is pipelined:
    // a read issues its address, waits a clock for the RAM, and latches.
    typedef enum logic [2:0] {
        C_IDLE, C_ISSUE, C_LATCH, C_XWAIT, C_NEXT, C_DONE
    } cst_t;
    cst_t        cst;
    logic        phase;
    logic [16:0] cpu_word_l;
    logic [15:0] cpu_d_l, cpu_dpal_l;
    logic  [1:0] cpu_be_l;
    logic        cpu_bank_l, cpu_we_l, cpu_srt_l;
    logic  [7:0] cpu_qa, cpu_qb;
    logic        cpu_tpl_l;

    // The door: refuse a request for the row the display is about to fetch
    // as well as the one it is fetching.  rf_run does not rise until the
    // clock after rf_start, and one word a line slipped through that gap --
    // which is one pixel a frame on the screen, and was.
    wire        cpu_door = (rf_start && (cpu_word[16:8] == rf_row))
                        || (rf_run   && (cpu_word[16:8] == rf_row_l));

    wire  [8:0] cpu_row  = cpu_word_l[16:8];
    wire        cpu_out  = !here(cpu_row);
    wire [16:0] cpu_pix  = {cpu_word_l[15:0], 1'b0} | {16'd0, phase};
    wire        cpu_bsel = phase ? cpu_be_l[1] : cpu_be_l[0];
    // a write with its byte disabled is not an access at all
    wire        cpu_do   = cpu_we_l ? cpu_bsel : 1'b1;
    wire        cpu_wr_l = (cst == C_ISSUE) && cpu_we_l && cpu_do && !cpu_out;
    wire        cpu_rd_l = (cst == C_ISSUE) && !cpu_we_l && !cpu_out;
    wire        cpu_rd_t = cpu_rd_l && is_tpl(cpu_row);
    wire        cpu_rd_m = cpu_rd_l && !is_tpl(cpu_row);

    always_ff @(posedge clk) begin
        cpu_ack <= 1'b0;
        if (rst) begin
            cst <= C_IDLE; phase <= 1'b0;
        end else case (cst)
            // Do not take a request for the row the display is fetching:
            // the access covers two pixels in two clocks, and letting the
            // first through and holding the second put exactly one pixel a
            // frame on the screen that MAME never showed.  Held at the door,
            // the whole word lands after the fetch, which is what the model
            // does with it.
            C_IDLE: if (cpu_req && !cpu_ack && !cpu_door) begin
                cpu_word_l <= cpu_word; cpu_d_l <= cpu_d; cpu_be_l <= cpu_be;
                cpu_bank_l <= cpu_bank; cpu_we_l <= cpu_we; cpu_dpal_l <= cpu_dpal;
                cpu_srt_l  <= cpu_srt && !cpu_we;
                phase      <= 1'b0;
                cpu_tpl_l  <= is_tpl(cpu_word[16:8]);
                cst        <= C_ISSUE;
            end
            C_ISSUE: begin
                if (!cpu_do)                             cst <= C_NEXT;
                else if (cpu_out)                        cst <= C_XWAIT;
                else if (cpu_we_l) begin
                    if (w_own == OWN_CPU)                cst <= C_NEXT;
                end else if (cpu_rd_t ? (t_own == OWN_CPU)
                                      : (r_own == OWN_CPU)) cst <= C_LATCH;
            end
            C_LATCH: begin
                // the template rows are their own RAMs, so a read of one
                // comes back on the T port, not the R port
                if (!phase) cpu_qa <= cpu_tpl_l ? (cpu_bank_l ? t_pix : t_pal)
                                                : (cpu_bank_l ? r_pix : r_pal);
                else        cpu_qb <= cpu_tpl_l ? (cpu_bank_l ? t_pix : t_pal)
                                                : (cpu_bank_l ? r_pix : r_pal);
                // A shift-register transfer answers with the first pixel's
                // whole entry, { palette, pixel }, which is what MAME's
                // to_shiftreg leaves in shiftreg[0]; one access, not two.
                if (cpu_srt_l) begin
                    cpu_qa <= cpu_tpl_l ? t_pix : r_pix;
                    cpu_qb <= cpu_tpl_l ? t_pal : r_pal;
                    cst    <= C_DONE;
                end else cst <= C_NEXT;
            end
            C_XWAIT: if (xm_ack) begin
                if (!phase) cpu_qa <= cpu_bank_l ? xm_q[7:0] : xm_q[15:8];
                else        cpu_qb <= cpu_bank_l ? xm_q[7:0] : xm_q[15:8];
                if (cpu_srt_l) begin
                    cpu_qa <= xm_q[7:0]; cpu_qb <= xm_q[15:8]; cst <= C_DONE;
                end else cst <= C_NEXT;
            end
            C_NEXT: begin
                if (!phase) begin phase <= 1'b1; cst <= C_ISSUE; end
                else                             cst <= C_DONE;
            end
            C_DONE: begin cpu_ack <= 1'b1; cst <= C_IDLE; end
            default: cst <= C_IDLE;
        endcase
    end
    assign cpu_q = {cpu_qb, cpu_qa};

    // ---------------------------------------------------- port arbitration
    // port R: the display fetch has the deadline; the CPU takes what is left,
    // which is every clock outside the 512 of horizontal blanking the fetch
    // uses.
    always_comb begin
        if      (rf_iss)   r_own = OWN_DISP;
        else if (cpu_rd_m) r_own = OWN_CPU;
        else               r_own = OWN_NONE;
    end
    always_comb begin
        unique case (r_own)
            OWN_DISP: r_addr = {rf_row_l[7:0], rf_cnt[8:0]};
            OWN_CPU:  r_addr = cpu_pix;
            default:  r_addr = '0;
        endcase
    end

    // The board loads a whole row into the VRAM shift registers in one
    // memory cycle, so the row the display is fetching cannot change
    // underneath it.  Here the fetch takes 512 clocks, so writes to *that*
    // row are held off for its duration -- 512 of a line's 6,072 clocks, and
    // only for the one row.  Without this the power-up RAM test, which writes
    // the frame buffer while it is being displayed, put 28 to 57 pixels a
    // frame on the screen that MAME never showed.
    // cpu_row is the latched row, so this only ever holds an access that was
    // accepted before the fetch began -- the door check above is what keeps
    // the rest out.
    wire lock_cpu  = (rf_run || rf_start) && (cpu_row == rf_row_l);
    wire lock_blit = rf_run && (bl_row  == rf_row_l);

    // port W: the CPU first, then the blitter, then the autoerase, which has
    // a whole frame of slack before the row it is clearing is fetched again.
    always_comb begin
        if      (cpu_wr_l && !lock_cpu)              w_own = OWN_CPU;
        else if (bl_req && here(bl_row) && !lock_blit) w_own = OWN_BLIT;
        else if (ae_pend)                            w_own = OWN_AE;
        else                                         w_own = OWN_NONE;
    end
    always_comb begin
        w_addr   = '0;
        w_pix    = '0;
        w_pal    = '0;
        w_pix_en = 1'b0;
        w_pal_en = 1'b0;
        w_tpl    = 1'b0;
        unique case (w_own)
            OWN_CPU: begin
                w_addr = cpu_pix;
                w_tpl  = is_tpl(cpu_row);
                if (cpu_bank_l) begin
                    // the pixel plane from the data and the palette plane
                    // from the blitter's palette register -- the low pixel
                    // takes its low byte, the high pixel its high byte
                    w_pix    = phase ? cpu_d_l[15:8]    : cpu_d_l[7:0];
                    w_pal    = phase ? cpu_dpal_l[15:8] : cpu_dpal_l[7:0];
                    w_pix_en = 1'b1;
                    w_pal_en = 1'b1;
                end else begin
                    // the palette plane alone; the pixel byte is kept
                    w_pal    = phase ? cpu_d_l[15:8] : cpu_d_l[7:0];
                    w_pal_en = 1'b1;
                end
            end
            OWN_BLIT: begin
                w_addr   = {bl_row[7:0], bl_col};
                w_tpl    = is_tpl(bl_row);
                w_pix    = bl_pix;
                w_pal    = bl_pal;
                w_pix_en = 1'b1;
                w_pal_en = 1'b1;
            end
            OWN_AE: begin
                w_addr   = {ae_row_l[7:0], ae_col_d};
                w_tpl    = is_tpl(ae_row_l);
                w_pix    = t_pix;
                w_pal    = t_pal;
                w_pix_en = 1'b1;
                w_pal_en = 1'b1;
            end
            default: ;
        endcase
    end

    wire bl_out = bl_req && !here(bl_row);

    assign bl_gnt = (w_own == OWN_BLIT) || (bl_out && xm_ack);

    // ------------------------------------------------- rows 256..509, SDRAM
    // One word per pixel.  Only the RAM test goes here, so it is the simplest
    // thing that works: the blitter first, and both requesters wait.
    assign xm_req  = bl_out || (cst == C_XWAIT);
    assign xm_we   = bl_out || ((cst == C_XWAIT) && cpu_we_l);
    assign xm_addr = bl_out ? {bl_row[7:0], bl_col} : cpu_pix;
    assign xm_d    = bl_out ? {bl_pal, bl_pix}
                            : (cpu_bank_l
                               ? {phase ? cpu_dpal_l[15:8] : cpu_dpal_l[7:0],
                                  phase ? cpu_d_l[15:8]    : cpu_d_l[7:0]}
                               : {phase ? cpu_d_l[15:8]    : cpu_d_l[7:0], 8'h00});
    // The plane split is what the byte enables are for: with the video bank
    // clear the CPU writes the palette byte and the pixel byte must survive,
    // exactly as it does in the two local planes.  Without this the power-up
    // RAM test would come back wrong on rows 256-509, which is the only
    // place it would ever show.
    assign xm_be   = bl_out ? 2'b11 : (cpu_bank_l ? 2'b11 : 2'b10);

    // ------------------------------------------------------------ the race
    // What used to be a corruption and is now a stall: how often a writer
    // wanted the row the display was fetching.  Measured on this game it is
    // zero for the blitter -- it draws rows 134-251 in vertical blank and
    // rows 1-133 at the mid-frame interrupt, neither of them the row being
    // scanned -- and non-zero only during the power-up RAM test, which writes
    // the whole frame buffer while it is on screen.
    always_ff @(posedge clk) begin
        if (rst) race <= '0;
        else if ((lock_blit && bl_req && here(bl_row)) || (lock_cpu && cpu_wr_l))
            if (race != 16'hffff) race <= race + 16'd1;
    end
endmodule

`default_nettype wire

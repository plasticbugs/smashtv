// Taken from the Xenophobe / Arch Rivals core (rtl/archrivals/hc55516.sv).  The
// decoder is the same part; the comments about addresses below describe that
// board - on Smash T.V.'s CVSD board 0x6000 lowers the clock and latches the
// bit and 0x6800 raises it (docs/hardware.md section 6).  Unchanged below.
//
// HC-55516 CVSD decoder — the speech channel on the Williams D-11581 sound
// board.
//
// Written from the documented behaviour rather than adapted from existing HDL:
// the model is entirely integer, so there is nothing to approximate. Constants
// are the HC55516 variant's (MAME hc55516_device): a 3-bit coincidence window,
// syllabic mask 0xFC0 shifted by 6, syllabic addend 0xFC1, integrator shift 4,
// and the bit is consumed on the RISING clock edge.
//
// The board drives this from two write-only addresses: 0x6800 lowers the clock
// and latches the data bit, 0x6000 raises it. So a bit is consumed on the
// 0x6000 write, and the falling edge does its own integrator step from the
// syllabic filter. Both edges do work, which is why this processes every
// change of cvsd_clk rather than just one edge.
//
// /FZ (force zero) is not wired on this board, so the "ignore the input bit and
// use the inverse of the previous one" path cannot be reached and is omitted.

module hc55516 (
    input  logic               clk,       // system clock
    input  logic               reset,
    input  logic               cvsd_clk,  // level; a change drives one step
    input  logic               digit,     // data bit, held by the board
    output logic signed [15:0] sample
);

    logic              clk_q;
    logic  [2:0]       shiftreg;
    logic [11:0]       sylfilter;
    logic signed [9:0] intfilter;

    // The integrator is railed and this bit would push it further out; when
    // frozen, neither filter moves.
    wire frozen = ((intfilter >=  10'sd384) && !digit)
               || ((intfilter <= -10'sd384) &&  digit);

    // Syllabic step: ((~sylfilter) & 0xFC0) >> 6 is just the complement of the
    // filter's top six bits.
    wire [5:0] syl_delta = ~sylfilter[11:6];

    // Coincidence: the last three bits are all the same.
    wire [2:0] sr_next  = {shiftreg[1:0], digit};
    wire       coincide = (sr_next == 3'b000) || (sr_next == 3'b111);

    // Rising edge: sext(((~intfilter) >> 4) + 1, 10).
    wire signed [9:0] inv_int  = ~intfilter;
    wire signed [9:0] sum_rise = (inv_int >>> 4) + 10'sd1;

    // Falling edge: +/- max(2, sylfilter >> 6), sign from the newest bit.
    wire        [5:0] sylv     = (sylfilter[11:6] < 6'd2) ? 6'd2 : sylfilter[11:6];
    wire signed [9:0] sylv_s   = $signed({4'b0, sylv});
    wire signed [9:0] sum_fall = shiftreg[0] ? -sylv_s : sylv_s;

    always_ff @(posedge clk) begin
        if (reset) begin
            clk_q     <= 1'b0;
            shiftreg  <= '0;
            sylfilter <= '0;
            intfilter <= '0;
        end else begin
            clk_q <= cvsd_clk;
            if (cvsd_clk != clk_q) begin
                if (cvsd_clk) begin                     // active (rising) edge
                    shiftreg <= sr_next;
                    if (!frozen) begin
                        // 12-bit wraparound is the mask in the reference model
                        sylfilter <= coincide
                            ? (sylfilter + {6'b0, syl_delta})
                            : (sylfilter + {6'b0, syl_delta} + 12'hfc1);
                        intfilter <= intfilter + sum_rise;
                    end
                end else begin                          // inactive edge
                    if (!frozen) intfilter <= intfilter + sum_fall;
                end
            end
        end
    end

    // Scale the 10-bit integrator to 16 bits the way the reference does: the
    // value in the top ten bits, and its offset-binary form's high six in the
    // bottom, so the output tracks smoothly rather than stepping by 64.
    wire [9:0] off = intfilter ^ 10'h200;
    assign sample = $signed({intfilter, off[9:4]});

endmodule

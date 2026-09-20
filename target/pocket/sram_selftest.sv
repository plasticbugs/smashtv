//------------------------------------------------------------------------------
// The power-on SRAM test (docs/bringup.md, panel row 3).
//
// Two known words go into the SRAM and come back out before the core is let
// out of reset, and what came back is shown on the panel: A55A 5AA5 is a pass.
// They go to 0x00000 and 0x10000 - either side of the chip's A16, which no core
// before this one drove; if that line were not a real address the second write
// would land on the first and the panel would read 5AA5 5AA5.  A55A and 5AA5
// are each other's byte-swap and nibble inverse, so a stuck bit, a swapped
// byte lane and a dead bus all read differently from a pass.
//
// WHAT WAS THERE IS PUT BACK.  0x10000 is the first word of the game's CMOS
// and the Pocket's SRAM keeps its contents across a core reset, so the game's
// settings and high scores survive restarts - and a test that left 5AA5 there
// damaged a little of them every time.  (0.1.0 did.)
//
// A port that never acknowledges would leave the core in reset for good and
// the panel showing nothing, which looks the same as a memory that answers
// wrongly; so it gives up after a millisecond, the read-backs stay zero, and
// the core runs and says so.
//------------------------------------------------------------------------------
`default_nettype none
module sram_selftest (
    input  logic        clk,
    input  logic        hold,           // the memories are not ready: start over
    output logic        req, we,
    output logic [16:0] addr,
    output logic [15:0] d,
    input  logic        ack,
    input  logic [15:0] q,
    output logic        done,
    output logic [15:0] rd0, rd1
);
    localparam logic [15:0] T0 = 16'hA55A, T1 = 16'h5AA5;
    localparam logic [16:0] A0 = 17'h00000, A1 = 17'h10000;

    logic  [3:0] st;                    // even: raise a request; odd: wait for its ack
    logic [15:0] o0, o1;                // what was there
    logic [16:0] tmo;

    always_ff @(posedge clk) begin
        if (hold) begin
            st <= 4'd0; done <= 1'b0; req <= 1'b0; we <= 1'b0;
            rd0 <= '0; rd1 <= '0; tmo <= '0;
        end else if (!done) begin
            tmo <= tmo + 17'd1;
            if (&tmo) begin done <= 1'b1; req <= 1'b0; end     // ~1.4 ms at 96 MHz
            else if (!st[0]) begin
                req <= 1'b1;
                unique case (st[3:1])
                    3'd0: begin we <= 1'b0; addr <= A0; end
                    3'd1: begin we <= 1'b0; addr <= A1; end
                    3'd2: begin we <= 1'b1; addr <= A0; d <= T0; end
                    3'd3: begin we <= 1'b1; addr <= A1; d <= T1; end
                    3'd4: begin we <= 1'b0; addr <= A0; end
                    3'd5: begin we <= 1'b0; addr <= A1; end
                    3'd6: begin we <= 1'b1; addr <= A0; d <= o0; end
                    3'd7: begin we <= 1'b1; addr <= A1; d <= o1; end
                endcase
                st <= st + 4'd1;
            end else if (ack) begin
                req <= 1'b0;
                unique case (st[3:1])
                    3'd0: o0  <= q;
                    3'd1: o1  <= q;
                    3'd4: rd0 <= q;
                    3'd5: rd1 <= q;
                    default: ;
                endcase
                if (st == 4'd15) done <= 1'b1;
                else             st <= st + 4'd1;
            end
        end
    end
endmodule
`default_nettype wire

//------------------------------------------------------------------------------
// One black dot either side of the picture: 410 becomes 412.
//
// The board's picture is 410 dots wide.  On a Pocket that came out with the two
// halves of every four-dot group exchanged - dots 2,3,0,1 - everywhere on the
// screen and nowhere in any simulation; every other core this was checked
// against has a width that is a multiple of four.  So the picture is handed
// over a multiple of four wide.  (Whether that is the cause is recorded in
// docs/bringup.md's log, with what the hardware showed.)
//
// Everything is delayed one dot so that the enable can open a dot early; all
// of it moves on cen_dot, so the hand-over to the video clock is unchanged.
//------------------------------------------------------------------------------
`default_nettype none
module stv_pad (
    input  logic        clk,
    input  logic        cen_dot,
    input  logic [23:0] rgb_i,
    input  logic        de_i, hs_i, vs_i, hb_i, vb_i,
    output logic [23:0] rgb_o,
    output logic        de_o, hs_o, vs_o, hb_o, vb_o
);
    logic [23:0] rgb_d;
    logic        de_d1, de_d2;
    always_ff @(posedge clk) if (cen_dot) begin
        rgb_d <= rgb_i; de_d1 <= de_i; de_d2 <= de_d1;
        hs_o  <= hs_i;  vs_o  <= vs_i;
    end
    assign de_o  = de_i | de_d1 | de_d2;        // one dot before, the picture, one after
    assign rgb_o = de_d1 ? rgb_d : 24'h000000;
    assign hb_o  = ~de_o;
    assign vb_o  = vb_i;
    wire _unused = hb_i;
endmodule
`default_nettype wire

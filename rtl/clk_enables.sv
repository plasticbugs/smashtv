//------------------------------------------------------------------------------
// Clock enables from the 96 MHz system clock (docs/core-design.md section 1).
//
//   cen_dot    the board's 8.000 MHz dot clock: 96 / 12, exact, and the same
//              number as the Pocket's video clock
//   cen_cpu    the TMS34010's 5.000 MHz machine cycle: 96 / 19.2, five pulses
//              in every 96 clocks, exact on average, 10 ns of jitter
//   cen_blit   the blitter's 41 ns pixel: 96 MHz x 65/256 = 24.375 MHz against
//              the board's 24.390, 0.06% slow
//
// The 6809's 2 MHz and the YM2151's 3.579545 MHz are made inside
// rtl/stv_sound.sv, because the 6809's divider has to stretch with its bus.
//------------------------------------------------------------------------------
`default_nettype none

module clk_enables (
    input  logic clk,
    input  logic rst,
    // One pulse just after each edge of the platform's video clock, which
    // restarts the dot divider.  Without it the dot enable would sit at
    // whatever phase the reset left it in, and the pixel handed to the video
    // clock could be sampled while it changes (METHODOLOGY section 5.4).
    input  logic pix_sync,
    input  logic pause,     // hold the CPU and the blitter; the raster runs on
    output logic cen_cpu,
    output logic cen_blit,
    output logic cen_dot
);
    logic [3:0] ddot;       // 0..11
    logic [7:0] cpuacc, blitacc;

    // Pausing freezes the accumulators and masks the enables with the same
    // signal, so nothing is skipped and nothing fires twice.  The dot divider
    // is separate and keeps running, which is what leaves the picture on the
    // screen behind the Pocket's menu (METHODOLOGY section 5.5).
    always_ff @(posedge clk) begin
        if (rst) begin
            ddot <= 4'd0; cpuacc <= 8'd0; blitacc <= 8'd0;
            cen_cpu <= 1'b0; cen_blit <= 1'b0;
        end else begin
            if (pix_sync)            ddot <= 4'd0;
            else if (ddot == 4'd11)  ddot <= 4'd0;
            else                     ddot <= ddot + 4'd1;

            cen_cpu  <= 1'b0;
            cen_blit <= 1'b0;
            if (!pause) begin
                // add 5, wrap at 96
                cen_cpu  <= (cpuacc >= 8'd91);
                cpuacc   <= (cpuacc >= 8'd91) ? cpuacc - 8'd91 : cpuacc + 8'd5;
                cen_blit <= (blitacc >= 8'd191);            // the add carries
                blitacc  <= blitacc + 8'd65;
            end
        end
    end
    assign cen_dot = (ddot == 4'd0);
endmodule

`default_nettype wire

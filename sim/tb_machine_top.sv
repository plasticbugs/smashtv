// The whole main board on ideal memories: rtl/stv_main.sv with arrays behind
// every port.  This is the FAST bench (METHODOLOGY 5.16): it is for the game,
// and it says nothing about the Pocket's memory glue, the download or the
// SDRAM -- none of which exist here.  Latencies are fixed and uncontended.
`default_nettype none
module tb_machine_top (
    input  logic        clk,
    input  logic        rst,
    // loading
    input  logic        ld_prog_we, input logic [16:0] ld_prog_a, input logic [15:0] ld_prog_d,
    input  logic        ld_gfx_we,  input logic [18:0] ld_gfx_a,  input logic [31:0] ld_gfx_d,
    input  logic [15:0] in0, in1, dsw,
    output logic [23:0] rgb,
    output logic        hsync, vsync, hblank, vblank, de, dot_ce,
    output logic [15:0] snd_word,
    output logic        snd_strobe,
    output logic [31:0] dbg_pc,
    output logic        dbg_unimpl,
    output logic  [7:0] dbg_ctrl
);
    // ---- enables: 96 MHz / 12 is the dot clock exactly; the CPU's 5 MHz and
    // the blitter's 24.39 MHz are fractional
    logic [3:0] dotdiv;  logic [7:0] cpuacc, blitacc;
    logic cen_cpu, cen_blit;
    always_ff @(posedge clk) begin
        if (rst) begin dotdiv <= '0; cpuacc <= '0; blitacc <= '0; cen_cpu <= 0; cen_blit <= 0; end
        else begin
            dotdiv   <= (dotdiv == 4'd11) ? 4'd0 : dotdiv + 4'd1;
            // 5/96 = 0.052083; 40/768 exactly: add 5, wrap at 96
            cen_cpu  <= (cpuacc >= 8'd91);
            cpuacc   <= (cpuacc >= 8'd91) ? cpuacc - 8'd91 : cpuacc + 8'd5;
            cen_blit <= (blitacc + 8'd65) < blitacc;
            blitacc  <= blitacc + 8'd65;
        end
    end
    assign dot_ce = (dotdiv == 4'd0);

    logic        mrom_req, mrom_ack; logic [16:0] mrom_addr; logic [15:0] mrom_q;
    logic        gfx_req, gfx_ack;   logic [20:0] gfx_addr;  logic [31:0] gfx_q;
    logic        ram_req, ram_we, ram_ack; logic [16:0] ram_addr; logic [15:0] ram_d, ram_q;
    logic        xm_req, xm_we, xm_ack; logic [16:0] xm_addr; logic [15:0] xm_d, xm_q; logic [1:0] xm_be;

    stv_main u_main (
        .clk(clk), .rst(rst), .cen_cpu(cen_cpu), .cen_dot(dot_ce), .cen_blit(cen_blit), .pause(1'b0),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_q(mrom_q),
        .gfx_req(gfx_req), .gfx_addr(gfx_addr), .gfx_ack(gfx_ack), .gfx_q(gfx_q),
        .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_d(ram_d),
        .ram_ack(ram_ack), .ram_q(ram_q),
        .xm_req(xm_req), .xm_we(xm_we), .xm_addr(xm_addr), .xm_d(xm_d), .xm_be(xm_be),
        .xm_ack(xm_ack), .xm_q(xm_q),
        .in0(in0), .in1(in1), .dsw(dsw),
        .snd_word(snd_word), .snd_strobe(snd_strobe),
        .rgb(rgb), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
        .dbg_pc(dbg_pc), .dbg_unimpl(dbg_unimpl), .dbg_ctrl(dbg_ctrl)
    );

    logic [15:0] prog [1 << 17];
    logic [31:0] gfx  [1 << 19];
    logic [15:0] ram  [1 << 17];
    logic [15:0] xmem [1 << 17];

    always_ff @(posedge clk) begin
        if (ld_prog_we) prog[ld_prog_a] <= ld_prog_d;
        if (ld_gfx_we)  gfx[ld_gfx_a]   <= ld_gfx_d;
        mrom_ack <= mrom_req && !mrom_ack;
        mrom_q   <= prog[mrom_addr];
        gfx_ack  <= gfx_req && !gfx_ack;
        gfx_q    <= gfx[gfx_addr[18:0]];
        ram_ack  <= ram_req && !ram_ack;
        if (ram_req && !ram_ack && ram_we) ram[ram_addr] <= ram_d;
        ram_q    <= ram[ram_addr];
        xm_ack   <= xm_req && !xm_ack;
        if (xm_req && !xm_ack && xm_we) begin
            if (xm_be[0]) xmem[xm_addr][7:0]  <= xm_d[7:0];
            if (xm_be[1]) xmem[xm_addr][15:8] <= xm_d[15:8];
        end
        xm_q     <= xmem[xm_addr];
    end
endmodule
`default_nettype wire

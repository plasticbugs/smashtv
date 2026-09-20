// The sound board alone, with its ROM as an ideal array: rtl/stv_sound.sv fed
// the main board's command words at the times MAME recorded them
// (tools/snd_trace.lua).  Proves the board, not that the core issues those
// commands (METHODOLOGY 5.10) - the machine bench logs its own for that.
`default_nettype none
module tb_sound_top (
    input  logic        clk,
    input  logic        rst,
    input  logic        ld_we, input logic [17:0] ld_a, input logic [7:0] ld_d,
    input  logic [9:0]  word,             // bits 9:0 of the latch at 0x01E00000
    output logic signed [15:0] snd,
    output logic [15:0] stalls,
    output logic [15:0] pc
);
    logic [17:0] rom_addr; logic rom_req; logic [7:0] rom_q;
    logic [7:0] rom [1 << 18];
    always_ff @(posedge clk) begin
        if (ld_we) rom[ld_a] <= ld_d;
        rom_q <= rom[rom_addr];
    end
    stv_sound u_snd (
        .clk(clk), .rst(rst), .pause(1'b0),
        .cmd(word[7:0]), .cmd_reset_n(word[8]), .cmd_strobe(word[9]),
        .rom_addr(rom_addr), .rom_req(rom_req), .rom_q(rom_q), .rom_ack(1'b1),
        .snd(snd), .stalls(stalls), .dbg_pc(pc)
    );
endmodule

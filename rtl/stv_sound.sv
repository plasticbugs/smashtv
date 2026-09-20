// The Williams CVSD sound board (5766-12702-00), docs/hardware.md section 6.
//
// MC6809E at 2 MHz, YM2151 at 3.579545 MHz, an MC1408 DAC on PIA port A, an
// HC-55516 CVSD decoder clocked by the 6809's own writes, and an MC6821 PIA
// as the glue.  The shape follows rtl/archrivals/s11_bg.sv in the Xenophobe
// core, which is the same design family and runs on hardware; what differs
// here is from MAME's williams_cvsd_sound_device:
//
//   * 0x6000 lowers the CVSD clock and latches the bit, 0x6800 raises it
//     (the other way round from the D-11581);
//   * the bank register is four bits: D1:D0 choose U4/U19/U20/none, D2 is
//     the EPROM's A15, D3 (A16) reaches nothing on 64 KB parts;
//   * MAME routes the HC-55516 straight to the mixer, with no filter, at
//     0.60; the DAC at 0.25 and each YM2151 channel at 0.10;
//   * 0x9CF6-0x9D21 is WRITABLE.  The EPROM is blank (0xFF) there, and the
//     program keeps eight 16-bit channel pointers at 0x9D06-0x9D15: measured,
//     66 writes and 660 reads in a minute of play.  MAME redirects the writes
//     into its copy of bank 0, so they read back only while bank 0 is
//     selected, and survive a sound-board reset.  This does the same.
//
// The 6809's E rate is the CVSD's bit rate, so the clock is an exact divide
// by 48 and the only thing that can stretch it is a ROM read that has not
// answered by the end of the cycle - `stalls` counts those, and the memory
// glue has to keep it at zero.
module stv_sound (
    input  logic        clk,          // 96 MHz
    input  logic        rst,          // power-up
    input  logic        pause,

    // the main board's latch at 0x01E00000
    input  logic [7:0]  cmd,          // bits 7:0
    input  logic        cmd_reset_n,  // bit 8: low holds the board in reset
    input  logic        cmd_strobe,   // bit 9 -> PIA CB1

    // sound ROM: {chip[1:0], A15, A[14:0]} into the 192 KB image
    output logic [17:0] rom_addr,
    output logic        rom_req,
    input  logic  [7:0] rom_q,
    input  logic        rom_ack,

    output logic signed [15:0] snd,
    output logic [15:0] stalls,       // E cycles stretched by the ROM
    output logic [15:0] dbg_pc
);
    wire reset = rst | ~cmd_reset_n;

    // ---------------- how this is timed ----------------
    // The 6809 core is one deep block of logic from its registers and its data
    // input back to its registers and out to its address bus (ADDR is
    // combinational), and it is enabled once in 48 clocks.  So the SDC gives
    // three kinds of path SND_MC clocks instead of one:
    //     6809 register -> 6809 register
    //     din_r         -> 6809 register
    //     6809 register -> anything else on this board, and the ROM cache
    // and this module is written so that is true of them:
    //   * the 6809 sees its data through din_r, and every source of din_r
    //     is still for at least SETTLE clocks before the cycle ends - the
    //     RAMs follow an address that settled at the start of the cycle, the
    //     PIA's and the YM2151's inputs are sampled once a cycle at SAMPLE,
    //     and a ROM byte that arrives late holds the cycle open (rom_age);
    //   * nothing acts on the address bus before phase SETTLE: the ROM
    //     request and the YM2151's read select wait for it, and every write
    //     happens on the last clock.
    // The enables themselves (phase -> cen_e, cen_q) are ordinary one-clock
    // paths and are NOT in the constraint.
    localparam int SETTLE = 5;          // > SND_MC (4) in the SDC
    localparam logic [5:0] SAMPLE = 6'd10;

    // ---------------- clocking ----------------
    logic [5:0] phase;
    wire        e_clk = (phase >= 6'd24);
    wire        q_clk = (phase >= 6'd12) && (phase < 6'd36);

    // The ROM's ack is a pulse that comes when it comes, so the byte is
    // latched then and the cycle is "answered" from there to its end.  (It
    // used to be looked for only on the last clock of the cycle, which an
    // always-ready bench ROM satisfied and the real memory glue never did:
    // every ROM cycle was stretched into a second access.  sim/run_pocket.sh
    // found it - 65,535 stalls in ten frames.)
    logic       rom_done;
    logic [7:0] rom_l;
    // ...and the cycle may not end until the byte has been in its register for
    // SETTLE clocks, because of how this board is timed (below).
    logic [2:0] rom_age;
    wire rom_wait = rom_want && (rom_age != 3'(SETTLE));
    wire last     = (phase == 6'd47);
    wire stall    = last && rom_wait;

    always_ff @(posedge clk)
        if (rst) phase <= 6'd0;
        else if (!pause && !stall) phase <= last ? 6'd0 : phase + 1'd1;

    wire cen_e  = last && !stall && !pause;       // E falls leaving phase 47
    wire cen_q  = (phase == 6'd35) && !pause;     // Q falls entering phase 36
    wire wr_now = cen_e && !cpu_rnw;

    logic stall_q;
    always_ff @(posedge clk) begin
        stall_q <= stall;
        if (rst) stalls <= '0;
        else if (stall && !stall_q && !(&stalls)) stalls <= stalls + 1'd1;
    end

    // YM2151: cen at 3.579545 MHz, cen_p1 at half that.
    // 2^24 * 3.579545 / 96 = 625571.6
    logic [24:0] ym_acc;
    logic        ym_half;
    logic        ym_cen, ym_cen_p1;
    always_ff @(posedge clk) begin
        ym_cen    <= 1'b0;
        ym_cen_p1 <= 1'b0;
        if (rst) begin
            ym_acc  <= '0;
            ym_half <= 1'b0;
        end else if (!pause) begin
            ym_acc <= {1'b0, ym_acc[23:0]} + 25'd625572;
            if (ym_acc[24]) begin
                ym_cen  <= 1'b1;
                ym_half <= ~ym_half;
                if (ym_half) ym_cen_p1 <= 1'b1;
            end
        end
    end

    // ---------------- CPU ----------------
    wire [15:0] cpu_addr;
    wire  [7:0] cpu_dout;
    wire        cpu_rnw;
    // The vendored 6809 drives ADDR from its next-address logic, which in a
    // few states looks at D; with the read mux below selecting on ADDR that
    // is a loop on paper.  It settles - no state's address depends on the
    // byte that address reads - and it is how the part runs in Xenophobe.
    /* verilator lint_off UNOPTFLAT */
    logic [7:0] cpu_din;
    /* verilator lint_on UNOPTFLAT */
    wire        pia_irqa, pia_irqb;
    wire        cpu_avma;

    mc6809e cpu (
        .D(din_r), .DOut(cpu_dout), .ADDR(cpu_addr), .RnW(cpu_rnw),
        .E(e_clk), .Q(q_clk), .BS(), .BA(),
        .clk(clk), .cen_e(cen_e), .cen_q(cen_q),
        .nIRQ(1'b1), .nFIRQ(~pia_irqa), .nNMI(~pia_irqb),
        .AVMA(cpu_avma), .BUSY(), .LIC(), .nHALT(1'b1), .nRESET(~reset)
    );
    assign dbg_pc = cpu_addr;

    // ---------------- decode ----------------
    wire sel_ram      = (cpu_addr[15:13] == 3'b000);
    wire sel_ym       = (cpu_addr[15:13] == 3'b001);
    wire sel_pia      = (cpu_addr[15:13] == 3'b010);
    wire sel_cvsd_clr = (cpu_addr[15:11] == 5'b01100);   // 0x6000: clock low + bit
    wire sel_cvsd_set = (cpu_addr[15:11] == 5'b01101);   // 0x6800: clock high
    wire sel_bank     = (cpu_addr[15:11] == 5'b01111);
    wire sel_rom      =  cpu_addr[15];
    wire sel_win      = (cpu_addr >= 16'h9cf6) && (cpu_addr <= 16'h9d21);

    // ---------------- RAM ----------------
    logic [7:0] ram [0:2047];
    logic [7:0] ram_q;
    always_ff @(posedge clk) begin
        if (sel_ram && wr_now) ram[cpu_addr[10:0]] <= cpu_dout;
        ram_q <= ram[cpu_addr[10:0]];
    end

    // ---------------- banked ROM ----------------
    logic [3:0] bank;
    always_ff @(posedge clk) begin
        if (reset) bank <= 4'd0;
        else if (sel_bank && wr_now) bank <= cpu_dout[3:0];
    end
    wire rom_open = (bank[1:0] == 2'b11);
    assign rom_addr = {bank[1:0], bank[2], cpu_addr[14:0]};
    // The request falls between bus cycles (the address is settled long before
    // phase 3), and there are none while the board is held in reset.
    // A 6809 spends a good part of its life in dead cycles, with 0xFFFF on
    // the address bus and nothing wanted from it.  Taken as reads they are a
    // ROM access each, all of the same word of whichever bank is selected -
    // and as the bank changes they chase each other out of the same cache
    // line (measured: most of the 33,000 cache misses a second in play).  A
    // cycle is dead when the CPU said so the cycle before (AVMA low) AND the
    // address is 0xFFFF; asking for both means a wrong AVMA cannot starve a
    // real read, such as the ROM checksum's of the last byte.
    logic vma;
    always_ff @(posedge clk) begin
        if (rst) vma <= 1'b1;
        else if (cen_e) vma <= cpu_avma;
    end
    wire   dead     = !vma && (cpu_addr == 16'hffff);
    wire   rom_want = sel_rom && cpu_rnw && !rom_open && !reset && !dead && (phase >= 6'(SETTLE));
    assign rom_req  = rom_want && !rom_done;
    always_ff @(posedge clk) begin
        if (rst || cen_e) rom_done <= 1'b0;
        else if (rom_req && rom_ack) begin rom_done <= 1'b1; rom_l <= rom_q; end
    end
    // the byte as the CPU sees it on the last clock: latched, or arriving now
    always_ff @(posedge clk) begin
        if (rst || cen_e || !rom_done) rom_age <= 3'd0;
        else if (rom_age != 3'(SETTLE)) rom_age <= rom_age + 3'd1;
    end
    wire [7:0] rom_byte = rom_l;

    // The writable window.  44 bytes; a byte reads back from here once it has
    // been written, and from the EPROM until then.
    wire  [5:0] win_a = 6'(cpu_addr - 16'h9cf6);
    logic [7:0] win [0:63];
    logic [7:0] win_q;
    logic [63:0] win_set;
    logic        win_hit;
    always_ff @(posedge clk) begin
        if (sel_win && wr_now) begin
            win[win_a]     <= cpu_dout;
            win_set[win_a] <= 1'b1;
        end
        win_q   <= win[win_a];
        win_hit <= sel_win && win_set[win_a] && (bank == 4'd0);
        if (rst) win_set <= '0;
    end

    // ---------------- what the 6809 reads, held still ----------------
    // The command latch, its strobe, the YM2151's interrupt and its status
    // move when they like; sampled here once a cycle they move at SAMPLE
    // only, 37 clocks before the 6809 looks.  A strobe is 5 us wide and a
    // cycle 0.5 us, so none is missed.
    logic [7:0] cmd_s, ym_dout_s, din_r;
    logic       cb1_s, ca1_s;
    always_ff @(posedge clk) begin
        if (phase == SAMPLE) begin
            cmd_s <= cmd; cb1_s <= cmd_strobe; ca1_s <= ym_irq_n; ym_dout_s <= ym_dout;
        end
        din_r <= cpu_din;
    end

    // ---------------- PIA ----------------
    wire [7:0] pia_dout, pia_pa, pia_ddra;
    wire       pia_ca2;
    wire       ym_irq_n;

    // cs only at the end of the cycle, so a read clears the interrupt flag
    // once, where the part would, and not for 48 clocks
    // Reset at power-up only.  The main board's reset line reaches the PIA on
    // the real board, but MAME's does not (reset_write resets the 6809 and the
    // bank, nothing else) and the program sets the PIA up again either way;
    // what it would change is the DAC, which would jump to +full-scale and
    // back on every sound-board reset because port A floats high while it is
    // an input (measured: a step in second 21 that MAME's recording lacks).
    pia6821 pia (
        .clk(clk), .reset(rst),
        .cs(sel_pia && cen_e), .we(sel_pia && wr_now), .rs(cpu_addr[1:0]),
        .din(cpu_dout), .dout(pia_dout),
        .pa_in(8'h00), .pa_out(pia_pa), .ddra_o(pia_ddra),
        .ca1(ca1_s),                           // MAME inverts an active-high IRQ; jt51's is active low already
        .ca2(pia_ca2),                         // -> YM2151 /IC
        .pb_in(cmd_s), .pb_out(), .ddrb_o(),
        .cb1(cb1_s), .cb2(),
        .irqa(pia_irqa), .irqb(pia_irqb)
    );

    // ---------------- YM2151 ----------------
    // A write is held until the chip has had an enable to see it: the E-high
    // window is 24 clocks and cen_p1 comes every ~54.  Two writes are never
    // closer than an instruction (>= 4 cycles, 192 clocks), so nothing queues.
    logic       ym_wr_pend;
    logic [7:0] ym_din_l;
    logic       ym_a0_l;
    always_ff @(posedge clk) begin
        if (reset) ym_wr_pend <= 1'b0;
        else begin
            if (ym_cen_p1) ym_wr_pend <= 1'b0;
            if (sel_ym && wr_now) begin
                ym_wr_pend <= 1'b1;
                ym_din_l   <= cpu_dout;
                ym_a0_l    <= cpu_addr[0];
            end
        end
    end

    wire [7:0] ym_dout;
    wire signed [15:0] ym_left, ym_right;

    jt51 ym (
        .rst(reset | ~pia_ca2), .clk(clk), .cen(ym_cen), .cen_p1(ym_cen_p1),
        .cs_n(~(ym_wr_pend | (sel_ym & cpu_rnw & (phase >= 6'(SETTLE))))),
        .wr_n(~ym_wr_pend),
        .a0(ym_wr_pend ? ym_a0_l : cpu_addr[0]),
        .din(ym_din_l), .dout(ym_dout),
        .ct1(), .ct2(), .irq_n(ym_irq_n), .sample(),
        .left(ym_left), .right(ym_right), .xleft(), .xright()
    );

    // ---------------- CVSD ----------------
    // MAME lowers the clock *before* it takes the new bit, so the decoder's
    // falling-edge step still sees the previous bit: hence the one-clock
    // delay on the digit.
    logic cvsd_clk_r;
    logic cvsd_dig_p;
    logic cvsd_dig_r;
    always_ff @(posedge clk) begin
        cvsd_dig_r <= cvsd_dig_p;
        if (rst) begin
            cvsd_clk_r <= 1'b0;
            cvsd_dig_p <= 1'b0;
        end else begin
            if (sel_cvsd_set && wr_now) cvsd_clk_r <= 1'b1;
            if (sel_cvsd_clr && wr_now) begin
                cvsd_clk_r <= 1'b0;
                cvsd_dig_p <= cpu_dout[0];
            end
        end
    end

    wire signed [15:0] cvsd_sample;
    hc55516 cvsd (
        .clk(clk), .reset(rst),
        .cvsd_clk(cvsd_clk_r), .digit(cvsd_dig_r),
        .sample(cvsd_sample)
    );

    // ---------------- CPU read mux ----------------
    always_comb begin
        cpu_din = 8'h00;
        if      (sel_ram) cpu_din = ram_q;
        else if (sel_pia) cpu_din = pia_dout;
        else if (sel_ym)  cpu_din = ym_dout_s;
        else if (sel_rom) cpu_din = win_hit ? win_q : rom_open ? 8'h00 : rom_byte;
    end

    // ---------------- mixer ----------------
    // MAME's weights with every source at a 16-bit full scale: each YM2151
    // channel 0.10, the DAC 0.25 (0x00..0xFF is -1..+1, so centred), the CVSD
    // 0.60.  In 1/4096: 410, 1024, 2458.  The sum can reach 1.05, so saturate.
    // Port A has pull-ups: a pin that is not yet an output reads high at the
    // DAC, which is what MAME's PIA hands its DAC too (+0.25 for the first
    // 14 ms after power-up, measured).
    wire        [7:0]  dac_in = pia_pa | ~pia_ddra;
    wire signed [15:0] dac_s  = {~dac_in[7], dac_in[6:0], 8'h00};

    // Three registered stages - the sources, the products, the sum - because
    // in one clock this was the worst path in the core (-8.4 ns): jt51's
    // `left`/`right` come through its own output companding, and then four
    // multiplies and an add.  Three clocks of latency on audio is nothing.
    logic signed [15:0] m_yl, m_yr, m_dac, m_cvsd;
    logic signed [31:0] p_ym, p_dac, p_cvsd, m_sum;
    wire  signed [16:0] m_ysum = {m_yl[15], m_yl} + {m_yr[15], m_yr};
    wire  signed [19:0] mix_s  = m_sum[31:12];
    always_ff @(posedge clk) begin
        m_yl <= ym_left; m_yr <= ym_right; m_dac <= dac_s; m_cvsd <= cvsd_sample;
        p_ym   <= 32'sd410  * m_ysum;
        p_dac  <= 32'sd1024 * m_dac;
        p_cvsd <= 32'sd2458 * m_cvsd;
        m_sum  <= p_ym + p_dac + p_cvsd;
        snd    <= (mix_s >  20'sd32767) ?  16'sd32767 :
                  (mix_s < -20'sd32768) ? 16'sh8000 : mix_s[15:0];
    end
endmodule

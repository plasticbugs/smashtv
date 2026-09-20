# ==============================================================================
# Smash TV on the Pocket: timing constraints beyond the BSP's
# sys_constr.sdc. The 96 MHz system clock, its 6.857 MHz video pair and the
# shifted SDRAM clock all come from core_pll and are timed as one related
# group; the two 74.25 MHz inputs and the audio PLL are asynchronous to it.
# The PLL's fifth output drives nothing in core_top, so no clock of its own
# reaches the netlist and it is not named here -- naming it only bought an
# ignored-filter warning that hid the ones that mattered.
# ==============================================================================
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

# SDRAM: the chip is clocked by the phase-shifted PLL output (core_pll's
# outclk_3).  The shift divides the budget between two checks that pull
# opposite ways: the data the chip returns is captured by an I/O-cell register
# on the core clock, and the address and command the core drives are captured
# by the chip.  On the captured data, setup gets 2T - shift and hold gets
# T - shift, so a nanosecond off the shift is a nanosecond onto setup and a
# nanosecond off hold.
#
# THE SHIFT IS PER-DESIGN.  5.859 ns is where Master of Weapon's fit balanced
# (setup slack = 6.241 - shift at slow 85C, hold slack = shift - 5.519 at fast
# 0C); the board is the same for every core but the fit is not.  If the worst
# path in a build is dram_dq[*] -> sdram_ctrl|dq_in[*], measure both slacks at
# two shift values, solve for where they meet, and round to a multiple of
# 130.2 ps, the step the 960 MHz VCO can make.  projects/report_worst.tcl
# writes the reports to read: worst_paths*.txt for setup, worst_hold_fast.txt
# for hold.  METHODOLOGY.md section 5.20.
create_generated_clock -name dram_clk -source \
    [get_pins {ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    [get_ports {dram_clk}]
set_input_delay -max -clock dram_clk 7.0 [get_ports {dram_dq[*]}]
set_input_delay -min -clock dram_clk 2.5 [get_ports {dram_dq[*]}]
set SDRAM_OUT [get_ports {dram_a[*] dram_ba[*] dram_cke dram_dqm[*] dram_dq[*] dram_ras_n dram_cas_n dram_we_n}]
set_output_delay -max -clock dram_clk  1.5 $SDRAM_OUT
set_output_delay -min -clock dram_clk -0.8 $SDRAM_OUT
set_multicycle_path -setup 2 -from [get_clocks {dram_clk}] -to [get_registers {*|sdram_ctrl:*|dq_in[*]}]
set_multicycle_path -setup 3 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]
set_multicycle_path -hold  2 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]

# The pixel hand-over to the 8 MHz video clock. The dot enable's phase is
# pinned to clk_vid (core_top.sv's pix_sync into clk_enables.sv), so the
# colour and sync registers are launched a fixed number of system clocks
# before the clk_vid edge that samples them, and the setup check starts from
# that launch edge. The toggle the other way (vt -> vt_s) is a plain
# flop-to-flop path, checked as it stands.
set VID_OUT [get_registers {ic|vr_q[*] ic|vg_q[*] ic|vb_q[*] ic|vhs_q ic|vvs_q ic|vde_q}]
set_multicycle_path -setup 3 -start -from [get_clocks {ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -to $VID_OUT
set_multicycle_path -hold  2 -start -from [get_clocks {ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -to $VID_OUT

# SRAM: registered pins held for whole system cycles, a read sampled several
# cycles after the address (target/pocket/sram_port.sv), so the pins are not
# timed against a clock.
set_false_path -to   [get_ports {sram_*}]
set_false_path -from [get_ports {sram_dq[*]}]

# The PSRAMs are unused on this board; the BSP still brings their pins out.
set_false_path -to   [get_ports {cram0_* cram1_*}]
set_false_path -from [get_ports {cram0_dq[*] cram1_dq[*] cram0_wait cram1_wait}]

# ------------------------------------------------------------------------------
# Multicycle exceptions for clock-enabled blocks go here.  None are claimed
# yet, because the skeleton has nothing that needs one.  Before adding any,
# read METHODOLOGY.md sections 5.11 and 5.20:
#
#   * write down why EVERYTHING the filter matches qualifies, and register
#     every input at the edge of the relaxed region;
#   * a register Quartus merges into a block RAM's output no longer exists by
#     name, the filter matches nothing, and the line is ignored with a warning
#     -- CI fails the build on that (Check every constraint was applied);
#   * a block RAM read closes on one clock.  Leave it alone.
#
# The shape the sibling cores use, proven on hardware, for a CPU that steps on
# clock enables four or more system clocks apart:
#
#   set M68K [get_keepers {*|fx68k:*|*}]
#   set_multicycle_path -setup 4 -from $M68K -to $M68K
#   set_multicycle_path -hold  3 -from $M68K -to $M68K
# ------------------------------------------------------------------------------

# The TMS34010 (rtl/tms34010.sv, parameter STEP = 3).  Its state machine - the
# register file, the status register, the instruction register, every counter
# and scratch register of the execute states - is enabled on one clock in
# three, because its execute state is about 19.5 ns of logic in this part
# (-9.1 ns of slack at 96 MHz before this).  So a path between two of those
# registers has three clocks.  The registers that see EVERY clock are the ones
# listed in CPU_FAST and are left at one: the step counter, the bus
# handshake's latched ack and data, the held display-interrupt pulse, the
# cycle balance and the local copy of reset.  If a register is added to the every-clock block at the end
# of tms34010.sv it MUST be added here, or it is given time it does not have.
set CPU_ALL  [get_registers {*|tms34010:u_cpu|*}]
set CPU_FAST [get_registers {*|tms34010:u_cpu|stepcnt[*] *|tms34010:u_cpu|q_ack *|tms34010:u_cpu|q_rdata[*] *|tms34010:u_cpu|dpy_l *|tms34010:u_cpu|bal[*] *|tms34010:u_cpu|rst_q}]
set CPU_STEP [remove_from_collection $CPU_ALL $CPU_FAST]
set_multicycle_path -setup 3 -from $CPU_STEP -to $CPU_STEP
set_multicycle_path -hold  2 -from $CPU_STEP -to $CPU_STEP

# The TMS34010's address out to the main board's read multiplexer.  bus_addr
# moves on a step with the request; rtl/stv_main.sv's bus machine sees the
# request a clock later and latches c_rd a clock after that at the earliest.
set_multicycle_path -setup 2 -from [get_registers {*|tms34010:u_cpu|bus_addr[*]}] -to [get_registers {*|stv_main:u_main|c_rd[*]}]
set_multicycle_path -hold  1 -from [get_registers {*|tms34010:u_cpu|bus_addr[*]}] -to [get_registers {*|stv_main:u_main|c_rd[*]}]

# The sound board's 6809 (rtl/stv_sound.sv, "how this is timed").  It is
# enabled once in 48 clocks; its data input is a register, din_r, whose
# sources are still for SETTLE (5) clocks before the cycle ends; and nothing
# acts on its address bus until SETTLE clocks into the cycle.  So these three
# kinds of path have SND_MC clocks.  The enables (phase -> cen_e, cen_q) are
# NOT among them and stay at one.
set SND_MC  4
set SND_CPU [get_registers {*|stv_sound:u_snd|mc6809e:cpu|*}]
set SND_DIN [get_registers {*|stv_sound:u_snd|din_r[*]}]
set SND_ALL [get_registers {*|stv_sound:u_snd|*}]
set SND_EXT [remove_from_collection $SND_ALL $SND_CPU]
set SND_ROMC [get_registers {*|smashtv_mem:u_mem|rom_cache:u_scache|*}]
set_multicycle_path -setup $SND_MC -from $SND_CPU -to $SND_CPU
set_multicycle_path -hold  [expr {$SND_MC - 1}] -from $SND_CPU -to $SND_CPU
set_multicycle_path -setup $SND_MC -from $SND_DIN -to $SND_CPU
set_multicycle_path -hold  [expr {$SND_MC - 1}] -from $SND_DIN -to $SND_CPU
set_multicycle_path -setup $SND_MC -from $SND_CPU -to $SND_EXT
set_multicycle_path -hold  [expr {$SND_MC - 1}] -from $SND_CPU -to $SND_EXT
set_multicycle_path -setup $SND_MC -from $SND_CPU -to $SND_ROMC
set_multicycle_path -hold  [expr {$SND_MC - 1}] -from $SND_CPU -to $SND_ROMC

# The YM2151 (modules/sound-jt51).  Every register in it is enabled by cen or
# cen_p1, 26 and 54 clocks apart, except its register file, which takes a
# write on any clock the strobe is up - and rtl/stv_sound.sv raises the strobe
# on the clock after a cen_p1 for that reason.  Two clocks.
set YM [get_registers {*|stv_sound:u_snd|jt51:ym|*}]
set_multicycle_path -setup 2 -from $YM -to $YM
set_multicycle_path -hold  1 -from $YM -to $YM

# The bring-up panel's "first sound ROM byte" latch is fed through the byte
# select, which is the 6809's address bit 0: one of the 6809's four-clock paths
# that happens to end in core_top.
set_multicycle_path -setup $SND_MC -from $SND_CPU -to [get_registers {ic|first_snd[*]}]
set_multicycle_path -hold  [expr {$SND_MC - 1}] -from $SND_CPU -to [get_registers {ic|first_snd[*]}]

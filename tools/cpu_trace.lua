-- MAME's debugger trace of the TMS34010 with the whole register file logged
-- before every instruction, for sim/run_cpu.sh:
--
--     =ST A0..A14 B0..B14 SP
--     PC: disassembly
--
-- Needs -debug -debugger none.  The bus trace is taken in a SEPARATE run, by
-- tools/bus_trace.lua with no debugger: the debugger's disassembler reads
-- every instruction through the address space before the CPU does, and a
-- memory tap cannot tell the two apart -- so with both in one run every
-- opcode fetch appears in the bus trace twice.  MAME is deterministic, and
-- the bench would notice at once if the two runs disagreed.
local mac = manager.machine
local dbg = mac.debugger
local dir = os.getenv("TRACE_DIR") or "."
local FRAMES = tonumber(os.getenv("TRACE_FRAMES") or "40")

local regs = "st"
for i = 0, 14 do regs = regs .. ",a" .. i end
for i = 0, 14 do regs = regs .. ",b" .. i end
regs = regs .. ",sp"
local fmt = "=" .. string.rep("%08X ", 32)
dbg:command(string.format('trace %s/trace_reg.txt,maincpu,noloop,{tracelog "%s\\n",%s}',
                          dir, fmt, regs))
dbg.execution_state = "run"

local frames, tracing = 0, true
_G.KEEP = {}
_G.KEEP.n = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if tracing and frames >= FRAMES then
        tracing = false
        dbg:command("trace off,maincpu")
    end
end)
_G.KEEP.s = emu.add_machine_stop_notifier(function()
    if tracing then dbg:command("trace off,maincpu") end
end)

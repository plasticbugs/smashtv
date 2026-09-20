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
local START  = tonumber(os.getenv("START_FRAME") or "0")

local regs = "st"
for i = 0, 14 do regs = regs .. ",a" .. i end
for i = 0, 14 do regs = regs .. ",b" .. i end
regs = regs .. ",sp"
local fmt = "=" .. string.rep("%08X ", 32)
-- CYCLES=1 appends the CPU's running cycle count, so the difference between
-- two lines is what MAME charged for the instruction between them (and any
-- interrupt entry).  sim/tb_cpu.cpp compares it with what the RTL charged.
if os.getenv("CYCLES") == "1" then
    regs = regs .. ",totalcycles"
    fmt = fmt .. "%X "
end
local function start_trace()
    dbg:command(string.format('trace %s/trace_reg.txt,maincpu,noloop,{tracelog "%s\\n",%s}',
                              dir, fmt, regs))
end
if START == 0 then start_trace() end
dbg.execution_state = "run"

-- set_value(1) is PRESSED whatever the port's polarity (measured: the game
-- read IN1 = FFFE from the frame after set_value(1)).  This had 0 for pressed
-- until the machine bench and MAME disagreed about when the coin went in.
local function press(port, field, on)
    local p = mac.ioport.ports[port]
    if p and p.fields[field] then p.fields[field]:set_value(on and 1 or 0) end
end

local frames, tracing = 0, true
_G.KEEP = {}
_G.KEEP.n = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames == 1600 then press(":IN1", "Coin 1", true) end
    if frames == 1610 then press(":IN1", "Coin 1", false) end
    if frames == 1700 then press(":IN1", "1 Player Start", true) end
    if frames == 1710 then press(":IN1", "1 Player Start", false) end
    if frames > 1800 then
        press(":IN0", "P1 Fire Right", (frames // 30) % 2 == 0)
        press(":IN0", "P1 Move Up",    (frames // 47) % 2 == 0)
    end
    if START > 0 and frames == START then start_trace() end
    if tracing and frames >= START + FRAMES then
        tracing = false
        dbg:command("trace off,maincpu")
    end
end)
_G.KEEP.s = emu.add_machine_stop_notifier(function()
    if tracing then dbg:command("trace off,maincpu") end
end)

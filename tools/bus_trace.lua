-- Log every bus transaction the TMS34010 makes, from reset, so a CPU written
-- from scratch can be held to MAME one transaction at a time
-- (METHODOLOGY section 4, the pattern rtl/i8085.sv was built on).
--
--   TRACE_DIR=... TRACE_N=2000000 tools/mame.sh -seconds_to_run 2 \
--       -autoboot_script tools/bus_trace.lua
--
-- Writes trace_bus.bin: 16 bytes per transaction, little-endian,
--
--   u32 index        0, 1, 2, ... in the order they happened
--   u32 addr         the TMS34010 bit address, 16-bit aligned
--   u16 data         the word read or written
--   u16 mask         mem_mask, so a byte access is visible as one
--   u8  write        0 read, 1 write
--   u8  region       0 frame buffer, 1 main RAM, 2 CMOS, 3 palette,
--                    4 blitter, 5 inputs, 6 sound, 7 control,
--                    8 graphics ROM, 9 program ROM, 10 I/O registers,
--                    11 anything else
--   u16 pad
--
-- and trace_bus.txt with the counts per region and per direction, which is
-- what tells you at a glance whether the trace saw what it should have.
--
-- Known limit, and it has to be measured rather than assumed: MAME's
-- TMS34010 fetches opcodes through a `cache` object over the same address
-- space, and a Lua tap may not see accesses that go through one.  The report
-- says how many reads of the program region were seen; if that number is
-- tiny next to the instruction count, the trace is data accesses only and
-- the RTL's own instruction fetches have to be checked another way.
local mac = manager.machine
local cpu = mac.devices[":maincpu"]
local sp  = cpu.spaces["program"]
local dir = os.getenv("TRACE_DIR") or "."
local WANT = tonumber(os.getenv("TRACE_N") or "2000000")
-- START_FRAME > 0 begins the trace at that frame's notifier instead of at
-- reset, and writes the TMS34010's I/O registers as they stand at that
-- instant to ioregs.txt, so the bench can warm-start the RTL there.
local START = tonumber(os.getenv("START_FRAME") or "0")
local recording = (START == 0)

local n = 0
local buf = {}
local f = io.open(dir .. "/trace_bus.bin", "wb")
local per_region_r = {}
local per_region_w = {}

local function region_of(a)
    if     a < 0x00200000                       then return 0
    elseif a >= 0x01000000 and a < 0x01100000   then return 1
    elseif a >= 0x01400000 and a < 0x01410000   then return 2
    elseif a >= 0x01800000 and a < 0x01820000   then return 3
    elseif a >= 0x01a00000 and a < 0x01a80100   then return 4
    elseif a >= 0x01c00000 and a < 0x01c00080   then return 5
    elseif a >= 0x01e00000 and a < 0x01e00020   then return 6
    elseif a >= 0x01f00000 and a < 0x01f00020   then return 7
    elseif a >= 0x02000000 and a < 0x06000000   then return 8
    elseif a >= 0xff800000                      then return 9
    elseif a >= 0xc0000000 and a < 0xc0000200   then return 10
    else                                             return 11
    end
end

local function rec(write, a, data, mask)
    if not recording or n >= WANT then return end
    local r = region_of(a)
    if write then per_region_w[r] = (per_region_w[r] or 0) + 1
    else         per_region_r[r] = (per_region_r[r] or 0) + 1 end
    buf[#buf + 1] = string.char(
        n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff,
        a & 0xff, (a >> 8) & 0xff, (a >> 16) & 0xff, (a >> 24) & 0xff,
        data & 0xff, (data >> 8) & 0xff,
        mask & 0xff, (mask >> 8) & 0xff,
        write and 1 or 0, r, 0, 0)
    n = n + 1
    if #buf >= 4096 then f:write(table.concat(buf)); buf = {} end
end

-- One tap over the whole space.  Reads and writes are separate taps; both
-- give (offset, data, mask) with the offset in the space's own units, which
-- for this CPU are bit addresses.
local taps = {}
taps[#taps+1] = sp:install_read_tap(0, 0xffffffff, "busr", function(off, data, mask)
    rec(false, off, data & 0xffff, mask & 0xffff)
end)
taps[#taps+1] = sp:install_write_tap(0, 0xffffffff, "busw", function(off, data, mask)
    rec(true, off, data & 0xffff, mask & 0xffff)
end)

local NAMES = {
    [0]="framebuffer", "mainram", "cmos", "palette", "blitter", "inputs",
    "sound", "control", "gfxrom", "progrom", "ioregs", "other"
}

local frames = 0
-- set_value(1) is PRESSED whatever the port's polarity (measured: the game
-- read IN1 = FFFE from the frame after set_value(1)).  This had 0 for pressed
-- until the machine bench and MAME disagreed about when the coin went in.
local function press(port, field, on)
    local p = mac.ioport.ports[port]
    if p and p.fields[field] then p.fields[field]:set_value(on and 1 or 0) end
end
_G.KEEP = { t = taps }
_G.KEEP.n = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    -- the same script of inputs every capture in this tree uses
    if frames == 1600 then press(":IN1", "Coin 1", true) end
    if frames == 1610 then press(":IN1", "Coin 1", false) end
    if frames == 1700 then press(":IN1", "1 Player Start", true) end
    if frames == 1710 then press(":IN1", "1 Player Start", false) end
    if frames > 1800 then
        press(":IN0", "P1 Fire Right", (frames // 30) % 2 == 0)
        press(":IN0", "P1 Move Up",    (frames // 47) % 2 == 0)
    end
    if START > 0 and frames == START then
        local o = io.open(dir .. "/ioregs.txt", "w")
        for r = 0, 31 do
            -- not HCOUNT (28): reading it is harmless but meaningless here
            o:write(string.format("%04x\n", sp:read_u16(0xc0000000 + r * 16)))
        end
        o:close()
        recording = true
    end
end)
_G.KEEP.s = emu.add_machine_stop_notifier(function()
    if #buf > 0 then f:write(table.concat(buf)) end
    f:close()
    local o = io.open(dir .. "/trace_bus.txt", "w")
    o:write(string.format("transactions %d (asked for %d)\n", n, WANT))
    o:write(string.format("%-12s %10s %10s\n", "region", "reads", "writes"))
    for i = 0, 11 do
        local r, w = per_region_r[i] or 0, per_region_w[i] or 0
        if r + w > 0 then
            o:write(string.format("%-12s %10d %10d\n", NAMES[i], r, w))
        end
    end
    o:write(string.format("\nPC now %08x\n", cpu.state["PC"].value))
    o:close()
end)

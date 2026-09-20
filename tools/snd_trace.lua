-- What the sound board is asked to do and what it does, from MAME, for the
-- sound bench (sim/run_sound.sh) and for docs/hardware.md section 6.
--
--   TRACE_DIR=ref/sound tools/mame.sh -seconds_to_run 60 \
--       -wavwrite ref/sound/mame.wav -autoboot_script tools/snd_trace.lua
--
-- Writes
--   snd_cmd.txt    one line per main-CPU write to 0x01E00000:
--                  "<seconds> <frame> <word>"  (seconds is emu.time(), the
--                  same clock -wavwrite's sample count runs on)
--   snd_trace.txt  the summary: 6809 writes into 0x8000-0xFFFF (the address
--                  range MAME patches over, 0x9CF6-0x9D21, separately), reads
--                  of that range, bank values, CVSD clock writes per second,
--                  DAC writes per second, YM writes.
local mac = manager.machine
local main = mac.devices[":maincpu"].spaces["program"]
local scpu = mac.devices[":cvsd:cpu"]
local snd  = scpu.spaces["program"]
local dir  = os.getenv("TRACE_DIR") or "."

local cmd = io.open(dir .. "/snd_cmd.txt", "w")
local frames = 0
local taps = {}

taps[#taps+1] = main:install_write_tap(0x01e00000, 0x01e0001f, "sndw", function(off, data, mask)
    if off == 0x01e00000 then
        cmd:write(string.format("%.9f %d %04x\n", emu.time(), frames, data & 0xffff))
    end
end)

local romw, romw_first = 0, {}
local protw, protr = 0, 0
local bank = {}
local cvsd_per_s, dac_per_s, ym_per_s = {}, {}, {}
local function bump(t) local s = math.floor(emu.time()); t[s] = (t[s] or 0) + 1 end

taps[#taps+1] = snd:install_write_tap(0x8000, 0xffff, "romw", function(off, data, mask)
    romw = romw + 1
    if off >= 0x9cf6 and off <= 0x9d21 then protw = protw + 1 end
    if #romw_first < 40 then
        romw_first[#romw_first+1] = string.format("  %.6f  %04x <- %02x  pc %04x",
            emu.time(), off, data & 0xff, scpu.state["PC"].value)
    end
end)
taps[#taps+1] = snd:install_read_tap(0x9cf6, 0x9d21, "protr", function(off, data, mask)
    protr = protr + 1
end)
taps[#taps+1] = snd:install_write_tap(0x6000, 0x7fff, "cvsdw", function(off, data, mask)
    if off >= 0x7800 then
        local v = data & 0x0f
        bank[v] = (bank[v] or 0) + 1
    elseif off >= 0x6800 and off < 0x7000 then
        bump(cvsd_per_s)
    end
end)
taps[#taps+1] = snd:install_write_tap(0x4000, 0x5fff, "piaw", function(off, data, mask)
    if (off & 3) == 0 then bump(dac_per_s) end
end)
taps[#taps+1] = snd:install_write_tap(0x2000, 0x3fff, "ymw", function(off, data, mask)
    bump(ym_per_s)
end)

local function press(port, field, on)
    local p = mac.ioport.ports[port]
    if p and p.fields[field] then p.fields[field]:set_value(on and 0 or 1) end
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
end)
_G.KEEP.s = emu.add_machine_stop_notifier(function()
    cmd:close()
    local o = io.open(dir .. "/snd_trace.txt", "w")
    o:write(string.format("frames %d, %.3f s\n", frames, emu.time()))
    o:write(string.format("6809 writes to 0x8000-0xFFFF: %d (of them in 0x9CF6-0x9D21: %d)\n", romw, protw))
    o:write(string.format("6809 reads of 0x9CF6-0x9D21: %d\n", protr))
    for _, l in ipairs(romw_first) do o:write(l .. "\n") end
    o:write("bank register values written:\n")
    for v = 0, 15 do if bank[v] then o:write(string.format("  %x: %d\n", v, bank[v])) end end
    o:write("per second: cvsd clock-high writes, DAC (PIA reg 0) writes, YM writes\n")
    for s = 0, math.floor(emu.time()) do
        o:write(string.format("  %3d %7d %7d %7d\n", s, cvsd_per_s[s] or 0, dac_per_s[s] or 0, ym_per_s[s] or 0))
    end
    o:close()
end)

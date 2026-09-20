-- MAME's picture at chosen frames, under the input script every capture in
-- this tree uses, for comparing with sim/run_machine.sh.
--   DUMP_DIR=... FRAMES="100 200 300" tools/mame.sh -seconds_to_run 40 \
--       -autoboot_script tools/snap_frames.lua
-- snapshot() is the picture of the frame just finished; pixels() is a frame
-- stale (docs/hardware.md, measured), so it is not used.
local mac = manager.machine
local dir = os.getenv("DUMP_DIR") or "."
local want = {}
for n in string.gmatch(os.getenv("FRAMES") or "", "%d+") do want[tonumber(n)] = true end
local frames = 0
local function press(port, field, on)
    local p = mac.ioport.ports[port]
    if p and p.fields[field] then p.fields[field]:set_value(on and 0 or 1) end
end
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
    if want[frames] then
        mac.screens[":screen"]:snapshot(string.format("%s/mame_%05d.png", dir, frames))
    end
end)
_G.KEEP.s = emu.add_machine_stop_notifier(function()
    local o = io.open(dir .. "/frames.txt", "w"); o:write(frames, "\n"); o:close()
end)

-- Instruction traces from MAME's debugger, in windows, so the set of
-- TMS34010 instructions this game executes is measured rather than guessed.
--
--   TRACE_DIR=... mame smashtv ... -debug -debugger none \
--       -autoboot_script tools/insn_trace.lua -seconds_to_run 48
--   (tools/insn_hist.sh wraps this.)
--
-- One file per window, tr_<frame>.txt, each WINDOW frames long.  The first
-- window starts at reset, which is where the self-tests live.
local mac = manager.machine
local dbg = mac.debugger
local dir = os.getenv("TRACE_DIR") or "."
local WINDOW = tonumber(os.getenv("WINDOW") or "12")
local STARTS = {}
for n in string.gmatch(os.getenv("STARTS") or "0,100,360,600,1045,1150,1500,1610,1705,1900,2300,2600", "%d+") do
  STARTS[tonumber(n)] = true
end
local frames, stop_at = 0, nil

local function start(n)
  dbg:command(string.format("trace %s/tr_%05d.txt,maincpu,noloop", dir, n))
  stop_at = n + WINDOW
end
if STARTS[0] then start(0) end
dbg.execution_state = "run"

-- set_value(1) is PRESSED whatever the port's polarity (measured: the game
-- read IN1 = FFFE from the frame after set_value(1)).  This had 0 for pressed
-- until the machine bench and MAME disagreed about when the coin went in.
local function press(port, field, on)
  local p = mac.ioport.ports[port]
  if p and p.fields[field] then p.fields[field]:set_value(on and 1 or 0) end
end

_G.KEEP = {}
_G.KEEP.s = emu.add_machine_stop_notifier(function()
  if stop_at then dbg:command("trace off,maincpu") end
end)
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
  if stop_at and frames >= stop_at then
    dbg:command("trace off,maincpu"); stop_at = nil
  end
  if STARTS[frames] and not stop_at then start(frames) end
end)

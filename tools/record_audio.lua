-- Drive the game so MAME's recorded audio can be lined up with the core's.
-- COIN and START are frame numbers; leave them out for a plain attract run.
local mac = manager.machine
local out = io.open(os.getenv("OUT") or "audio_run.txt", "w")
local COIN  = tonumber(os.getenv("COIN")  or "-1")
local START = tonumber(os.getenv("START") or "-1")
local n = 0
-- set_value(1) is PRESSED whatever the port's polarity (measured: the game
-- read IN1 = FFFE from the frame after set_value(1)).  This had 0 for pressed
-- until the machine bench and MAME disagreed about when the coin went in.
local function press(f, on)
  mac.ioport.ports[":IN1"].fields[f]:set_value(on and 1 or 0)
end
_G.KEEP = {}
_G.KEEP.n = emu.add_machine_frame_notifier(function()
  n = n + 1
  if n == COIN      then press("Coin 1", true)  end
  if n == COIN + 10 then press("Coin 1", false) end
  if n == START     then press("1 Player Start", true)  end
  if n == START +10 then press("1 Player Start", false) end
end)
_G.KEEP.s = emu.add_machine_stop_notifier(function()
  out:write(string.format("frames %d\n", n)); out:close()
end)

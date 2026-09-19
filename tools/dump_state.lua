-- Freeze the whole video state of smashtv at chosen frames, plus MAME's own
-- picture of the same frame, so tools/render_model.py can be held to it pixel
-- for pixel and the RTL can be loaded with it.
--
--   DUMPFRAMES=1000,2000 DUMP_DIR=... tools/mame.sh -seconds_to_run 40 \
--       -autoboot_script tools/dump_state.lua
--
-- One binary file per frame, little-endian throughout:
--
--   magic "STVS", u32 version = 2, u32 frame
--   u16 ctrl              last value written to 0x01F00000 (docs/hardware.md 7.5)
--   u16 dma[16]           the blitter's registers as last written
--   u16 vram[262144]      the frame buffer: 512 rows of 512 pixels, each
--                         { palette byte, pixel byte } exactly as MAME holds it
--   u16 pal[4096]         palette RAM, xRRRRRGGGGGBBBBB
--   u32 pix[256][410]     MAME's own output for this frame, from screen:pixels()
--
-- The frame buffer is two planes and the CPU can only see one at a time, so
-- this flips the video bank select in the control register, reads each plane
-- through the CPU's own VRAM window, and puts the register back the way the
-- game left it.  control_w only latches three values, so writing it twice
-- here is invisible to the game -- and the CPU is stopped while this runs.
--
-- DUMPWHEN picks the moment inside the frame:
--   "done"  (default) the frame-done notifier, i.e. after the whole picture
--           has been scanned out and autoerase has wiped it
--   "dpyint" the first display interrupt of the frame, which on this game is
--           inside vertical blank at line 282 with the picture fully drawn
local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
local dir = os.getenv("DUMP_DIR") or "."
local when = os.getenv("DUMPWHEN") or "done"

local VRAM_BASE = 0x00000000
local PAL_BASE  = 0x01800000
local DMA_BASE  = 0x01a80000
local CTRL_BASE = 0x01f00000

local want = {}
for n in string.gmatch(os.getenv("DUMPFRAMES") or "1000", "%d+") do
  want[tonumber(n)] = true
end
local COIN  = tonumber(os.getenv("COIN")  or "1600")
local START = tonumber(os.getenv("START") or "1700")

local frames = 0
local ctrl_last = 0x2c          -- until the game writes one
local dma = {}
local taps = {}

local function u16(f, v) f:write(string.char(v & 0xff, (v >> 8) & 0xff)) end
local function u32(f, v)
  f:write(string.char(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff))
end

-- read `words` 16-bit words from `base`, a bit address, into the file
local function block(f, base, words)
  local t = {}
  for i = 0, words - 1 do
    local v = sp:read_u16(base + i * 16)
    t[#t + 1] = string.char(v & 0xff, (v >> 8) & 0xff)
    if #t == 8192 then f:write(table.concat(t)); t = {} end
  end
  if #t > 0 then f:write(table.concat(t)) end
end

-- The frame buffer, both planes, as one u16 per pixel.  A VRAM word covers two
-- pixels: with the pixel bank selected it reads {px[2n+1].pixel, px[2n].pixel},
-- with the palette bank {px[2n+1].pal, px[2n].pal}.
local function dump_vram(f)
  local N = 512 * 512 // 2                       -- words
  sp:write_u16(CTRL_BASE, (ctrl_last | 0x20) & 0xffff)      -- pixel plane
  local pixlo, pixhi = {}, {}
  for i = 0, N - 1 do
    local v = sp:read_u16(VRAM_BASE + i * 16)
    pixlo[i] = v & 0xff ; pixhi[i] = (v >> 8) & 0xff
  end
  sp:write_u16(CTRL_BASE, ctrl_last & 0xffdf)               -- palette plane
  local t = {}
  for i = 0, N - 1 do
    local v = sp:read_u16(VRAM_BASE + i * 16)
    local e0 = ((v & 0xff) << 8) | pixlo[i]
    local e1 = (v & 0xff00) | pixhi[i]
    t[#t + 1] = string.char(e0 & 0xff, (e0 >> 8) & 0xff, e1 & 0xff, (e1 >> 8) & 0xff)
    if #t == 4096 then f:write(table.concat(t)); t = {} end
  end
  if #t > 0 then f:write(table.concat(t)) end
  sp:write_u16(CTRL_BASE, ctrl_last)                        -- as the game left it
end

local function dump(n)
  local f = io.open(string.format("%s/state_%05d.bin", dir, n), "wb")
  f:write("STVS"); u32(f, 2); u32(f, n)
  u16(f, ctrl_last)
  for i = 0, 15 do u16(f, dma[i] or 0) end
  dump_vram(f)
  block(f, PAL_BASE, 4096)
  f:write(mac.screens[":screen"]:pixels())
  f:close()
  mac.screens[":screen"]:snapshot(string.format("%s/mame_%05d.png", dir, n))
end

taps[#taps+1] = sp:install_write_tap(CTRL_BASE, CTRL_BASE + 0x1f, "ctrl", function(off, data)
  ctrl_last = data & 0xffff
end)
taps[#taps+1] = sp:install_write_tap(DMA_BASE, DMA_BASE + 0x9f, "dma", function(off, data)
  dma[((off - DMA_BASE) >> 4) & 0xf] = data & 0xffff
end)

local function press(port, field, on)
  local p = mac.ioport.ports[port]
  if p and p.fields[field] then p.fields[field]:set_value(on and 0 or 1) end
end

-- "dpyint": fire on the frame's first display interrupt, which this game puts
-- at line 282, inside vertical blank, with the picture drawn and not yet
-- autoerased.  The game rewrites DPYINT from inside the handler, so a write
-- tap on it is the same event one instruction later.
local pending = nil
if when == "dpyint" then
  taps[#taps+1] = sp:install_write_tap(0xc00000a0, 0xc00000af, "dpyint", function(off, data)
    if pending and (data & 0xffff) == 0x009a then dump(pending); pending = nil end
  end)
end

_G.KEEP = { t = taps }
_G.KEEP.s = emu.add_machine_stop_notifier(function()
  local f = io.open(dir .. "/run.txt", "w")
  f:write(string.format("frames %d\n", frames))
  for n in pairs(want) do
    local h = io.open(string.format("%s/state_%05d.bin", dir, n), "rb")
    f:write(string.format("want %d %s\n", n, h and "ok" or "MISSING"))
    if h then h:close() end
  end
  f:close()
end)
_G.KEEP.n = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if frames == COIN      then press(":IN1", "Coin 1", true)  end
  if frames == COIN + 10 then press(":IN1", "Coin 1", false) end
  if frames == START     then press(":IN1", "1 Player Start", true)  end
  if frames == START + 10 then press(":IN1", "1 Player Start", false) end
  if frames > START + 100 then
    press(":IN0", "P1 Fire Right", (frames // 30) % 2 == 0)
    press(":IN0", "P1 Move Up",    (frames // 47) % 2 == 0)
  end
  if want[frames] then
    if when == "dpyint" then pending = frames else dump(frames) end
  end
end)

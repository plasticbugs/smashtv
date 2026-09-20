-- Freeze smashtv's video state, then record everything that touches the
-- picture for a run of frames, so tools/render_model.py can reproduce MAME's
-- output frame by frame and the RTL can be held to the same trace.
--
--   DUMP_DIR=... FROM=1500 COUNT=8 tools/mame.sh -seconds_to_run 40 \
--       -autoboot_script tools/dump_state.lua
--
-- Why a trace and not one frozen frame: this game races the beam.  Autoerase
-- is turned on part-way down the picture, so rows 134-251 are wiped as they
-- are scanned out and redrawn before the beam comes round again -- there is no
-- instant at which the frame buffer holds a whole picture.  Measured: a
-- frame-done freeze reproduces MAME exactly on rows 0-133 and 252-255 and
-- differs on every pixel of rows 134-251, for any frame it is compared with.
--
-- Files, all little-endian:
--
--   state_NNNNN.bin   the freeze at the frame-done boundary after picture
--                     NNNNN, which is where the replay starts:
--                       magic "STVS", u32 version = 3, u32 frame
--                       u16 ctrl              0x01F00000, as last written
--                       u16 dma[16]           the blitter's registers
--                       u16 fb[262144]        512 rows of 512 pixels,
--                                             { palette byte, pixel byte }
--                       u16 pen[4096]         the display pens (see below)
--
--   trace.bin         every event that can change the picture, in order:
--                       u32 frame   the frame-done boundary it follows, so
--                                   these events compose picture frame+1
--                       u16 vpos    raster line, 0..288, read from the
--                                   TMS34010's own VCOUNT register (the Lua
--                                   screen object in MAME 0.288 has no vpos)
--                       u16 seq     sequence within the line, so two events
--                                   on one line keep their order
--                       u8  kind    0 blitter register, 1 CPU frame-buffer
--                                   write, 2 palette write, 3 control write
--                       u8  reg     blitter register number, for kind 0
--                       u32 addr    word offset within the block
--                       u16 data
--                       u16 mask    the access's mem_mask
--                     18 bytes each.
--
--   pic_NNNNN.bin     MAME's own picture for frame NNNNN: u32 ARGB, 410x256.
--
-- The pens are built by following palette writes rather than read back,
-- because the pen is offset & 0xfff (paletteram_w in midyunit_v.cpp) and this
-- game writes its palette through offsets 0x1000-0x1fff while 0x000-0xfff
-- still hold the power-up RAM test's patterns.  Measured: 12,287 writes to the
-- low half and 6,839 to the high half in a 28-second run, and the low half
-- reads back as doubled-byte test patterns, not colours.
--
-- The frame buffer is two planes and the CPU sees one at a time, so the freeze
-- flips the video bank select in the control register, reads each plane
-- through the CPU's own VRAM window, and puts the register back.  control_w
-- only latches three values and the CPU is stopped while this runs.
local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
local scr = mac.screens[":screen"]
local dir = os.getenv("DUMP_DIR") or "."

local VRAM_BASE = 0x00000000
local PAL_BASE  = 0x01800000
local DMA_BASE  = 0x01a80000       -- the mirror the game uses
local CTRL_BASE = 0x01f00000

local FROM  = tonumber(os.getenv("FROM")  or "1500")
local COUNT = tonumber(os.getenv("COUNT") or "8")
local COIN  = tonumber(os.getenv("COIN")  or "1600")
local START = tonumber(os.getenv("START") or "1700")

local frames = 0
local ctrl_last = 0x2c
local dma = {}
local pen = {}
local taps = {}
local trace = nil                  -- open while recording
local tbuf = {}

local function u16(f, v) f:write(string.char(v & 0xff, (v >> 8) & 0xff)) end
local function u32(f, v)
  f:write(string.char(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff))
end

local VCOUNT = 0xc0000000 + 29 * 16      -- reading it has no side effects
local seq, seq_line = 0, -1

local function event(kind, reg, addr, data, mask)
  if not trace then return end
  local v = sp:read_u16(VCOUNT)
  if v ~= seq_line then seq_line, seq = v, 0 else seq = seq + 1 end
  local h = seq & 0xffff
  tbuf[#tbuf + 1] = string.char(
    frames & 0xff, (frames >> 8) & 0xff, (frames >> 16) & 0xff, (frames >> 24) & 0xff,
    v & 0xff, (v >> 8) & 0xff, h & 0xff, (h >> 8) & 0xff,
    kind & 0xff, reg & 0xff,
    addr & 0xff, (addr >> 8) & 0xff, (addr >> 16) & 0xff, (addr >> 24) & 0xff,
    data & 0xff, (data >> 8) & 0xff, mask & 0xff, (mask >> 8) & 0xff)
  if #tbuf >= 2048 then trace:write(table.concat(tbuf)); tbuf = {} end
end

taps[#taps+1] = sp:install_write_tap(CTRL_BASE, CTRL_BASE + 0x1f, "ctrl", function(off, data, mask)
  ctrl_last = data & 0xffff
  event(3, 0, (off - CTRL_BASE) >> 4, data & 0xffff, mask & 0xffff)
end)
taps[#taps+1] = sp:install_write_tap(DMA_BASE, DMA_BASE + 0x9f, "dma", function(off, data, mask)
  local r = ((off - DMA_BASE) >> 4) & 0xf
  dma[r] = data & 0xffff
  event(0, r, r, data & 0xffff, mask & 0xffff)
end)
taps[#taps+1] = sp:install_write_tap(PAL_BASE, PAL_BASE + 0x1ffff, "pal", function(off, data, mask)
  local o = ((off - PAL_BASE) >> 4) & 0xfff
  local m = mask & 0xffff
  pen[o] = ((pen[o] or 0) & ~m) | (data & m)
  event(2, 0, o, data & 0xffff, m)
end)
taps[#taps+1] = sp:install_write_tap(VRAM_BASE, VRAM_BASE + 0x1fffff, "fb", function(off, data, mask)
  event(1, 0, (off - VRAM_BASE) >> 4, data & 0xffff, mask & 0xffff)
end)

local function dump_state(n)
  local f = io.open(string.format("%s/state_%05d.bin", dir, n), "wb")
  f:write("STVS"); u32(f, 3); u32(f, n)
  u16(f, ctrl_last)
  for i = 0, 15 do u16(f, dma[i] or 0) end
  local N = 512 * 512 // 2
  -- Keep the register value in a local.  Writing it fires this script's own
  -- control tap, which would otherwise overwrite ctrl_last with the flipped
  -- value and make the restore below put the machine back wrong -- it left
  -- the video bank select at 0 for the rest of the run, and the only place
  -- that shows is a window where the CPU writes the frame buffer, which is
  -- the power-up RAM test.  METHODOLOGY 5.1: suspect the instrument.
  local keep = ctrl_last
  sp:write_u16(CTRL_BASE, (keep | 0x20) & 0xffff)           -- pixel plane
  local pixlo, pixhi = {}, {}
  for i = 0, N - 1 do
    local v = sp:read_u16(VRAM_BASE + i * 16)
    pixlo[i] = v & 0xff ; pixhi[i] = (v >> 8) & 0xff
  end
  sp:write_u16(CTRL_BASE, keep & 0xffdf)                    -- palette plane
  local t = {}
  for i = 0, N - 1 do
    local v = sp:read_u16(VRAM_BASE + i * 16)
    local e0 = ((v & 0xff) << 8) | pixlo[i]
    local e1 = (v & 0xff00) | pixhi[i]
    t[#t + 1] = string.char(e0 & 0xff, (e0 >> 8) & 0xff, e1 & 0xff, (e1 >> 8) & 0xff)
    if #t == 4096 then f:write(table.concat(t)); t = {} end
  end
  if #t > 0 then f:write(table.concat(t)) end
  sp:write_u16(CTRL_BASE, keep)                             -- exactly as found
  ctrl_last = keep
  for i = 0, 4095 do u16(f, pen[i] or 0) end
  f:close()
end

-- set_value(1) is PRESSED whatever the port's polarity (measured: the game
-- read IN1 = FFFE from the frame after set_value(1)).  This had 0 for pressed
-- until the machine bench and MAME disagreed about when the coin went in.
local function press(port, field, on)
  local p = mac.ioport.ports[port]
  if p and p.fields[field] then p.fields[field]:set_value(on and 1 or 0) end
end

_G.KEEP = { t = taps }
_G.KEEP.s = emu.add_machine_stop_notifier(function()
  if trace then
    if #tbuf > 0 then trace:write(table.concat(tbuf)) end
    trace:close(); trace = nil
  end
  local f = io.open(dir .. "/run.txt", "w")
  f:write(string.format("frames %d\nfrom %d\ncount %d\n", frames, FROM, COUNT))
  f:write(frames >= FROM + COUNT and "complete\n" or "TRUNCATED\n")
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
  if frames >= FROM and frames <= FROM + COUNT then
    -- snapshot(), not pixels().  Measured: taken at the same instant,
    -- screen:pixels() returns a bitmap one frame older than screen:snapshot()
    -- -- MAME double-buffers and pixels() reads the other buffer.  Comparing
    -- against pixels() made a correct renderer look one frame ahead on every
    -- moving object and exactly right on every still screen, which is the
    -- shape of an instrument fault, not a renderer fault (METHODOLOGY 5.1).
    scr:snapshot(string.format("%s/mame_%05d.png", dir, frames))
  end
  if frames == FROM then
    dump_state(frames)
    trace = io.open(dir .. "/trace.bin", "wb")
  end
  if frames == FROM + COUNT and trace then
    if #tbuf > 0 then trace:write(table.concat(tbuf)); tbuf = {} end
    trace:close(); trace = nil
    -- a second freeze at the far end of the window, so the replay's frame
    -- buffer can be compared with MAME's directly.  That separates a wrong
    -- blit from wrong timing: if the buffers agree and the pictures do not,
    -- the fault is in when things happen, not in what they draw.
    dump_state(frames)
  end
end)

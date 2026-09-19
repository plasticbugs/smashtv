-- Dump what MAME hands the chips, so tools/verify_rom.py can check the image
-- the .mra builds against it.
--
--   REGION_DIR=... tools/mame.sh -seconds_to_run 2 -autoboot_script tools/dump_regions.lua
--
-- Two of the three are read through the CPU's own address space rather than
-- out of a ROM region, because that is where the driver's interleaving and
-- decoding happen and it is the bytes the game sees that matter:
--
--   prog.bin  131072 words, big-endian, read at 0xFFE00000 upwards -- the
--             TMS34010's own view of the two interleaved EPROMs.
--   gfx.bin   1572864 bytes, one per pixel, read through the graphics ROM
--             window at 0x02000000 -- midyunit's init_gfxrom(6) unpacks three
--             plane-pairs into this, and gfxrom_r serves two pixels a word.
--   snd.bin   196608 bytes, the three sound EPROMs end to end, taken from the
--             "cvsd:cpu" region at the offsets williamssound.cpp banks them
--             from (0x10000, 0x30000, 0x50000); the ROM_RELOADed copies above
--             them are the same bytes again.
local mac = manager.machine
local sp  = mac.devices[":maincpu"].spaces["program"]
local dir = os.getenv("REGION_DIR") or "."

local PROG_BASE  = 0xffe00000          -- bit address of the first program word
local PROG_WORDS = 0x20000             -- 128 Ki words = 256 KB
local GFX_BASE   = 0x02000000          -- bit address of graphics pixel 0
local GFX_PIXELS = 0x180000            -- what the nine EPROMs actually fill
local SND_PARTS  = { 0x10000, 0x30000, 0x50000 }
local SND_LEN    = 0x10000

local function write_chunks(f, gen, n)
  local t = {}
  for i = 0, n - 1 do
    t[#t + 1] = gen(i)
    if #t == 8192 then f:write(table.concat(t)); t = {} end
  end
  if #t > 0 then f:write(table.concat(t)) end
end

_G.KEEP = {}
_G.KEEP.s = emu.add_machine_stop_notifier(function() end)

-- program: big-endian words, the order the image stores them in
local f = io.open(dir .. "/prog.bin", "wb")
write_chunks(f, function(i)
  local v = sp:read_u16(PROG_BASE + i * 16)
  return string.char((v >> 8) & 0xff, v & 0xff)
end, PROG_WORDS)
f:close()

-- graphics: one byte per pixel, two pixels to a word, low pixel first
f = io.open(dir .. "/gfx.bin", "wb")
write_chunks(f, function(i)
  local v = sp:read_u16(GFX_BASE + i * 16)
  return string.char(v & 0xff, (v >> 8) & 0xff)
end, GFX_PIXELS // 2)
f:close()

-- sound: the three EPROMs as the bank register reaches them
local r = mac.memory.regions[":cvsd:cpu"]
f = io.open(dir .. "/snd.bin", "wb")
for _, base in ipairs(SND_PARTS) do
  write_chunks(f, function(i) return string.char(r:read_u8(base + i)) end, SND_LEN)
end
f:close()

local done = io.open(dir .. "/regions.txt", "w")
done:write(string.format("prog %d\ngfx %d\nsnd %d\n",
                         PROG_WORDS * 2, GFX_PIXELS, #SND_PARTS * SND_LEN))
done:close()

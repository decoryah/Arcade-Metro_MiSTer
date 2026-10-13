-- Randomised VDP scenes for the reference renderer: park the 68000 in a RAM loop, write a random but valid VDP state through the CPU's address
-- space (VRAM of all three layers, tile table, palette, sprite RAM, every video register), let MAME render it, then dump the state and MAME's
-- snapshot exactly like vstate.lua.  This exercises features the real game never uses (zoom, flips, 8bpp, 16x16, windows, screen flip, blank).
--   mame dharma ... -autoboot_script vfuzz.lua -seconds_to_run N
--   VF_OUT    output prefix (the files are <prefix>.<n>.mem/.regs/.png, so tools/metro_ref.py reads them like vstate dumps)
--   VF_N      number of scenes (default 40)    VF_SEED   PRNG seed (default 1)    VF_BASE  VDP base, hex (default 800000)
--   VF_FEATS  comma list restricting what the scenes may use: any of zoom,flip,tile8,tile16,window,scroll,screenflip,blank,sprpri
--             (default: all)
local m    = manager.machine
local cpu  = m.devices[":maincpu"]
local prog = cpu.spaces["program"]
local scr  = m.screens[":screen"]
local base = tonumber(os.getenv("VF_BASE") or "800000", 16)
local prefix = os.getenv("VF_OUT") or "vfuzz"
local nscenes = tonumber(os.getenv("VF_N") or "40")
math.randomseed(tonumber(os.getenv("VF_SEED") or "1"))
local feats = {}
local fl = os.getenv("VF_FEATS")
for f in string.gmatch(fl or "zoom,flip,tile8,tile16,window,scroll,screenflip,blank,sprpri", "[^,]+") do feats[f] = true end

local function R(n) return math.random(0, n - 1) end
local regs = {}
local alias = { [0x78800] = 0x79700, [0x78804] = 0x79704, [0x78806] = 0x79706, [0x78808] = 0x79708, [0x78810] = 0x79710, [0x78812] = 0x79712 }
local taps = {}
local function tap(lo, hi)
  taps[#taps + 1] = prog:install_write_tap(base + lo, base + hi, string.format("vf%x", lo), function(offset, data, mask)
    local a = (offset - base) & ~1
    a = alias[a] or a
    local old = regs[a] or 0
    regs[a] = (old & ~mask & 0xffff) | (data & mask & 0xffff)
  end)
end
tap(0x78800, 0x78813); tap(0x78850, 0x7887b); tap(0x78880, 0x788af); tap(0x79700, 0x79713)
KEEP = { taps = taps }

local function w(a, v) prog:write_u16(base + a, v & 0xffff) end

local function dump_words(f, lo, nbytes)
  local chunk, n = {}, 0
  for a = lo, lo + nbytes - 2, 2 do
    n = n + 1
    chunk[n] = string.pack(">I2", prog:read_u16(base + a))
    if n == 2048 then f:write(table.concat(chunk, "", 1, n)); n = 0 end
  end
  if n > 0 then f:write(table.concat(chunk, "", 1, n)) end
end

local function dump(idx)
  local f = assert(io.open(string.format("%s.%d.mem", prefix, idx), "wb"))
  dump_words(f, 0x00000, 0x20000); dump_words(f, 0x20000, 0x20000); dump_words(f, 0x40000, 0x20000)
  dump_words(f, 0x72000, 0x2000);  dump_words(f, 0x74000, 0x1000);  dump_words(f, 0x78000, 0x800)
  f:close()
  local r = assert(io.open(string.format("%s.%d.regs", prefix, idx), "w"))
  local keys = {}
  for a in pairs(regs) do keys[#keys + 1] = a end
  table.sort(keys)
  for _, a in ipairs(keys) do r:write(string.format("%05x %04x\n", a, regs[a])) end
  r:close()
  scr:snapshot(string.format("%s.%d.png", prefix, idx))
end

local function scene()
  -- palette: random words
  for i = 0, 0xfff do w(0x72000 + i * 2, R(0x10000)) end
  -- tile table: 512 entries x 2 words
  for e = 0, 511 do
    local color8 = R(256)
    if feats.tile8 and R(4) == 0 then color8 = 0xf0 + R(16) end
    if not feats.tile8 and (color8 & 0xf0) == 0xf0 then color8 = color8 & 0x7f end
    local hi, lo
    if R(10) == 0 then hi, lo = R(16), R(0x10000) else hi, lo = 0, R(0x1000) end
    w(0x78000 + e * 4, (color8 << 4) | hi); w(0x78000 + e * 4 + 2, lo)
  end
  -- layer VRAM
  for layer = 0, 2 do
    for i = 0, 0xffff do
      local code
      local k = R(20)
      if k == 0 then code = 0x8000 | R(0x1000)                                  -- solid colour tile
      else
        code = (R(512) << 4) | R(16)
        if feats.flip then code = code | (R(4) << 13) end
      end
      w(layer * 0x20000 + i * 2, code)
    end
  end
  -- sprite RAM (only the first 130 entries matter; the count register below limits it)
  local scrx = 0x9f; local scry = 0x6f; local sprx = 0x400; local spry = 0x200
  if R(2) == 0 then scrx, scry = R(0x200), R(0x200); sprx, spry = R(0x800), R(0x400) end
  for s = 0, 511 do
    local pri5 = R(32); if R(10) == 0 then pri5 = 0x1f end
    local x = (sprx - (scrx + 1) + R(360) - 20) & 0x7ff
    local y = (spry - (scry + 1) + R(260) - 20) & 0x3ff
    local zoom = 0x1d; if feats.zoom then zoom = R(64) end
    local attr = (R(8) << 11) | (R(8) << 8) | (R(16) << 4)
    if R(7) == 0 then attr = (attr & ~0xf0) | 0xf0 end
    if feats.flip then attr = attr | (R(4) << 14) end
    if R(10) == 0 then attr = attr | R(16) end
    local code = (R(10) == 0) and R(0x10000) or R(0x2000)
    w(0x74000 + s * 8,     (pri5 << 11) | x)
    w(0x74000 + s * 8 + 2, (zoom << 10) | y)
    w(0x74000 + s * 8 + 4, attr)
    w(0x74000 + s * 8 + 6, code)
  end
  -- registers
  local count = R(140); if R(15) == 0 then count = 512 + R(10) end
  w(0x79700, count)
  local sp = R(0x10000) & 0x8f1f
  if not feats.sprpri then sp = 0x8000 end
  w(0x79702, sp)
  w(0x79704, spry); w(0x79706, sprx); w(0x79708, R(16))
  w(0x79710, (R(4) << 4) | (R(4) << 2) | R(4))
  w(0x79712, R(0x1000))
  w(0x78850, scry); w(0x78852, scrx)
  for i = 0, 5 do
    w(0x78860 + i * 2, (feats.window and R(2) == 0) and R(0x10000) or 0)
    w(0x78870 + i * 2, feats.scroll and R(0x10000) or 0)
  end
  local sc = 0x0700
  if feats.tile16 then sc = sc | (R(8) << 5) end
  if feats.screenflip and R(3) == 0 then sc = sc | 1 end
  if feats.blank and R(10) == 0 then sc = sc | 2 end
  w(0x788ac, sc)
end

local state, idx, wait = "boot", 0, 0
emu.register_frame_done(function()
  local fr = scr:frame_number()
  if state == "boot" and fr >= 200 then
    -- park the 68000: bra.s * in RAM, interrupts masked
    prog:write_u16(0x400000, 0x60fe)
    cpu.state["PC"].value = 0x400000
    cpu.state["SR"].value = 0x2700
    state = "inject"
  elseif state == "inject" then
    scene(); wait = 0; state = "settle"
  elseif state == "settle" then
    wait = wait + 1
    if wait >= 2 then
      dump(idx); idx = idx + 1
      print(string.format("scene %d dumped", idx - 1))
      if idx >= nscenes then m:exit() else state = "inject" end
    end
  end
end)

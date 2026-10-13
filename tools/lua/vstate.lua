-- Frozen-state dump for the reference renderer: at chosen frames write the Imagetek VDP's memories, its (write-only) registers and MAME's own
-- snapshot of that frame.   mame dharma ... -autoboot_script vstate.lua -seconds_to_run N
--   VS_OUT     output prefix (default vstate)  ->  <prefix>.<frame>.mem / .regs / .png
--   VS_FRAMES  comma list of frames to dump
--   VS_BASE    VDP base in the 68000 map, hex (default 800000)
--   VS_COIN / VS_START  frame to pulse coin 1 / 1P start (6-frame pulses)
--   VS_PLAY    frame from which a fixed pseudo-random joystick/button pattern is applied (to reach varied game states)
--   VS_I4100   1: the board has an I4100 (its sprite priority register 0x78802 is folded onto 0x79702 like the other aliases)
--   VS_FLIPDIP 1: set the "Flip Screen" DIP to On at the start (the game then flips the picture itself)
-- .mem layout (bytes, big-endian words as the CPU sees them): vram0 0x20000, vram1 0x20000, vram2 0x20000, palette 0x2000, spriteram 0x1000,
-- tiletable 0x800.  .regs: "addr value" lines (hex), the last value written to each VDP control register (aliases folded onto the 0x797xx
-- sprite/layer block).  Render state is taken in the frame_done hook, i.e. the state MAME just rendered the frame from.
local m    = manager.machine
local prog = m.devices[":maincpu"].spaces["program"]
local scr  = m.screens[":screen"]
local base = tonumber(os.getenv("VS_BASE") or "800000", 16)
local prefix = os.getenv("VS_OUT") or "vstate"
if os.getenv("VS_FLIPDIP") == "1" then
  local port = m.ioport.ports[":DSW0"]
  local done = false
  if port then
    for n, f in pairs(port.fields) do
      if n == "Flip Screen" then f.user_value = 0; done = true end    -- the "On" setting is 0 in DSW0 bit 6
    end
  end
  print("VS_FLIPDIP: " .. (done and "Flip Screen set to On" or "FIELD NOT FOUND"))
end
local want = {}
for f in string.gmatch(os.getenv("VS_FRAMES") or "", "%d+") do want[tonumber(f)] = true end

-- shadow of the write-only registers
local regs = {}
local alias = { [0x78800] = 0x79700, [0x78804] = 0x79704, [0x78806] = 0x79706, [0x78808] = 0x79708, [0x78810] = 0x79710, [0x78812] = 0x79712 }
if os.getenv("VS_I4100") == "1" then alias[0x78802] = 0x79702 end   -- the I4100 has the sprite priority register at 0x78802 (the I4220's puzzlet mirror does not)
if os.getenv("VS_I4300") == "1" then      -- the I4300's register map (v3_map) folded onto the I4220's layout the bench and the reference renderer use
  alias = { [0x78800] = 0x788a0, [0x78802] = 0x78890, [0x78804] = 0x78880,                          -- crtc unlock / horz / vert
            [0x78808] = 0x78852, [0x7880a] = 0x78850, [0x7880e] = 0x788ac,                          -- screen x / y offset, screen control
            [0x78830] = 0x788a4,                                                                    -- irq enable (the byte at 0x78831)
            [0x78850] = 0x78870, [0x78852] = 0x78872, [0x78854] = 0x78874, [0x78856] = 0x78876,    -- scroll
            [0x78858] = 0x78878, [0x7885a] = 0x7887a, [0x78870] = 0x788aa }                         -- rombank
end
local taps = {}
local function tap(lo, hi)
  taps[#taps + 1] = prog:install_write_tap(base + lo, base + hi, string.format("vs%x", lo), function(offset, data, mask)
    local a = (offset - base) & ~1
    a = alias[a] or a
    local old = regs[a] or 0
    regs[a] = (old & ~mask & 0xffff) | (data & mask & 0xffff)
  end)
end
tap(0x78800, 0x78813)   -- sprite/layer block, puzzlet-compat mirror
if os.getenv("VS_I4300") == "1" then tap(0x78814, 0x7887f) end   -- (I4300: the irq level / vector bytes and everything else up to the rombank)
tap(0x78840, 0x7884d)   -- blitter
tap(0x78850, 0x7887b)   -- screen offsets, window, scroll
tap(0x78880, 0x788af)   -- crtc, irq, rombank, screen control
tap(0x79700, 0x79713)   -- sprite/layer block

-- VS_ROZ=1 (Blazing Tornado / Grand Striker 2): the Konami 053936's control block (0x600000, write only), its line RAM (0x500000, write only) and the tile map RAM
-- (0x400000, 256 KB) go to <prefix>.<frame>.roz: 16 + 2048 control / line words, then 131072 RAM words, big endian.
local roz_on = os.getenv("VS_ROZ") == "1"
local roz_ctrl, roz_line = {}, {}
if roz_on then
  taps[#taps + 1] = prog:install_write_tap(0x600000, 0x60001f, "rozc", function(offset, data, mask)
    local i = ((offset - 0x600000) >> 1)
    roz_ctrl[i] = ((roz_ctrl[i] or 0) & ~mask & 0xffff) | (data & mask & 0xffff)
  end)
  taps[#taps + 1] = prog:install_write_tap(0x500000, 0x500fff, "rozl", function(offset, data, mask)
    local i = ((offset - 0x500000) >> 1)
    roz_line[i] = ((roz_line[i] or 0) & ~mask & 0xffff) | (data & mask & 0xffff)
  end)
end

local function dump_words(f, lo, nbytes)
  local chunk, n = {}, 0
  for a = lo, lo + nbytes - 2, 2 do
    n = n + 1
    chunk[n] = string.pack(">I2", prog:read_u16(base + a))
    if n == 2048 then f:write(table.concat(chunk, "", 1, n)); n = 0 end
  end
  if n > 0 then f:write(table.concat(chunk, "", 1, n)) end
end

-- input injection
local function find(port, name) local p = m.ioport.ports[port]; if not p then return nil end for n, f in pairs(p.fields) do if n == name then return f end end end
local function findany(name)       -- the field on whichever port has it (the I4300 boards put coin / start / joystick on other ports)
  for pn in pairs(m.ioport.ports) do local f = find(pn, name); if f then return f end end
end
local coin, start = find(":IN0", "Coin 1") or findany("Coin 1"), find(":IN0", "1 Player Start") or findany("1 Player Start")
local up, down, left, right, b1 = find(":IN1", "P1 Up") or findany("P1 Up"), find(":IN1", "P1 Down") or findany("P1 Down"), find(":IN1", "P1 Left") or findany("P1 Left"), find(":IN1", "P1 Right") or findany("P1 Right"), find(":IN1", "P1 Button 1") or findany("P1 Button 1")
local coin_f, start_f, play_f = tonumber(os.getenv("VS_COIN") or ""), tonumber(os.getenv("VS_START") or ""), tonumber(os.getenv("VS_PLAY") or "")
local coin_every = tonumber(os.getenv("VS_COIN_EVERY") or "")     -- repeat coin (+0) and 1P start (+100) every N frames from VS_COIN
local rng = 12345
local function rnd(n) rng = (rng * 1103515245 + 12345) & 0x7fffffff; return (rng >> 8) % n end
local dir = 0

KEEP = { taps = taps }   -- global: the Lua GC would otherwise drop the taps
emu.register_frame_done(function()
  local fr = scr:frame_number()
  if coin_every and coin and fr >= coin_f then      -- repeat: coin at +0, start at +100 of every period (survives game over)
    local ph = (fr - coin_f) % coin_every
    coin:set_value((ph < 6) and 1 or 0)
    if start then start:set_value((ph >= 100 and ph < 106) and 1 or 0) end
  else
    if coin_f and coin then coin:set_value((fr >= coin_f and fr < coin_f + 6) and 1 or 0) end
    if start_f and start then start:set_value((fr >= start_f and fr < start_f + 6) and 1 or 0) end
  end
  if play_f and fr >= play_f and up then
    if fr % 12 == 0 then dir = rnd(5) end
    up:set_value(dir == 1 and 1 or 0); down:set_value(dir == 2 and 1 or 0); left:set_value(dir == 3 and 1 or 0); right:set_value(dir == 4 and 1 or 0)
    if b1 then b1:set_value((fr % 20 < 4) and 1 or 0) end
  end
  if want[fr] then
    local f = assert(io.open(string.format("%s.%d.mem", prefix, fr), "wb"))
    dump_words(f, 0x00000, 0x20000); dump_words(f, 0x20000, 0x20000); dump_words(f, 0x40000, 0x20000)
    dump_words(f, 0x72000, 0x2000);  dump_words(f, 0x74000, 0x1000);  dump_words(f, 0x78000, 0x800)
    f:close()
    local r = assert(io.open(string.format("%s.%d.regs", prefix, fr), "w"))
    local keys = {}
    for a in pairs(regs) do keys[#keys + 1] = a end
    table.sort(keys)
    for _, a in ipairs(keys) do r:write(string.format("%05x %04x\n", a, regs[a])) end
    r:close()
    if roz_on then
      local z = assert(io.open(string.format("%s.%d.roz", prefix, fr), "wb"))
      for i = 0, 15 do z:write(string.pack(">I2", roz_ctrl[i] or 0)) end
      for i = 0, 2047 do z:write(string.pack(">I2", roz_line[i] or 0)) end
      local chunk, n = {}, 0
      for a = 0x400000, 0x43fffe, 2 do
        n = n + 1
        chunk[n] = string.pack(">I2", prog:read_u16(a))
        if n == 2048 then z:write(table.concat(chunk, "", 1, n)); n = 0 end
      end
      z:close()
    end
    scr:snapshot(string.format("%s.%d.png", prefix, fr))
    print(string.format("dumped frame %d", fr))
  end
end)

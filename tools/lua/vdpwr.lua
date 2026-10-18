-- every 68000 write to the VDP (VW_BASE + 0..0x7ffff) with the emulated time, plus the time of every frame_done (the beam at line 224); also runs tools/lua/vstate.lua
-- (VS_* variables) so the state at the dump frame is written in the same run.   VW_OUT, VW_F0, VW_F1 (frames, as scr:frame_number() in frame_done), VW_BASE (hex, default 400000)
local m    = manager.machine
local prog = m.devices[":maincpu"].spaces["program"]
local scr  = m.screens[":screen"]
local base = tonumber(os.getenv("VW_BASE") or "400000", 16)
local out  = assert(io.open(os.getenv("VW_OUT") or "vdpwr.txt", "w"))
local f0, f1 = tonumber(os.getenv("VW_F0") or "0"), tonumber(os.getenv("VW_F1") or "100000")
local function now() local t = m.time; if type(t) ~= "number" then t = t:as_double() end; return t end
local fr_now = 0
out:write(string.format("# scan_period %.9f frame_period %.9f\n", scr.scan_period, scr.frame_period))
TAPS_KEEP = {}
TAPS_KEEP[1] = prog:install_write_tap(base, base + 0x7ffff, "vw", function(offset, data, mask)
  if fr_now >= f0 and fr_now <= f1 then
    out:write(string.format("W %.9f %x %04x %04x\n", now(), offset - base, data & 0xffff, mask & 0xffff))
  end
end)
emu.register_frame_done(function()
  fr_now = scr:frame_number()
  if fr_now >= f0 and fr_now <= f1 then out:write(string.format("F %.9f %d\n", now(), fr_now)); out:flush() end
end)
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or ".")
dofile(os.getenv("VS_LUA") or (here .. "/vstate.lua"))

-- Sound-CPU oracle driver: inject coin / start / random play like vstate.lua (no state dumps) and log every sound command the 68000 writes
-- (frame, byte).  Use together with the debugger trace of the sound CPU (tools/atrace.sh):
--   mame dharma -debug -debugscript <script with 'trace <file>,:audiocpu,noloop'> -video none -sound none -nothrottle -autoboot_script ainput.lua -seconds_to_run N
--   AI_COIN_EVERY  repeat the coin (+0) and 1P start (+100) every N frames from AI_COIN (default 300, every 1500)   AI_PLAY  first frame of random play (default 560)
--   AI_OUT         sound command log (default sndcmd.txt)
--   AI_SNDADDR     the sound command latch (hex word address; default 8788a8 = Dharma, Toride II: c788a8)
local m    = manager.machine
local prog = m.devices[":maincpu"].spaces["program"]
local scr  = m.screens[":screen"]
local out  = assert(io.open(os.getenv("AI_OUT") or "sndcmd.txt", "w"))
local function find(port, name) local p = m.ioport.ports[port]; if not p then return nil end for n, f in pairs(p.fields) do if n == name then return f end end end
local coin, start = find(":IN0", "Coin 1"), find(":IN0", "1 Player Start")
local up, down, left, right, b1, b2 = find(":IN1", "P1 Up"), find(":IN1", "P1 Down"), find(":IN1", "P1 Left"), find(":IN1", "P1 Right"), find(":IN1", "P1 Button 1"), find(":IN1", "P1 Button 2")
local coin_f  = tonumber(os.getenv("AI_COIN") or "300")
local every   = tonumber(os.getenv("AI_COIN_EVERY") or "1500")
local play_f  = tonumber(os.getenv("AI_PLAY") or "560")
local rng, dir = 12345, 0
local function rnd(n) rng = (rng * 1103515245 + 12345) & 0x7fffffff; return (rng >> 8) % n end
local ncmd = 0
KEEP = {}
local sndaddr = tonumber(os.getenv("AI_SNDADDR") or "8788a8", 16)
KEEP.tap = prog:install_write_tap(sndaddr, sndaddr + 1, "sndcmd", function(offset, data, mask)
  if (mask & 0x00ff) ~= 0 then
    ncmd = ncmd + 1
    local tm = m.time
    local secs = (type(tm) == "number") and tm or tm:as_double()
    out:write(string.format("%d %d %02x %.9f\n", scr:frame_number(), ncmd, data & 0xff, secs)); out:flush()
  end
end)
emu.register_frame_done(function()
  local fr = scr:frame_number()
  if coin and fr >= coin_f then
    local ph = (fr - coin_f) % every
    coin:set_value((ph < 6) and 1 or 0)
    if start then start:set_value((ph >= 100 and ph < 106) and 1 or 0) end
  end
  if fr >= play_f and up then
    if fr % 12 == 0 then dir = rnd(5) end
    up:set_value(dir == 1 and 1 or 0); down:set_value(dir == 2 and 1 or 0); left:set_value(dir == 3 and 1 or 0); right:set_value(dir == 4 and 1 or 0)
    if b1 then b1:set_value((fr % 20 < 4) and 1 or 0) end
    if b2 then b2:set_value((fr % 90 < 3) and 1 or 0) end
  end
end)
emu.add_machine_stop_notifier(function() out:close() end)

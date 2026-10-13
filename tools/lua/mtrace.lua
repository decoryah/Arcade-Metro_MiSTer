-- Metro oracle trace: log the 68000's writes to the Imagetek VDP control registers (and a few reads) with frame + beam position.
-- Run with MAME 0.289:  mame dharma -video none -sound none -nothrottle -skip_gameinfo -autoboot_script mtrace.lua -seconds_to_run N
--   MT_OUT    output file (default mtrace.txt)
--   MT_BASE   VDP base address in the 68000 map, hex (default 800000 = Dharma; Hyper Duel is 400000)
--   MT_CAP    max logged lines per address (default 60); the total per address is always counted and printed at the end
-- Offsets below are VDP-relative, i4220 v2_map (see docs/hardware.md section 4 and ref/.../i4220_spec.md section 2).
local m    = manager.machine
local prog = m.devices[":maincpu"].spaces["program"]
local scr  = m.screens[":screen"]
local base = tonumber(os.getenv("MT_BASE") or "800000", 16)
local cap  = tonumber(os.getenv("MT_CAP") or "60")
local out  = assert(io.open(os.getenv("MT_OUT") or "mtrace.txt", "w"))

local names = {
  [0x78840] = "blitter", [0x78850] = "scr_yoff", [0x78852] = "scr_xoff", [0x78860] = "window", [0x78870] = "scroll",
  [0x78880] = "crtc_vert", [0x78890] = "crtc_horz", [0x788a0] = "crtc_unlock", [0x788a2] = "irq_cause", [0x788a4] = "irq_enable",
  [0x788a8] = "sound_latch", [0x788aa] = "rombank", [0x788ac] = "screen_ctrl",
  [0x79700] = "spr_count", [0x79702] = "spr_pri", [0x79704] = "spr_yoff", [0x79706] = "spr_xoff", [0x79708] = "spr_color",
  [0x79710] = "layer_pri", [0x79712] = "bg_color",
  [0x78800] = "mirror_spr_count", [0x78804] = "mirror_spr_yoff", [0x78806] = "mirror_spr_xoff", [0x78808] = "mirror_spr_color",
  [0x78810] = "mirror_layer_pri", [0x78812] = "mirror_bg_color",
}
local counts, logged, hist = {}, {}, {}

-- 0.289's Lua has no screen:vpos(): derive the beam line from the time left until the next line 0
-- (frame_period / scan_period are properties here, time_until_pos() returns seconds as a number).
local function vpos()
  local t = scr:time_until_pos(0)
  if type(t) ~= "number" then t = t:as_double() end
  local v = math.floor((scr.frame_period - t) / scr.scan_period)
  if v < 0 or v >= 1000 then v = 0 end
  return v
end

-- optional input injection (the title screen waits for a coin): MT_COIN=<frame>, MT_START=<frame>, 6-frame pulses
local function find(port, name) for n, f in pairs(m.ioport.ports[port].fields) do if n == name then return f end end end
local coin, start = find(":IN0", "Coin 1"), find(":IN0", "1 Player Start")
local coin_f, start_f = tonumber(os.getenv("MT_COIN") or ""), tonumber(os.getenv("MT_START") or "")

local function tap(kind, lo, hi)
  local f = (kind == "W") and prog.install_write_tap or prog.install_read_tap
  return f(prog, base + lo, base + hi, kind .. string.format("%x", lo), function(offset, data, mask)
    local ok, err = pcall(function()
      local rel = offset - base
      local key = string.format("%s %05x", kind, rel)
      counts[key] = (counts[key] or 0) + 1
      logged[key] = (logged[key] or 0) + 1
      if (rel & ~1) == 0x788a2 and (mask & 0xff) ~= 0 then   -- IRQ cause (byte at 0x788a3): histogram of every value, read and written
        local hk = string.format("%s cause=%02x", kind, data & 0xff)
        hist[hk] = (hist[hk] or 0) + 1
      end
      if logged[key] <= cap then
        local nm = names[rel & ~1] or ""
        out:write(string.format("f%-5d v%-3d %s %05x d=%04x m=%04x %s\n", scr:frame_number(), vpos(), kind, rel, data & 0xffff, mask & 0xffff, nm))
      end
    end)
    if not ok and not tap_err_shown then tap_err_shown = true; print("mtrace callback error: " .. tostring(err) .. "  (offset=" .. tostring(offset) .. ")") end
  end)
end

local taps = {
  tap("W", 0x78800, 0x78813), tap("W", 0x78840, 0x7884d), tap("W", 0x78850, 0x7887b), tap("W", 0x78880, 0x788af),
  tap("W", 0x79700, 0x79713), tap("R", 0x788a0, 0x788a5),
}

emu.register_frame_done(function()
  out:flush()
  local f = scr:frame_number()
  if coin_f and coin then coin:set_value((f >= coin_f and f < coin_f + 6) and 1 or 0) end
  if start_f and start then start:set_value((f >= start_f and f < start_f + 6) and 1 or 0) end
  if f % 300 == 0 then print("frame " .. f) end
end)

-- keep the tap handles and the stop subscription alive in globals: if the Lua GC collects them MAME silently drops the taps
-- (this cost an afternoon of misreading "frozen" write counters)
MTRACE_KEEP = { taps = taps }
MTRACE_KEEP.stop = emu.add_machine_stop_notifier(function()
  out:write("\n=== totals (writes W / reads R by VDP-relative address) ===\n")
  local keys = {}
  for k in pairs(counts) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do out:write(string.format("%s  %d\n", k, counts[k])) end
  out:write("\n=== IRQ cause register values (byte at VDP+0x788a3), every access ===\n")
  local hkeys = {}
  for k in pairs(hist) do hkeys[#hkeys + 1] = k end
  table.sort(hkeys)
  for _, k in ipairs(hkeys) do out:write(string.format("%s  %d\n", k, hist[k])) end
  out:write(string.format("last frame %d\n", scr:frame_number()))
  out:close()
end)

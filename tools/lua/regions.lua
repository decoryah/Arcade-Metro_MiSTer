-- Dump MAME's static ROM regions (as the driver has them AFTER its init, e.g. init_dharmak's GFX descramble) so
-- tools/metro_rom.py can be checked against them:  python tools/metro_rom.py check <set> <prefix>
--   MR_OUT   output prefix (files are <prefix>.<region>.bin)
--   MR_TAGS  comma list of region tags (default :maincpu,:audiocpu,:vdp,:vdp2,:oki)
local m = manager.machine
local scr = m.screens[":screen"]
local prefix = os.getenv("MR_OUT") or "regions"
local done = false
emu.register_frame_done(function()
  if done then return end
  done = true
  for tag in string.gmatch(os.getenv("MR_TAGS") or ":maincpu,:audiocpu,:vdp,:vdp2,:oki", "[^,]+") do
    local reg = m.memory.regions[tag]
    if reg then
      local f = assert(io.open(prefix .. "." .. tag:gsub(":", "") .. ".bin", "wb"))
      local chunk, n = {}, 0
      for i = 0, reg.size - 1 do
        n = n + 1
        chunk[n] = reg:read_u8(i)
        if n == 4096 then f:write(string.char(table.unpack(chunk, 1, n))); n = 0 end
      end
      if n > 0 then f:write(string.char(table.unpack(chunk, 1, n))) end
      f:close()
      print(string.format("dumped %s: 0x%x bytes", tag, reg.size))
    end
  end
  m:exit()
end)

#!/usr/bin/env zzlua

local sdl = require('sdl2')
local bit = require('bit')
local sched = require('sched')

sched(function()
   pf("SDL version: %d.%d.%d", sdl.GetVersion())
   pf("Running on platform '%s'", sdl.GetPlatform())
   pf("Amount of RAM configured in the system: %d MB", sdl.GetSystemRAM())
   pf("Number of available CPU cores: %d", sdl.GetCPUCount())
   local n_displays = sdl.GetNumVideoDisplays()
   pf("Number of video displays: %d", n_displays)
   for d=1,n_displays do
      pf("Display #%d:", d)
      pf("  Name: %s", sdl.GetDisplayName(d))
      local bounds = sdl.GetDisplayBounds(d)
      pf("  Bounds: %d,%d,%d,%d", bounds.x, bounds.y, bounds.w, bounds.h)
      local n_displaymodes = sdl.GetNumDisplayModes(d)
      pf("  Number of display modes: %d", n_displaymodes)
      for m=1,n_displaymodes do
         local mode = sdl.GetDisplayMode(d,m)
         pf("    #%d: %s", m, mode)
      end
      pf("  Desktop display mode: %s", sdl.GetDesktopDisplayMode(d))
      pf("  Current display mode: %s", sdl.GetCurrentDisplayMode(d))
   end
   print("Creating SDL window...")
   local w = sdl.CreateWindow("hello", 0, 0, 800, 600,
                              bit.bor(sdl.SDL_WINDOW_OPENGL,
                                      sdl.SDL_WINDOW_RESIZABLE))
   w:show()
   print("To quit the example app, press Escape while the SDL window has keyboard focus or simply close the window")
   sched.on('sdl.keydown', function(evdata)
      pf("got sdl.keydown event, keysym=%s", evdata.key.keysym.sym)
      if evdata.key.keysym.sym == sdl.SDLK_ESCAPE then
         sched.quit()
      end
   end)
   sched.on('sdl.quit', sched.quit)
   sched(function()
      -- game loop
      local fps = 60
      while true do
         now = sched.now
         -- redraw the screen
         sched.wait(now+1/fps)
      end
   end)
   sched.wait('quit')
   print("got quit signal, destroying window")
   w:destroy()
end)

sched()
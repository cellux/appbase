local ffi = require('ffi')
local sched = require('sched')
local sdl = require('sdl2')
local ui = require('ui')
local fluid = require('fluidsynth')
local fs = require('fs')

local FONT_SIZE = 11
local SAMPLE_RATE = 48000

local function Logger(grid)
   local log_row = 0
   return function(template, ...)
      if template then
         grid:write(0, log_row, sf(template, ...))
      end
      if log_row < grid.height - 1 then
         log_row = log_row + 1
      else
         grid:scroll_up()
      end
      sched.yield()
   end
end

local function main()
   local sf2_path = arg[1]
   if not fs.exists(sf2_path) then
      ef("Usage: fluidsynth <sf2-path>")
   end

   local ui = ui {
      title = "FluidSynth",
      fullscreen_desktop = true,
   }

   local script_path = arg[0]
   local script_dir = fs.dirname(script_path)
   local examples_dir = fs.dirname(script_dir)
   local ttf_path = fs.join(examples_dir, "freetype/DroidSansMono.ttf")
   if not fs.exists(ttf_path) then
      ef("missing ttf: %s", ttf_path)
   end
   local font = ui:Font { source = ttf_path, size = FONT_SIZE }

   ui:show()

   local grid = ui:CharGrid {
      font = font,
      width = math.floor(ui:width() / font.max_advance),
      height = math.floor(ui:height() / font.height),
   }
   ui:add(grid)

   ui:layout()

   local loop = ui:RenderLoop { measure = true }
   sched(loop)

   local log = Logger(grid)
   local settings = fluid.Settings()
   settings:setnum("synth.gain", 1)
   settings:setint("synth.midi-channels", 256)
   settings:setnum("synth.sample-rate", SAMPLE_RATE)
   log("synth.sample-rate=%s", settings:getnum("synth.sample-rate"))
   log("synth.audio-channels=%s", settings:getint("synth.audio-channels"))
   log("synth.midi-channels=%s", settings:getint("synth.midi-channels"))
   log("synth.gain=%s", settings:getnum("synth.gain"))

   local synth = fluid.Synth(settings)
   local sf_id = synth:sfload(sf2_path, true)
   log("successfully loaded %s, id=%d", sf2_path, sf_id)
      
   log("GetCurrentAudioDriver()=%s", sdl.GetCurrentAudioDriver())
   for i=1,sdl.GetNumAudioDevices() do
      log("GetAudioDeviceName(%d)=%s", i, sdl.GetAudioDeviceName(i))
   end

   local dev = sdl.OpenAudioDevice {
      freq = SAMPLE_RATE,
      format = sdl.AUDIO_S16SYS,
      channels = 2,
      samples = 1024,
      callback = ffi.C.zz_fluidsynth_sdl_audio_callback,
      userdata = synth.synth
   }
   log("SDL_OpenAudioDevice(): %d", dev.id)
   log("  freq=%d", dev.freq)
   log("  format=%d", dev.format)
   log("  channels=%d", dev.channels)
   log("  samples=%d", dev.samples)
   log("  size=%d", dev.size)
   
   log("zsxdcvgbhnjm: notes from current octave")
   log("q2w3er5t6y7u: notes from next octave")
   log("UP: octave up")
   log("DOWN: octave down")
   log("RIGHT: next program")
   log("LEFT: previous program")
   log("BACKSPACE: all notes off")
   log("ESC: quit")
   log()
   log("unpausing audio device")
   dev:start()
   log("now play.")

   local octave = 5
   local min_octave = 0
   local max_octave = 10
   
   local prognum = 0
   local max_prognum = 127
   local min_prognum = 0

   local key_map = {
      [sdl.SDLK_z] = 0,
      [sdl.SDLK_s] = 1,
      [sdl.SDLK_x] = 2,
      [sdl.SDLK_d] = 3,
      [sdl.SDLK_c] = 4,
      [sdl.SDLK_v] = 5,
      [sdl.SDLK_g] = 6,
      [sdl.SDLK_b] = 7,
      [sdl.SDLK_h] = 8,
      [sdl.SDLK_n] = 9,
      [sdl.SDLK_j] = 10,
      [sdl.SDLK_m] = 11,
      
      [sdl.SDLK_q] = 12,
      [sdl.SDLK_2] = 13,
      [sdl.SDLK_w] = 14,
      [sdl.SDLK_3] = 15,
      [sdl.SDLK_e] = 16,
      [sdl.SDLK_r] = 17,
      [sdl.SDLK_5] = 18,
      [sdl.SDLK_t] = 19,
      [sdl.SDLK_6] = 20,
      [sdl.SDLK_y] = 21,
      [sdl.SDLK_7] = 22,
      [sdl.SDLK_u] = 23,
   }
   
   local function log_channel_info(chan)
      local info = synth:get_channel_info(chan)
      log("sfont_id=%d bank=%d program=%d: %s", info.sfont_id, info.bank, info.program, info.name)
   end
   
   local handle_keys = true
   
   local function quit()
      handle_keys = false
      log("pausing audio device")
      dev:stop()
      log("closing audio device")
      dev:close()
      log("cleanup fluidsynth")
      synth:delete()
      settings:delete()
      log("exiting")
      sched.quit()
   end

   local function handle_keydown(evdata)
      if not handle_keys then return end
      local sym = evdata.key.keysym.sym
      if sym == sdl.SDLK_UP then
         if octave < max_octave then
            octave = octave + 1
         end
      elseif sym == sdl.SDLK_DOWN then
         if octave > min_octave then
            octave = octave - 1
         end
      elseif sym == sdl.SDLK_RIGHT then
         if prognum < max_prognum then
            prognum = prognum + 1
            synth:program_change(0, prognum)
            log_channel_info(0)
         end
      elseif sym == sdl.SDLK_LEFT then
         if prognum > min_prognum then
            prognum = prognum - 1
            synth:program_change(0, prognum)
            log_channel_info(0)
         end
      elseif sym == sdl.SDLK_BACKSPACE then
         synth:all_notes_off(0)
      elseif sym == sdl.SDLK_ESCAPE then
         quit()
      else
         local key = key_map[sym]
         if key then
            synth:noteon(0, octave*12+key, 127)
         end
      end
   end

   local function handle_keyup(evdata)
      if not handle_keys then return end
      local sym = evdata.key.keysym.sym
      local key = key_map[sym]
      if key then
         synth:noteoff(0, octave*12+key)
      end
   end

   sched.on('sdl.keydown', handle_keydown)
   --sched.on('sdl.keyup', handle_keyup)
end

sched(main)
sched()

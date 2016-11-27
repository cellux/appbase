#!/usr/bin/env zzlua

local ui = require('ui')
local fs = require('fs')
local file = require('file')
local sched = require('sched')

local function main()
   local ui = ui {
      title = "gridedit",
      fullscreen_desktop = true,
      quit_on_escape = true,
   }

   local script_path = arg[0]
   local script_dir = fs.dirname(script_path)
   local examples_dir = fs.dirname(script_dir)
   local ttf_path = fs.join(examples_dir, "freetype/DroidSansMono.ttf")
   if not fs.exists(ttf_path) then
      ef("missing ttf: %s", ttf_path)
   end

   local file_path = arg[1]
   if not file_path then
      ef("Usage: %s <path>", arg[0])
   end
   local text = ''
   if fs.exists(file_path) then
      text = file.read(file_path)
   end

   local font_size = 12 -- initial font size in points
   local font = ui:Font { source = ttf_path, size = font_size }

   local editor = ui:GridEdit { font = font }
   editor:text(text)
   ui:add(editor)
   ui:show()
   ui:layout()

   local keymapper = ui:KeyMapper()
   keymapper:push(editor.default_keymap)

   local loop = ui:RenderLoop { measure = true }
   sched(loop)
   sched.wait('quit')
end

sched(main)
sched()

#!/usr/bin/env zzlua

local ffi = require('ffi')
local bit = require('bit')
local engine = require('engine')
local sched = require('sched')
local freetype = require('freetype')
local fs = require('fs')
local file = require('file')
local sdl = require('sdl2')
local iconv = require('iconv')
local time = require('time')

local app = engine.DesktopApp {
   title = "render-text",
}

local function round(x)
   return math.floor(tonumber(x)+0.5)
end

local function Font(source, size, window, renderer)
   local self = {
      face = freetype.Face(source),
      size = nil, -- initialized below
   }
   function self:set_size(size)
      self.size = size -- measured in points
      self.face:Set_Char_Size(0, self.size*64, window:dpi())
      local metrics = self.face.face.size.metrics
      self.ascender = round(metrics.ascender / 64)
      self.descender = round(metrics.descender / 64)
      self.height = round(metrics.height / 64)
      self.max_advance = round(metrics.max_advance / 64)
   end
   self:set_size(size)
   local glyph_cache = {}
   function self:get_glyph(charcode)
      if not glyph_cache[charcode] then
         self.face:Load_Char(charcode)
         self.face:Render_Glyph(freetype.FT_RENDER_MODE_LCD)
         local g = self.face.face.glyph
         local gd = { -- glyph data
            bearing_x = g.bitmap_left,
            bearing_y = g.bitmap_top,
            advance_x = round(g.advance.x/64),
            advance_y = round(g.advance.y/64),
            width = 0,
            height = 0,
            texture = nil,
            srcrect = sdl.Rect(0,0,0,0),
         }
         local pixels = g.bitmap.buffer
         -- pixels can be nil when we draw a whitespace character
         if pixels ~= nil then
            local pitch = g.bitmap.pitch
            gd.width = g.bitmap.width/3
            gd.height = g.bitmap.rows
            gd.srcrect.w = gd.width
            gd.srcrect.h = gd.height
            gd.texture = renderer:CreateTexture(sdl.SDL_PIXELFORMAT_RGB24,
                                                sdl.SDL_TEXTUREACCESS_STATIC,
                                                gd.width, gd.height)
            gd.texture:UpdateTexture(gd.srcrect, pixels, pitch)
         end
         glyph_cache[charcode] = gd
      end
      return glyph_cache[charcode]
   end
   function self:delete()
      for charcode,gd in pairs(glyph_cache) do
         if gd.texture then
            gd.texture:DestroyTexture()
            gd.texture = nil
         end
      end
      glyph_cache = {}
      if self.face then
         face:Done_Face()
         self.face = nil
      end
   end
   return setmetatable(self, { __gc = self.delete })
end

function app:init()
   local script_path = arg[0]
   local script_contents = file.read(script_path)
   local script_dir = fs.dirname(script_path)
   local ttf_path = fs.join(script_dir, "DejaVuSerif.ttf")
   local font_size = 20 -- initial font size in points
   local font = Font(ttf_path, font_size, self.window, self.renderer)

   local text_top = 0
   sched(function()
         while true do
            text_top = text_top-1
            sched.sleep(1/self.fps)
         end
   end)

   local r = self.renderer

   local function lines(s)
      local index = 1
      local function next()
         local rv = nil
         if index <= #s then
            local lf_pos = s:find("\n", index, true)
            if lf_pos then
               rv = s:sub(index, lf_pos-1)
               index = lf_pos+1
            else
               rv = s:sub(index)
               index = #s+1
            end
         end
         return rv
      end
      return next
   end

   local function draw_char(font, charcode, ox, oy)
      local glyph_data = font:get_glyph(charcode)
      if glyph_data.width > 0 then
         local dstrect = sdl.Rect(ox+glyph_data.bearing_x,
                                  oy-glyph_data.bearing_y,
                                  glyph_data.width, glyph_data.height)
         r:RenderCopy(glyph_data.texture, glyph_data.srcrect, dstrect)
      end
      return round(glyph_data.advance_x)
   end

   local function draw_string(font, s, x, y)
      local cp = iconv.utf8_codepoints(s)
      local ox = x
      local oy = y+font.ascender
      for i=1,#cp do
         local advance = draw_char(font, cp[i], ox, oy)
         ox = ox + advance
         if ox >= self.w then
            break
         end
      end
      return font.height
   end

   local function CumulativeMovingAverage()
      local avg = 0
      local n = 0
      return function(x)
         if x then
            n = n + 1
            avg = (x + (n-1)*avg) / n
         else
            return avg
         end
      end
   end

   local avg_time = CumulativeMovingAverage()

   sched(function()
      while true do
         sched.sleep(1)
         pf("app:draw() takes %s seconds in average", avg_time())
      end
   end)

   function app:draw()
      local t1 = time.time()
      r:SetRenderDrawColor(0,0,0,255)
      r:RenderClear()
      local top = text_top
      for line in lines(script_contents) do
         if top >= -font.height then
            draw_string(font, line, 0, top)
         end
         top = top + font.height
         if top >= self.h then
            break
         end
      end
      local t2 = time.time()
      local elapsed = t2 - t1
      avg_time(elapsed)
   end

   function app:done()
      font:delete()
   end
end

app:run()
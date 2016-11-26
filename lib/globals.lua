local ffi = require('ffi')

-- commonly used C types and functions

ffi.cdef [[

typedef long int ssize_t;

/* types of struct stat fields */

typedef unsigned long long int __dev_t;
typedef unsigned long int __ino_t;
typedef unsigned int __mode_t;
typedef unsigned int __nlink_t;
typedef unsigned int __uid_t;
typedef unsigned int __gid_t;
typedef long int __off_t;
typedef long int __blksize_t;
typedef long int __blkcnt_t;

void *malloc (size_t size);
void free (void *ptr);

]]

-- global definitions

_G.sf = string.format

function _G.pf(fmt, ...)
   print(string.format(fmt, ...))
end

function _G.ef(fmt, ...)
   local msg = string.format(fmt, ...)
   if coroutine.running() then
      -- append stack trace of the current thread
      msg = sf("%s%s", msg, debug.traceback("", 2))
   end
   error(msg, 2)
end

ffi.cdef [[

typedef struct SDL_Point {
  int x, y;
} SDL_Point;

typedef struct SDL_Rect {
  int x, y;
  int w, h;
} SDL_Rect;

typedef struct zz_size {
  int w, h;
} zz_size;

typedef struct SDL_Color {
  uint8_t r;
  uint8_t g;
  uint8_t b;
  uint8_t a;
} SDL_Color;

]]

-- Point

local Point_mt = {}

function Point_mt:__tostring()
   return sf("Point(%d,%d)", self.x, self.y)
end

_G.Point = ffi.metatype("SDL_Point", Point_mt)

-- Rect

local Rect_mt = {}

function Rect_mt:__tostring()
   return sf("Rect(%d,%d,%d,%d)",
             self.x, self.y,
             self.w, self.h)
end

function Rect_mt:update(x,y,w,h)
   self.x = x or self.x
   self.y = y or self.y
   self.w = w or self.w
   self.h = h or self.h
end

function Rect_mt:clear()
   self:update(0,0,0,0)
end

_G.Rect = ffi.metatype("SDL_Rect", Rect_mt)

-- Size

local Size_mt = {}

function Size_mt:__tostring()
   return sf("Size(%d,%d)", self.w, self.h)
end

function Size_mt:update(w,h)
   self.w = w or self.w
   self.h = h or self.h
end

function Size_mt:clear()
   self:update(0,0)
end

_G.Size = ffi.metatype("zz_size", Size_mt)

-- Color

local Color_mt = {}

function Color_mt:bytes()
   return self.r, self.g, self.b, self.a
end

function Color_mt:floats()
   return self.r/255, self.g/255, self.b/255, self.a/255
end

function Color_mt:u32be()
   return
      bit.lshift(self.r, 24) +
      bit.lshift(self.g, 16) +
      bit.lshift(self.b, 8) +
      bit.lshift(self.a, 0)
end

function Color_mt:u32le()
   return
      bit.lshift(self.r, 0) +
      bit.lshift(self.g, 8) +
      bit.lshift(self.b, 16) +
      bit.lshift(self.a, 24)
end

function Color_mt:u32()
   return ffi.abi("le") and self:u32le() or self:u32be()
end

Color_mt.__index = Color_mt

_G.Color = ffi.metatype("SDL_Color", Color_mt)
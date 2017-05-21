local buffer = require('buffer')
local ffi = require('ffi')
local assert = require('assert')

-- a plain buffer() call allocates a buffer
-- with default capacity and zero size
local buf = buffer()
assert(buf:capacity() > 0)
assert.equals(buf:size(), 0)
assert.equals(#buf, 0) -- #buf is equivalent to buf:size()
assert.equals(buf:str(), "") -- get contents as a string
assert.equals(tostring(buf), "") -- same as buf:str()

-- compare with string
assert(buf=="")
assert(""==buf)

-- compare with another buffer
assert(buf==buffer())

-- append
buf:append("hello")
assert(buf=="hello")
assert.equals(#buf, 5)
buf:append(", world!")
assert.equals(#buf, 13)
assert(buf=="hello, world!")

-- buffer with an explicit capacity
local buf2 = buffer(5)
assert.equals(buf2:capacity(), 5)
assert.equals(#buf2, 0) -- initial size is zero
assert(buf2=="")
buf2:append("hell")
assert.equals(buf2:capacity(), 5)
assert.equals(#buf2, 4)

-- automatic resize rounds capacity to next multiple of 1024
buf2:append("o, world!")
assert.equals(buf2:capacity(), 1024)
assert.equals(#buf2, 13)
assert(buf2=="hello, world!")
assert(buf==buf2)

-- append first N bytes of a string
buf2:append("\n\n\n\n\n\n", 2)
assert(buf2=="hello, world!\n\n")

-- append a section of another buffer
buf2:append(buf2:ptr()+3, 3)
assert(buf2=="hello, world!\n\nlo,")

-- buffer with initial data
local three_spaces = '   '
local buf3 = buffer(three_spaces)
assert.equals(#buf3, 3)
assert.equals(buf3:capacity(), 3)
assert(buf3=='   ')

-- fill
buf3:fill(0x41)
assert(buf3=='AAA')

-- if a buffer is initialized from existing data, that data is copied
-- by default => three_spaces still has its original value
assert(three_spaces=='   ')

-- clear: fill with zeroes
buf3:clear()
assert(buf3=='\0\0\0')

-- reset: set size to 0
buf3:reset()
assert(buf3:capacity()==3)
assert(buf3:size()==0)
assert(buf3=="")

buf3:append('zzz')
assert(buf3=='zzz')
assert.equals(#buf3, 3)

-- buffer with shared data
-- arguments are (data, size, shared)
-- `size` defaults to #data
-- `shared` defaults to false
local buf3b = buffer(buf3, nil, true)
assert(buf3b=='zzz')

-- indexing
assert(buf3b[1]==0x7a)
buf3b[1]=0x78
assert(buf3b=='zxz')

-- as we shared data with buf3, it changed too:
assert(buf3=='zxz')

-- warning: never modify a buffer which shares its data with a Lua
-- string - it interferes with the interning logic

-- buffer with initial data of specified size
local buf4 = buffer('abcdef', 3)
assert.equals(#buf4, 3)
assert.equals(buf4:capacity(), 3)
assert(buf4=='abc')

-- change capacity
local buf5 = buffer()
buf5:capacity(2100)
-- capacity is rounded up to next multiple of 1024
assert.equals(buf5:capacity(), 3072)
buf5:capacity(4000)
assert.equals(buf5:capacity(), 4096)
assert.equals(#buf5, 0)
for i=0,4095 do
   buf5:append(string.char(0x41+i%26))
end
assert.equals(buf5:capacity(), 4096)
assert.equals(#buf5, 4096)

-- change size
buf5:size(5)
assert.equals(#buf5, 5)
assert(buf5=='ABCDE')
buf5:size(4096)

-- buf:get(index) and buf[index]
assert.equals(buf5:get(0), 0x41) -- byte value at index 0
assert.equals(buf5[0], 0x41)     -- sugar for buf5:get(0)

-- buf:str(index, length)
assert.equals(buf5:str(0,10), "ABCDEFGHIJ")
assert.equals(buf5:str(5,10), "FGHIJKLMNO")

-- buf:set(index, value) and buf[index] = value
buf5:set(2, 0x7A) -- byte value
assert.equals(buf5:str(0,10), "ABzDEFGHIJ")
buf5[2] = 0x79 -- sugar for buf5:set(2, 0x7A)
assert.equals(buf5:str(0,10), "AByDEFGHIJ")

-- getting a uint8_t* pointer to buffer data
assert.equals(ffi.string(buf5:ptr()+7,2), "HI")

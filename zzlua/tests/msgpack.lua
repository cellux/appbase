local msgpack = require('msgpack')
local assert = require('assert')

local function test_pack_unpack(x)
   local packed = msgpack.pack(x)
   local unpacked = msgpack.unpack(packed)
   assert.equals(x, unpacked)
end

test_pack_unpack(nil)
test_pack_unpack(true)
test_pack_unpack(false)
test_pack_unpack(0)
test_pack_unpack(123)
test_pack_unpack(123.25)
test_pack_unpack("hello, world!")
test_pack_unpack({nil,true,false,0,123,123.25,"hello, world!"})
test_pack_unpack({[0]=true,[1]=false,[123]={x=123.25,y=-123.5},str="hello, world!"})

-- pack_array() ensures the table is packed as an array
-- it's the user's reponsibility that the array is valid
local packed = msgpack.pack_array({1,2,"abc",4})
assert.equals(string.byte(packed,1), 0x94, "initial byte of msgpacked {1,2,\"abc\",4}")

-- pack() packs numbers as doubles
local packed = msgpack.pack(1234)
assert.equals(string.byte(packed,1), 0xcb, "initial byte of msgpacked 1234")

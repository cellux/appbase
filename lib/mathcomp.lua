local util = require('util')

local M = {}

local function CodeGen()
   local self = {}
   local items = {}
   local function call(self, code)
      if code and #code > 0 then
         table.insert(items, code)
      end
   end
   function self:code()
      return table.concat(items, "\n")
   end
   return setmetatable(self, { __call = call })
end

local next_struct_id = util.Counter()

function M.CompilerContext(opts)
   opts = opts or {}
   local numtype = opts.numtype or 'float'

   local ctx = {}

   local node_counter = util.Counter()

   local function is_node(x)
      return type(x)=="table" and x.type
   end

   local function is_node_type(x, t)
      return is_node(x) and x.type==t
   end

   local function is_num(x)
      return type(x)=="number" or is_node_type(x, "num")
   end

   local function is_vec(x)
      return is_node_type(x, "vec")
   end

   local function is_mat(x)
      return is_node_type(x, "mat")
   end

   function ctx:node(t)
      local self = {
         type = t,
         id = node_counter(),
         deps = {},
         assigned_name = nil,
         is_param = false,
      }
      function self:param(name)
         if name then
            self.assigned_name = name
         end
         self.is_param = true
         return self
      end
      function self:name()
         return self.assigned_name or sf('%s_%d', t, self.id)
      end
      function self:var()
         if self.is_param then
            return sf('_.%s', self:name())
         else
            return self:name()
         end
      end
      function self:depends(items)
         assert(type(items)=="table")
         self.deps = {}
         for _,x in ipairs(items) do
            if is_node(x) then
               table.insert(self.deps, x)
            end
         end
         return self
      end
      function self:invoke(visitor, recursive)
         if recursive then
            for _,node in ipairs(self.deps) do
               node:invoke(visitor, recursive)
            end
         end
         visitor(self)
      end
      function self:emit_decl_l(codegen)
         codegen(sf("local %s", self:name()))
      end
      function self:emit_decl_p(codegen)
         -- to be implemented downstream
      end
      function self:emit_code(codegen)
         -- to be implemented downstream
      end
      return self
   end

   local function source_of(x)
      return sf('%s', is_node(x) and x:var() or x)
   end

   local function sources_of(items, sep)
      local values = {}
      for _,item in ipairs(items) do
         table.insert(values, source_of(item))
      end
      if sep then
         values = table.concat(values, sep)
      end
      return values
   end

   local ctx_mt = {}

   function ctx_mt.__add(n1, n2)
      return ctx:binop("+", n1, n2)
   end

   function ctx_mt.__sub(n1, n2)
      return ctx:binop("-", n1, n2)
   end

   function ctx_mt.__mul(n1, n2)
      return ctx:binop("*", n1, n2)
   end

   function ctx_mt.__div(n1, n2)
      return ctx:binop("/", n1, n2)
   end

   function ctx:num()
      local self = ctx:node("num")
      function self:emit_decl_p(codegen)
         codegen(sf("%s %s;", numtype, self:name()))
      end
      return setmetatable(self, ctx_mt)
   end

   function ctx:fn(func_name, ...)
      local params = {...}
      local self = ctx:num():depends(params)
      function self:emit_code(codegen)
         codegen(sf("%s = %s(%s)",
                    self:var(),
                    func_name,
                    sources_of(params, ',')))
      end
      return self
   end

   function ctx:binop(op, arg1, arg2)
      local self = ctx:num():depends{arg1, arg2}
      function self:emit_code(codegen)
         codegen(sf("%s = (%s %s %s)",
                    self:var(),
                    source_of(arg1), op, source_of(arg2)))
      end
      return self
   end

   -- vector

   local vec_mt = {}

   function vec_mt:index(i)
      if self.is_param then
         return i-1
      else
         return i
      end
   end

   function vec_mt:ref(i)
      return sf("%s[%d]", self:var(), self:index(i))
   end

   function vec_mt.__unm(v)
      local self = ctx:vec(v.size):depends{v}
      function self:emit_code(codegen)
         for i=1,self.size do
            codegen(sf("%s = -%s", self:ref(i), v:ref(i)))
         end
      end
      return self
   end

   function vec_mt.__add(lhs, rhs)
      assert(is_vec(lhs))
      assert(is_vec(rhs))
      assert(lhs.size == rhs.size)
      local self = ctx:vec(lhs.size):depends{lhs, rhs}
      function self:emit_code(codegen)
         for i=1,self.size do
            codegen(sf("%s = %s + %s",
                       self:ref(i),
                       lhs:ref(i),
                       rhs:ref(i)))
         end
      end
      return self
   end

   function vec_mt.__sub(lhs, rhs)
      return lhs + -rhs
   end

   function vec_mt.__mul(lhs, rhs)
      if is_num(lhs) then
         lhs,rhs = rhs,lhs
      end
      assert(is_vec(lhs))
      if is_num(rhs) then
         local self = ctx:vec(lhs.size):depends{lhs, rhs}
         function self:emit_code(codegen)
            codegen("do")
            codegen(sf("local m = %s", source_of(rhs)))
            for i=1,self.size do
               codegen(sf("%s = %s * m", self:ref(i), lhs:ref(i)))
            end
            codegen("end")
         end
         return self
      elseif is_mat(rhs) then
         assert(lhs.size==rhs.rows)
         local self = ctx:vec(rhs.cols):depends{lhs, rhs}
         function self:emit_code(codegen)
            for x=1,self.size do
               local terms = {}
               for i=1,lhs.size do
                  table.insert(terms, sf("%s*%s",
                                         lhs:ref(i),
                                         rhs:ref(x,i)))
               end
               codegen(sf("%s = %s",
                          self:ref(x),
                          table.concat(terms,'+')))
            end
         end
         return self
      else
         ef("invalid operand: %s", rhs)
      end
   end

   function vec_mt.__div(lhs, rhs)
      assert(is_vec(lhs))
      assert(is_num(rhs))
      return lhs * ctx:binop("/", 1, rhs)
   end

   function vec_mt.__len(v)
      local self = ctx:num():depends{v}
      function self:emit_code(codegen)
         local terms = {}
         for i=1,v.size do
            table.insert(terms, sf("%s*%s", v:ref(i), v:ref(i)))
         end
         codegen(sf("%s = math.sqrt(%s)", self:var(), table.concat(terms,'+')))
      end
      return self
   end

   function vec_mt:mag()
      return #self
   end

   function vec_mt.normalize(v)
      return v * ctx:binop("/", 1, #v)
   end

   function vec_mt:project(v2)
      local dot = ctx:dot(self, v2)
      local v2_mag = #v2
      local sq = ctx:binop("*", v2_mag, v2_mag)
      return v2 * ctx:binop("/", dot, sq)
   end

   vec_mt.__index = vec_mt

   function ctx:vec(size, init)
      local elements = {}
      assert(type(size)=="number")
      if init then
         if type(init)=="number" then
            for i=1,size do
               elements[i] = init
            end
         elseif type(init)=="table" then
            assert(#init==size)
            elements = init
         else
            ef("invalid vector initializer: %s", init)
         end
      end
      local self = ctx:node("vec")
      self.size = size
      function self:emit_decl_l(codegen)
         codegen(sf("local %s = {%s}",
                    self:name(),
                    sources_of(elements, ',')))
      end
      function self:emit_decl_p(codegen)
         codegen(sf("%s %s[%d];", numtype, self:name(), self.size))
      end
      function self:emit_code(codegen)
         if self.is_param then
            for i=1,self.size do
               codegen(sf("%s = %s",
                          self:ref(i),
                          source_of(elements[i])))
            end
         end
      end
      return setmetatable(self, vec_mt)
   end

   function ctx:dot(lhs, rhs)
      assert(is_vec(lhs))
      assert(is_vec(rhs))
      assert(lhs.size==rhs.size)
      local self = ctx:num():depends{lhs, rhs}
      function self:emit_code(codegen)
         local terms = {}
         for i=1,lhs.size do
            table.insert(terms, sf("%s*%s", lhs:ref(i), rhs:ref(i)))
         end
         codegen(sf("%s = %s",
                    self:var(),
                    table.concat(terms,'+')))
      end
      return self
   end

   function ctx:cross(lhs, rhs)
      assert(is_vec(lhs))
      assert(is_vec(rhs))
      assert(lhs.size==rhs.size)
      assert(lhs.size==3)
      local self = ctx:vec(lhs.size):depends{lhs, rhs}
      function self:emit_code(codegen)
         codegen(sf("%s = %s*%s - %s*%s",
                    self:ref(1),
                    lhs:ref(2), rhs:ref(3),
                    lhs:ref(3), rhs:ref(2)))
         codegen(sf("%s = %s*%s - %s*%s",
                    self:ref(2),
                    lhs:ref(3), rhs:ref(1),
                    lhs:ref(1), rhs:ref(3)))
         codegen(sf("%s = %s*%s - %s*%s",
                    self:ref(3),
                    lhs:ref(1), rhs:ref(2),
                    lhs:ref(2), rhs:ref(1)))
      end
      return self
   end

   function ctx:distance(v1, v2)
      return #(v2-v1)
   end

   function ctx:angle(v1, v2)
      return ctx:fn("math.acos",
                    ctx:binop("/",
                              ctx:dot(v1,v2),
                              ctx:binop("*", #v1, #v2)))
   end

   -- matrix

   local mat_mt = {}

   function mat_mt:index(x, y)
      local i = (x - 1) * self.rows + y
      if self.is_param then
         return i-1
      else
         return i
      end
   end

   function mat_mt:ref(x, y)
      return sf("%s[%d]", self:var(), self:index(x, y))
   end

   function mat_mt.__mul(lhs, rhs)
      if is_num(lhs) then
         lhs,rhs = rhs,lhs
      end
      if is_num(rhs) then
         local self = ctx:mat(lhs.cols, lhs.rows):depends{lhs, rhs}
         function self:emit_code(codegen)
            codegen("do")
            codegen(sf("local m = %s", source_of(rhs)))
            for x=1,self.cols do
               for y=1,self.rows do
                  codegen(sf("%s = %s * m",
                             self:ref(x,y),
                             lhs:ref(x,y)))
               end
            end
            codegen("end")
         end
         return self
      elseif is_mat(rhs) then
         assert(lhs.cols==rhs.rows)
         local self = ctx:mat(rhs.cols, lhs.rows):depends{lhs, rhs}
         function self:emit_code(codegen)
            for x=1,self.cols do
               for y=1,self.rows do
                  local terms = {}
                  for i=1,lhs.cols do
                     table.insert(terms, sf("%s*%s",
                                            lhs:ref(i,y),
                                            rhs:ref(x,i)))
                  end
                  codegen(sf("%s = %s",
                             self:ref(x,y),
                             table.concat(terms,'+')))
               end
            end
         end
         return self
      elseif is_vec(rhs) then
         assert(lhs.cols==rhs.size)
         local self = ctx:vec(lhs.rows):depends{lhs, rhs}
         function self:emit_code(codegen)
            for y=1,self.size do
               local terms = {}
               for i=1,lhs.cols do
                  table.insert(terms, sf("%s*%s",
                                         lhs:ref(i,y),
                                         rhs:ref(i)))
               end
               codegen(sf("%s = %s",
                          self:ref(y),
                          table.concat(terms,'+')))
            end
         end
         return self
      else
         ef("invalid operand: %s", rhs)
      end
   end

   function mat_mt.__div(lhs, rhs)
      assert(is_mat(lhs))
      assert(is_num(rhs))
      return lhs * ctx:binop("/", 1, rhs)
   end

   function mat_mt.extend(m, size)
      assert(type(size)=="number")
      assert(size >= m.cols)
      assert(size >= m.rows)
      local self = ctx:mat_identity(size):depends{m}
      local super_emit_code = self.emit_code
      function self:emit_code(codegen)
         super_emit_code(self, codegen)
         for x=1,m.cols do
            for y=1,m.rows do
               codegen(sf("%s = %s", self:ref(x,y), m:ref(x,y)))
            end
         end
      end
      return self
   end

   function mat_mt.transpose(m)
      local self = ctx:mat(m.rows, m.cols):depends{m}
      function self:emit_code(codegen)
         for x=1,self.cols do
            for y=1,self.rows do
               codegen(sf("%s = %s",
                          self:ref(x,y),
                          m:ref(y,x)))
            end
         end
      end
      return self
   end

   function mat_mt.minor(m, x0, y0)
      assert(m.cols >= 2)
      assert(m.rows >= 2)
      assert(is_num(x0))
      assert(is_num(y0))
      local self = ctx:mat(m.rows-1, m.cols-1):depends{m}
      function self:emit_code(codegen)
         for x=1,self.cols do
            local mx = (x >= x0) and (x+1) or x
            for y=1,self.rows do
               local my = (y >= y0) and (y+1) or y
               codegen(sf("%s=%s", self:ref(x, y), m:ref(mx, my)))
            end
         end
      end
      return self
   end

   function mat_mt.cofactor(m, x, y)
      local sign = ((x+y) % 2 == 0) and 1 or -1
      return ctx:binop("*", m:minor(x,y):det(), sign)
   end

   function mat_mt.det(m)
      assert(m.cols==m.rows)
      local self
      if m.rows == 2 then
         self = ctx:num():depends{m}
         function self:emit_code(codegen)
            codegen(sf("%s = %s * %s - %s * %s",
                       self:var(),
                       m:ref(1,1), m:ref(2,2),
                       m:ref(2,1), m:ref(1,2)))
         end
      elseif m.rows > 2 then
         local cofactors = {}
         for x=1,m.cols do
            table.insert(cofactors, m:cofactor(x,1))
         end
         self = ctx:num():depends{m, unpack(cofactors)}
         function self:emit_code(codegen)
            local terms = {}
            for x=1,m.cols do
               table.insert(terms, sf("%s * %s",
                                      m:ref(x,1),
                                      cofactors[x]:var()))
            end
            codegen(sf("%s = %s",
                       self:var(),
                       table.concat(terms,' + ')))
         end
      else
         ef("invalid matrix size: %s, must be >= 2 to calculate determinant", m.rows)
      end
      return self
   end

   function mat_mt.cofactors(m)
      assert(m.cols==m.rows)
      local cofactors = {}
      for x=1,m.cols do
         for y=1,m.rows do
            table.insert(cofactors, m:cofactor(x,y))
         end
      end
      local self = ctx:mat(m.cols, m.rows):depends{m, unpack(cofactors)}
      function self:emit_code(codegen)
         for x=1,self.cols do
            for y=1,self.rows do
               local i = (x - 1) * self.rows + y
               codegen(sf("%s = %s",
                          self:ref(x,y),
                          cofactors[i]:var()))
            end
         end
      end
      return self
   end

   function mat_mt.adj(m)
      return m:cofactors():transpose()
   end

   function mat_mt.inv(m)
      return m:adj() / m:det()
   end

   mat_mt.__index = mat_mt

   function ctx:mat(cols, rows, init)
      local elements = {}
      assert(type(cols)=="number")
      rows = rows or cols
      assert(type(rows)=="number")
      local size = cols * rows
      if init then
         if type(init)=="number" then
            for i=1,size do
               elements[i] = init
            end
         elseif type(init)=="table" then
            assert(#init==size)
            elements = init
         else
            ef("invalid matrix initializer: %s", init)
         end
      end
      local self = ctx:node("mat")
      self.cols = cols
      self.rows = rows
      self.size = size
      function self:emit_decl_l(codegen)
         codegen(sf("local %s = {%s}",
                    self:name(),
                    sources_of(elements, ',')))
      end
      function self:emit_decl_p(codegen)
         codegen(sf("%s %s[%d];", numtype, self:name(), size))
      end
      function self:emit_code(codegen)
         if self.is_param then
            for x=1,cols do
               for y=1,rows do
                  local i = (x-1)*rows + y
                  codegen(sf("%s[%d]=%s", self:var(), i-1, source_of(elements[i])))
               end
            end
         end
      end
      return setmetatable(self, mat_mt)
   end

   function ctx:mat_zero(size)
      return ctx:mat(size, size, 0)
   end

   function ctx:mat_identity(size)
      local elements = {}
      for x=1,size do
         for y=1,size do
            elements[(x-1)*size+y] = (x==y and 1 or 0)
         end
      end
      return ctx:mat(size, size, elements)
   end

   function ctx:mat2_rotate(angle)
      local self = ctx:mat(2,2):depends{angle}
      function self:emit_code(codegen)
         codegen "do"
         codegen(sf("local cos = math.cos(%s)", source_of(angle)))
         codegen(sf("local sin = math.sin(%s)", source_of(angle)))
         codegen(sf("%s = cos", self:ref(1,1)))
         codegen(sf("%s =-sin", self:ref(1,2)))
         codegen(sf("%s = sin", self:ref(2,1)))
         codegen(sf("%s = cos", self:ref(2,2)))
         codegen "end"
      end
      return self
   end

   function ctx:mat3_rotate_x(angle)
      local self = ctx:mat(3,3):depends{angle}
      function self:emit_code(codegen)
         codegen "do"
         codegen(sf("local cos = math.cos(%s)", source_of(angle)))
         codegen(sf("local sin = math.sin(%s)", source_of(angle)))
         codegen(sf("%s = 1",   self:ref(1,1)))
         codegen(sf("%s = 0",   self:ref(1,2)))
         codegen(sf("%s = 0",   self:ref(1,3)))
         codegen(sf("%s = 0",   self:ref(2,1)))
         codegen(sf("%s = cos", self:ref(2,2)))
         codegen(sf("%s =-sin", self:ref(2,3)))
         codegen(sf("%s = 0",   self:ref(3,1)))
         codegen(sf("%s = sin", self:ref(3,2)))
         codegen(sf("%s = cos", self:ref(3,3)))
         codegen "end"
      end
      return self
   end

   function ctx:mat3_rotate_y(angle)
      local self = ctx:mat(3,3):depends{angle}
      function self:emit_code(codegen)
         codegen "do"
         codegen(sf("local cos = math.cos(%s)", source_of(angle)))
         codegen(sf("local sin = math.sin(%s)", source_of(angle)))
         codegen(sf("%s = cos", self:ref(1,1)))
         codegen(sf("%s = 0",   self:ref(1,2)))
         codegen(sf("%s = sin", self:ref(1,3)))
         codegen(sf("%s = 0",   self:ref(2,1)))
         codegen(sf("%s = 1",   self:ref(2,2)))
         codegen(sf("%s = 0",   self:ref(2,3)))
         codegen(sf("%s =-sin", self:ref(3,1)))
         codegen(sf("%s = 0",   self:ref(3,2)))
         codegen(sf("%s = cos", self:ref(3,3)))
         codegen "end"
      end
      return self
   end

   function ctx:mat3_rotate_z(angle)
      local self = ctx:mat(3,3):depends{angle}
      function self:emit_code(codegen)
         codegen "do"
         codegen(sf("local cos = math.cos(%s)", source_of(angle)))
         codegen(sf("local sin = math.sin(%s)", source_of(angle)))
         codegen(sf("%s = cos", self:ref(1,1)))
         codegen(sf("%s =-sin", self:ref(1,2)))
         codegen(sf("%s = 0",   self:ref(1,3)))
         codegen(sf("%s = sin", self:ref(2,1)))
         codegen(sf("%s = cos", self:ref(2,2)))
         codegen(sf("%s = 0",   self:ref(2,3)))
         codegen(sf("%s = 0",   self:ref(3,1)))
         codegen(sf("%s = 0",   self:ref(3,2)))
         codegen(sf("%s = 1",   self:ref(3,3)))
         codegen "end"
      end
      return self
   end

   function ctx:mat3_rotate(angle, axis)
      -- axis must be a unit vector
      assert(is_vec(axis))
      assert(axis.size==3)
      local self = ctx:mat(3,3):depends{angle,axis}
      function self:emit_code(codegen)
         local function gen(x,y,n1,n2,n3,n3mul)
            codegen(sf("%s = %s",
                       self:ref(x,y),
                       sf("%s*(1-cos) + %s*%s",
                          sf("%s*%s", axis:ref(n1), axis:ref(n2)),
                          n3 == 0 and "1" or axis:ref(n3),
                          n3mul)))
         end
         codegen "do"
         codegen(sf("local cos = math.cos(%s)", source_of(angle)))
         codegen(sf("local sin = math.sin(%s)", source_of(angle)))
         gen(1,1,1,1,0,'cos')
         gen(1,2,1,2,3,'-sin')
         gen(1,3,1,3,2,'sin')
         gen(2,1,2,1,3,'sin')
         gen(2,2,2,2,0,'cos')
         gen(2,3,2,3,1,'-sin')
         gen(3,1,3,1,2,'-sin')
         gen(3,2,3,2,1,'sin')
         gen(3,3,3,3,0,'cos')
         codegen "end"
      end
      return self
   end

   function ctx:mat4_translate(v)
      assert(is_vec(v))
      assert(v.size==3)
      local self = ctx:mat_identity(4):depends{v}
      local super_emit_code = self.emit_code
      function self:emit_code(codegen)
         super_emit_code(self, codegen)
         codegen(sf("%s = %s", self:ref(1,4), v:ref(1)))
         codegen(sf("%s = %s", self:ref(2,4), v:ref(2)))
         codegen(sf("%s = %s", self:ref(3,4), v:ref(3)))
      end
      return self
   end

   function ctx:mat_scale(factor, axis)
      -- axis must be a unit vector
      assert(is_num(factor))
      assert(is_vec(axis))
      local self = ctx:mat(axis.size):depends{factor, axis}
      function self:emit_code(codegen)
         codegen "do"
         codegen(sf("local k1 = (%s)-1", source_of(factor)))
         for x=1,self.cols do
            for y=1,self.rows do
               codegen(sf("%s = %s",
                          self:ref(x,y),
                          sf("%d + k1*%s*%s",
                             x==y and 1 or 0,
                             axis:ref(x), axis:ref(y))))
            end
         end
         codegen "end"
      end
      return self
   end

   function ctx:mat4_perspective(fovy, aspect, znear, zfar)
      local elements = {}
      for x=1,4 do
         for y=1,4 do
            elements[(x-1)*4+y] = 0
         end
      end
      local zoom_y = 1 / math.tan(fovy/2)
      local zoom_x = zoom_y / aspect
      elements[0*4+1] = zoom_x
      elements[1*4+2] = zoom_y
      elements[2*4+3] = (zfar + znear) / (zfar - znear)
      elements[2*4+4] = (2 * znear * zfar) / (znear - zfar)
      elements[3*4+3] = 1
      return ctx:mat(4, 4, elements)
   end

   function ctx:compile(...)
      local roots = {...}
      -- mark all roots as (output) parameters
      for _,node in ipairs(roots) do
         node:invoke(function(n) n:param() end, false)
      end
      local codegen = CodeGen()
      codegen "local ffi = require('ffi')"
      codegen "local mt = {}"
      local codegen_p = CodeGen() -- params
      local codegen_l = CodeGen() -- locals
      local emit_decl_invoked = {}
      local function emit_decl(node)
         if not emit_decl_invoked[node] then
            if node.is_param then
               node:emit_decl_p(codegen_p)
            else
               node:emit_decl_l(codegen_l)
            end
            emit_decl_invoked[node] = true
         end
      end
      for _,node in ipairs(roots) do
         node:invoke(emit_decl, true)
      end
      local struct_name = sf("zz_mathcomp_%d", next_struct_id())
      codegen(sf("ffi.cdef [[ struct %s {", struct_name))
      codegen(codegen_p:code())
      codegen "}; ]]"
      codegen "function mt.calculate(_)"
      codegen(codegen_l:code())
      local emit_code_invoked = {}
      local function emit_code(node)
         if not emit_code_invoked[node] then
            node:emit_code(codegen)
            emit_code_invoked[node] = true
         end
      end
      for _,node in ipairs(roots) do
         node:invoke(emit_code, true)
      end
      codegen "return _"
      codegen "end"
      codegen "function mt.outputs(_)"
      codegen(sf("return %s", sources_of(roots, ',')))
      codegen "end"
      codegen "mt.__index = mt"
      codegen(sf("return ffi.metatype('struct %s', mt)()", struct_name))
      local code = codegen:code()
      --print(code)
      return assert(loadstring(code))()
   end

   return ctx
end

return setmetatable(M, { __call = M.CompilerContext })

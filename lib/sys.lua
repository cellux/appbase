local ffi = require('ffi')
local util = require('util')
local socket = require('socket')

ffi.cdef [[

typedef int __pid_t;
typedef __pid_t pid_t;

/* process identification */

pid_t getpid ();
pid_t getppid ();

/* process creation */

pid_t fork ();

/* execution */

int system (const char *COMMAND);
int execv (const char *FILENAME,
           char *const ARGV[]);
int execl (const char *FILENAME,
           const char *ARG0,
           ...);
int execve (const char *FILENAME,
            char *const ARGV[],
            char *const ENV[]);
int execvp (const char *FILENAME,
            char *const ARGV[]);
int execlp (const char *FILENAME,
            const char *ARG0,
            ...);

/* process completion */

pid_t waitpid (pid_t PID, int *STATUSPTR, int OPTIONS);

/* process state */

char *getcwd (char *buf, size_t size);
int chdir (const char *path);
void exit (int);

/* trying to call the libc atexit() directly results in an "undefined
   symbol" error, so we use a trampoline.  */

int zz_sys_atexit (void (*fn)(void));

]]

local M = {}

function M.getpid()
   return ffi.C.getpid()
end

function M.fork(child_fn)
   if child_fn then
      local sp, sc = socket.socketpair(socket.PF_LOCAL,
                                       socket.SOCK_STREAM,
                                       0)
      local pid = util.check_bad("fork", -1, ffi.C.fork())
      if pid == 0 then
         sp:close()
         pcall(child_fn, sc)
         -- we don't close sc here because it may be used in an atexit
         -- function. when the child exits, it will be closed anyway.
         --
         -- sc:close()
         M.exit(0)
      else
         sc:close()
         return pid, sp
      end
   else
      return util.check_bad("fork", -1, ffi.C.fork())
   end
end

function M.system(command)
   return ffi.C.system(command)
end

function M.execvp(path, argv)
   -- stringify args
   for i=1,#argv do
      argv[i] = tostring(argv[i])
   end
   -- build const char* argv[] for execvp()
   local execvp_argv = ffi.new("char*[?]", #argv+1)
   for i=1,#argv do
      execvp_argv[i-1] = ffi.cast("char*", argv[i])
   end
   execvp_argv[#argv] = nil
   util.check_bad("execvp", -1, ffi.C.execvp(path, execvp_argv))
end

function M.waitpid(pid, options)
   options = options or 0
   local status = ffi.new("int[1]")
   local rv = util.check_bad("waitpid", -1, ffi.C.waitpid(pid, status, options))
   return rv, tonumber(status[0])
end

function M.getcwd()
   local buf = ffi.C.getcwd(nil, 0)
   local cwd = ffi.string(buf)
   ffi.C.free(buf)
   return cwd
end

function M.chdir(path)
   return util.check_ok("chdir", 0, ffi.C.chdir(path))
end

function M.exit(status)
   ffi.C.exit(status or 0)
end

local atexit_fns

local function atexit_handler()
   for i=1,#atexit_fns do
      pcall(atexit_fns[i])
   end
end

function M.atexit(fn)
   if not atexit_fns then
      atexit_fns = {}
      util.check_ok("atexit", 0, ffi.C.zz_sys_atexit(atexit_handler))
   end
   table.insert(atexit_fns, fn)
end

return M
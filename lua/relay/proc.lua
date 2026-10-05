-- Process table helpers. On Linux everything comes straight from /proc (no subprocess);
-- elsewhere a single `ps` call is used and per-process details are limited.
local util = require("relay.util")

local M = {}

---@class relay.Proc
---@field pid integer
---@field ppid integer|nil
---@field comm string
---@field tty string|nil   controlling terminal, nil when the process has none
---@field start string|nil start time in clock ticks since boot (Linux)
---@field args string|nil  full command line (non-Linux)
---@field argv string[]|nil
---@field agent relay.Agent|false|nil cached by relay.agents.detect

--- Linux tty_nr (from /proc/<pid>/stat) to a comparable terminal name.
---@param nr string|integer|nil
---@return string|nil
function M.tty_name(nr)
  nr = tonumber(nr) or 0
  if nr == 0 then
    return nil
  end
  local major = math.floor(nr / 256) % 4096
  local hi = math.floor(nr / 4096)
  local minor = nr % 256 + (hi - hi % 256) % 1048576
  if major >= 136 and major <= 143 then
    return "/dev/pts/" .. ((major - 136) * 256 + minor)
  end
  return "tty:" .. nr
end

---@param pid integer
---@param stat string
---@return relay.Proc|nil
function M.parse_stat(pid, stat)
  local l = stat:find("(", 1, true)
  local r = stat:match(".*()%)") -- the command name may itself contain ')'
  if not l or not r then
    return nil
  end
  local fields, i = {}, 0
  for field in stat:sub(r + 2):gmatch("%S+") do
    i = i + 1
    fields[i] = field
    if i >= 20 then
      break
    end
  end
  return {
    pid = pid,
    comm = stat:sub(l + 1, r - 1),
    ppid = tonumber(fields[2]),
    tty = M.tty_name(fields[5]),
    start = fields[20],
  }
end

local function has_proc()
  return util.is_linux and util.uv.fs_stat("/proc/self/stat") ~= nil
end

--- Snapshot of all processes, keyed by pid. Calls `cb` synchronously on Linux.
---@param cb fun(procs: table<integer, relay.Proc>)
function M.snapshot(cb)
  if has_proc() then
    local procs = {}
    for name in vim.fs.dir("/proc") do
      local pid = tonumber(name)
      if pid then
        local stat = util.read_file("/proc/" .. name .. "/stat")
        local p = stat and M.parse_stat(pid, stat)
        if p then
          procs[pid] = p
        end
      end
    end
    return cb(procs)
  end
  util.run({ "ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "tty=", "-o", "args=" }, {}, function(ok, out)
    local procs = {}
    if ok then
      for line in out:gmatch("[^\n]+") do
        local pid, ppid, tty, args = line:match("^%s*(%d+)%s+(%d+)%s+(%S+)%s*(.*)$")
        if pid then
          local argv0 = args:match("^%S+") or ""
          procs[tonumber(pid)] = {
            pid = tonumber(pid),
            ppid = tonumber(ppid),
            tty = (tty ~= "?" and tty ~= "??" and tty ~= "-") and ("/dev/" .. tty) or nil,
            comm = (vim.fs.basename(argv0):gsub(":$", "")),
            args = args,
          }
        end
      end
    end
    cb(procs)
  end)
end

---@param p relay.Proc
---@return string[]
function M.argv(p)
  if not p.argv then
    if has_proc() then
      local s = util.read_file("/proc/" .. p.pid .. "/cmdline") or ""
      p.argv = vim.split(s, "\0", { plain = true, trimempty = true })
    else
      p.argv = vim.split(p.args or "", "%s+", { trimempty = true })
    end
  end
  return p.argv
end

--- Environment of a process (Linux only, own processes only).
---@param pid integer
---@return table<string, string>
function M.environ(pid)
  local env = {}
  if not has_proc() then
    return env
  end
  local s = util.read_file("/proc/" .. pid .. "/environ")
  if s then
    for _, kv in ipairs(vim.split(s, "\0", { plain = true, trimempty = true })) do
      local k, v = kv:match("^([^=]+)=(.*)$")
      if k then
        env[k] = v
      end
    end
  end
  return env
end

---@param pid integer
---@return string|nil
function M.cwd(pid)
  if has_proc() then
    return util.uv.fs_readlink("/proc/" .. pid .. "/cwd") or nil
  end
end

--- Executable of a running process, so we talk to e.g. a tmux/zellij server with the
--- exact binary (and protocol version) that runs it.
---@param p relay.Proc
---@return string|nil
function M.exe(p)
  if has_proc() then
    local exe = util.uv.fs_readlink("/proc/" .. p.pid .. "/exe")
    if exe then
      exe = exe:gsub(" %(deleted%)$", "")
      if vim.fn.executable(exe) == 1 then
        return exe
      end
    end
  end
  local argv0 = M.argv(p)[1]
  if argv0 and argv0:sub(1, 1) == "/" and vim.fn.executable(argv0) == 1 then
    return argv0
  end
end

return M

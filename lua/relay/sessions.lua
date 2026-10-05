-- Discovers running Claude Code sessions and how to reach each one.
--
-- Discovery runs on demand only (nothing polls in the background), so it is always as fresh
-- as the moment you send. Sources:
--   * Claude Code's own live registry (~/.claude/sessions/<pid>.json): name, cwd, busy/idle
--   * the process table: finds sessions of older Claude versions and, for every session, the
--     program that owns its terminal (Neovim, tmux, zellij, kitty, wezterm)
-- On Linux this is a /proc scan (a few ms, no subprocess). The only subprocesses are one
-- `tmux list-panes` per tmux server (and similar) when such sessions exist.
local util = require("relay.util")
local proc = require("relay.proc")
local config = require("relay.config")
local state = require("relay.state")

local M = {}

---@class relay.Session
---@field pid integer
---@field start string|nil
---@field tty string
---@field name string|nil
---@field cwd string|nil
---@field branch string|nil
---@field status string|nil       busy | idle | waiting | blocked | ...
---@field waiting_for string|nil
---@field updated number
---@field host string|nil         nvim | nvim_remote | tmux | zellij | kitty | wezterm
---@field addr table|nil          backend specific address
---@field where string|nil        human readable location
---@field title string|nil        terminal title, when known
---@field reachable boolean
---@field reason string|nil       why the session can't be reached

-- name of the process that owns a session's terminal -> backend
local HOSTS = {
  nvim = "nvim",
  ["tmux: server"] = "tmux",
  tmux = "tmux",
  zellij = "zellij",
  kitty = "kitty",
  wezterm = "wezterm",
  ["wezterm-gui"] = "wezterm",
  ["wezterm-mux-server"] = "wezterm",
  ["wezterm-mux-ser"] = "wezterm", -- Linux truncates process names to 15 bytes
}

-- `claude <subcommand>` invocations that have no interactive prompt
local NON_INTERACTIVE = {
  mcp = true,
  config = true,
  doctor = true,
  update = true,
  upgrade = true,
  install = true,
  plugin = true,
  plugins = true,
  ["migrate-installer"] = true,
  ["setup-token"] = true,
}

local STATUS_ICON = { busy = "●", idle = "○", waiting = "◐", blocked = "◐", stopped = "■", done = "✓" }

local function str(v)
  return type(v) == "string" and v ~= "" and v or nil
end

function M.claude_dir()
  local dir = config.options.claude_dir or vim.env.CLAUDE_CONFIG_DIR
  if not dir or dir == "" then
    dir = vim.fs.joinpath(util.uv.os_homedir(), ".claude")
  end
  return vim.fs.normalize(dir)
end

--- Sessions registered by Claude Code itself.
---@return table<integer, table> entries usable interactive sessions by pid
---@return table<integer, true> seen every live pid that has a registry entry
local function read_registry(procs)
  local entries, seen = {}, {}
  local dir = vim.fs.joinpath(M.claude_dir(), "sessions")
  local st = util.uv.fs_stat(dir)
  if not st or st.type ~= "directory" then
    return entries, seen
  end
  for name, typ in vim.fs.dir(dir) do
    local pid = tonumber(name:match("^(%d+)%.json$"))
    local p = pid and procs[pid]
    if p and typ == "file" then
      local ok, data = pcall(vim.json.decode, util.read_file(vim.fs.joinpath(dir, name)) or "")
      if ok and type(data) == "table" then
        -- a stale file whose pid now belongs to another process doesn't count
        local same = not (p.start and data.procStart ~= nil) or tostring(data.procStart) == p.start
        if same then
          seen[pid] = true
          local kind = str(data.kind)
          if (kind == nil or kind == "interactive") and data.spare ~= true then
            entries[pid] = data
          end
        end
      end
    end
  end
  return entries, seen
end

local function is_claude_name(name)
  return name == "claude" or name == "claude.exe"
end

---@param p relay.Proc
local function is_claude(p)
  if not (is_claude_name(p.comm) or p.comm == "node" or p.comm == "bun") then
    return false
  end
  local argv = proc.argv(p)
  if #argv == 0 then
    return false
  end
  local first = 2
  if not is_claude_name(vim.fs.basename(argv[1])) then
    -- `node .../@anthropic-ai/claude-code/cli.js`
    local script = argv[2] or ""
    if not (is_claude_name(vim.fs.basename(script)) or script:find("claude-code", 1, true)) then
      return false
    end
    first = 3
  end
  for i = first, #argv do
    if argv[i] == "-p" or argv[i] == "--print" then
      return false
    end
  end
  return not (argv[first] and NON_INTERACTIVE[argv[first]])
end

--- The program that owns a session's terminal is the first ancestor that is not attached to
--- that same terminal (a multiplexer server, a terminal emulator or Neovim). Also returns the
--- process it started on that terminal (usually the shell, or claude itself).
---@return relay.Proc|nil owner
---@return relay.Proc child
local function terminal_owner(p, procs)
  local child, cur = p, procs[p.ppid or -1]
  for _ = 1, 64 do
    if not cur then
      return nil, child
    end
    if cur.tty ~= p.tty then
      return cur, child
    end
    child, cur = cur, procs[cur.ppid or -1]
  end
  return nil, child
end

--- A claude process started by another claude on the same terminal is not a session.
local function is_nested(p, owner, procs)
  local cur = procs[p.ppid or -1]
  for _ = 1, 64 do
    if not cur or cur == owner then
      return false
    end
    if is_claude_name(cur.comm) then
      return true
    end
    cur = procs[cur.ppid or -1]
  end
  return false
end

local function add_job(jobs, key, cmd, opts, handler)
  local job = jobs[key]
  if not job then
    job = { cmd = cmd, opts = opts, handlers = {} }
    jobs[key] = job
  end
  table.insert(job.handlers, handler)
end

local resolvers = {}

---@param s relay.Session
function resolvers.nvim(s, p, owner, child)
  if owner.pid == vim.fn.getpid() then
    for _, chan in ipairs(vim.api.nvim_list_chans()) do
      if chan.mode == "terminal" and chan.buffer then
        local ok, job_pid = pcall(vim.fn.jobpid, chan.id)
        if ok and job_pid == child.pid then
          s.addr = { chan = chan.id, buf = chan.buffer }
          s.where = "nvim terminal #" .. chan.buffer
          local title = str(vim.b[chan.buffer].term_title)
          s.title = title and not title:find("^term://") and title or nil -- default title is the buffer name
          s.reachable = true
          return
        end
      end
    end
    s.reason = "its terminal buffer was not found"
    return
  end
  local server = str(proc.environ(p.pid).NVIM)
  if server then
    s.host = "nvim_remote"
    s.addr = { server = server, job_pid = child.pid }
    s.where = "nvim (pid " .. owner.pid .. ")"
    s.reachable = true
  else
    s.reason = "runs in another Neovim whose address is unknown"
  end
end

---@param s relay.Session
function resolvers.tmux(s, p, owner, _, jobs)
  local env = proc.environ(p.pid)
  local socket = env.TMUX and env.TMUX:match("^([^,]+)")
  local base = { proc.exe(owner) or "tmux" }
  if socket and socket ~= "" then
    vim.list_extend(base, { "-S", socket })
  end
  s.addr = { cmd = base }
  s.reason = "tmux pane not found"
  local cmd = vim.list_extend(vim.deepcopy(base), {
    "list-panes",
    "-a",
    "-F",
    "#{pane_id}\t#{pane_tty}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_title}",
  })
  local hostname = vim.fn.hostname()
  add_job(jobs, "tmux " .. table.concat(base, " "), cmd, nil, function(res)
    if not res.ok then
      s.reason = "tmux: " .. res.err
      return
    end
    for line in res.out:gmatch("[^\n]+") do
      local id, tty, loc, title = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$")
      if id and tty == s.tty then
        s.addr.pane = id
        s.where = "tmux " .. loc
        s.title = title ~= hostname and str(title) or nil
        s.reachable = true
        s.reason = nil
        return
      end
    end
  end)
end

---@param s relay.Session
function resolvers.zellij(s, p, owner, _, jobs)
  local argv = proc.argv(owner)
  local socket
  for i, a in ipairs(argv) do
    if a == "--server" then
      socket = argv[i + 1]
    end
  end
  local env = proc.environ(p.pid)
  local session = str(env.ZELLIJ_SESSION_NAME) or (socket and vim.fs.basename(socket))
  local pane = str(env.ZELLIJ_PANE_ID)
  if not session or not pane then
    s.reason = "zellij pane unknown"
    return
  end
  local exe = proc.exe(owner) or "zellij"
  s.addr = { exe = exe, session = session, pane = pane }
  s.where = ("zellij %s/%s"):format(session, pane)
  -- each server lives in a versioned socket dir: .../zellij/<version>/<session>
  local major, minor = (socket or ""):match("/(%d+)%.(%d+)%.%d+[^/]*/[^/]+$")
  major, minor = tonumber(major), tonumber(minor)
  if not major or major > 0 or minor >= 44 then
    s.addr.mode = "pane" -- `action paste --pane-id` (zellij 0.44+)
    s.reachable = true
    return
  end
  -- Older zellij can only type into the focused pane. With one client attached, Relay moves
  -- that client's focus to the pane while typing ("cycle"); with several, only when they all
  -- focus it already.
  s.reason = ("nobody is attached to zellij session %s (zellij %d.%d can only type into a focused pane)"):format(
    session,
    major,
    minor
  )
  local cmd = { exe, "--session", session, "action", "list-clients" }
  add_job(jobs, "zellij " .. exe .. " " .. session, cmd, nil, function(res)
    if not res.ok then
      s.reason = "zellij: " .. res.err
      return
    end
    local clients, focused = 0, 0
    for line in res.out:gmatch("[^\n]+") do
      local id, focus = line:match("^%s*(%d+)%s+(%S+)")
      if id then
        clients = clients + 1
        if focus == "terminal_" .. pane then
          focused = focused + 1
        end
      end
    end
    if clients == 1 then
      s.addr.mode = "cycle"
    elseif clients > 1 and focused == clients then
      s.addr.mode = "focused"
    elseif clients > 1 then
      s.reason = ("zellij session %s is attached in %d windows; zellij %d.%d can't pick a pane then (0.44+ can)"):format(
        session,
        clients,
        major,
        minor
      )
      return
    else
      return
    end
    s.reachable = true
    s.reason = nil
  end)
end

---@param s relay.Session
function resolvers.kitty(s, p, owner)
  local env = proc.environ(p.pid)
  local win, to = str(env.KITTY_WINDOW_ID), str(env.KITTY_LISTEN_ON)
  if not win then
    s.reason = "kitty window unknown"
    return
  end
  if not to then
    s.reason = "kitty remote control is off (set allow_remote_control and listen_on)"
    return
  end
  s.addr = { exe = proc.exe(owner) or "kitty", to = to, win = win }
  s.where = "kitty window " .. win
  s.reachable = true
end

---@param s relay.Session
function resolvers.wezterm(s, p, owner, _, jobs)
  local env = proc.environ(p.pid)
  local exe = "wezterm"
  local owner_exe = proc.exe(owner)
  if owner_exe then
    local cli = vim.fs.joinpath(vim.fs.dirname(owner_exe), "wezterm")
    if vim.fn.executable(cli) == 1 then
      exe = cli
    end
  end
  local socket = str(env.WEZTERM_UNIX_SOCKET)
  s.addr = { exe = exe, env = socket and { WEZTERM_UNIX_SOCKET = socket } or nil, pane = str(env.WEZTERM_PANE) }
  if s.addr.pane then
    s.where = "wezterm pane " .. s.addr.pane
    s.reachable = true
    return
  end
  s.reason = "wezterm pane not found"
  local cmd = { exe, "cli", "list", "--format", "json" }
  add_job(jobs, "wezterm " .. exe .. " " .. (socket or ""), cmd, { env = s.addr.env }, function(res)
    local ok, panes = pcall(vim.json.decode, res.ok and res.out or "")
    if not ok or type(panes) ~= "table" then
      return
    end
    for _, pane in ipairs(panes) do
      if type(pane) == "table" and pane.tty_name == s.tty and pane.pane_id ~= nil then
        s.addr.pane = tostring(pane.pane_id)
        s.where = "wezterm pane " .. s.addr.pane
        s.title = str(pane.title)
        s.reachable = true
        s.reason = nil
        return
      end
    end
  end)
end

---@return relay.Session
local function build(p, procs, reg, owner, child, jobs)
  local s = {
    pid = p.pid,
    start = p.start,
    tty = p.tty,
    name = reg and str(reg.name),
    cwd = reg and str(reg.cwd) or proc.cwd(p.pid),
    status = reg and str(reg.status),
    waiting_for = reg and str(reg.waitingFor),
    updated = reg and tonumber(reg.statusUpdatedAt or reg.updatedAt) or 0,
    reachable = false,
  }
  s.branch = util.git_branch(s.cwd)
  local host = owner and HOSTS[owner.comm]
  if not host then
    s.reason = owner and ("runs in %s, which Relay can't type into"):format(owner.comm) or "no terminal found"
    return s
  end
  if config.options.backends[host] == false then
    s.where = host
    s.reason = host .. " backend is disabled"
    return s
  end
  s.host = host
  resolvers[host](s, p, owner, child, jobs)
  if s.host == "nvim_remote" and config.options.backends.nvim == false then
    s.reachable = false
    s.reason = "nvim backend is disabled"
  end
  return s
end

--- Order for pickers: reachable sessions first, then the one used last, then the session
--- working closest to what you're editing (the deepest cwd containing it), then most recent.
---@param list relay.Session[]
function M.sort(list)
  local cwd = util.realpath(vim.fn.getcwd())
  local file = util.realpath(vim.api.nvim_buf_get_name(0))
  local function relevance(s)
    local base = s.cwd and util.realpath(s.cwd)
    if not base then
      return 0
    end
    if (file and util.relpath(base, file)) or base == cwd or util.relpath(base, cwd) then
      return #base
    end
    return 0
  end
  local key = {}
  for _, s in ipairs(list) do
    key[s] = { s.reachable and 1 or 0, s.pid == state.last_pid and 1 or 0, relevance(s), s.updated or 0, -s.pid }
  end
  table.sort(list, function(a, b)
    local ka, kb = key[a], key[b]
    for i = 1, #ka do
      if ka[i] ~= kb[i] then
        return ka[i] > kb[i]
      end
    end
    return false
  end)
end

--- Find all running Claude Code sessions. `cb(list)` runs on the main loop.
---@param cb fun(list: relay.Session[])
function M.discover(cb)
  proc.snapshot(function(procs)
    local registry, seen = read_registry(procs)
    local jobs, list = {}, {}
    for pid, data in pairs(registry) do
      local p = procs[pid]
      if p.tty then
        local owner, child = terminal_owner(p, procs)
        list[#list + 1] = build(p, procs, data, owner, child, jobs)
      end
    end
    for pid, p in pairs(procs) do
      if not seen[pid] and p.tty and is_claude(p) then
        local owner, child = terminal_owner(p, procs)
        if not is_nested(p, owner, procs) then
          list[#list + 1] = build(p, procs, nil, owner, child, jobs)
        end
      end
    end
    local run = {}
    for key, job in pairs(jobs) do
      run[key] = { cmd = job.cmd, opts = vim.tbl_extend("force", { timeout = 1500 }, job.opts or {}) }
    end
    util.run_all(run, function(results)
      for key, job in pairs(jobs) do
        for _, handler in ipairs(job.handlers) do
          handler(results[key])
        end
      end
      M.sort(list)
      cb(list)
    end)
  end)
end

---@param s relay.Session
function M.short(s)
  return s.name or (s.cwd and vim.fs.basename(s.cwd)) or ("claude " .. s.pid)
end

--- One line for pickers, most telling parts first:
--- "○ idle  api-refactor [feat/x]  tmux main:1.0  ~/code/api-wt"
---@param s relay.Session
function M.label(s)
  local status = s.status or "live"
  if s.waiting_for then
    status = status .. ":" .. s.waiting_for
  end
  local name = M.short(s) .. (s.branch and (" [" .. s.branch .. "]") or "")
  local where = (s.where or s.host or "unknown terminal") .. (s.reachable and "" or " ⊘")
  local parts = { (STATUS_ICON[s.status] or "·") .. " " .. status, name, where }
  if s.title then
    parts[#parts + 1] = "“" .. util.truncate(s.title, 32) .. "”"
  end
  if s.cwd then
    parts[#parts + 1] = util.truncate_left(util.home(s.cwd), 40)
  end
  if not s.reachable then
    parts[#parts + 1] = "— clipboard only: " .. (s.reason or "can't be reached")
  end
  return table.concat(parts, "  ")
end

---@param list relay.Session[]
---@return relay.Session|nil
function M.find(list, pid, start)
  for _, s in ipairs(list) do
    if s.pid == pid and (start == nil or s.start == nil or s.start == start) then
      return s
    end
  end
end

return M

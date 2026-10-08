-- Starts an agent session in a Neovim terminal, and waits until it can take a message.
--
-- Claude Code is ready once it has registered itself in its session registry, which it does
-- only when its prompt is up (not while the trust dialog is open). Codex and Copilot publish
-- nothing, so for them readiness is a guess: bracketed paste is on, the output has settled and
-- no startup screen waits for a key. Those screens matter because Enter picks their default
-- option, which can be "No, exit" (Claude's trust dialog) or "Update now" (Codex), so Enter is
-- never pressed for a session that was only guessed to be ready.
local util = require("relay.util")
local config = require("relay.config")
local agents = require("relay.agents")
local sessions = require("relay.sessions")

local M = {}

local POLL = 150 -- ms between readiness checks
local QUIET = 400 -- ms without output that count as settled
local NOISY = 3000 -- ms after bracketed paste went on: output that never settles (a spinner) is fine
local CLAUDE_GRACE = 5000 -- ms to wait for Claude's registry entry (older versions write none)
local TIMEOUT = 60000
local MIN_WIDTH = 50 -- agents' prompts get cramped below this (unless that's over half the editor)

-- the footer of a startup screen that waits for a key (lowercase)
local PROMPTS = { "enter to continue", "enter to confirm", "enter to select" }

---@param id string
---@return string|string[]|nil
function M.command(id)
  local launch = config.options.launch
  return launch and launch.cmd and launch.cmd[id] or nil
end

--- The program that starts the agent (nil when it isn't offered).
---@param id string
---@return string|nil
function M.program(id)
  local cmd = M.command(id)
  return type(cmd) == "table" and cmd[1] or (type(cmd) == "string" and cmd:match("^%s*(%S+)")) or nil
end

local function installed(id)
  local exe = M.program(id)
  return exe ~= nil and vim.fn.executable(exe) == 1
end

--- Agents that can be started here: enabled, with their command on PATH.
---@return relay.Agent[]
function M.available()
  local out = {}
  if not config.options.launch then
    return out
  end
  for _, a in ipairs(agents.list) do
    if config.options.agents[a.id] ~= false and installed(a.id) then
      out[#out + 1] = a
    end
  end
  return out
end

--- Open the window for the agent's terminal (and enter it).
---@param buf integer
local function open_window(buf, launch)
  if launch.split == "tab" then
    vim.cmd("tab sbuffer " .. buf)
    return vim.api.nvim_get_current_win()
  end
  local split = launch.split or "right"
  local vertical = split == "left" or split == "right"
  local total = vertical and vim.o.columns or (vim.o.lines - vim.o.cmdheight - 1)
  local size = tonumber(launch.size) or 0
  if size <= 0 then
    size = 0.35
  end
  size = size < 1 and math.floor(total * size) or math.floor(size)
  if vertical then
    size = math.max(size, math.min(MIN_WIDTH, math.floor(total / 2)))
  end
  local win = vim.api.nvim_open_win(buf, true, {
    split = split,
    win = -1,
    width = vertical and size or nil,
    height = not vertical and size or nil,
  })
  -- keep its size when other windows open or close
  vim.wo[win][vertical and "winfixwidth" or "winfixheight"] = true
  return win
end

--- Whether the bottom of the terminal shows a screen that waits for a key.
local function prompting(buf)
  local count = vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, math.max(0, count - 100), count, false)
  local seen = 0
  for i = #lines, 1, -1 do
    local line = lines[i]:lower()
    if line:find("%S") then
      for _, p in ipairs(PROMPTS) do
        if line:find(p, 1, true) then
          return true
        end
      end
      seen = seen + 1
      if seen == 3 then
        break
      end
    end
  end
  return false
end

--- Open a terminal running the agent. With `cb`, wait until it is ready (or, with
--- `wait = "found"`, until it can be discovered) and call `cb(session)`, or `cb(nil, why)`
--- when it exits or times out first. The session is marked `fresh` when its readiness was only
--- guessed.
---@param agent relay.Agent
---@param opts { wait?: "ready"|"found", enter?: boolean }
---@param cb? fun(s: relay.Session|nil, why: string|nil)
function M.start(agent, opts, cb)
  local function fail(why)
    if cb then
      cb(nil, why)
    else
      util.warn(why)
    end
  end
  if not installed(agent.id) then
    return fail(("%s can't be started: `%s` is not on PATH"):format(agent.label, M.program(agent.id) or "?"))
  end
  local cmd = M.command(agent.id)
  local launch = config.options.launch or {}
  local cwd = vim.fn.getcwd()
  local origin = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, false)
  local win = open_window(buf, launch)

  local term = { paste_at = nil, output = vim.uv.now(), tail = "", exited = nil }
  local job = {
    cwd = cwd,
    on_stdout = function(_, data)
      local text = term.tail .. table.concat(data, "\n")
      -- the last switch wins: 2004h turns bracketed paste on, 2004l off
      local on, off = text:match(".*()\27%[%?2004h"), text:match(".*()\27%[%?2004l")
      if on and on > (off or 0) then
        term.paste_at = vim.uv.now()
      elseif off then
        term.paste_at = nil
      end
      term.tail = text:sub(-7) -- a switch split across two chunks
      term.output = vim.uv.now()
    end,
    on_exit = function(_, code)
      term.exited = code
    end,
  }
  local ok, chan = pcall(function()
    if vim.fn.has("nvim-0.11") == 1 then
      return vim.fn.jobstart(cmd, vim.tbl_extend("force", job, { term = true }))
    end
    return vim.fn.termopen(cmd, job)
  end)
  if not ok or type(chan) ~= "number" or chan <= 0 then
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.api.nvim_set_current_win, origin)
    return fail(("Starting %s failed (%s)"):format(agent.label, ok and "invalid command" or tostring(chan)))
  end
  local enter = opts.enter
  if enter == nil then
    enter = config.options.focus ~= false
  end
  if enter then
    vim.cmd.startinsert()
  else
    vim.api.nvim_set_current_win(origin)
  end
  util.info(("Starting %s in %s"):format(agent.label, util.home(cwd)))
  if not cb then
    return
  end

  local started, told = vim.uv.now(), false
  --- "registered" when the agent said its prompt is up, "guessed" when it looks ready
  ---@return "registered"|"guessed"|nil
  local function readiness(s)
    if s.status then
      return "registered" -- Claude only registers once its prompt is up
    end
    if opts.wait == "found" then
      return "guessed"
    end
    local now = vim.uv.now()
    if prompting(buf) then
      if not told then
        told = true
        util.info(("%s is waiting for an answer in its window; the message follows once it's ready"):format(agent.label))
      end
      return nil
    end
    if not term.paste_at or (agent.id == "claude" and now - started < CLAUDE_GRACE) then
      return nil
    end
    if now - term.output >= QUIET or now - term.paste_at >= NOISY then
      return "guessed"
    end
  end

  local function check()
    if term.exited then
      return cb(nil, ("%s exited before it was ready"):format(agent.label))
    end
    if vim.uv.now() - started > TIMEOUT then
      return cb(nil, ("%s wasn't ready after %ds"):format(agent.label, TIMEOUT / 1000))
    end
    sessions.discover(function(list)
      if term.exited then
        return check()
      end
      for _, s in ipairs(list) do
        if s.host == "nvim" and s.addr and s.addr.buf == buf then
          local r = readiness(s)
          if r then
            s.fresh = r == "guessed" or nil
            return cb(s)
          end
          break
        end
      end
      vim.defer_fn(check, POLL)
    end)
  end
  vim.defer_fn(check, POLL)
end

return M

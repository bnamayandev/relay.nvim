-- Delivers text into a session's prompt. Text is always sent as a bracketed paste, so Claude
-- Code inserts it literally (no slash commands, no @ autocomplete, newlines don't submit).
local util = require("relay.util")
local config = require("relay.config")

local M = {}

local PASTE_START, PASTE_END = "\27[200~", "\27[201~"
-- zellij takes the text as a command line argument; stay well below Linux' 128 KiB limit
local ZELLIJ_CHUNK = 96 * 1024

--- Strip control characters so nothing in a snippet can end the paste early or act as a key
--- press. Tabs and newlines are kept.
---@param text string
function M.sanitize(text)
  text = text:gsub("\r\n?", "\n")
  text = text:gsub("[%z\1-\8\11-\31\127]", "")
  text = text:gsub("\194[\128-\159]", "") -- C1 controls (UTF-8 encoded)
  return text
end

function M.bracketed(text)
  return PASTE_START .. text .. PASTE_END
end

--- Split text into pieces of at most `size` bytes, preferring line boundaries and never
--- splitting a UTF-8 sequence.
function M.chunks(text, size)
  local out, i = {}, 1
  while i <= #text do
    local j = math.min(i + size - 1, #text)
    if j < #text then
      local nl = text:sub(i, j):match(".*()\n")
      if nl and nl > 1 then
        j = i + nl - 1
      else
        while j > i and text:byte(j + 1) and text:byte(j + 1) >= 128 and text:byte(j + 1) < 192 do
          j = j - 1
        end
      end
    end
    out[#out + 1] = text:sub(i, j)
    i = j + 1
  end
  return out
end

local function run(cmd, opts, cb)
  util.run(cmd, opts, function(ok, _, err)
    cb(ok, err)
  end)
end

local function concat(a, b)
  return vim.list_extend(vim.deepcopy(a), b)
end

---@type table<string, { send: fun(s, text, cb), submit: fun(s, cb), focus: fun(s) }>
local backends = {}

backends.nvim = {
  send = function(s, text, cb)
    local ok, err = pcall(vim.api.nvim_chan_send, s.addr.chan, M.bracketed(text))
    cb(ok, not ok and tostring(err) or nil)
  end,
  submit = function(s, cb)
    local ok, err = pcall(vim.api.nvim_chan_send, s.addr.chan, "\r")
    cb(ok, not ok and tostring(err) or nil)
  end,
  focus = function(s)
    local buf = s.addr.buf
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local win = vim.fn.win_findbuf(buf)[1]
    if win then
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd("botright vsplit")
      vim.api.nvim_win_set_buf(0, buf)
    end
    vim.cmd.startinsert()
  end,
}

-- A terminal in another Neovim instance: ask that instance (over RPC) to write into it.
-- Fire-and-forget notifications, so a busy remote instance can never block this one.
local REMOTE = [[
local job_pid, data, submit, delay, focus = ...
for _, c in ipairs(vim.api.nvim_list_chans()) do
  if c.mode == "terminal" and c.buffer then
    local ok, pid = pcall(vim.fn.jobpid, c.id)
    if ok and pid == job_pid then
      if data ~= "" then vim.api.nvim_chan_send(c.id, data) end
      if submit then
        vim.defer_fn(function() pcall(vim.api.nvim_chan_send, c.id, "\r") end, delay)
      end
      if focus then
        local win = vim.fn.win_findbuf(c.buffer)[1]
        if win then vim.api.nvim_set_current_win(win) end
      end
      return
    end
  end
end
]]

local function remote_notify(s, text, submit, focus, cb)
  local server = s.addr.server
  local mode = (server:find("/", 1, true) or server:find("\\", 1, true)) and "pipe" or "tcp"
  local ok, chan = pcall(vim.fn.sockconnect, mode, server, { rpc = true })
  if not ok or not chan or chan == 0 then
    return cb(false, "can't connect to " .. server)
  end
  local sent, err = pcall(vim.rpcnotify, chan, "nvim_exec_lua", REMOTE, {
    s.addr.job_pid,
    text and M.bracketed(text) or "",
    submit,
    config.options.submit_delay,
    focus,
  })
  vim.defer_fn(function()
    pcall(vim.fn.chanclose, chan)
  end, 1000)
  cb(sent, not sent and tostring(err) or nil)
end

backends.nvim_remote = {
  -- submit/focus are folded into the single notification
  send = function(s, text, cb, opts)
    remote_notify(s, text, opts.submit, opts.focus, cb)
  end,
  submit = function(_, cb)
    cb(true)
  end,
  focus = function() end,
  combined = true,
}

backends.tmux = {
  send = function(s, text, cb)
    local name = "relay-" .. vim.fn.getpid()
    run(concat(s.addr.cmd, { "load-buffer", "-b", name, "-" }), { stdin = text }, function(ok, err)
      if not ok then
        return cb(false, err)
      end
      -- -p: bracketed paste, -r: keep newlines as LF, -d: delete the buffer afterwards
      run(concat(s.addr.cmd, { "paste-buffer", "-p", "-r", "-d", "-b", name, "-t", s.addr.pane }), nil, cb)
    end)
  end,
  submit = function(s, cb)
    run(concat(s.addr.cmd, { "send-keys", "-t", s.addr.pane, "Enter" }), nil, cb)
  end,
  focus = function(s)
    local cmd = s.addr.cmd
    run(concat(cmd, { "select-window", "-t", s.addr.pane }), nil, function()
      run(concat(cmd, { "select-pane", "-t", s.addr.pane }), nil, function()
        -- when Neovim itself runs in a client of that server, bring the client over too
        if vim.env.TMUX and vim.env.TMUX ~= "" then
          run(concat(cmd, { "switch-client", "-t", s.addr.pane }), nil, function() end)
        end
      end)
    end)
  end,
}

local function zellij(s, args)
  return concat({ s.addr.exe, "--session", s.addr.session, "action" }, args)
end

--- zellij < 0.44 types into the focused pane: make sure that is still the session's pane.
local function zellij_still_focused(s, cb)
  util.run(zellij(s, { "list-clients" }), nil, function(ok, out)
    local clients, focused = 0, 0
    for line in (ok and out or ""):gmatch("[^\n]+") do
      local id, pane = line:match("^%s*(%d+)%s+(%S+)")
      if id then
        clients = clients + 1
        focused = focused + (pane == "terminal_" .. s.addr.pane and 1 or 0)
      end
    end
    cb(clients > 0 and focused == clients)
  end)
end

backends.zellij = {
  send = function(s, text, cb)
    if s.addr.mode == "focused" then
      return zellij_still_focused(s, function(focused)
        if not focused then
          return cb(false, "its pane is no longer focused (zellij < 0.44 can only type into the focused pane)")
        end
        run(zellij(s, { "write-chars", "--", M.bracketed(text) }), nil, cb)
      end)
    end
    local pieces = M.chunks(text, ZELLIJ_CHUNK)
    local function step(i)
      if i > #pieces then
        return cb(true)
      end
      run(zellij(s, { "paste", "--pane-id", "terminal_" .. s.addr.pane, "--", pieces[i] }), nil, function(ok, err)
        if not ok then
          return cb(false, err)
        end
        step(i + 1)
      end)
    end
    step(1)
  end,
  submit = function(s, cb)
    if s.addr.mode == "focused" then
      return run(zellij(s, { "write", "13" }), nil, cb)
    end
    run(zellij(s, { "send-keys", "--pane-id", "terminal_" .. s.addr.pane, "Enter" }), nil, cb)
  end,
  focus = function(s)
    if s.addr.mode == "pane" then
      run(zellij(s, { "focus-pane-id", "terminal_" .. s.addr.pane }), nil, function() end)
    end
  end,
}

local function kitty(s, args)
  return concat({ s.addr.exe, "@", "--to", s.addr.to }, args)
end

backends.kitty = {
  send = function(s, text, cb)
    run(kitty(s, { "send-text", "--match", "id:" .. s.addr.win, "--stdin" }), { stdin = M.bracketed(text) }, cb)
  end,
  submit = function(s, cb)
    run(kitty(s, { "send-text", "--match", "id:" .. s.addr.win, "--stdin" }), { stdin = "\r" }, cb)
  end,
  focus = function(s)
    run(kitty(s, { "focus-window", "--match", "id:" .. s.addr.win }), nil, function() end)
  end,
}

local function wezterm(s, args)
  return concat({ s.addr.exe, "cli" }, args)
end

backends.wezterm = {
  send = function(s, text, cb)
    local cmd = wezterm(s, { "send-text", "--pane-id", s.addr.pane, "--no-paste" })
    run(cmd, { stdin = M.bracketed(text), env = s.addr.env }, cb)
  end,
  submit = function(s, cb)
    local cmd = wezterm(s, { "send-text", "--pane-id", s.addr.pane, "--no-paste" })
    run(cmd, { stdin = "\r", env = s.addr.env }, cb)
  end,
  focus = function(s)
    run(wezterm(s, { "activate-pane", "--pane-id", s.addr.pane }), { env = s.addr.env }, function() end)
  end,
}

--- Paste `text` into the session's prompt.
---@param s relay.Session
---@param text string
---@param opts { submit: boolean, focus: boolean }
---@param cb fun(ok: boolean, err: string|nil)
function M.send(s, text, opts, cb)
  local backend = backends[s.host or ""]
  if not backend or not s.reachable then
    return cb(false, s.reason or "no way to reach this session")
  end
  text = M.sanitize(text)
  backend.send(s, text, function(ok, err)
    if not ok then
      return cb(false, err)
    end
    local function done()
      if opts.focus and not backend.combined then
        backend.focus(s)
      end
      cb(true)
    end
    if not opts.submit or backend.combined then
      return done()
    end
    vim.defer_fn(function()
      backend.submit(s, function(sub_ok, sub_err)
        if not sub_ok then
          util.warn("Pasted, but pressing Enter failed: " .. (sub_err or "?"))
        end
        done()
      end)
    end, config.options.submit_delay)
  end, opts)
end

--- Switch to the session's pane/window.
---@param s relay.Session
function M.focus(s)
  local backend = backends[s.host or ""]
  if not backend or not s.reachable then
    return false
  end
  if s.host == "nvim_remote" then
    remote_notify(s, nil, false, true, function() end)
  else
    backend.focus(s)
  end
  return true
end

return M

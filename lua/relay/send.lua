-- Resolving a target session and delivering messages to it.
local config = require("relay.config")
local util = require("relay.util")
local state = require("relay.state")
local queue = require("relay.queue")
local format = require("relay.format")
local sessions = require("relay.sessions")
local transport = require("relay.transport")

local M = {}

local function copy(text, why)
  local system = util.copy(text)
  local where = system and "the clipboard" or 'register "'
  if why then
    util.warn(("%s, so the message was copied to %s"):format(why, where))
  else
    util.info("Message copied to " .. where)
  end
end

--- Entries that start an agent are highlighted in pickers that take highlighted chunks (snacks
--- calls `format_item(item, true)`); others get the plain text.
local function highlight_new(text, chunks)
  if chunks == true then
    return { { text, "RelayNewAgent" } }
  end
  return text
end

---@alias relay.Choice { session?: relay.Session, launch?: relay.Agent, clipboard?: boolean, unpin?: boolean }

--- Second step of "New agent…": which installed agent to start.
---@param agents relay.Agent[]
---@param cb fun(choice: relay.Choice|nil)
local function pick_agent(agents, cb)
  vim.ui.select(agents, {
    prompt = "Start in Neovim · " .. util.home(vim.fn.getcwd()),
    kind = "relay.agent",
    format_item = function(a, chunks)
      return highlight_new("󰐕  " .. a.label, chunks)
    end,
  }, function(a)
    cb(a and { launch = a } or nil)
  end)
end

--- With sessions to choose from, the agents in `opts.launch` fold into one "New agent…" entry
--- at the bottom that expands into them; without, they are listed right away.
---@param list relay.Session[]
---@param opts { prompt?: string, clipboard?: boolean, unpin?: boolean, launch?: relay.Agent[] }
---@param cb fun(choice: relay.Choice|nil)
function M.pick(list, opts, cb)
  local agents = opts.launch or {}
  local entries = {}
  for _, s in ipairs(list) do
    entries[#entries + 1] = { session = s }
  end
  if #list == 0 then
    for _, a in ipairs(agents) do
      entries[#entries + 1] = { launch = a }
    end
  end
  if opts.clipboard then
    entries[#entries + 1] = { clipboard = true }
  end
  if opts.unpin then
    entries[#entries + 1] = { unpin = true }
  end
  if #list > 0 and #agents > 0 then
    entries[#entries + 1] = { new = true }
  end
  vim.ui.select(entries, {
    prompt = opts.prompt or "Send to session",
    kind = "relay.session",
    format_item = function(e, chunks)
      if e.new then
        return highlight_new("󰐕  New agent…", chunks)
      elseif e.launch then
        return highlight_new(("󰐕  Start %s in Neovim  %s"):format(e.launch.label, util.home(vim.fn.getcwd())), chunks)
      elseif e.clipboard then
        return "󰆏  Copy to clipboard"
      elseif e.unpin then
        return "󰐄  Unpin " .. (state.pinned and state.pinned.label or "target")
      end
      return sessions.label(e.session)
    end,
  }, function(choice)
    if choice and choice.new then
      return pick_agent(agents, cb)
    end
    cb(choice)
  end)
end

local NO_SESSION = "No running agent session found (Claude Code, Codex, Copilot)"

--- Agents that can be started (see relay.launch), offered in every picker.
---@return relay.Agent[]
local function startable()
  return require("relay.launch").available()
end

---@param list relay.Session[]
local function open_in_nvim(list)
  for _, s in ipairs(list) do
    if s.host == "nvim" then
      return true
    end
  end
  return false
end

---@param list relay.Session[]
---@param agents relay.Agent[]
---@param what string
local function prompt(list, agents, what)
  if #agents == 0 or open_in_nvim(list) then
    return what
  end
  return what .. (#list == 0 and " · none is running, start one" or " · none is open in Neovim")
end

--- Start `agent` in a Neovim terminal and wait for it (see relay.launch).
---@param cb fun(target: relay.Session|false, why: string|nil)
local function start(agent, wait, cb)
  require("relay.launch").start(agent, { wait = wait }, function(s, why)
    cb(s or false, why)
  end)
end

--- Decide where to send: the pinned session, the only session, or ask (the picker can also
--- start a new agent). While no session is open in this Neovim, it always asks.
---@param opts { pick?: boolean }
---@param cb fun(target: relay.Session|false|nil, why: string|nil)  false = clipboard, nil = cancelled
function M.resolve(opts, cb)
  sessions.discover(function(list)
    local pinned = state.pinned
    if pinned and not opts.pick then
      local s = sessions.find(list, pinned.pid, pinned.start)
      if s and s.reachable then
        return cb(s)
      end
      state.pinned = nil
      queue.emit()
      util.warn(("Pinned session %s %s — unpinned"):format(pinned.label, s and "can't be reached" or "has ended"))
    end
    local agents = startable()
    if #list == 0 and #agents == 0 then
      return cb(false, NO_SESSION)
    end
    if #list == 1 and not opts.pick and (#agents == 0 or open_in_nvim(list)) then
      return cb(list[1])
    end
    local title = prompt(list, agents, "Send to session")
    M.pick(list, { prompt = title, launch = agents, clipboard = true }, function(choice)
      if not choice then
        return cb(nil)
      end
      if choice.launch then
        return start(choice.launch, "ready", cb)
      end
      cb(choice.session or false)
    end)
  end)
end

local function focus_after(opts, submit)
  local focus = opts.focus
  if focus == nil then
    focus = config.options.focus
  end
  if focus == "auto" then
    return not submit
  end
  return focus == true
end

--- Send snippets (the queue by default) to an agent session.
---@param opts? { items?: relay.Item[], message?: string, pick?: boolean, submit?: boolean, focus?: boolean|"auto", on_sent?: fun() }
function M.send(opts)
  opts = opts or {}
  local from_queue = opts.items == nil
  local items = opts.items or queue.items()
  if #items == 0 and vim.trim(opts.message or "") == "" then
    util.warn("Nothing to send: the queue is empty")
    return
  end
  M.resolve(opts, function(target, why)
    if target == nil then
      return
    end
    if from_queue then
      queue.refresh_all()
      items = queue.items()
    end
    local cwd = target and target.cwd or vim.fn.getcwd()
    local text = format.build(items, { cwd = cwd, message = opts.message })
    if target == false then
      if why and not config.options.clipboard_fallback then
        return util.error(why)
      end
      return copy(text, why)
    end
    if not target.reachable then
      local reason = ("%s %s"):format(sessions.short(target), target.reason or "can't be reached")
      if not config.options.clipboard_fallback then
        return util.error(reason)
      end
      return copy(text, reason)
    end
    local submit = opts.submit
    if submit == nil then
      submit = config.options.submit
    end
    -- a session that just started may still show a startup screen, where Enter picks an option
    local held = submit and target.fresh
    if held then
      submit = false
    end
    transport.send(target, text, { submit = submit, focus = focus_after(opts, submit) }, function(ok, err)
      if not ok then
        local reason = ("Sending to %s failed (%s)"):format(sessions.short(target), err or "?")
        if config.options.clipboard_fallback then
          return copy(text, reason)
        end
        return util.error(reason)
      end
      state.last_pid = target.pid
      state.last_cwd = target.cwd
      local what = #items > 0 and util.plural(#items, "snippet") or "message"
      local note = submit and " (submitted)" or held and " (not submitted: it just started, press Enter there)" or ""
      util.info(("%s %s → %s%s"):format(config.options.ui.icon, what, sessions.short(target), note))
      if from_queue and config.options.clear_on_send and #items > 0 then
        queue.clear()
      end
      if opts.on_sent then
        opts.on_sent()
      end
    end)
  end)
end

---@param s relay.Session
local function pin(s)
  if not s.reachable then
    return util.warn(("%s can't be reached: %s"):format(sessions.short(s), s.reason or "?"))
  end
  state.pinned = { pid = s.pid, start = s.start, label = sessions.short(s), cwd = s.cwd }
  util.info("Pinned " .. state.pinned.label)
  queue.emit()
end

--- Pin the session sends go to (skips the picker), or unpin.
function M.pin()
  sessions.discover(function(list)
    local agents = startable()
    if #list == 0 and #agents == 0 and not state.pinned then
      return util.warn(NO_SESSION)
    end
    local title = prompt(list, agents, "Pin session")
    M.pick(list, { prompt = title, unpin = state.pinned ~= nil, launch = agents }, function(choice)
      if not choice then
        return
      end
      if choice.launch then
        return start(choice.launch, "found", function(s, why)
          if s then
            pin(s)
          else
            util.warn(why or "?")
          end
        end)
      end
      if choice.unpin then
        state.pinned = nil
        util.info("Unpinned: sends will ask which session to use")
        queue.emit()
        return
      end
      pin(choice.session)
    end)
  end)
end

--- Pick a running session and switch to it.
function M.jump()
  sessions.discover(function(list)
    local agents = startable()
    if #list == 0 and #agents == 0 then
      return util.warn(NO_SESSION)
    end
    M.pick(list, { prompt = prompt(list, agents, "Jump to session"), launch = agents }, function(choice)
      if choice and choice.launch then
        return require("relay.launch").start(choice.launch, { enter = true })
      end
      if not (choice and choice.session) then
        return
      end
      if not transport.focus(choice.session) then
        util.warn(("Can't switch to %s: %s"):format(sessions.short(choice.session), choice.session.reason or "?"))
      end
    end)
  end)
end

return M

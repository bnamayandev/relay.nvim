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

---@param list relay.Session[]
---@param opts { prompt?: string, clipboard?: boolean, unpin?: boolean }
---@param cb fun(choice: { session?: relay.Session, clipboard?: boolean, unpin?: boolean }|nil)
function M.pick(list, opts, cb)
  local entries = {}
  for _, s in ipairs(list) do
    entries[#entries + 1] = { session = s }
  end
  if opts.clipboard then
    entries[#entries + 1] = { clipboard = true }
  end
  if opts.unpin then
    entries[#entries + 1] = { unpin = true }
  end
  vim.ui.select(entries, {
    prompt = opts.prompt or "Send to session",
    kind = "relay.session",
    format_item = function(e)
      if e.clipboard then
        return "󰆏  Copy to clipboard"
      elseif e.unpin then
        return "󰐄  Unpin " .. (state.pinned and state.pinned.label or "target")
      end
      return sessions.label(e.session)
    end,
  }, function(choice)
    cb(choice)
  end)
end

--- Decide where to send: the pinned session, the only session, or ask.
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
    if #list == 0 then
      return cb(false, "No running agent session found (Claude Code, Codex, Copilot)")
    end
    if #list == 1 and not opts.pick then
      return cb(list[1])
    end
    M.pick(list, { clipboard = true }, function(choice)
      if not choice then
        return cb(nil)
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
      util.info(("%s %s → %s%s"):format(config.options.ui.icon, what, sessions.short(target), submit and " (submitted)" or ""))
      if from_queue and config.options.clear_on_send and #items > 0 then
        queue.clear()
      end
      if opts.on_sent then
        opts.on_sent()
      end
    end)
  end)
end

--- Pin the session sends go to (skips the picker), or unpin.
function M.pin()
  sessions.discover(function(list)
    if #list == 0 and not state.pinned then
      return util.warn("No running agent session found")
    end
    M.pick(list, { prompt = "Pin session", unpin = state.pinned ~= nil }, function(choice)
      if not choice then
        return
      end
      if choice.unpin then
        state.pinned = nil
        util.info("Unpinned: sends will ask which session to use")
        queue.emit()
        return
      end
      local s = choice.session
      if not s.reachable then
        return util.warn(("%s can't be reached: %s"):format(sessions.short(s), s.reason or "?"))
      end
      state.pinned = { pid = s.pid, start = s.start, label = sessions.short(s), cwd = s.cwd }
      util.info("Pinned " .. state.pinned.label)
      queue.emit()
    end)
  end)
end

--- Pick a running session and switch to it.
function M.jump()
  sessions.discover(function(list)
    if #list == 0 then
      return util.warn("No running agent session found")
    end
    M.pick(list, { prompt = "Jump to session" }, function(choice)
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

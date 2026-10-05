-- relay.nvim: send code from Neovim to Claude Code, Codex and Copilot sessions.
local M = {}

local initialized = false

local HIGHLIGHTS = {
  RelayTitle = "FloatTitle",
  RelayFooter = "FloatFooter",
  RelayKey = "Special",
  RelayMuted = "Comment",
  RelayIndex = "Number",
  RelayPath = "Directory",
  RelayMode = "Type",
  RelayNote = "String",
  RelayWarn = "DiagnosticWarn",
  RelaySign = "DiagnosticInfo",
  RelayVirtText = "Comment",
}

local function set_highlights()
  for group, link in pairs(HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

--- Wrap an autocmd handler so a bug can never spam errors on every buffer event.
local function guarded(fn)
  local reported = false
  return function(ev)
    local ok, err = xpcall(fn, debug.traceback, ev)
    if not ok and not reported then
      reported = true
      vim.schedule(function()
        vim.notify("relay.nvim: " .. tostring(err), vim.log.levels.ERROR, { title = "Relay" })
      end)
    end
  end
end

local function init()
  if initialized then
    return
  end
  initialized = true
  set_highlights()
  local queue = require("relay.queue")
  local group = vim.api.nvim_create_augroup("relay", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })
  -- keep queued snippets attached to their code across reloads, unloads and renames
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = guarded(function(ev)
      queue.on_read(ev.buf)
    end),
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    callback = guarded(function(ev)
      queue.on_unload(ev.buf)
    end),
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = guarded(function(ev)
      queue.on_wipe(ev.buf)
    end),
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = guarded(function(ev)
      queue.on_write(ev.buf)
    end),
  })
end

local function set_keymaps()
  local keymaps = require("relay.config").options.keymaps
  if not keymaps then
    return
  end
  local function map(mode, lhs, rhs, desc)
    if type(lhs) == "string" and lhs ~= "" then
      vim.keymap.set(mode, lhs, rhs, { desc = "Relay: " .. desc, silent = true })
    end
  end
  map({ "n", "x" }, keymaps.menu, M.menu, "actions for the selection / line")
  map("x", keymaps.open, M.open, "send selection to an agent")
  map("x", keymaps.add, M.add, "add selection to the queue")
  map("n", keymaps.queue, M.queue, "open the queue")
  map("n", keymaps.send, M.send, "send the queue")
  map("n", keymaps.file, M.add_file, "add this file to the queue")
  map("n", keymaps.note, M.note, "edit the context of the snippet under the cursor")
  map("n", keymaps.clear, M.clear, "clear the queue")
  map("n", keymaps.target, M.target, "pin the target session")
  map("n", keymaps.sessions, M.sessions, "jump to an agent session")
end

---@param opts? relay.Config|table
function M.setup(opts)
  require("relay.config").setup(opts)
  initialized = false
  init()
  set_keymaps()
end

local function label(item)
  return require("relay.queue").label(item)
end

local function queued(index, item, existed)
  local icon = require("relay.config").options.ui.icon
  require("relay.util").info(("%s Queued #%d %s%s"):format(icon, index, label(item), existed and " (updated)" or ""))
end
M._queued = queued

--- Action menu for the visual selection (or a command range), or the cursor line when
--- nothing is selected: add to queue, add with context, send it, send the queue, view queue.
---@param range? { range: integer, line1: integer, line2: integer }
function M.menu(range)
  init()
  local util = require("relay.util")
  local queue = require("relay.queue")
  local capture = require("relay.capture")
  local input = require("relay.ui.input")
  local data, err
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" or (range and range.range and range.range > 0) then
    data, err = capture.selection(range)
    if not data then
      return util.warn(err)
    end
  else
    local row = vim.api.nvim_win_get_cursor(0)[1]
    data = capture.lines(row, row)
  end
  local existing, index = queue.find(data)
  local what = label(data)
  local count = queue.count()

  -- an optional prompt that goes at the top of the message
  local function with_prompt(fn)
    input.open({
      title = "Prompt (optional, goes first)",
      submit_label = "send",
      on_submit = fn,
    })
  end

  require("relay.ui.menu").open({
    title = require("relay.config").options.ui.icon .. " " .. what .. (existing and (" · queued #" .. index) or ""),
    items = {
      {
        key = "a",
        label = "Add to queue",
        action = function()
          local i, existed = queue.add(data)
          queued(i, data, existed)
        end,
      },
      {
        key = "c",
        label = existing and "Edit context" or "Add with context",
        action = function()
          input.open({
            title = "Context for " .. what .. " (sent as \"context: code\")",
            text = existing and existing.note or "",
            submit_label = existing and "save" or "add",
            on_submit = function(text)
              local item, i = queue.find(data)
              if item then
                item.note = text
                queue.emit()
                util.info(("Context saved for #%d %s"):format(i, label(item)))
              else
                data.note = text
                local new, existed = queue.add(data)
                queued(new, data, existed)
              end
            end,
          })
        end,
      },
      {
        key = "s",
        label = data.srow == data.erow and "Send line" or "Send selection",
        action = function()
          with_prompt(function(prompt)
            local item = vim.deepcopy(data)
            if existing then
              item.note = existing.note -- keep the context it was queued with
            end
            M.send({ items = { item }, message = prompt })
          end)
        end,
      },
      {
        key = "S",
        label = ("Send queue (%d)"):format(count),
        disabled = count == 0 and "The queue is empty" or nil,
        action = function()
          with_prompt(function(prompt)
            M.send({ message = prompt })
          end)
        end,
      },
      {
        key = "v",
        label = ("View queue (%d)"):format(count),
        action = M.queue,
      },
    },
  })
end

--- Open the overlay for the visual selection (or a command range).
---@param range? { range: integer, line1: integer, line2: integer }
function M.open(range)
  init()
  local data, err = require("relay.capture").selection(range)
  if not data then
    return require("relay.util").warn(err)
  end
  require("relay.ui.overlay").open(data)
end

--- Add the visual selection (or a command range) to the queue.
---@param range? { range: integer, line1: integer, line2: integer }
---@param note? string
function M.add(range, note)
  init()
  local data, err = require("relay.capture").selection(range)
  if not data then
    return require("relay.util").warn(err)
  end
  if note and vim.trim(note) ~= "" then
    data.note = vim.trim(note)
  end
  local index, existed = require("relay.queue").add(data)
  queued(index, data, existed)
end

--- Add the current file (as a whole) to the queue.
---@param note? string
function M.add_file(note)
  init()
  local data, err = require("relay.capture").file()
  if not data then
    return require("relay.util").warn(err)
  end
  if note and vim.trim(note) ~= "" then
    data.note = vim.trim(note)
  end
  local index, existed = require("relay.queue").add(data)
  queued(index, data, existed)
end

--- Send the queue (or opts.items).
---@param opts? { items?: relay.Item[], message?: string, pick?: boolean, submit?: boolean, focus?: boolean|"auto" }
function M.send(opts)
  init()
  require("relay.send").send(opts)
end

function M.queue()
  init()
  require("relay.ui.queue").open()
end

function M.clear()
  init()
  local n = require("relay.queue").clear()
  local util = require("relay.util")
  if n == 0 then
    util.info("The queue is already empty")
  else
    util.info(("Cleared %s · :Relay restore brings them back"):format(util.plural(n, "snippet")))
  end
end

function M.restore()
  init()
  local n = require("relay.queue").restore()
  local util = require("relay.util")
  util.info(n == 0 and "Nothing to restore" or ("Restored %s"):format(util.plural(n, "snippet")))
end

--- Pin (or unpin) the session sends go to.
function M.target()
  init()
  require("relay.send").pin()
end

function M.unpin()
  require("relay.state").pinned = nil
  require("relay.queue").emit()
  require("relay.util").info("Unpinned: sends will ask which session to use")
end

--- Pick a running agent session and switch to it.
function M.sessions()
  init()
  require("relay.send").jump()
end

--- Edit the context of the queued snippet under the cursor.
function M.note()
  init()
  local queue = require("relay.queue")
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local item, index = queue.item_at(vim.api.nvim_get_current_buf(), row)
  if not item then
    return require("relay.util").warn("No queued snippet under the cursor")
  end
  require("relay.ui.input").open({
    title = ("Context for #%d %s"):format(index, label(item)),
    text = item.note,
    on_submit = function(text)
      item.note = text
      queue.emit()
    end,
  })
end

--- Show the exact message the queue would produce.
function M.preview()
  init()
  require("relay.ui.queue").preview_message(require("relay.queue").items())
end

---@return relay.Item[]
function M.items()
  return require("relay.queue").items()
end

function M.count()
  local queue = package.loaded["relay.queue"]
  return queue and queue.count() or 0
end

--- Statusline component: "󰚩 3" (+ "→ session" when pinned); empty when there is nothing to show.
function M.statusline()
  local n = M.count()
  local state = require("relay.state")
  if n == 0 and not state.pinned then
    return ""
  end
  local icon = require("relay.config").options.ui.icon
  local s = n > 0 and (icon .. " " .. n) or icon
  if state.pinned then
    s = s .. " → " .. state.pinned.label
  end
  return s
end

return M

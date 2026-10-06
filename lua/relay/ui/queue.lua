-- The queue window: list of snippets with a live preview of the one under the cursor.
local config = require("relay.config")
local ui = require("relay.ui")
local util = require("relay.util")
local queue = require("relay.queue")
local format = require("relay.format")
local state = require("relay.state")

local M = {}

---@type { lbuf: integer, lwin: integer, pbuf?: integer, pwin?: integer, origin: integer, group: integer, suspended: boolean }|nil
local view

local HINTS = {
  { "s", "send" },
  { "S", "send to…" },
  { "m", "+prompt" },
  { "e", "context" },
  { "x", "delete" },
  { "?", "more" },
}

local HELP = {
  { "s", "send the queue" },
  { "S", "send, picking a session" },
  { "m", "write a prompt (goes first), then send the queue" },
  { "e / i / a", "edit the snippet's context" },
  { "x / dd", "delete the snippet" },
  { "u", "restore the last deleted snippet(s)" },
  { "K / J", "move the snippet up / down" },
  { "f", "cycle format: auto → ref → inline" },
  { "D", "include / exclude LSP diagnostics" },
  { "p", "preview the message the agent will get" },
  { "⏎ / o", "jump to the snippet" },
  { "C", "clear the queue" },
  { "t", "pin the session sends go to" },
  { "q / esc", "close" },
}

local function next_format(f)
  if f == nil then
    return "ref"
  elseif f == "ref" then
    return "inline"
  end
  return nil
end

local function name_of(item)
  return item.path and util.display(item.path) or item.name
end

local location = queue.label

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function current()
  if not (view and valid(view.lwin)) then
    return nil
  end
  local i = vim.api.nvim_win_get_cursor(view.lwin)[1]
  return queue.items()[i], i
end

local function preview_text(item)
  if item.kind ~= "file" then
    return item.text or {}
  end
  local max = config.options.ui.max_preview
  if item.buf and vim.api.nvim_buf_is_loaded(item.buf) then
    return vim.api.nvim_buf_get_lines(item.buf, 0, max, false)
  end
  local ok, lines = pcall(vim.fn.readfile, item.path, "", max)
  return ok and lines or {}
end

local function rows(width)
  local items = queue.items()
  local lines, marks = {}, {}
  if #items == 0 then
    local text = "  The queue is empty" .. (queue.can_restore() and " · u restores the last removal" or "")
    return { text }, { { { 0, #text, "RelayMuted" } } }
  end
  local locs, loc_w = {}, 0
  for i, item in ipairs(items) do
    locs[i] = location(item)
    loc_w = math.max(loc_w, vim.fn.strdisplaywidth(locs[i]))
  end
  loc_w = math.min(loc_w, math.max(20, math.floor(width * 0.5)))
  for i, item in ipairs(items) do
    local loc = util.truncate(locs[i], loc_w)
    loc = loc .. string.rep(" ", loc_w - vim.fn.strdisplaywidth(loc))
    local flags = {}
    if item.lost then
      flags[#flags + 1] = "gone from file"
    elseif item.changed then
      flags[#flags + 1] = "edited outside"
    end
    if queue.modified(item) then
      flags[#flags + 1] = "unsaved"
    end
    if item.diagnostics then
      flags[#flags + 1] = "+diagnostics"
    end
    local segments = {
      { (" %2d  "):format(i), "RelayIndex" },
      { loc, "RelayPath" },
      { "  " .. format.mode(item) .. (item.format and "*" or ""), "RelayMode" },
    }
    if #flags > 0 then
      segments[#segments + 1] = { "  " .. table.concat(flags, " "), item.lost and "RelayWarn" or "RelayMuted" }
    end
    local note = util.first_line(item.note)
    if note ~= "" then
      segments[#segments + 1] = { "  " .. note, "RelayNote" }
    end
    local line, m = "", {}
    for _, seg in ipairs(segments) do
      m[#m + 1] = { #line, #line + #seg[1], seg[2] }
      line = line .. seg[1]
    end
    lines[i], marks[i] = line, m
  end
  return lines, marks
end

--- Window geometry. The list stays put while the preview below it changes height.
local function layout()
  local width = ui.width(0.7)
  local cols, screen_rows = ui.screen()
  local border = ui.has_border() and 2 or 0
  local lh = math.max(1, math.min(math.max(queue.count(), 1), math.max(3, math.floor(screen_rows * 0.3))))
  local ph = math.max(0, math.min(config.options.ui.max_preview, screen_rows - lh - 2 * border - 3))
  local height = lh + border + (ph > 0 and ph + border or 0)
  return {
    width = width,
    lh = lh,
    ph = ph, -- maximum preview height
    row = math.max(0, math.floor((screen_rows - height) / 2) - 1),
    col = math.max(0, math.floor((cols - width - border) / 2)),
    border = border,
  }
end

local function title()
  local chunks = { { (" %s Relay queue "):format(config.options.ui.icon), "RelayTitle" } }
  if state.pinned then
    chunks[#chunks + 1] = { "→ " .. state.pinned.label .. " ", "RelayMuted" }
  end
  return chunks
end

local function update_preview()
  if not view then
    return
  end
  local item = current()
  local lines = item and preview_text(item) or {}
  local L = layout()
  if not item or #lines == 0 or L.ph == 0 then
    ui.close({ view.pwin })
    view.pwin, view.pbuf = nil, nil
    return
  end
  local buf = ui.scratch(lines)
  vim.bo[buf].modifiable = false
  local note = util.first_line(item.note)
  local cfg = ui.win_config({
    row = L.row + L.lh + L.border,
    col = L.col,
    width = L.width,
    height = math.min(#lines, L.ph),
    focusable = false,
    title = { { " " .. location(item) .. " ", "RelayTitle" } },
    title_pos = "left",
    footer = note ~= "" and { { " " .. util.truncate(note, L.width - 4) .. " ", "RelayNote" } } or nil,
    footer_pos = "left",
  })
  if valid(view.pwin) then
    vim.api.nvim_win_set_buf(view.pwin, buf)
    if cfg.footer == nil and ui.has_border() then
      cfg.footer = ""
    end
    vim.api.nvim_win_set_config(view.pwin, cfg)
  else
    view.pwin = vim.api.nvim_open_win(buf, false, cfg)
  end
  view.pbuf = buf
  vim.wo[view.pwin].wrap = false
  if item.kind == "range" then
    ui.line_numbers(view.pwin, item.srow, #lines)
  else
    ui.line_numbers(view.pwin, 1, #lines)
  end
  ui.highlight(buf, item.ft)
end

function M.render()
  if not (view and valid(view.lwin)) then
    return M.close()
  end
  queue.refresh_all()
  local L = layout()
  local lines, marks = rows(L.width)
  vim.bo[view.lbuf].modifiable = true
  vim.api.nvim_buf_set_lines(view.lbuf, 0, -1, false, lines)
  vim.bo[view.lbuf].modifiable = false
  vim.api.nvim_buf_clear_namespace(view.lbuf, ui.ns, 0, -1)
  for i, m in ipairs(marks) do
    for _, r in ipairs(m) do
      vim.api.nvim_buf_set_extmark(view.lbuf, ui.ns, i - 1, r[1], { end_col = r[2], hl_group = r[3] })
    end
  end
  vim.api.nvim_win_set_config(
    view.lwin,
    ui.win_config({
      row = L.row,
      col = L.col,
      width = L.width,
      height = L.lh,
      title = title(),
      title_pos = "left",
      footer = ui.hints(HINTS, L.width),
      footer_pos = "center",
    })
  )
  local cursor = vim.api.nvim_win_get_cursor(view.lwin)
  if cursor[1] > #lines then
    vim.api.nvim_win_set_cursor(view.lwin, { #lines, 0 })
  end
  update_preview()
end

function M.close()
  if not view then
    return
  end
  local v = view
  view = nil
  pcall(vim.api.nvim_del_augroup_by_id, v.group)
  ui.close({ v.pwin, v.lwin })
end

local function resume()
  if not view then
    return
  end
  view.suspended = false
  if valid(view.lwin) then
    vim.api.nvim_set_current_win(view.lwin)
    M.render()
  else
    M.close()
  end
end

local function edit_note()
  local item, i = current()
  if not item then
    return
  end
  view.suspended = true
  require("relay.ui.input").open({
    title = ("Context for #%d %s"):format(i, location(item)),
    text = item.note,
    on_submit = function(text)
      item.note = text
      queue.emit()
      resume()
    end,
    on_cancel = resume,
  })
end

local function jump()
  local item = current()
  if not item then
    return
  end
  local origin = view.origin
  M.close()
  if valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  local ok = false
  if item.buf and vim.api.nvim_buf_is_valid(item.buf) then
    ok = pcall(vim.cmd.buffer, item.buf)
  end
  if not ok and item.path then
    ok = pcall(vim.cmd.edit, vim.fn.fnameescape(item.path))
  end
  if not ok then
    return util.warn("Can't open " .. name_of(item))
  end
  if item.kind == "range" then
    local count = vim.api.nvim_buf_line_count(0)
    pcall(vim.api.nvim_win_set_cursor, 0, { math.min(item.srow, count), item.vmode == "v" and item.scol or 0 })
    vim.cmd("normal! zz")
  end
end

local function send(opts)
  if queue.count() == 0 then
    return util.warn("Nothing to send: the queue is empty")
  end
  M.close()
  require("relay.send").send(opts)
end

--- Float showing exactly what the agent will receive.
---@param items relay.Item[]
---@param on_close? fun()
function M.preview_message(items, on_close)
  if #items == 0 then
    return util.warn("Nothing to preview: the queue is empty")
  end
  queue.refresh_all()
  local cwd = (state.pinned and state.pinned.cwd) or state.last_cwd or vim.fn.getcwd()
  local lines = vim.split(format.build(items, { cwd = cwd }), "\n", { plain = true })
  local buf = ui.scratch(lines)
  vim.bo[buf].modifiable = false
  local width = ui.width(0.7)
  local cols, screen_rows = ui.screen()
  local height = math.max(1, math.min(#lines, screen_rows - 6))
  local win = vim.api.nvim_open_win(
    buf,
    true,
    ui.win_config({
      row = math.max(0, math.floor((screen_rows - height) / 2) - 1),
      col = math.max(0, math.floor((cols - width - 2) / 2)),
      width = width,
      height = height,
      zindex = 80,
      title = { { " Message preview ", "RelayTitle" } },
      title_pos = "left",
      footer = {
        { " paths relative to " .. util.truncate_left(util.home(cwd), math.max(10, width - 30)) .. " · ", "RelayFooter" },
        { "q", "RelayKey" },
        { " close ", "RelayFooter" },
      },
      footer_pos = "center",
    })
  )
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  ui.highlight(buf, "markdown")
  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    ui.close({ win })
    if on_close then
      vim.schedule(on_close)
    end
  end
  ui.map(buf, "n", { "q", "<Esc>", "p" }, close, "Close")
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
end

local function help()
  local key_w = 0
  for _, h in ipairs(HELP) do
    key_w = math.max(key_w, vim.fn.strdisplaywidth(h[1]))
  end
  local lines, width = {}, 0
  for i, h in ipairs(HELP) do
    lines[i] = "  " .. h[1] .. string.rep(" ", key_w - vim.fn.strdisplaywidth(h[1]) + 2) .. h[2] .. " "
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]))
  end
  local buf = ui.scratch(lines)
  vim.bo[buf].modifiable = false
  for i, h in ipairs(HELP) do
    vim.api.nvim_buf_set_extmark(buf, ui.ns, i - 1, 2, { end_col = 2 + #h[1], hl_group = "RelayKey" })
  end
  local cols, screen_rows = ui.screen()
  view.suspended = true
  local win = vim.api.nvim_open_win(
    buf,
    true,
    ui.win_config({
      row = math.max(0, math.floor((screen_rows - #lines) / 2) - 1),
      col = math.max(0, math.floor((cols - width - 2) / 2)),
      width = width,
      height = #lines,
      zindex = 80,
      title = { { " Relay queue keys ", "RelayTitle" } },
      title_pos = "left",
    })
  )
  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    ui.close({ win })
    vim.schedule(resume)
  end
  ui.map(buf, "n", { "q", "<Esc>", "?" }, close, "Close")
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
end

function M.open()
  if view and valid(view.lwin) then
    vim.api.nvim_set_current_win(view.lwin)
    return
  end
  queue.refresh_all()
  local origin = vim.api.nvim_get_current_win()
  local lbuf = ui.scratch()
  vim.bo[lbuf].modifiable = false
  vim.bo[lbuf].filetype = "relay"
  local L = layout()
  local lwin = vim.api.nvim_open_win(
    lbuf,
    true,
    ui.win_config({
      row = L.row,
      col = L.col,
      width = L.width,
      height = L.lh,
      title = title(),
      title_pos = "left",
    })
  )
  vim.wo[lwin].cursorline = true
  vim.wo[lwin].wrap = false
  local group = vim.api.nvim_create_augroup("relay.queue_view", { clear = true })
  view = { lbuf = lbuf, lwin = lwin, origin = origin, group = group, suspended = false }

  local function map(lhs, fn, desc)
    ui.map(lbuf, "n", lhs, fn, desc)
  end
  map({ "<CR>", "o" }, jump, "Jump to snippet")
  map({ "e", "i", "a" }, edit_note, "Edit context")
  map({ "x", "dd" }, function()
    local item, i = current()
    if item then
      queue.remove(i)
    end
  end, "Delete")
  map("u", function()
    local n = queue.restore()
    if n == 0 then
      util.info("Nothing to restore")
    end
  end, "Restore")
  map("K", function()
    local item, i = current()
    if item then
      local j = queue.move(i, -1)
      vim.api.nvim_win_set_cursor(view.lwin, { j, 0 })
      update_preview()
    end
  end, "Move up")
  map("J", function()
    local item, i = current()
    if item then
      local j = queue.move(i, 1)
      vim.api.nvim_win_set_cursor(view.lwin, { j, 0 })
      update_preview()
    end
  end, "Move down")
  map("f", function()
    local item = current()
    if item then
      item.format = next_format(item.format)
      queue.emit()
    end
  end, "Cycle format")
  map("D", function()
    local item = current()
    if item and item.kind == "range" then
      item.diagnostics = not item.diagnostics
      queue.emit()
    end
  end, "Toggle diagnostics")
  map("p", function()
    if queue.count() > 0 then
      view.suspended = true
      M.preview_message(queue.items(), resume)
    end
  end, "Preview message")
  map("s", function()
    send({})
  end, "Send")
  map("S", function()
    send({ pick = true })
  end, "Send to a chosen session")
  map("m", function()
    if queue.count() == 0 then
      return util.warn("Nothing to send: the queue is empty")
    end
    view.suspended = true
    require("relay.ui.input").open({
      title = "Prompt (goes first)",
      submit_label = "send",
      on_submit = function(text)
        M.close()
        require("relay.send").send({ message = text })
      end,
      on_cancel = resume,
    })
  end, "Send with a prompt")
  map("C", function()
    local n = queue.clear()
    if n > 0 then
      util.info(("Cleared %s · u restores"):format(util.plural(n, "snippet")))
    end
  end, "Clear")
  map("t", function()
    M.close()
    require("relay.send").pin()
  end, "Pin session")
  map({ "q", "<Esc>" }, M.close, "Close")
  map("?", help, "Help")

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = lbuf,
    callback = function()
      update_preview()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "RelayQueueChanged",
    callback = function()
      vim.schedule(function()
        if view and valid(view.lwin) then
          M.render()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = lbuf,
    callback = function()
      vim.schedule(function()
        if view and not view.suspended and vim.api.nvim_get_current_win() ~= view.lwin then
          M.close()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(lwin),
    callback = function()
      vim.schedule(M.close)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      vim.schedule(M.render)
    end,
  })
  M.render()
end

function M.is_open()
  return view ~= nil
end

return M

-- The queue of snippets waiting to be sent.
--
-- Every queued range is tracked with an extmark, so its line numbers follow your edits.
-- Extmarks don't survive a reload from disk (e.g. after Claude edited the file and
-- 'autoread'/:checktime picked it up): they keep their old row numbers. So on every
-- BufReadPost the snippet is found again by its content, nearest to where it was.
local config = require("relay.config")
local util = require("relay.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("relay")

---@class relay.Item
---@field id integer
---@field kind "range"|"file"
---@field buf integer|nil
---@field path string|nil        file on disk (nil for buffers without one)
---@field name string            display name for buffers without a file
---@field ft string
---@field vmode string           "v" | "V" | "\22"
---@field srow integer           first line (1-based)
---@field erow integer           last line (1-based)
---@field scol integer           start column (0-based bytes, charwise selections)
---@field ecol integer           exclusive end column on erow (0-based bytes)
---@field text string[]          the selected text
---@field anchor string[]        full lines srow..erow, used to find the code again
---@field note string
---@field format "ref"|"inline"|nil  per-snippet override of config.format
---@field diagnostics boolean
---@field mark integer|nil
---@field lost boolean|nil       the code can no longer be found in the file
---@field changed boolean|nil    found again, but edited outside Neovim
---@field empty boolean|nil      the selection was empty (a blank line)

---@type relay.Item[]
local items = {}
local trash = {} -- stack of removed batches, for restore()
local MAX_TRASH = 20
local next_id = 0

function M.items()
  return items
end

function M.count()
  return #items
end

function M.can_restore()
  return #trash > 0
end

local function loaded(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
end

local function index_of(item)
  for i, it in ipairs(items) do
    if it == item then
      return i
    end
  end
end

local function find_buf(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == path then
      return buf
    end
  end
end

--- "path:10-20" (or "path (whole file)") for messages and lists.
---@param item relay.Item
function M.label(item)
  local name = item.path and util.display(item.path) or item.name
  if item.kind == "file" then
    return name .. " (whole file)"
  end
  local range = item.srow == item.erow and (":" .. item.srow) or (":%d-%d"):format(item.srow, item.erow)
  return name .. range
end

---@param item relay.Item
function M.modified(item)
  return loaded(item.buf) and vim.bo[item.buf].modified or false
end

local function decoration(item, index)
  local cfg = config.options
  local opts = {}
  if cfg.signs then
    opts.sign_text = "▎"
    opts.sign_hl_group = "RelaySign"
  end
  if cfg.virtual_text then
    local note = util.first_line(item.note)
    local text = ("%s #%d%s"):format(cfg.ui.icon, index, note ~= "" and (" " .. util.truncate(note, 40)) or "")
    opts.virt_text = { { text, "RelayVirtText" } }
    opts.virt_text_pos = "eol"
  end
  return opts
end

local function mark_opts(item, end_row, end_col)
  return vim.tbl_extend("force", decoration(item, index_of(item) or 0), {
    id = item.mark,
    end_row = end_row,
    end_col = end_col,
    right_gravity = true,
    end_right_gravity = false,
    undo_restore = true, -- deleting the code collapses the range; undo brings it back
  })
end

local function unmark(item)
  if item.mark and loaded(item.buf) then
    pcall(vim.api.nvim_buf_del_extmark, item.buf, M.ns, item.mark)
  end
  item.mark = nil
end

--- Put the item's extmark at item.srow..item.erow.
local function place(item)
  local buf = item.buf
  local count = vim.api.nvim_buf_line_count(buf)
  local sr = math.min(item.srow, count) - 1
  local er = math.max(sr, math.min(item.erow, count) - 1)
  local sline = vim.api.nvim_buf_get_lines(buf, sr, sr + 1, false)[1] or ""
  local eline = vim.api.nvim_buf_get_lines(buf, er, er + 1, false)[1] or ""
  local sc, ec = 0, #eline
  if item.vmode == "v" then
    sc = math.min(item.scol, #sline)
    ec = math.min(item.ecol, #eline)
    if er == sr and ec < sc then
      ec = sc
    end
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, sr, sc, mark_opts(item, er, ec))
  if ok then
    item.mark = id
  end
end

--- Update an item from its extmark: line numbers and text follow edits made in Neovim.
---@param item relay.Item
function M.refresh(item)
  if item.kind ~= "range" or not item.mark or not loaded(item.buf) then
    return
  end
  local buf = item.buf
  local m = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns, item.mark, { details = true })
  if #m == 0 then
    item.mark = nil
    return
  end
  local sr, sc = m[1], m[2]
  local er, ec = m[3].end_row or sr, m[3].end_col or sc
  if er < sr or (er == sr and ec < sc) then
    -- The range was deleted and new text inserted in its place (`cc`, `cw`, a
    -- set_lines() over it, ...). The start mark moved past the new text and the end
    -- mark stayed before it, so the new text lies between them: swap the two.
    sr, sc, er, ec = er, ec, sr, sc
    if ec == 0 and er > sr then
      er = er - 1 -- ends at the start of a line: the line before is the last one
      ec = #(vim.api.nvim_buf_get_lines(buf, er, er + 1, false)[1] or "")
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, sr, sc, mark_opts(item, er, ec))
  elseif er == sr and ec == sc and not item.empty then
    -- everything was deleted (unless the selection was an empty line to begin with)
    item.lost = true
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, sr, er + 1, false)
  if #lines == 0 then
    item.lost = true
    return
  end
  item.lost = nil
  item.srow, item.erow, item.scol, item.ecol = sr + 1, er + 1, sc, ec
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" and vim.bo[buf].buftype == "" then
    item.path = name -- follows :saveas, and unnamed buffers that got written to a file
  end
  if not vim.deep_equal(lines, item.anchor) then
    item.anchor = lines
    if item.vmode == "v" then
      local ok, text = pcall(vim.api.nvim_buf_get_text, buf, sr, sc, er, ec, {})
      if ok then
        item.text = text
      end
    else
      -- a block selection can't follow edits; fall back to whole lines once they change
      item.vmode = "V"
      item.text = lines
    end
  end
end

function M.refresh_all()
  for _, item in ipairs(items) do
    M.refresh(item)
  end
end

local function find_block(lines, anchor, near)
  local n = #anchor
  local best, best_d
  for i = 1, #lines - n + 1 do
    if lines[i] == anchor[1] then
      local match = true
      for j = 2, n do
        if lines[i + j - 1] ~= anchor[j] then
          match = false
          break
        end
      end
      if match and (not best or math.abs(i - near) < best_d) then
        best, best_d = i, math.abs(i - near)
      end
    end
  end
  return best
end

--- The first and last lines survived but something in between changed.
local function find_edges(lines, anchor, near)
  local n = #anchor
  local first, last = anchor[1], anchor[n]
  if n < 2 or vim.trim(first) == "" or vim.trim(last) == "" then
    return nil
  end
  local best, best_end, best_d
  for i = 1, #lines do
    if lines[i] == first then
      for k = i + 1, math.min(#lines, i + 2 * n + 10) do
        if lines[k] == last then
          if not best or math.abs(i - near) < best_d then
            best, best_end, best_d = i, k, math.abs(i - near)
          end
          break
        end
      end
    end
  end
  return best, best_end
end

--- Find the item's code in its (loaded) buffer again and move the extmark there.
---@param item relay.Item
function M.reanchor(item)
  local lines = vim.api.nvim_buf_get_lines(item.buf, 0, -1, false)
  local s = find_block(lines, item.anchor, item.srow)
  local e
  if s then
    e = s + #item.anchor - 1
    item.lost, item.changed = nil, nil
  else
    s, e = find_edges(lines, item.anchor, item.srow)
    if s then
      item.lost, item.changed = nil, true
      if item.vmode == "v" then
        item.vmode = "V"
      end
    end
  end
  if not s then
    item.lost = true
    unmark(item)
    return
  end
  item.srow, item.erow = s, e
  place(item)
  M.refresh(item)
end

--- Attach an item to the loaded buffer of its file, if there is one.
---@param item relay.Item
function M.track(item)
  if item.kind ~= "range" then
    return
  end
  if not loaded(item.buf) then
    item.buf = item.path and find_buf(item.path) or nil
    item.mark = nil
  end
  if loaded(item.buf) then
    M.reanchor(item)
  end
end

local function emit()
  M.decorate()
  vim.api.nvim_exec_autocmds("User", { pattern = "RelayQueueChanged", modeline = false })
end
M.emit = emit

--- Refresh signs and virtual text (queue numbers change when items move).
function M.decorate()
  for _, item in ipairs(items) do
    if item.kind == "range" and item.mark and loaded(item.buf) then
      local m = vim.api.nvim_buf_get_extmark_by_id(item.buf, M.ns, item.mark, { details = true })
      if #m > 0 then
        local opts = mark_opts(item, m[3].end_row or m[1], m[3].end_col or m[2])
        pcall(vim.api.nvim_buf_set_extmark, item.buf, M.ns, m[1], m[2], opts)
      end
    end
  end
end

local function same_place(a, b)
  if (a.path or a.buf) ~= (b.path or b.buf) or a.kind ~= b.kind then
    return false
  end
  if a.kind == "file" then
    return true
  end
  return a.srow == b.srow and a.erow == b.erow and a.scol == b.scol and a.ecol == b.ecol and a.vmode == b.vmode
end

--- The queued entry covering exactly the same code as `data`, if any.
---@return relay.Item|nil, integer|nil
function M.find(data)
  M.refresh_all()
  for i, it in ipairs(items) do
    if not it.lost and same_place(it, data) then
      return it, i
    end
  end
end

--- Add a snippet. Queuing the same place twice updates the existing entry instead.
---@return integer index
---@return boolean existed
function M.add(data)
  M.refresh_all()
  for i, it in ipairs(items) do
    if not it.lost and same_place(it, data) then
      if data.note and data.note ~= "" then
        it.note = data.note
      end
      if data.format ~= nil then
        it.format = data.format
      end
      it.diagnostics = data.diagnostics or it.diagnostics
      emit()
      return i, true
    end
  end
  next_id = next_id + 1
  local item = vim.tbl_extend("force", { note = "", diagnostics = config.options.diagnostics }, data)
  item.id, item.mark = next_id, nil
  table.insert(items, item)
  if item.kind == "range" and loaded(item.buf) then
    place(item)
  end
  emit()
  return #items, false
end

local function push_trash(batch)
  table.insert(trash, batch)
  if #trash > MAX_TRASH then
    table.remove(trash, 1)
  end
end

function M.remove(index)
  local item = items[index]
  if not item then
    return nil
  end
  M.refresh(item)
  table.remove(items, index)
  unmark(item)
  push_trash({ { item = item, index = index } })
  emit()
  return item
end

function M.move(index, delta)
  local target = index + delta
  if not items[index] or target < 1 or target > #items then
    return index
  end
  items[index], items[target] = items[target], items[index]
  emit()
  return target
end

---@return integer removed
function M.clear()
  if #items == 0 then
    return 0
  end
  M.refresh_all()
  local batch = {}
  for i, item in ipairs(items) do
    unmark(item)
    batch[#batch + 1] = { item = item, index = i }
  end
  items = {}
  push_trash(batch)
  emit()
  return #batch
end

--- Bring back the last removed item(s).
---@return integer restored
function M.restore()
  local batch = table.remove(trash)
  if not batch then
    return 0
  end
  for _, entry in ipairs(batch) do
    table.insert(items, math.min(entry.index, #items + 1), entry.item)
    M.track(entry.item)
  end
  emit()
  return #batch
end

--- The queued range under a position.
---@return relay.Item|nil, integer|nil
function M.item_at(buf, row)
  M.refresh_all()
  for i, item in ipairs(items) do
    if item.kind == "range" and item.buf == buf and not item.lost and row >= item.srow and row <= item.erow then
      return item, i
    end
  end
end

-- Buffer lifecycle ---------------------------------------------------------------------

local function has_items(buf, name)
  for _, item in ipairs(items) do
    if item.kind == "range" and (item.buf == buf or (name and item.path == name)) then
      return true
    end
  end
  return false
end

--- BufReadPost: the buffer's content was (re)read from disk.
function M.on_read(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or not has_items(buf, name) then
    return
  end
  for _, item in ipairs(items) do
    if item.kind == "range" and (item.buf == buf or item.path == name) then
      if item.buf ~= buf then
        item.buf, item.mark = buf, nil
      elseif item.mark and #vim.api.nvim_buf_get_extmark_by_id(buf, M.ns, item.mark, {}) == 0 then
        item.mark = nil
      end
      M.reanchor(item)
    end
  end
  emit()
end

--- BufUnload: remember where everything was; the marks are recreated on the next read.
function M.on_unload(buf)
  if not has_items(buf) then
    return
  end
  for _, item in ipairs(items) do
    if item.kind == "range" and item.buf == buf then
      M.refresh(item)
      unmark(item)
    end
  end
end

function M.on_wipe(buf)
  for _, item in ipairs(items) do
    if item.buf == buf then
      item.buf, item.mark = nil, nil
    end
  end
end

--- BufWritePost: positions/anchors are current, and "unsaved" state changed.
function M.on_write(buf)
  if not has_items(buf) then
    return
  end
  for _, item in ipairs(items) do
    if item.buf == buf then
      M.refresh(item)
    end
  end
  emit()
end

return M

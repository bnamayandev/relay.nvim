-- Turns the current visual selection (or a command range) into snippet data.
local config = require("relay.config")
local util = require("relay.util")

local M = {}

local VISUAL = { v = true, V = true, ["\22"] = true }

local function file_of(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local bt = vim.bo[buf].buftype
  if name ~= "" and (bt == "" or bt == "help") then
    return name
  end
end

local function display_name(buf, path)
  if path then
    return util.display(path)
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return "[No Name]"
  end
  return util.truncate(vim.fn.fnamemodify(name, ":~:."), 60)
end

---@param buf integer
---@param vmode string
---@param srow integer 1-based
---@param erow integer 1-based
---@param scol integer 0-based (charwise)
---@param ecol integer 0-based exclusive (charwise)
---@param text string[]
local function build(buf, vmode, srow, erow, scol, ecol, text)
  local path = file_of(buf)
  return {
    kind = "range",
    buf = buf,
    path = path,
    name = display_name(buf, path),
    ft = vim.bo[buf].filetype,
    vmode = vmode,
    srow = srow,
    erow = erow,
    scol = scol,
    ecol = ecol,
    text = text,
    anchor = vim.api.nvim_buf_get_lines(buf, srow - 1, erow, false),
    empty = srow == erow and ecol <= scol,
    note = "",
    diagnostics = config.options.diagnostics,
  }
end

local function linewise(buf, line1, line2)
  local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
  return build(buf, "V", line1, line2, 0, #(lines[#lines] or ""), lines)
end

--- Whole lines of the current buffer (e.g. the cursor line when nothing is selected).
---@param line1 integer
---@param line2 integer
function M.lines(line1, line2)
  return linewise(vim.api.nvim_get_current_buf(), line1, line2)
end

--- Capture the selection. Works from a visual-mode mapping (exits visual mode) or from a
--- command with a range (`:'<,'>Relay ...` / `:10,20Relay ...`).
---@param range? { range: integer, line1: integer, line2: integer }
---@return table|nil data
---@return string|nil err
function M.selection(range)
  local buf = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local vmode
  if VISUAL[mode] then
    vmode = mode
    -- leaving visual mode updates the '< and '> marks
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  elseif range and range.range and range.range > 0 then
    local s = vim.api.nvim_buf_get_mark(buf, "<")
    local e = vim.api.nvim_buf_get_mark(buf, ">")
    local last = vim.fn.visualmode()
    if not (VISUAL[last] and s[1] == range.line1 and e[1] == range.line2) then
      return linewise(buf, range.line1, range.line2)
    end
    vmode = last -- the range came from the last visual selection: keep its exact shape
  else
    return nil, "Nothing selected: select some code in visual mode first"
  end

  local s = vim.api.nvim_buf_get_mark(buf, "<")
  local e = vim.api.nvim_buf_get_mark(buf, ">")
  if s[1] == 0 or e[1] == 0 then
    return nil, "Nothing selected"
  end
  local srow, erow = s[1], e[1]
  if vmode == "V" then
    return linewise(buf, srow, erow)
  end

  local ok, text = pcall(vim.fn.getregion, vim.fn.getpos("'<"), vim.fn.getpos("'>"), { type = vmode })
  if not ok or type(text) ~= "table" or #text == 0 then
    return linewise(buf, srow, erow)
  end
  if vmode == "\22" then
    -- tracked as whole lines; the text keeps the block's columns
    local data = linewise(buf, srow, erow)
    data.vmode = "\22"
    data.text = text
    return data
  end

  local sline = vim.api.nvim_buf_get_lines(buf, srow - 1, srow, false)[1] or ""
  local eline = vim.api.nvim_buf_get_lines(buf, erow - 1, erow, false)[1] or ""
  local scol = math.min(s[2], #sline)
  local ecol = 0
  if #eline > 0 then
    -- '> points at the first byte of the last selected character; include all of it
    local last = math.min(e[2], #eline - 1)
    ecol = last + 1 + vim.str_utf_end(eline, last + 1)
  end
  if srow == erow and ecol < scol then
    ecol = scol
  end
  return build(buf, "v", srow, erow, scol, ecol, text)
end

--- The current buffer as a whole-file reference.
---@return table|nil data
---@return string|nil err
function M.file()
  local buf = vim.api.nvim_get_current_buf()
  local path = file_of(buf)
  if not path or not util.is_file(path) then
    return nil, "The current buffer is not a file on disk"
  end
  return {
    kind = "file",
    buf = buf,
    path = path,
    name = util.display(path),
    ft = vim.bo[buf].filetype,
    note = "",
    diagnostics = false,
  }
end

return M

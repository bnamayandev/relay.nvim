-- Builds the message the agent receives (the same for Claude Code, Codex and Copilot):
--
--   <prompt>
--
--   <context>: @path#L10-20
--
--   @other/file.lua#L3
--
-- A saved file is referenced with Claude Code's mention syntax, `@path#L10-20`, which makes
-- the agent read exactly those lines from disk. Code that only exists in Neovim (unsaved
-- changes, buffers without a file, code deleted since it was queued) is inlined in a fence.
local config = require("relay.config")
local util = require("relay.util")
local queue = require("relay.queue")

local M = {}

local LANG = {
  typescriptreact = "tsx",
  javascriptreact = "jsx",
  sh = "bash",
  zsh = "bash",
  ["objective-c"] = "objc",
  cs = "csharp",
  text = "",
}

--- The format a snippet will actually be sent in.
---@param item relay.Item
---@return "ref"|"inline"
function M.mode(item)
  if item.kind == "file" then
    return "ref"
  end
  if not item.path or not util.is_file(item.path) then
    return "inline"
  end
  local mode = item.format or config.options.format
  if mode == "auto" then
    if item.lost or queue.modified(item) then
      return "inline"
    end
    return "ref"
  end
  return mode
end

--- `@path#L1-2` for a file, relative to the session's cwd when inside it.
---@param path string
---@param range string|nil e.g. "#L10-20"
---@param cwd string|nil
---@return string|nil mention, nil when the path can't be expressed as a mention
function M.mention(path, range, cwd)
  local real = util.realpath(path)
  local p = util.relpath(util.realpath(cwd), real) or real
  if p:find("#", 1, true) then
    return nil -- Claude splits mentions at '#'
  end
  local token = p .. (range or "")
  -- unquoted mentions end at whitespace and must end on a word character
  if not token:find("%s") and token:find("[%w_]$") then
    return "@" .. token
  end
  if token:find('"', 1, true) then
    return nil
  end
  return '@"' .. token .. '"'
end

local function range_suffix(item)
  if item.srow == item.erow then
    return "#L" .. item.srow
  end
  return ("#L%d-%d"):format(item.srow, item.erow)
end

local function fence(lines)
  local longest = 2
  for _, line in ipairs(lines) do
    for ticks in line:gmatch("`+") do
      longest = math.max(longest, #ticks)
    end
  end
  return string.rep("`", longest + 1)
end

local function location(item, cwd)
  if not item.path then
    return item.name
  end
  local real = util.realpath(item.path)
  return util.relpath(util.realpath(cwd), real) or util.home(real)
end

---@param item relay.Item
---@return string[]
function M.diagnostics(item)
  local out = {}
  if item.kind ~= "range" or not item.buf or not vim.api.nvim_buf_is_valid(item.buf) then
    return out
  end
  local diags = vim.diagnostic.get(item.buf)
  table.sort(diags, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return (a.severity or 4) < (b.severity or 4)
  end)
  for _, d in ipairs(diags) do
    local line = d.lnum + 1
    if line >= item.srow and line <= item.erow then
      local severity = (vim.diagnostic.severity[d.severity] or "info"):lower()
      local message = vim.trim((d.message or ""):gsub("%s*\n%s*", " "))
      local source = d.source and (" (" .. d.source .. ")") or ""
      out[#out + 1] = ("- L%d %s: %s%s"):format(line, severity, message, source)
    end
  end
  return out
end

---@param item relay.Item
---@param cwd string|nil
---@return string
function M.item(item, cwd)
  local out = {}
  -- context goes in front of the snippet: "why is this slow: @app.ts#L10-20"
  local context = vim.trim((item.note or ""):gsub("%s*\n%s*", " "))
  context = context ~= "" and (context:gsub("%s*:$", "") .. ": ") or ""
  local mention
  if M.mode(item) == "ref" then
    mention = M.mention(item.path, item.kind == "range" and range_suffix(item) or nil, cwd)
  end
  if mention then
    out[#out + 1] = context .. mention
  else
    local notes = {}
    if item.kind == "range" then
      notes[#notes + 1] = item.srow == item.erow and ("line " .. item.srow) or ("lines %d-%d"):format(item.srow, item.erow)
    end
    if item.lost then
      notes[#notes + 1] = "no longer in the file"
    elseif queue.modified(item) then
      notes[#notes + 1] = "unsaved"
    end
    local header = location(item, cwd)
    if #notes > 0 then
      header = header .. " (" .. table.concat(notes, ", ") .. ")"
    end
    local text = item.text or {}
    if item.kind == "file" then
      text = item.buf and vim.api.nvim_buf_is_valid(item.buf) and vim.api.nvim_buf_get_lines(item.buf, 0, -1, false) or {}
    end
    local ticks = fence(text)
    local lang = LANG[item.ft] or item.ft or ""
    out[#out + 1] = context .. header .. ":"
    out[#out + 1] = ticks .. lang
    vim.list_extend(out, text)
    out[#out + 1] = ticks
  end
  if item.diagnostics then
    local diags = M.diagnostics(item)
    if #diags > 0 then
      out[#out + 1] = "Diagnostics:"
      vim.list_extend(out, diags)
    end
  end
  return table.concat(out, "\n")
end

--- The full message: the prompt (if any) first, then the snippets.
---@param items relay.Item[]
---@param opts? { cwd?: string, message?: string }
function M.build(items, opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()
  local parts = {}
  local message = vim.trim(opts.message or "")
  if message ~= "" then
    parts[#parts + 1] = message
  end
  for _, item in ipairs(items) do
    parts[#parts + 1] = M.item(item, cwd)
  end
  return table.concat(parts, "\n\n")
end

return M

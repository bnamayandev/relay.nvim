-- Shared helpers for Relay's floating windows.
local config = require("relay.config")

local M = {}

M.ns = vim.api.nvim_create_namespace("relay.ui")

---@param lines string[]|nil
---@return integer buf
function M.scratch(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.b[buf].completion = false -- blink.cmp
  if lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  return buf
end

--- Syntax highlight a scratch buffer as `ft` without triggering FileType autocmds (so no
--- LSP/linters attach to it).
function M.highlight(buf, ft)
  if not ft or ft == "" then
    return
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  if not pcall(vim.treesitter.start, buf, lang) then
    vim.bo[buf].syntax = ft
  end
end

--- Turn off completion plugins in the current buffer.
function M.no_completion()
  if package.loaded["cmp"] then
    pcall(function()
      require("cmp").setup.buffer({ enabled = false })
    end)
  end
end

function M.has_border()
  local b = config.options.ui.border
  return b ~= nil and b ~= "none" and b ~= ""
end

--- Editor area available for floats.
function M.screen()
  local rows = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0)
  return vim.o.columns, math.max(rows, 1)
end

function M.width(fraction)
  local cols = M.screen()
  local w = math.floor(cols * (fraction or config.options.ui.width))
  w = math.max(w, math.min(72, cols - 4))
  return math.max(math.min(w, cols - 4), 10)
end

--- Footer/title hints like "⏎ send  ⇥ queue", cut to fit `width`.
---@param hints { [1]: string, [2]: string }[]
function M.hints(hints, width)
  local chunks, used = {}, 2
  for _, h in ipairs(hints) do
    local len = vim.fn.strdisplaywidth(h[1]) + vim.fn.strdisplaywidth(h[2]) + 3
    if used + len > width then
      break
    end
    chunks[#chunks + 1] = { #chunks == 0 and " " or "  ", "RelayFooter" }
    chunks[#chunks + 1] = { h[1], "RelayKey" }
    chunks[#chunks + 1] = { " " .. h[2], "RelayFooter" }
    used = used + len
  end
  if #chunks > 0 then
    chunks[#chunks + 1] = { " ", "RelayFooter" }
  end
  return chunks
end

--- nvim_open_win config with title/footer only when there is a border to put them on.
function M.win_config(cfg)
  cfg = vim.tbl_extend("force", {
    relative = "editor",
    style = "minimal",
    border = config.options.ui.border,
    zindex = 60,
  }, cfg)
  if not M.has_border() then
    cfg.title, cfg.title_pos, cfg.footer, cfg.footer_pos = nil, nil, nil, nil
  else
    if cfg.title == nil then
      cfg.title_pos = nil
    end
    if cfg.footer == nil or (type(cfg.footer) == "table" and #cfg.footer == 0) then
      cfg.footer, cfg.footer_pos = nil, nil
    end
  end
  return cfg
end

function M.set_footer(win, footer, pos)
  if not (win and vim.api.nvim_win_is_valid(win)) or not M.has_border() then
    return
  end
  if #footer == 0 then
    footer = ""
  end
  pcall(vim.api.nvim_win_set_config, win, { footer = footer, footer_pos = pos or "center" })
end

function M.close(wins)
  for _, win in ipairs(wins) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

--- Show line numbers starting at `first` in a preview window.
function M.line_numbers(win, first, count)
  vim.wo[win].number = true
  vim.wo[win].numberwidth = math.max(#tostring(first + count - 1) + 1, 3)
  vim.wo[win].statuscolumn = ("%%#LineNr#%%=%%{v:virtnum ? '' : v:lnum + %d} "):format(first - 1)
end

---@param buf integer
---@param mode string|string[]
---@param lhs string|string[]
---@param rhs function
function M.map(buf, mode, lhs, rhs, desc)
  for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
    vim.keymap.set(mode, key, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
end

return M

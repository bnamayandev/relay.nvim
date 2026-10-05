-- A small action menu anchored at the cursor.
local ui = require("relay.ui")

local M = {}

---@class relay.MenuItem
---@field key string            key that runs the item (items also get 1, 2, 3, ...)
---@field label string
---@field detail string|nil     dimmed text after the label
---@field disabled string|nil   why the item can't run right now (shown dimmed)
---@field action fun()

---@param opts { title: string, items: relay.MenuItem[] }
---@return integer win
function M.open(opts)
  local items = opts.items
  local label_w = 0
  for _, it in ipairs(items) do
    label_w = math.max(label_w, vim.fn.strdisplaywidth(it.label))
  end
  local lines, width = {}, 0
  for i, it in ipairs(items) do
    local line = "  " .. it.key .. "  " .. it.label
    if it.detail then
      line = line .. string.rep(" ", label_w - vim.fn.strdisplaywidth(it.label) + 3) .. it.detail
    end
    lines[i] = line .. " "
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]))
  end
  local title = " " .. opts.title .. " "
  local cols, rows = ui.screen()
  local border = ui.has_border() and 2 or 0
  width = math.min(math.max(width, vim.fn.strdisplaywidth(title) + 2, 30), cols - border)
  local height = #lines

  -- just below the cursor, or above it when there's no room
  local origin = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(origin)
  local pos = vim.fn.screenpos(origin, cursor[1], cursor[2] + 1)
  local row, col
  if pos.row > 0 then
    row = pos.row
    if row + height + border > rows then
      row = pos.row - 1 - height - border
    end
    col = pos.col - 1
  else
    row = math.floor((rows - height - border) / 2)
    col = math.floor((cols - width - border) / 2)
  end
  row = math.max(0, math.min(row, rows - height - border))
  col = math.max(0, math.min(col, cols - width - border))

  local buf = ui.scratch(lines)
  vim.bo[buf].modifiable = false
  for i, it in ipairs(items) do
    vim.api.nvim_buf_set_extmark(buf, ui.ns, i - 1, 2, {
      end_col = 2 + #it.key,
      hl_group = it.disabled and "RelayMuted" or "RelayKey",
    })
    if it.disabled then
      vim.api.nvim_buf_set_extmark(buf, ui.ns, i - 1, 2 + #it.key, { end_col = #lines[i], hl_group = "RelayMuted" })
    elseif it.detail then
      local start = #lines[i] - 1 - #it.detail
      vim.api.nvim_buf_set_extmark(buf, ui.ns, i - 1, start, { end_col = #lines[i], hl_group = "RelayMuted" })
    end
  end

  local win = vim.api.nvim_open_win(
    buf,
    true,
    ui.win_config({
      row = row,
      col = col,
      width = width,
      height = height,
      zindex = 70,
      title = { { title, "RelayTitle" } },
      title_pos = "left",
      footer = ui.hints({ { "⏎", "select" }, { "q", "close" } }, width),
      footer_pos = "right",
    })
  )
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  for i, it in ipairs(items) do
    if not it.disabled then
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      break
    end
  end

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    ui.close({ win })
  end
  local function run(it)
    if not it then
      return
    end
    if it.disabled then
      return require("relay.util").warn(it.disabled)
    end
    close()
    vim.schedule(it.action)
  end

  for i, it in ipairs(items) do
    ui.map(buf, "n", { it.key, tostring(i) }, function()
      run(it)
    end, it.label)
  end
  ui.map(buf, "n", "<CR>", function()
    run(items[vim.api.nvim_win_get_cursor(win)[1]])
  end, "Select")
  ui.map(buf, "n", { "q", "<Esc>" }, close, "Close")
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
  return win
end

return M

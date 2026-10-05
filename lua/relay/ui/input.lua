-- A small multi-line text box (notes, messages).
local ui = require("relay.ui")

local M = {}

---@param opts { title: string, text?: string, on_submit: fun(text: string), on_cancel?: fun(), submit_label?: string }
function M.open(opts)
  local lines = vim.split(opts.text or "", "\n", { plain = true })
  local buf = ui.scratch(lines)
  local width = ui.width(0.5)
  local height = math.max(3, math.min(#lines + 1, 12))
  local cols, rows = ui.screen()
  local win = vim.api.nvim_open_win(
    buf,
    true,
    ui.win_config({
      row = math.max(0, math.floor((rows - height) / 2) - 1),
      col = math.max(0, math.floor((cols - width - 2) / 2)),
      width = width,
      height = height,
      zindex = 80,
      title = { { " " .. opts.title .. " ", "RelayTitle" } },
      title_pos = "left",
      footer = ui.hints({
        { "⏎", opts.submit_label or "save" },
        { "^j", "new line" },
        { "^c", "cancel" },
      }, width),
      footer_pos = "center",
    })
  )
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  ui.no_completion()

  local done = false
  local function finish(submitted)
    if done then
      return
    end
    done = true
    local text = vim.api.nvim_buf_is_valid(buf)
        and vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
      or ""
    if vim.api.nvim_get_current_win() == win then
      vim.cmd.stopinsert()
    end
    ui.close({ win })
    vim.schedule(function()
      if submitted then
        opts.on_submit(text)
      elseif opts.on_cancel then
        opts.on_cancel()
      end
    end)
  end

  ui.map(buf, { "i", "n" }, "<CR>", function()
    finish(true)
  end, "Save")
  ui.map(buf, { "i", "n" }, "<C-c>", function()
    finish(false)
  end, "Cancel")
  ui.map(buf, "n", { "<Esc>", "q" }, function()
    finish(false)
  end, "Cancel")
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        finish(false)
      end)
    end,
  })

  vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
  vim.cmd("startinsert!")
end

return M

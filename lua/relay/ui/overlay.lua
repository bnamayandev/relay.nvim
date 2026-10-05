-- The overlay opened from visual mode: a preview of the selection and its context for the agent.
local config = require("relay.config")
local ui = require("relay.ui")
local queue = require("relay.queue")
local format = require("relay.format")

local M = {}

---@param data table snippet data from relay.capture
function M.open(data)
  local cfg = config.options
  local state = { format = data.format, diagnostics = data.diagnostics }
  local width = ui.width()
  local cols, rows = ui.screen()
  local border = ui.has_border() and 2 or 0
  local total = #data.text
  local ph = math.max(1, math.min(total, cfg.ui.max_preview, rows - 7 - 2 * border))
  local nh = 3
  local row = math.max(0, math.floor((rows - (ph + nh + 2 * border)) / 2) - 1)
  local col = math.max(0, math.floor((cols - width - border) / 2))
  local range = data.srow == data.erow and (":" .. data.srow) or (":%d-%d"):format(data.srow, data.erow)
  local ndiag = #format.diagnostics(data)

  -- preview of the selection
  local pbuf = ui.scratch(data.text)
  vim.bo[pbuf].modifiable = false
  local pwin = vim.api.nvim_open_win(
    pbuf,
    false,
    ui.win_config({
      row = row,
      col = col,
      width = width,
      height = ph,
      focusable = false,
      title = { { (" %s %s%s "):format(cfg.ui.icon, data.name, range), "RelayTitle" } },
      title_pos = "left",
      footer = nil, -- set below: format / diagnostics state
      footer_pos = "right",
    })
  )
  vim.wo[pwin].wrap = false
  ui.line_numbers(pwin, data.srow, total)
  ui.highlight(pbuf, data.ft)

  -- toggles live in the preview's footer, actions in the note's footer
  local function toggles()
    local probe = setmetatable({ format = state.format }, { __index = data })
    local mode = format.mode(probe)
    local hints = {
      { "^f", mode == "ref" and "@mention" or "inline code" },
      { "^d", (state.diagnostics and "diagnostics" or "no diagnostics") .. (ndiag > 0 and (" (" .. ndiag .. ")") or "") },
    }
    if total > ph then
      table.insert(hints, 1, { "^e/^y", ("scroll +%d"):format(total - ph) })
    end
    return ui.hints(hints, width)
  end
  ui.set_footer(pwin, toggles(), "right")

  -- note
  local nbuf = ui.scratch({ "" })
  local function hints()
    local n = queue.count()
    return ui.hints({
      { "⏎", "send" },
      { "⇥", n > 0 and ("queue (" .. n .. ")") or "queue" },
      { "^a", "queue & send all" },
      { "^s", "send+⏎" },
      { "^t", "pick session" },
      { "^c", "close" },
    }, width)
  end
  local nwin = vim.api.nvim_open_win(
    nbuf,
    true,
    ui.win_config({
      row = row + ph + border,
      col = col,
      width = width,
      height = nh,
      title = { { " Context ", "RelayTitle" }, { "(optional, sent as \"context: code\") ", "RelayMuted" } },
      title_pos = "left",
      footer = hints(),
      footer_pos = "center",
    })
  )
  vim.wo[nwin].wrap = true
  vim.wo[nwin].linebreak = true
  ui.no_completion()

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_get_current_win() == nwin then
      vim.cmd.stopinsert()
    end
    ui.close({ nwin, pwin })
  end

  local function snippet()
    local it = vim.deepcopy(data)
    if vim.api.nvim_buf_is_valid(nbuf) then
      it.note = vim.trim(table.concat(vim.api.nvim_buf_get_lines(nbuf, 0, -1, false), "\n"))
    end
    it.format = state.format
    it.diagnostics = state.diagnostics
    return it
  end

  local function action(fn)
    return function()
      local it = snippet()
      close()
      vim.schedule(function()
        fn(it)
      end)
    end
  end

  local function enqueue(it)
    local index, existed = queue.add(it)
    require("relay")._queued(index, it, existed)
  end

  local function send(opts)
    return action(function(it)
      require("relay.send").send(vim.tbl_extend("force", { items = { it } }, opts))
    end)
  end

  local function scroll(key)
    return function()
      if vim.api.nvim_win_is_valid(pwin) then
        vim.api.nvim_win_call(pwin, function()
          vim.cmd("normal! " .. vim.keycode(key))
        end)
      end
    end
  end

  local modes = { "i", "n" }
  ui.map(nbuf, modes, "<CR>", send({}), "Relay: send to the agent")
  ui.map(nbuf, modes, "<C-s>", send({ submit = true }), "Relay: send and press Enter")
  ui.map(nbuf, modes, "<C-t>", send({ pick = true }), "Relay: send to a chosen session")
  ui.map(nbuf, modes, "<Tab>", action(enqueue), "Relay: add to queue")
  ui.map(
    nbuf,
    modes,
    "<C-a>",
    action(function(it)
      queue.add(it)
      require("relay.send").send()
    end),
    "Relay: add to queue and send the queue"
  )
  ui.map(nbuf, modes, "<C-f>", function()
    local probe = setmetatable({ format = state.format }, { __index = data })
    -- flip what will actually be sent; "auto" is kept when it already gives that
    local want = format.mode(probe) == "ref" and "inline" or "ref"
    state.format = want
    if format.mode(setmetatable({}, { __index = data })) == want then
      state.format = nil
    end
    ui.set_footer(pwin, toggles(), "right")
  end, "Relay: toggle @mention / inline code")
  ui.map(nbuf, modes, "<C-d>", function()
    state.diagnostics = not state.diagnostics
    ui.set_footer(pwin, toggles(), "right")
  end, "Relay: toggle diagnostics")
  ui.map(nbuf, modes, "<C-e>", scroll("<C-e>"), "Relay: scroll preview down")
  ui.map(nbuf, modes, "<C-y>", scroll("<C-y>"), "Relay: scroll preview up")
  ui.map(nbuf, modes, "<C-c>", close, "Relay: close")
  ui.map(nbuf, "n", { "<Esc>", "q" }, close, "Relay: close")

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = nbuf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
  vim.cmd.startinsert()
end

return M

local M = {}

---@class relay.Keymaps
---@field menu string|false     normal + visual: action menu for the line / selection
---@field open string|false     visual: open the overlay for the selection
---@field add string|false      visual: add the selection to the queue without the menu
---@field queue string|false    normal: open the queue
---@field send string|false     normal: send the queue
---@field file string|false     normal: add the current file to the queue
---@field note string|false     normal: edit the context of the queued snippet under the cursor
---@field clear string|false    normal: clear the queue
---@field target string|false   normal: pin (or unpin) the session sends go to
---@field sessions string|false normal: jump to a running Claude Code session

---@class relay.Config
---@field keymaps relay.Keymaps|false
---@field format "auto"|"ref"|"inline"
---@field submit boolean
---@field focus boolean|"auto"
---@field clear_on_send boolean
---@field diagnostics boolean
---@field clipboard_fallback boolean
---@field submit_delay integer
---@field claude_dir string|nil
---@field backends table<string, boolean>
---@field signs boolean
---@field virtual_text boolean
---@field ui { border: string|string[], width: number, max_preview: integer, icon: string }
local defaults = {
  keymaps = {
    menu = "<leader>aq",
    open = "<leader>aa",
    add = false,
    queue = false,
    send = "<leader>as",
    file = "<leader>af",
    note = "<leader>an",
    clear = "<leader>ax",
    target = "<leader>at",
    sessions = "<leader>aj",
  },
  -- How a snippet is handed to Claude:
  --   "ref"    -> @path#L10-20 mention; Claude reads the lines from disk
  --   "inline" -> the code itself in a fenced block
  --   "auto"   -> ref when the file is saved on disk, inline otherwise (unsaved, no file, deleted)
  format = "auto",
  -- Press Enter in Claude after pasting. When false the text waits in Claude's prompt.
  submit = false,
  -- Switch to the Claude pane after sending. "auto" focuses only when not submitting.
  focus = "auto",
  -- Empty the queue after it was delivered (restorable with :Relay restore).
  clear_on_send = true,
  -- Include LSP diagnostics of the selected lines by default (toggle per snippet).
  diagnostics = false,
  -- Copy the message to the clipboard when no session can receive it.
  clipboard_fallback = true,
  -- Milliseconds between pasting and pressing Enter.
  submit_delay = 80,
  -- Claude Code's config dir. Defaults to $CLAUDE_CONFIG_DIR or ~/.claude.
  claude_dir = nil,
  -- Where sessions can be reached. Disable a backend to ignore sessions hosted by it.
  backends = { nvim = true, tmux = true, zellij = true, kitty = true, wezterm = true },
  -- Mark queued lines in the sign column.
  signs = true,
  -- Show the queue number and note after the first queued line.
  virtual_text = true,
  ui = {
    border = "rounded",
    width = 0.6, -- fraction of the editor width
    max_preview = 15, -- max lines of code shown in previews
    icon = "󰚩",
  },
}

---@type relay.Config
M.options = vim.deepcopy(defaults)

local FORMATS = { auto = true, ref = true, inline = true }

---@param opts relay.Config|table|nil
function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  if not FORMATS[M.options.format] then
    vim.notify(
      ("relay.nvim: invalid format %q, using \"auto\""):format(tostring(M.options.format)),
      vim.log.levels.WARN
    )
    M.options.format = "auto"
  end
  return M.options
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return M

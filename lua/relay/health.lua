local M = {}

function M.check()
  local health = vim.health
  local util = require("relay.util")
  local sessions = require("relay.sessions")

  health.start("relay.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required")
  end

  if vim.fn.executable("claude") == 1 then
    health.ok("`claude` found: " .. vim.fn.exepath("claude"))
  else
    health.warn("`claude` is not on PATH (only needed to start sessions; sending works without it)")
  end

  local registry = vim.fs.joinpath(sessions.claude_dir(), "sessions")
  if util.uv.fs_stat(registry) then
    health.ok("Claude Code session registry: " .. registry)
  else
    health.info("No session registry at " .. registry .. " (older Claude Code; processes are scanned instead)")
  end

  if util.is_linux then
    health.ok("Process info from /proc (no subprocess per lookup)")
  else
    health.info("Not on Linux: sessions in zellij, kitty and remote Neovims can't be located; tmux, wezterm and Neovim terminals work")
  end

  health.start("relay.nvim: terminals")
  if vim.fn.executable("tmux") == 1 then
    health.ok("tmux: " .. vim.trim(vim.fn.system({ "tmux", "-V" })))
  else
    health.info("tmux not found")
  end
  if vim.fn.executable("zellij") == 1 then
    local version = vim.trim(vim.fn.system({ "zellij", "--version" }))
    local major, minor = version:match("(%d+)%.(%d+)")
    if major and (tonumber(major) > 0 or tonumber(minor) >= 44) then
      health.ok(version .. " (pastes into any pane directly)")
    else
      health.ok(
        version
          .. ": older zellij can only type into the focused pane, so Relay briefly moves focus to the"
          .. " Claude pane (0.44+ pastes without moving focus)"
      )
    end
  else
    health.info("zellij not found")
  end
  if vim.env.KITTY_WINDOW_ID then
    if vim.env.KITTY_LISTEN_ON and vim.env.KITTY_LISTEN_ON ~= "" then
      health.ok("kitty remote control: " .. vim.env.KITTY_LISTEN_ON)
    else
      health.info(
        "kitty remote control is off, so sessions running directly in kitty windows can't be reached "
          .. "(add `allow_remote_control socket-only` and `listen_on unix:/tmp/kitty` to kitty.conf)"
      )
    end
  end
  if vim.fn.executable("wezterm") == 1 then
    health.ok("wezterm found")
  end

  health.start("relay.nvim: live sessions")
  local list
  sessions.discover(function(l)
    list = l
  end)
  vim.wait(3000, function()
    return list ~= nil
  end, 20)
  if not list then
    health.warn("Session discovery timed out")
    return
  end
  if #list == 0 then
    health.info("No running Claude Code sessions")
  end
  for _, s in ipairs(list) do
    if s.reachable then
      health.ok(sessions.label(s))
    else
      health.warn(sessions.label(s))
    end
  end
end

return M

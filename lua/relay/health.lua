local M = {}

function M.check()
  local health = vim.health
  local util = require("relay.util")
  local sessions = require("relay.sessions")
  local agents = require("relay.agents")
  local config = require("relay.config")

  health.start("relay.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required")
  end

  if util.is_linux then
    health.ok("Process info from /proc (no subprocess per lookup)")
  else
    health.info("Not on Linux: sessions in zellij, kitty and remote Neovims can't be located; tmux, wezterm and Neovim terminals work")
  end

  health.start("relay.nvim: agents")
  local launch = require("relay.launch")
  for _, a in ipairs(agents.list) do
    local exe = launch.program(a.id)
    if config.options.agents[a.id] == false then
      health.info(a.label .. ": disabled in `agents`")
    elseif not exe then
      health.info(a.label .. ": not offered when no session is running (`launch`)")
    elseif vim.fn.executable(exe) == 1 then
      health.ok(("%s: `%s` found: %s (can be started)"):format(a.label, exe, vim.fn.exepath(exe)))
    else
      health.info(("%s: `%s` is not on PATH (only needed to start sessions)"):format(a.label, exe))
    end
  end

  local registry = vim.fs.joinpath(sessions.claude_dir(), "sessions")
  if util.uv.fs_stat(registry) then
    health.ok("Claude Code session registry: " .. registry)
  else
    health.info("No session registry at " .. registry .. " (older Claude Code; processes are scanned instead)")
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
          .. " agent's pane (0.44+ pastes without moving focus)"
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
    health.info("No running agent sessions")
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

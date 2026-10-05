-- The coding agents Relay can send to, and how to recognize their processes.
--
-- Agents are recognized by their command line, not by the process name: the npm installs run
-- a node wrapper that starts a native binary on the same terminal, and Copilot's native
-- binary renames itself to "MainThread".
local proc = require("relay.proc")

local M = {}

---@class relay.Agent
---@field id string
---@field label string
---@field names table<string, true>        executable names
---@field package string                   path fragment of the npm package (node wrappers)
---@field print_flags table<string, true>  flags that run one prompt and exit
---@field non_interactive table<string, true> subcommands without an interactive prompt
---@field paste_suffix string|nil          appended to every paste

---@type relay.Agent[]
M.list = {
  {
    id = "claude",
    label = "Claude Code",
    names = { claude = true, ["claude.exe"] = true },
    package = "claude-code",
    print_flags = { ["-p"] = true, ["--print"] = true },
    non_interactive = {
      mcp = true,
      config = true,
      doctor = true,
      update = true,
      upgrade = true,
      install = true,
      plugin = true,
      plugins = true,
      ["migrate-installer"] = true,
      ["setup-token"] = true,
    },
  },
  {
    id = "codex",
    label = "Codex",
    names = { codex = true, ["codex.exe"] = true },
    package = "/@openai/codex/",
    print_flags = {}, -- `-p` is --profile; one-shot runs are `codex exec`
    non_interactive = {
      exec = true,
      e = true,
      review = true,
      login = true,
      logout = true,
      mcp = true,
      plugin = true,
      ["mcp-server"] = true,
      ["app-server"] = true,
      ["remote-control"] = true,
      ["exec-server"] = true,
      completion = true,
      update = true,
      doctor = true,
      sandbox = true,
      debug = true,
      apply = true,
      a = true,
      archive = true,
      delete = true,
      unarchive = true,
      cloud = true,
      features = true,
      help = true,
    },
    -- a message ending in `@path#L1` would leave Codex's file search popup open, and that
    -- popup takes the Enter meant to submit
    paste_suffix = " ",
  },
  {
    id = "copilot",
    label = "Copilot",
    names = { copilot = true, ["copilot.exe"] = true },
    package = "/@github/copilot/",
    print_flags = { ["-p"] = true, ["--prompt"] = true },
    non_interactive = {
      app = true,
      login = true,
      help = true,
      init = true,
      config = true,
      update = true,
      version = true,
      workflow = true,
      sessions = true,
      memories = true,
      plugin = true,
      mcp = true,
      skill = true,
      instruction = true,
      lsp = true,
      sandbox = true,
      completion = true,
    },
  },
}

---@type table<string, relay.Agent>
M.by_id = {}
for _, a in ipairs(M.list) do
  M.by_id[a.id] = a
end

local INTERPRETERS = { node = true, nodejs = true, bun = true, deno = true }

local function basename(path)
  return (path or ""):match("([^/\\]*)$")
end

--- The agent whose program this command line runs, and the index of its first argument.
---@param argv string[]
---@return relay.Agent|nil
---@return integer|nil
local function program(argv)
  local exe = basename(argv[1])
  for _, a in ipairs(M.list) do
    if a.names[exe] then
      return a, 2
    end
  end
  if not INTERPRETERS[exe] then
    return nil
  end
  -- `node .../bin/codex`, `node .../@github/copilot/npm-loader.js`
  local script = argv[2] or ""
  for _, a in ipairs(M.list) do
    if a.names[basename(script)] or script:find(a.package, 1, true) then
      return a, 3
    end
  end
end

--- The agent an interactive process runs, or nil (also for one-shot runs like `claude -p`).
---@param argv string[]
---@return relay.Agent|nil
function M.match(argv)
  local a, first = program(argv)
  if not a then
    return nil
  end
  for i = first, #argv do
    local arg = argv[i]
    if a.print_flags[arg] or a.print_flags[arg:match("^(%-%-[^=]+)=") or ""] then
      return nil
    end
  end
  if argv[first] and a.non_interactive[argv[first]] then
    return nil
  end
  return a
end

---@param p relay.Proc
---@return relay.Agent|nil
function M.detect(p)
  if p.agent == nil then
    p.agent = M.match(proc.argv(p)) or false
  end
  return p.agent or nil
end

return M

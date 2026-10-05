local M = {}

local uv = vim.uv or vim.loop
M.uv = uv
M.is_linux = uv.os_uname().sysname == "Linux"

---@param msg string
---@param level? integer
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Relay" })
end

function M.info(msg)
  M.notify(msg, vim.log.levels.INFO)
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

---@param path string
---@return string|nil
function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local ok, data = pcall(f.read, f, "*a")
  f:close()
  return ok and data or nil
end

---@param path string|nil
function M.is_file(path)
  local st = path and path ~= "" and uv.fs_stat(path)
  return st and st.type == "file" or false
end

---@param path string|nil
---@return string|nil
function M.realpath(path)
  if not path or path == "" then
    return nil
  end
  return uv.fs_realpath(path) or path
end

--- Path of `path` relative to the directory `base`, or nil when it is not inside it.
---@param base string|nil
---@param path string|nil
---@return string|nil
function M.relpath(base, path)
  if not base or base == "" or not path then
    return nil
  end
  base = base:gsub("/+$", "")
  if base == "" then
    return path:sub(2)
  end
  if path:sub(1, #base + 1) == base .. "/" then
    return path:sub(#base + 2)
  end
end

--- `~/foo` style path for display.
function M.home(path)
  return vim.fn.fnamemodify(path, ":~")
end

--- Path relative to Neovim's cwd when inside it, `~/...` otherwise.
function M.display(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

function M.first_line(s)
  return (s or ""):match("^[^\n]*")
end

---@param s string
---@param width integer
function M.truncate(s, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  if width == 1 then
    return "…"
  end
  local n = vim.fn.strchars(s)
  local out = vim.fn.strcharpart(s, 0, math.min(n, width - 1))
  while out ~= "" and vim.fn.strdisplaywidth(out) > width - 1 do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out .. "…"
end

--- Like truncate, but keeps the end ("…/projects/app").
---@param s string
---@param width integer
function M.truncate_left(s, width)
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  local n = vim.fn.strchars(s)
  local start = 0
  while start < n and vim.fn.strdisplaywidth(vim.fn.strcharpart(s, start)) > width - 1 do
    start = start + 1
  end
  return "…" .. vim.fn.strcharpart(s, start)
end

---@param n integer
---@param word string
function M.plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

--- Run a command without blocking. `cb(ok, stdout, err)` runs on the main loop.
---@param cmd string[]
---@param opts? { stdin?: string, timeout?: integer, env?: table<string, string> }
---@param cb fun(ok: boolean, stdout: string, err: string)
function M.run(cmd, opts, cb)
  opts = opts or {}
  local function finish(ok, out, err)
    vim.schedule(function()
      cb(ok, out or "", err or "")
    end)
  end
  if vim.fn.executable(cmd[1]) ~= 1 then
    return finish(false, "", cmd[1] .. ": command not found")
  end
  local ok, err = pcall(vim.system, cmd, {
    text = true,
    stdin = opts.stdin,
    env = opts.env,
    timeout = opts.timeout or 3000,
  }, function(res)
    local msg = vim.trim(res.stderr or "")
    if res.code == 124 then
      msg = "timed out"
    elseif msg == "" then
      msg = "exit code " .. tostring(res.code)
    end
    finish(res.code == 0, res.stdout, msg)
  end)
  if not ok then
    finish(false, "", tostring(err))
  end
end

--- Run several commands in parallel; `cb(results)` gets `{ [key] = { ok, out, err } }`.
---@param jobs table<string, { cmd: string[], opts?: table }>
---@param cb fun(results: table<string, { ok: boolean, out: string, err: string }>)
function M.run_all(jobs, cb)
  local keys = vim.tbl_keys(jobs)
  local pending = #keys
  local results = {}
  if pending == 0 then
    return cb(results)
  end
  for _, key in ipairs(keys) do
    M.run(jobs[key].cmd, jobs[key].opts, function(ok, out, err)
      results[key] = { ok = ok, out = out, err = err }
      pending = pending - 1
      if pending == 0 then
        cb(results)
      end
    end)
  end
end

--- Current git branch (or short commit) of the repository containing `dir`.
---@param dir string|nil
---@return string|nil
function M.git_branch(dir)
  if not dir or dir == "" then
    return nil
  end
  local git = vim.fs.find(".git", { path = dir, upward = true, limit = 1 })[1]
  if not git then
    return nil
  end
  local gitdir = git
  local st = uv.fs_stat(git)
  if st and st.type == "file" then
    -- worktrees and submodules: ".git" is a file pointing at the real git dir
    local target = (M.read_file(git) or ""):match("gitdir:%s*(.-)%s*$")
    if not target then
      return nil
    end
    if target:sub(1, 1) ~= "/" then
      target = vim.fs.joinpath(vim.fs.dirname(git), target)
    end
    gitdir = target
  end
  local head = M.read_file(vim.fs.joinpath(gitdir, "HEAD"))
  if not head then
    return nil
  end
  local ref = head:match("^ref:%s*refs/heads/(.-)%s*$")
  if ref then
    return ref
  end
  local sha = head:match("^(%x+)")
  return sha and sha:sub(1, 7) or nil
end

--- Copy text to the system clipboard (and the unnamed register).
---@return boolean copied_to_system_clipboard
function M.copy(text)
  pcall(vim.fn.setreg, '"', text)
  if vim.fn.has("clipboard") == 1 then
    return (pcall(vim.fn.setreg, "+", text))
  end
  return false
end

return M

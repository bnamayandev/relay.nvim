-- Test suite. Run from the repository root:
--   nvim --headless --clean -l tests/run.lua
-- The end-to-end tests start fake Claude sessions (python3) in Neovim terminals; nothing is
-- ever sent to a real session.
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
vim.opt.rtp:prepend(root)
vim.cmd("runtime plugin/relay.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/project", "p")
vim.fn.mkdir(tmp .. "/claude/sessions", "p")
vim.fn.chdir(tmp .. "/project")

local relay = require("relay")
relay.setup({ claude_dir = tmp .. "/claude", submit = false, submit_delay = 30 })
local util = require("relay.util")
local proc = require("relay.proc")
local queue = require("relay.queue")
local capture = require("relay.capture")
local format = require("relay.format")
local transport = require("relay.transport")
local sessions = require("relay.sessions")
local agents = require("relay.agents")

local passed, failed = 0, 0
local current = ""

local function test(name, fn)
  current = name
  local ok, err = xpcall(fn, debug.traceback)
  queue.clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buftype ~= "terminal" then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if ok then
    passed = passed + 1
    print("ok    " .. name)
  else
    failed = failed + 1
    print("FAIL  " .. name .. "\n      " .. tostring(err):gsub("\n", "\n      "))
  end
end

local function eq(expected, actual, what)
  if not vim.deep_equal(expected, actual) then
    error(("%s: expected %s, got %s"):format(what or "value", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function truthy(v, what)
  if not v then
    error((what or "condition") .. " is false", 2)
  end
end

local function write(path, lines)
  vim.fn.writefile(lines, path)
end

local LINES = { "local a = 1", "local bé = 2 -- é", "local c = 3", "return a + bé + c" }

local function open_file(name, lines)
  local path = tmp .. "/project/" .. name
  write(path, lines or LINES)
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  return path, vim.api.nvim_get_current_buf()
end

local function select(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "nx", false)
end

--- Make a selection, then run fn while still in visual mode (like a mapping does).
local function in_visual(keys, fn)
  local result
  vim.keymap.set("x", "<F12>", function()
    result = { fn() }
  end)
  vim.api.nvim_feedkeys(vim.keycode(keys .. "<F12>"), "mx", false)
  vim.keymap.del("x", "<F12>")
  return unpack(result)
end

-- the file on disk changes behind Neovim's back (as when Claude edits it)
local function external_write(path, lines)
  local stat = vim.uv.fs_stat(path)
  write(path, lines)
  -- make sure the mtime differs even on coarse filesystems
  vim.uv.fs_utime(path, stat.mtime.sec + 2, stat.mtime.sec + 2)
  vim.cmd("checktime")
end

vim.o.autoread = true

-- unit ---------------------------------------------------------------------------------

test("tty numbers map to pts paths", function()
  eq("/dev/pts/1", proc.tty_name(34817))
  eq("/dev/pts/300", proc.tty_name(137 * 256 + 44))
  eq(nil, proc.tty_name(0))
end)

test("/proc stat parsing handles odd command names", function()
  local fields = {}
  for i = 3, 52 do
    fields[#fields + 1] = tostring(i)
  end
  fields[2], fields[5], fields[20] = "77", "34817", "123456"
  local p = proc.parse_stat(42, "42 (we (ird) name) " .. table.concat(fields, " "))
  eq("we (ird) name", p.comm)
  eq(77, p.ppid)
  eq("/dev/pts/1", p.tty)
  eq("123456", p.start)
end)

test("sanitize removes anything that could escape the paste", function()
  eq("a\tb\nc\nd[201~x", transport.sanitize("a\tb\r\nc\rd\27[201~\3x"))
  eq("é", transport.sanitize("é\194\155"))
end)

test("chunks split on lines and never inside a character", function()
  local text = ("é"):rep(10) .. "\n" .. ("x"):rep(30) .. "\n" .. ("é"):rep(40)
  local pieces = transport.chunks(text, 25)
  eq(text, table.concat(pieces))
  for _, p in ipairs(pieces) do
    truthy(#p <= 25, "chunk size")
    truthy(vim.str_utfindex and pcall(vim.str_utfindex, p) or true, "valid utf-8")
    truthy(not p:find("^[\128-\191]"), "chunk starts mid-character")
  end
end)

test("mentions are relative to the session and quoted when needed", function()
  local dir = tmp .. "/project"
  write(dir .. "/a.lua", { "x" })
  vim.fn.mkdir(dir .. "/sp ace", "p")
  write(dir .. "/sp ace/b.lua", { "x" })
  write(dir .. "/c.c++", { "x" })
  write(dir .. "/d#e.lua", { "x" })
  eq("@a.lua#L1-2", format.mention(dir .. "/a.lua", "#L1-2", dir))
  eq("@" .. util.realpath(dir .. "/a.lua") .. "#L3", format.mention(dir .. "/a.lua", "#L3", "/somewhere/else"))
  eq('@"sp ace/b.lua#L1"', format.mention(dir .. "/sp ace/b.lua", "#L1", dir))
  eq('@"c.c++"', format.mention(dir .. "/c.c++", nil, dir))
  eq("@c.c++#L1", format.mention(dir .. "/c.c++", "#L1", dir))
  eq(nil, format.mention(dir .. "/d#e.lua", "#L1", dir))
end)

test("agents are recognized by their command line", function()
  local function id(argv)
    local a = agents.match(argv)
    return a and a.id or nil
  end
  eq("claude", id({ "claude" }))
  eq("claude", id({ "node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js" }))
  eq(nil, id({ "claude", "-p", "hi" }))
  eq(nil, id({ "claude", "mcp", "list" }))
  -- the npm wrapper and the native binary it starts
  eq("codex", id({ "node", "/home/u/.nvm/versions/node/v22/bin/codex", "-c", "x=1" }))
  eq("codex", id({ "/x/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex" }))
  eq("codex", id({ "codex", "-p", "work" }), "-p is --profile for codex")
  eq("codex", id({ "codex", "resume", "--last" }))
  eq(nil, id({ "codex", "exec", "fix it" }))
  eq(nil, id({ "codex", "e", "fix it" }))
  eq("copilot", id({ "node", "/usr/lib/node_modules/.bin/copilot" }))
  eq("copilot", id({ "node", "/usr/lib/node_modules/@github/copilot/npm-loader.js" }))
  eq("copilot", id({ "/x/node_modules/@github/copilot-linux-x64/copilot", "--resume" }))
  eq("copilot", id({ "copilot", "-i", "fix it" }))
  eq(nil, id({ "copilot", "-p", "fix it" }))
  eq(nil, id({ "copilot", "--prompt=fix it" }))
  eq(nil, id({ "copilot", "login" }))
  -- not agents
  eq(nil, id({ "node", "/x/node_modules/@github/copilot-language-server/dist/language-server.js", "--stdio" }))
  eq(nil, id({ "node", "server.js" }))
  eq(nil, id({ "zsh" }))
  eq(nil, id({}))
end)

test("session labels name the agent", function()
  local base = { pid = 7, cwd = "/srv/api", reachable = true, where = "tmux w:1.0" }
  eq("api  /srv/api  · codex  tmux w:1.0", sessions.label(vim.tbl_extend("force", base, { agent = "codex" })))
  eq(
    "refactor  /srv/api  [main]  ○ claude idle  tmux w:1.0",
    sessions.label(vim.tbl_extend("force", base, { agent = "claude", status = "idle", name = "refactor", branch = "main" }))
  )
  eq("copilot api", sessions.short(vim.tbl_extend("force", base, { agent = "copilot" })))
end)

-- capture ------------------------------------------------------------------------------

test("linewise selection", function()
  local path, buf = open_file("v1.lua")
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  local data = in_visual("Vj", capture.selection)
  eq("range", data.kind)
  eq(path, data.path)
  eq(buf, data.buf)
  eq({ 2, 3 }, { data.srow, data.erow })
  eq({ LINES[2], LINES[3] }, data.text)
  eq("n", vim.fn.mode())
end)

test("charwise selection keeps exact text, including a multibyte last char", function()
  open_file("v2.lua")
  -- from "a" on line 1 to the "é" (2 bytes) of "bé" on line 2
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  local data = in_visual("vjl", capture.selection)
  eq({ "a = 1", "local bé" }, data.text)
  eq({ 1, 2, 6, 9 }, { data.srow, data.erow, data.scol, data.ecol })
  -- to the end of the line
  vim.api.nvim_win_set_cursor(0, { 2, 6 })
  data = in_visual("v$", capture.selection)
  eq("bé = 2 -- é", data.text[1])
  eq({ 2, 6, #LINES[2] }, { data.erow, data.scol, data.ecol })
end)

test("blockwise selection", function()
  open_file("v3.lua")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local data = in_visual("<C-v>jjll", capture.selection)
  eq("\22", data.vmode)
  eq({ "loc", "loc", "loc" }, data.text)
  eq({ 1, 3 }, { data.srow, data.erow })
end)

test("command ranges and the 'nothing selected' error", function()
  open_file("v4.lua")
  local data = capture.selection({ range = 2, line1 = 3, line2 = 4 })
  eq({ LINES[3], LINES[4] }, data.text)
  local none, err = capture.selection()
  eq(nil, none)
  truthy(err and err:find("select"), "error message")
  -- :'<,'>Relay add after a charwise selection keeps the exact shape
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  select("vl<Esc>")
  data = capture.selection({ range = 2, line1 = 1, line2 = 1 })
  eq({ "a " }, data.text)
end)

-- format -------------------------------------------------------------------------------

test("saved files are mentioned, unsaved code is inlined", function()
  local _, buf = open_file("f1.lua")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local data = in_visual("Vj", capture.selection)
  data.note = "why two?"
  eq("why two?: @f1.lua#L2-3", format.item(data, tmp .. "/project"))
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- new" })
  local text = format.item(data, tmp .. "/project")
  truthy(text:find("^why two%?: f1%.lua %(lines 2%-3, unsaved%):\n```lua\n"), text)
  truthy(text:find("\n```$"), text)
end)

test("context is one line in front of the snippet", function()
  open_file("f4.lua")
  local data = capture.selection({ range = 2, line1 = 2, line2 = 2 })
  data.note = "  first\n  second:  "
  eq("first second: @f4.lua#L2", format.item(data, tmp .. "/project"))
  data.note = ""
  eq("@f4.lua#L2", format.item(data, tmp .. "/project"))
end)

test("inline fences outgrow backticks in the code", function()
  local data = {
    kind = "range",
    name = "[No Name]",
    ft = "markdown",
    srow = 1,
    erow = 2,
    text = { "```lua", "x" },
    note = "",
  }
  eq("[No Name] (lines 1-2):\n````markdown\n```lua\nx\n````", format.item(data))
end)

test("diagnostics of the range are included on request", function()
  local _, buf = open_file("f2.lua")
  local ns = vim.api.nvim_create_namespace("relay.test")
  vim.diagnostic.set(ns, buf, {
    { lnum = 1, col = 0, message = "unused\nvariable", severity = vim.diagnostic.severity.WARN, source = "lua_ls" },
    { lnum = 3, col = 0, message = "outside", severity = vim.diagnostic.severity.ERROR },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local data = in_visual("Vj", capture.selection)
  data.diagnostics = true
  eq("@f2.lua#L1-2\nDiagnostics:\n- L2 warn: unused variable (lua_ls)", format.item(data, tmp .. "/project"))
end)

test("the prompt goes before all snippets", function()
  open_file("f3.lua")
  local a = capture.selection({ range = 2, line1 = 1, line2 = 1 })
  local b = capture.selection({ range = 2, line1 = 4, line2 = 4 })
  a.note = "pure?"
  eq("refactor these\n\npure?: @f3.lua#L1\n\n@f3.lua#L4", format.build({ a, b }, { cwd = tmp .. "/project", message = "refactor these" }))
  eq("@f3.lua#L4", format.build({ b }, { cwd = tmp .. "/project", message = "  " }))
end)

-- queue --------------------------------------------------------------------------------

test("queuing the same code twice updates the entry", function()
  open_file("q1.lua")
  local i1 = queue.add(capture.selection({ range = 2, line1 = 1, line2 = 2 }))
  local data = capture.selection({ range = 2, line1 = 1, line2 = 2 })
  data.note = "updated"
  local i2, existed = queue.add(data)
  eq(1, i1)
  eq(1, i2)
  truthy(existed, "existed")
  eq(1, queue.count())
  eq("updated", queue.items()[1].note)
end)

test("line numbers follow edits made in Neovim", function()
  local _, buf = open_file("q2.lua")
  queue.add(capture.selection({ range = 2, line1 = 3, line2 = 4 }))
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- 1", "-- 2" })
  queue.refresh_all()
  local item = queue.items()[1]
  eq({ 5, 6 }, { item.srow, item.erow })
  vim.api.nvim_buf_set_text(buf, 4, 10, 4, 11, { "30" })
  queue.refresh_all()
  eq({ "local c = 30", LINES[4] }, item.text)
  -- deleting the first line shrinks the snippet
  vim.api.nvim_buf_set_lines(buf, 4, 5, false, {})
  queue.refresh_all()
  eq({ 5, 5 }, { item.srow, item.erow })
  eq({ LINES[4] }, item.text)
end)

test("snippets are found again after the file changes on disk", function()
  local path, buf = open_file("q3.lua")
  queue.add(capture.selection({ range = 2, line1 = 2, line2 = 3 }))
  local item = queue.items()[1]
  external_write(path, { "-- added", "-- by", "-- claude", unpack(LINES) })
  eq(buf, item.buf)
  eq({ 5, 6 }, { item.srow, item.erow })
  truthy(not item.lost and not item.changed, "found exactly")
  eq("@q3.lua#L5-6", format.item(item, tmp .. "/project"))
  -- edited in the middle, but the first and last lines survived
  local lines = { "-- added", "-- by", "-- claude", LINES[1], LINES[2], "local inserted = true", LINES[3], LINES[4] }
  external_write(path, lines)
  eq({ 5, 7 }, { item.srow, item.erow })
  truthy(item.changed, "marked as changed")
  -- gone entirely: fall back to the text that was queued
  external_write(path, { "completely", "different" })
  truthy(item.lost, "lost")
  local text = format.item(item, tmp .. "/project")
  truthy(text:find("no longer in the file", 1, true), text)
  truthy(text:find("local inserted = true", 1, true), text)
end)

test("rewriting the queued code keeps tracking the new text", function()
  local _, buf = open_file("q8.lua")
  queue.add(capture.selection({ range = 2, line1 = 2, line2 = 2 }))
  local single = queue.items()[1]
  vim.cmd("normal! 2Gcclocal b2 = 22")
  queue.refresh_all()
  truthy(not single.lost, "single line rewritten with cc is not lost")
  eq({ 2, 2 }, { single.srow, single.erow })
  eq({ "local b2 = 22" }, single.text)
  -- a whole range replaced through the API (formatters, LSP edits)
  queue.clear()
  queue.add(capture.selection({ range = 2, line1 = 2, line2 = 3 }))
  local range = queue.items()[1]
  vim.api.nvim_buf_set_lines(buf, 1, 3, false, { "x1", "x2", "x3" })
  queue.refresh_all()
  eq({ 2, 4 }, { range.srow, range.erow })
  eq({ "x1", "x2", "x3" }, range.text)
  -- a charwise selection replaced with `c`
  queue.clear()
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  in_visual("v", relay.add)
  local word = queue.items()[1]
  vim.cmd("normal! 1G06lcwalpha")
  queue.refresh_all()
  eq({ "alpha" }, word.text)
  -- and the marks keep following edits afterwards
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- top" })
  queue.refresh_all()
  eq(2, word.srow)
  eq({ "alpha" }, word.text)
end)

test("deleting the code in Neovim marks it lost; undo brings it back", function()
  local _, buf = open_file("q4.lua")
  queue.add(capture.selection({ range = 2, line1 = 2, line2 = 3 }))
  local item = queue.items()[1]
  vim.cmd("let &undolevels = &undolevels") -- start a new undo block
  vim.cmd("normal! 2Gdj")
  queue.refresh_all()
  truthy(item.lost, "lost after delete")
  eq("inline", format.mode(item))
  vim.cmd("normal! u")
  queue.refresh_all()
  truthy(not item.lost, "back after undo")
  eq({ 2, 3 }, { item.srow, item.erow })
end)

test("wiped buffers are re-attached when the file is opened again", function()
  local path, buf = open_file("q5.lua")
  queue.add(capture.selection({ range = 2, line1 = 2, line2 = 2 }))
  local item = queue.items()[1]
  vim.cmd("bwipeout! " .. buf)
  eq(nil, item.buf)
  write(path, { "-- top", unpack(LINES) })
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  eq(vim.api.nvim_get_current_buf(), item.buf)
  eq(3, item.srow)
  truthy(item.mark, "has a mark again")
end)

test("remove, clear and restore", function()
  open_file("q6.lua")
  queue.add(capture.selection({ range = 2, line1 = 1, line2 = 1 }))
  queue.add(capture.selection({ range = 2, line1 = 2, line2 = 2 }))
  queue.add(capture.selection({ range = 2, line1 = 3, line2 = 3 }))
  queue.remove(2)
  eq({ 1, 3 }, vim.tbl_map(function(i)
    return i.srow
  end, queue.items()))
  queue.restore()
  eq({ 1, 2, 3 }, vim.tbl_map(function(i)
    return i.srow
  end, queue.items()))
  eq(3, queue.clear())
  eq(0, queue.count())
  eq(3, queue.restore())
  eq(3, queue.count())
  eq(2, queue.move(1, 1))
  eq({ 2, 1, 3 }, vim.tbl_map(function(i)
    return i.srow
  end, queue.items()))
end)

test("signs and virtual text mark queued code", function()
  local _, buf = open_file("q7.lua")
  queue.add(capture.selection({ range = 2, line1 = 2, line2 = 3 }))
  queue.items()[1].note = "check this"
  queue.emit()
  local marks = vim.api.nvim_buf_get_extmarks(buf, queue.ns, 0, -1, { details = true })
  eq(1, #marks)
  eq(1, marks[1][2])
  truthy(marks[1][4].sign_text, "sign")
  truthy(marks[1][4].virt_text[1][1]:find("#1 check this", 1, true), "virtual text")
end)

-- menu ---------------------------------------------------------------------------------

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
  vim.wait(50)
end

local function menu_lines()
  local cfg = vim.api.nvim_win_get_config(0)
  truthy(cfg.relative ~= "", "a float is focused")
  return vim.api.nvim_buf_get_lines(0, 0, -1, false), cfg
end

--- Type into the context/prompt box that is open and press Enter.
local function answer(text)
  vim.wait(200, function()
    return vim.api.nvim_win_get_config(0).relative ~= ""
  end, 10)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, "\n"))
  feed("<CR>")
  vim.wait(50)
end

test("<leader>aq opens the menu for the cursor line", function()
  open_file("m1.lua")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  relay.menu()
  local lines = menu_lines()
  eq(6, #lines)
  eq("  a  Add to queue ", lines[1])
  eq("  A  Add file ", lines[2])
  eq("  s  Send line ", lines[4])
  eq("  S  Send queue (0) ", lines[5])
  -- the queue is empty: sending it is refused and the menu stays open
  feed("S")
  truthy(vim.api.nvim_win_get_config(0).relative ~= "", "menu still open")
  feed("a")
  vim.wait(100)
  eq(1, queue.count())
  eq({ 2, 2 }, { queue.items()[1].srow, queue.items()[1].erow })
  eq("", vim.api.nvim_win_get_config(0).relative)
end)

test("A in the menu queues the whole file", function()
  open_file("m4.lua")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  relay.menu()
  feed("A")
  vim.wait(100)
  eq(1, queue.count())
  eq("file", queue.items()[1].kind)
  eq("m4.lua (whole file)", queue.label(queue.items()[1]))
end)

test("the menu adds or edits the context of a snippet", function()
  open_file("m2.lua")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  relay.menu()
  feed("c")
  answer("why 3?")
  eq(1, queue.count())
  eq("why 3?", queue.items()[1].note)
  -- same line again: the menu knows it's queued and edits its context
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  relay.menu()
  local _, cfg = menu_lines()
  truthy(vim.inspect(cfg.title):find("queued #1", 1, true), vim.inspect(cfg.title))
  feed("c")
  eq("why 3?", vim.api.nvim_buf_get_lines(0, 0, -1, false)[1])
  answer("why three?")
  eq(1, queue.count())
  eq("why three?", queue.items()[1].note)
end)

test("the menu works on a visual selection and opens the queue", function()
  open_file("m3.lua")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  in_visual("Vj", relay.menu)
  feed("a")
  vim.wait(100)
  eq({ 1, 2 }, { queue.items()[1].srow, queue.items()[1].erow })
  relay.menu()
  feed("v")
  vim.wait(100)
  eq("relay", vim.bo.filetype)
  truthy(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("m3.lua:1-2", 1, true), "queue lists the snippet")
  feed("x")
  vim.wait(100)
  eq(0, queue.count())
  feed("q")
end)

-- end to end ---------------------------------------------------------------------------

local python = vim.fn.exepath("python3")
if python == "" or not util.is_linux then
  print("skip  end-to-end tests (need python3 and Linux)")
else
  vim.fn.mkdir(tmp .. "/bin", "p")
  vim.uv.fs_symlink(python, tmp .. "/bin/claude")
  local fake = { tmp .. "/bin/claude", root .. "/tests/fake_claude.py" }

  local function wait_file(path)
    return vim.wait(3000, function()
      return util.is_file(path)
    end, 20)
  end
  local function discover()
    local list
    sessions.discover(function(l)
      list = l
    end)
    vim.wait(5000, function()
      return list ~= nil
    end, 10)
    return list
  end
  local function only_fakes(list, logs)
    local out = {}
    for _, s in ipairs(list) do
      local cmd = (util.read_file("/proc/" .. s.pid .. "/cmdline") or ""):gsub("%z", " ")
      for tag, log in pairs(logs) do
        if cmd:find(log, 1, true) then
          out[tag] = s
        end
      end
    end
    return out
  end

  --- Run `job` in a terminal of this Neovim until it has created `log`; returns its pid.
  local function start_term(job, log, env)
    vim.cmd("enew")
    local chan
    if vim.fn.has("nvim-0.11") == 1 then
      chan = vim.fn.jobstart(job, { term = true, env = env })
    else
      chan = vim.fn.termopen(job, { env = env })
    end
    wait_file(log)
    return vim.fn.jobpid(chan)
  end

  -- a fake session in a terminal of this Neovim, registered like Claude Code does
  local local_log = tmp .. "/local.log"
  local local_pid = start_term(vim.list_extend(vim.deepcopy(fake), { local_log }), local_log)
  local stat = proc.parse_stat(local_pid, util.read_file("/proc/" .. local_pid .. "/stat"))
  vim.fn.writefile({
    vim.json.encode({
      pid = local_pid,
      procStart = stat.start,
      cwd = tmp .. "/project",
      name = "fake-session",
      status = "idle",
      kind = "interactive",
    }),
  }, tmp .. "/claude/sessions/" .. local_pid .. ".json")

  -- a fake session in another Neovim instance
  local remote_log = tmp .. "/remote.log"
  local sock = tmp .. "/remote.sock"
  local remote = vim.system({
    "nvim",
    "--headless",
    "--clean",
    "--listen",
    sock,
    "-c",
    "terminal " .. table.concat(vim.list_extend(vim.deepcopy(fake), { remote_log }), " "),
  })
  wait_file(remote_log)

  local logs = { ["local"] = local_log, remote = remote_log }

  -- nothing in these tests may ever reach a real Claude session
  local real_send = transport.send
  transport.send = function(s, ...)
    local cmd = (util.read_file("/proc/" .. s.pid .. "/cmdline") or ""):gsub("%z", " ")
    assert(cmd:find("fake_claude.py", 1, true), "refusing to send to a real session")
    return real_send(s, ...)
  end

  test("fake sessions are discovered with their registry metadata", function()
    local found = only_fakes(discover(), logs)
    truthy(found["local"], "local session")
    eq("nvim", found["local"].host)
    eq("fake-session", found["local"].name)
    eq("idle", found["local"].status)
    truthy(found["local"].reachable, "local reachable")
    truthy(found.remote, "remote session")
    eq("nvim_remote", found.remote.host)
    truthy(found.remote.reachable, "remote reachable")
  end)

  test("stale registry entries are ignored", function()
    local path = tmp .. "/claude/sessions/" .. local_pid .. ".json"
    local saved = vim.fn.readfile(path)
    local data = vim.json.decode(saved[1])
    data.procStart = "1" -- the pid was reused by another process
    vim.fn.writefile({ vim.json.encode(data) }, path)
    local found = only_fakes(discover(), logs)
    vim.fn.writefile(saved, path)
    truthy(found["local"], "still found by scanning processes")
    eq(nil, found["local"].name)
  end)

  test("sending pastes the message and presses Enter", function()
    local found = only_fakes(discover(), logs)
    for tag, s in pairs(found) do
      local done
      transport.send(s, "@a.lua#L1-2\nnote\27[201~", { submit = true }, function(ok, err)
        done = { ok, err }
      end)
      vim.wait(3000, function()
        return done ~= nil and (util.read_file(logs[tag]) or ""):find("\r", 1, true) ~= nil
      end, 20)
      eq({ true, nil }, done, tag .. " result")
      eq("\27[200~@a.lua#L1-2\nnote[201~\27[201~\r", util.read_file(logs[tag]), tag .. " log")
    end
  end)

  test("the queue goes out through the picker and is cleared", function()
    local found = only_fakes(discover(), logs)
    vim.fn.writefile({}, local_log)
    open_file("e1.lua")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    in_visual("Vj", relay.add)
    eq(1, queue.count())
    local labels
    vim.ui.select = function(entries, opts, cb)
      labels = vim.tbl_map(opts.format_item, entries)
      for _, e in ipairs(entries) do
        if e.session and e.session.pid == found["local"].pid then
          return cb(e)
        end
      end
      cb(nil)
    end
    relay.send({ message = "explain" })
    vim.wait(3000, function()
      return (util.read_file(local_log) or "") ~= ""
    end, 20)
    eq("\27[200~explain\n\n@e1.lua#L2-3\27[201~", util.read_file(local_log))
    truthy(table.concat(labels, "\n"):find("Copy to clipboard", 1, true), "clipboard entry")
    eq(0, queue.count())
  end)

  test("the menu sends one line with a prompt in front", function()
    local found = only_fakes(discover(), logs)
    vim.fn.writefile({}, local_log)
    open_file("e2.lua")
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    relay.menu()
    feed("c")
    answer("returns the sum")
    vim.ui.select = function(entries, _, cb)
      for _, e in ipairs(entries) do
        if e.session and e.session.pid == found["local"].pid then
          return cb(e)
        end
      end
      cb(nil)
    end
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(vim.fn.bufnr("e2.lua"))[1])
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    relay.menu()
    feed("s")
    answer("is this right?")
    vim.wait(3000, function()
      return (util.read_file(local_log) or "") ~= ""
    end, 20)
    eq("\27[200~is this right?\n\nreturns the sum: @e2.lua#L4\27[201~", util.read_file(local_log))
    eq(1, queue.count(), "sending one line leaves the queue alone")
  end)

  -- Codex as its npm package runs it: a node wrapper that starts the native binary
  vim.fn.mkdir(tmp .. "/native", "p")
  vim.uv.fs_symlink(python, tmp .. "/bin/node")
  vim.uv.fs_symlink(root .. "/tests/fake_wrapper.py", tmp .. "/bin/codex")
  vim.uv.fs_symlink(python, tmp .. "/native/codex")
  local codex_log = tmp .. "/codex.log"
  local codex_pid = start_term({
    tmp .. "/bin/node",
    tmp .. "/bin/codex",
    tmp .. "/native/codex",
    root .. "/tests/fake_claude.py",
    codex_log,
  }, codex_log)
  -- Copilot's native binary, which names its process "MainThread"
  vim.uv.fs_symlink(python, tmp .. "/native/copilot")
  local copilot_log = tmp .. "/copilot.log"
  local copilot_pid = start_term(
    { tmp .. "/native/copilot", root .. "/tests/fake_claude.py", copilot_log },
    copilot_log,
    { FAKE_COMM = "MainThread" }
  )
  local agent_logs = { codex = codex_log, copilot = copilot_log }

  test("codex and copilot sessions are discovered once each", function()
    eq("MainThread\n", util.read_file("/proc/" .. copilot_pid .. "/comm"), "fake copilot renamed itself")
    local count = { codex = 0, copilot = 0 }
    for _, s in ipairs(discover()) do
      local cmd = (util.read_file("/proc/" .. s.pid .. "/cmdline") or ""):gsub("%z", " ")
      for tag, log in pairs(agent_logs) do
        if cmd:find(log, 1, true) then
          count[tag] = count[tag] + 1
        end
      end
    end
    eq({ codex = 1, copilot = 1 }, count, "sessions per agent (the native codex under its wrapper is no session)")
    local found = only_fakes(discover(), agent_logs)
    eq(codex_pid, found.codex.pid)
    eq("codex", found.codex.agent)
    eq("nvim", found.codex.host)
    truthy(found.codex.reachable, "codex reachable")
    eq(copilot_pid, found.copilot.pid)
    eq("copilot", found.copilot.agent)
    truthy(found.copilot.reachable, "copilot reachable")
  end)

  test("copilot sessions are named from workspace.yaml via the inuse lock", function()
    local home = tmp .. "/copilot-home"
    local dir = home .. "/session-state/0b1c2d3e-aaaa-bbbb-cccc-111122223333"
    vim.fn.mkdir(dir, "p")
    -- another session's lock must not be picked up
    vim.fn.mkdir(home .. "/session-state/other", "p")
    vim.fn.writefile({ "name: wrong", "user_named: true" }, home .. "/session-state/other/workspace.yaml")
    vim.fn.writefile({}, home .. "/session-state/other/inuse.1.lock")
    vim.fn.writefile({}, dir .. "/inuse." .. copilot_pid .. ".lock")
    vim.env.COPILOT_HOME = home
    local function name_with(lines)
      vim.fn.writefile(lines, dir .. "/workspace.yaml")
      return only_fakes(discover(), agent_logs).copilot.name
    end
    local base = { "id: 0b1c2d3e-aaaa-bbbb-cccc-111122223333", "cwd: /x", "summary: Fix the parser" }
    eq("api-refactor", name_with(vim.list_extend(vim.deepcopy(base), { "name: api-refactor", "user_named: true" })), "/rename")
    eq("Fix the parser", name_with(vim.list_extend(vim.deepcopy(base), { "name: auto name" })), "auto name loses to summary")
    eq("auto name", name_with({ "id: 0b1c2d3e-aaaa", "name: auto name" }), "auto name")
    eq("0b1c2d3e", name_with({ "id: 0b1c2d3e-aaaa-bbbb-cccc-111122223333" }), "id prefix")
    eq("multi word", name_with({ "name: |", "  multi word", "  second line", "user_named: true" }), "block scalar")
    eq("folded", name_with({ "name: >-", "  folded", "user_named: true", "cwd: /x" }), "folded scalar")
    eq("quoted: name", name_with({ 'name: "quoted: name"', "user_named: true" }), "quoted")
    vim.fn.delete(dir .. "/workspace.yaml")
    eq(nil, only_fakes(discover(), agent_logs).copilot.name, "no workspace.yaml falls back to the folder")
    vim.fn.delete(dir .. "/inuse." .. copilot_pid .. ".lock")
    eq(nil, only_fakes(discover(), agent_logs).copilot.name, "no lock")
    vim.env.COPILOT_HOME = nil
  end)

  test("codex and copilot get the same message (codex with a space after it)", function()
    local found = only_fakes(discover(), agent_logs)
    for tag, s in pairs(found) do
      local done
      transport.send(s, "explain\n\n@a.lua#L1-2", { submit = true }, function(ok, err)
        done = { ok, err }
      end)
      vim.wait(3000, function()
        return done ~= nil and (util.read_file(agent_logs[tag]) or ""):find("\r", 1, true) ~= nil
      end, 20)
      eq({ true, nil }, done, tag .. " result")
      local space = tag == "codex" and " " or ""
      eq("\27[200~explain\n\n@a.lua#L1-2" .. space .. "\27[201~\r", util.read_file(agent_logs[tag]), tag .. " log")
    end
  end)

  test("the picker offers every agent and sends to the one picked", function()
    local found = only_fakes(discover(), agent_logs)
    vim.fn.writefile({}, copilot_log)
    open_file("e3.lua")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    in_visual("V", relay.add)
    local labels
    vim.ui.select = function(entries, opts, cb)
      labels = table.concat(vim.tbl_map(opts.format_item, entries), "\n")
      for _, e in ipairs(entries) do
        if e.session and e.session.pid == found.copilot.pid then
          return cb(e)
        end
      end
      cb(nil)
    end
    relay.send({ message = "explain" })
    vim.wait(3000, function()
      return (util.read_file(copilot_log) or "") ~= ""
    end, 20)
    eq("\27[200~explain\n\n@e3.lua#L2\27[201~", util.read_file(copilot_log))
    truthy(labels:find("fake-session", 1, true), labels)
    truthy(labels:find("project", 1, true), labels)
    truthy(labels:find("· copilot", 1, true), labels)
  end)

  test("agents can be turned off", function()
    local config = require("relay.config")
    config.options.agents.codex = false
    local found = only_fakes(discover(), agent_logs)
    config.options.agents.codex = true
    eq(nil, found.codex)
    truthy(found.copilot, "copilot still listed")
  end)

  -- starting a session when none is running ----------------------------------------------

  local config = require("relay.config")
  local state = require("relay.state")

  local function fake_cmd(log)
    return { tmp .. "/bin/claude", root .. "/tests/fake_claude.py", log }
  end
  local function fake_codex_cmd(log)
    return { tmp .. "/bin/node", tmp .. "/bin/codex", tmp .. "/native/codex", root .. "/tests/fake_claude.py", log }
  end

  --- Run `fn` as if no session were running except those whose command line contains
  --- `marker`, with `cmd` as the launch commands; stop the sessions it started afterwards.
  local function no_sessions(marker, cmd, fn)
    local real, launch = sessions.discover, vim.deepcopy(config.options.launch)
    sessions.discover = function(cb)
      real(function(list)
        cb(vim.tbl_filter(function(s)
          local cmdline = (util.read_file("/proc/" .. s.pid .. "/cmdline") or ""):gsub("%z", " ")
          return cmdline:find(marker, 1, true) ~= nil
        end, list))
      end)
    end
    if cmd then
      config.options.launch.cmd = cmd
    else
      config.options.launch = false
    end
    local before = vim.api.nvim_list_bufs()
    local ok, err = pcall(fn)
    sessions.discover, config.options.launch = real, launch
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if not vim.tbl_contains(before, buf) and vim.bo[buf].buftype == "terminal" then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    if not ok then
      error(err, 0)
    end
  end

  --- Stub vim.ui.select: pick the entry starting `agent`; returns the labels it was shown.
  local function pick_start(agent)
    local seen = {}
    vim.ui.select = function(entries, opts, cb)
      seen.labels = vim.tbl_map(opts.format_item, entries)
      seen.prompt = opts.prompt
      for _, e in ipairs(entries) do
        if e.launch and e.launch.id == agent then
          return cb(e)
        end
      end
      cb(nil)
    end
    return seen
  end

  test("with no session running, the picked agent is started and the message follows", function()
    local log = tmp .. "/launch-claude.log"
    local cmd = { claude = fake_cmd(log), codex = fake_codex_cmd(tmp .. "/unused.log"), copilot = false }
    vim.env.FAKE_REGISTRY = tmp .. "/claude/sessions"
    no_sessions(log, cmd, function()
      local seen = pick_start("claude")
      open_file("l1.lua")
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      in_visual("V", relay.add)
      relay.send({ message = "explain", submit = true })
      vim.wait(5000, function()
        return (util.read_file(log) or ""):find("\r", 1, true) ~= nil
      end, 20)
      local where = util.home(vim.fn.getcwd())
      eq({ "󰐕  Start Claude Code in Neovim  " .. where, "󰐕  Start Codex in Neovim  " .. where, "󰆏  Copy to clipboard" }, seen.labels)
      -- Claude registered itself, so its prompt is up and Enter is pressed as asked
      eq("\27[200~explain\n\n@l1.lua#L2\27[201~\r", util.read_file(log))
      eq(0, queue.count())
      eq("terminal", vim.bo.buftype, "the new session is focused")
      eq(vim.fn.winnr("$"), vim.fn.winnr(), "it opened on the far right")
      eq(math.max(math.floor(vim.o.columns * 0.35), math.min(50, math.floor(vim.o.columns / 2))), vim.fn.winwidth(0))
    end)
    vim.env.FAKE_REGISTRY = nil
  end)

  test("with sessions only outside this Neovim, the picker opens with New agent at the bottom", function()
    no_sessions(remote_log, { claude = fake_cmd(tmp .. "/unused.log"), codex = false, copilot = false }, function()
      local seen = {}
      vim.ui.select = function(entries, opts, cb)
        seen.labels = vim.tbl_map(opts.format_item, entries)
        seen.prompt = opts.prompt
        for _, e in ipairs(entries) do
          if e.session then
            return cb(e)
          end
        end
        cb(nil)
      end
      vim.fn.writefile({}, remote_log)
      relay.send({ message = "to the other neovim" })
      vim.wait(3000, function()
        return (util.read_file(remote_log) or "") ~= ""
      end, 20)
      truthy(seen.labels, "the picker opened although only one session runs")
      eq(3, #seen.labels)
      truthy(seen.labels[1]:find("nvim (pid", 1, true), seen.labels[1])
      eq({ "󰆏  Copy to clipboard", "󰐕  New agent…" }, { seen.labels[2], seen.labels[3] })
      truthy(seen.prompt:find("none is open in Neovim", 1, true), seen.prompt)
      eq("\27[200~to the other neovim\27[201~", util.read_file(remote_log))
    end)
  end)

  test("New agent expands into the installed agents, highlighted, and starts the one picked", function()
    local cmd = { claude = fake_cmd(tmp .. "/unused.log"), codex = fake_codex_cmd(tmp .. "/launch-new.log"), copilot = false }
    no_sessions("launch-new.log", cmd, function()
      local steps = {}
      vim.ui.select = function(entries, opts, cb)
        local step = { prompt = opts.prompt, labels = vim.tbl_map(opts.format_item, entries) }
        steps[#steps + 1] = step
        for _, e in ipairs(entries) do
          if e.new then
            step.chunks = opts.format_item(e, true)
            return cb(e)
          elseif e.id == "codex" then
            step.chunks = opts.format_item(e, true)
            return cb(e)
          end
        end
        cb(nil)
      end
      -- a session elsewhere, so the agents fold into "New agent…"
      local real = sessions.discover
      sessions.discover = function(cb)
        real(function(list)
          if #list == 0 then
            list = { { pid = 1, agent = "claude", tty = "x", updated = 0, reachable = false, reason = "test" } }
          end
          cb(list)
        end)
      end
      local ok, err = pcall(function()
        relay.sessions()
        vim.wait(3000, function()
          return #steps == 2 and vim.bo.buftype == "terminal"
        end, 20)
      end)
      sessions.discover = real
      assert(ok, err)
      eq("󰐕  New agent…", steps[1].labels[#steps[1].labels])
      eq({ { "󰐕  New agent…", "RelayNewAgent" } }, steps[1].chunks)
      eq({ "󰐕  Claude Code", "󰐕  Codex" }, steps[2].labels)
      eq({ { "󰐕  Codex", "RelayNewAgent" } }, steps[2].chunks)
      eq("terminal", vim.bo.buftype, "the picked agent opened")
    end)
  end)

  test("a session open in this Neovim is used as before, without offering to start one", function()
    no_sessions(local_log, { claude = fake_cmd(tmp .. "/unused.log"), codex = false, copilot = false }, function()
      local seen = pick_start("claude")
      vim.fn.writefile({}, local_log)
      relay.send({ message = "straight there" })
      vim.wait(3000, function()
        return (util.read_file(local_log) or "") ~= ""
      end, 20)
      eq(nil, seen.labels, "no picker")
      eq("\27[200~straight there\27[201~", util.read_file(local_log))
    end)
  end)

  test("a startup screen is answered first; Enter is never pressed for a guessed-ready session", function()
    local log = tmp .. "/launch-codex.log"
    vim.env.FAKE_DIALOG = "1"
    no_sessions(log, { claude = false, codex = fake_codex_cmd(log), copilot = false }, function()
      pick_start("codex")
      open_file("l2.lua")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      in_visual("V", relay.add)
      relay.send({ message = "explain", submit = true })
      vim.wait(1500)
      eq(nil, util.read_file(log), "nothing typed into the startup screen")
      eq("terminal", vim.bo.buftype, "the new session is focused")
      vim.api.nvim_chan_send(vim.bo.channel, "\r") -- the user answers it
      vim.wait(5000, function()
        return (util.read_file(log) or "") ~= ""
      end, 20)
      vim.wait(300)
      eq("\27[200~explain\n\n@l2.lua#L1 \27[201~", util.read_file(log))
    end)
    vim.env.FAKE_DIALOG = nil
  end)

  test("a started session that exits before it's ready leaves the message on the clipboard", function()
    local cmd = { claude = { tmp .. "/bin/claude", "-c", "import time; time.sleep(0.3)  # launch-exit" } }
    no_sessions("launch-exit", cmd, function()
      pick_start("claude")
      vim.fn.setreg('"', "")
      relay.send({ message = "explain this" })
      vim.wait(5000, function()
        return vim.fn.getreg('"') ~= ""
      end, 20)
      eq("explain this", vim.fn.getreg('"'))
    end)
  end)

  test("pinning with no session running starts one and pins it", function()
    local log = tmp .. "/launch-pin.log"
    no_sessions(log, { claude = fake_cmd(log), codex = false, copilot = false }, function()
      local seen = pick_start("claude")
      relay.target()
      vim.wait(5000, function()
        return state.pinned ~= nil
      end, 20)
      eq("Pin session · none is running, start one", seen.prompt)
      truthy(state.pinned, "pinned")
      eq("claude project", state.pinned.label)
      state.pinned = nil
    end)
  end)

  test("with launch = false nothing is started and the message is copied", function()
    no_sessions("launch-none", nil, function()
      local seen = pick_start("claude")
      vim.fn.setreg('"', "")
      relay.send({ message = "copy me" })
      vim.wait(2000, function()
        return vim.fn.getreg('"') ~= ""
      end, 20)
      eq(nil, seen.labels, "no picker")
      eq("copy me", vim.fn.getreg('"'))
    end)
  end)

  remote:kill(15)
end

print(("\n%d passed, %d failed"):format(passed, failed))
vim.fn.delete(tmp, "rf")
vim.cmd(failed == 0 and "qa!" or "cq!")

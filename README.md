# relay.nvim

Send code from Neovim straight into the prompt of a running [Claude Code](https://claude.com/claude-code) session — or collect a queue of snippets, annotate them, and send them all at once. Built for working with several agents in parallel: every send looks up the live sessions at that moment and lets you pick one.

- **One menu, `<leader>aq`**: on a selection (or the cursor line) — add to queue, add with context, send it to your agent, send the whole queue, view the queue.
- **Claude's own mention syntax**: saved code goes as `@src/app.ts#L10-24` (Claude reads exactly those lines). Code that only exists in Neovim (unsaved changes, buffers without a file) is inlined as a fenced block.
- **Queue**: add any number of snippets from any files, give each its context, reorder, delete, preview the exact message, undo deletions.
- **Live session discovery**: every running `claude` on the machine, with its name, busy/idle status, cwd and git branch, wherever it runs: a Neovim terminal (this one or another instance), tmux, zellij, kitty or WezTerm.
- **Snippets follow your code**: line numbers track edits, and when Claude rewrites the file on disk the snippet is found again by its content.

## Requirements

- Neovim ≥ 0.10
- Claude Code running in one of:
  - a Neovim `:terminal` (this instance, or another one on Linux)
  - tmux
  - zellij ≥ 0.44 (older versions: only when the Claude pane is the focused one)
  - kitty with remote control (`allow_remote_control socket-only` + `listen_on unix:/tmp/kitty`)
  - WezTerm
- Linux gets the full feature set (process info is read from `/proc`). On macOS, sessions in Neovim terminals, tmux and WezTerm work.

Sessions that can't be typed into (e.g. Claude in a plain terminal window) still show up; picking one copies the message to the clipboard instead.

## Install

[lazy.nvim](https://github.com/folke/lazy.nvim), from a local checkout:

```lua
{
  dir = "~/projects/relay.nvim",
  opts = {},
}
```

(Once the repository is on GitHub, use `"<user>/relay.nvim"` instead of `dir`.)

`setup()` only defines keymaps, highlights and a few autocmds; everything else loads on first use. To lazy-load anyway, add `cmd = "Relay"` and list the keymaps under `keys`.

## Usage

Default keymaps (all under `<leader>a`, change or disable them in `opts.keymaps`):

| Mode | Key | Action |
| --- | --- | --- |
| normal, visual | `<leader>aq` | **action menu** for the selection, or the cursor line |
| visual | `<leader>aa` | overlay: preview + context box for the selection |
| normal | `<leader>as` | send the queue |
| normal | `<leader>af` | add the current file (whole) to the queue |
| normal | `<leader>an` | edit the context of the queued snippet under the cursor |
| normal | `<leader>ax` | clear the queue |
| normal | `<leader>at` | pin the session sends go to (or unpin) |
| normal | `<leader>aj` | jump to a running Claude session |

### Menu

`<leader>aq` opens a small menu at the cursor. In visual mode it acts on the selection, in normal mode on the cursor line.

| Key | Action |
| --- | --- |
| `a` | add to the queue |
| `c` | add with context (or edit the context if it's already queued) |
| `s` | send just this to your agent — asks for an optional prompt first |
| `S` | send the whole queue — asks for an optional prompt first |
| `v` | view the queue (delete entries with `x`) |

Also `1`–`5`, or move with `j`/`k` and press `⏎`. In the prompt box `⏎` sends; leave it empty to send without a prompt.

### Overlay

| Key | Action |
| --- | --- |
| `⏎` | send this snippet (with its context) |
| `<C-s>` | send and press Enter in Claude |
| `<Tab>` | add to the queue |
| `<C-a>` | add to the queue and send the whole queue |
| `<C-t>` | send, choosing the session even if one is pinned |
| `<C-f>` | toggle `@mention` / inline code |
| `<C-d>` | toggle including LSP diagnostics of the lines |
| `<C-e>` / `<C-y>` | scroll the preview |
| `<C-c>`, `<Esc>` (normal mode) | close |

The context box is a normal buffer: `<C-j>` inserts a new line.

### Queue

| Key | Action |
| --- | --- |
| `s` / `S` | send / send to a chosen session |
| `m` | write a prompt (goes first), then send the queue |
| `e` `i` `a` | edit the snippet's context |
| `x` `dd` | delete · `u` restores |
| `K` / `J` | move up / down |
| `f` | cycle the snippet's format: auto → ref → inline |
| `D` | toggle LSP diagnostics |
| `p` | preview the exact message |
| `⏎` `o` | jump to the snippet |
| `C` | clear (restorable) |
| `t` | pin a session |
| `?` | all keys |

The rows flag snippets whose code was edited outside Neovim, deleted (`gone from file`, sent with the text you queued), or has unsaved changes.

### What Claude receives

````text
Make the reload idempotent.

runs twice after a reload: @lua/relay/queue.lua#L120-148

@lua/relay/init.lua#L60-75

scratch.lua (lines 3-9, unsaved):
```lua
local x = compute()
```
````

The prompt comes first, then the snippets separated by blank lines; a snippet's context sits in front of it as `context: code`. Paths are relative to the receiving session's directory when the file is inside it. The text arrives as a bracketed paste, so Claude shows it as `[Pasted text #1 +N lines]` and still resolves every mention when you submit.

By default the text waits in Claude's prompt and Relay switches to that pane so you can add to it; with `submit = true` (or `<C-s>` in the overlay) Enter is pressed for you and you stay in Neovim.

### Choosing the session

When you send, Relay lists the running sessions:

```
○ idle  api-refactor [feat/cache]  tmux work:2.1  ~/code/api-wt-cache
● busy  relay-nvim [main]  nvim terminal #12  ~/projects/relay.nvim
◐ waiting:permission  docs [main]  zellij agents/3  ~/code/docs
```

With one session it's used directly; with several you pick (the one you used last and the one working on the current project come first). `<leader>at` pins a session so sends go straight there until it exits.

## Commands

```
:Relay                     action menu for the cursor line (with a range: the lines)
:'<,'>Relay open           overlay for the selection
:'<,'>Relay add [context]  queue the selection
:Relay file [context]      queue the current file
:Relay send[!] [prompt]    send the queue (! = choose the session)
:Relay queue | clear | restore | preview | note
:Relay target [clear]      pin a session / unpin
:Relay sessions            jump to a session
```

## Configuration

Defaults:

```lua
require("relay").setup({
  keymaps = {
    menu = "<leader>aq", open = "<leader>aa", add = false, queue = false, send = "<leader>as",
    file = "<leader>af", note = "<leader>an", clear = "<leader>ax",
    target = "<leader>at", sessions = "<leader>aj",
  }, -- or false; set a single key to false to skip it
  format = "auto",          -- "auto" | "ref" (@mention) | "inline" (code block)
  submit = false,           -- press Enter after pasting
  focus = "auto",           -- switch to the Claude pane: true | false | "auto" (when not submitting)
  clear_on_send = true,     -- empty the queue after sending (:Relay restore brings it back)
  diagnostics = false,      -- include LSP diagnostics by default
  clipboard_fallback = true,-- copy the message when no session can receive it
  submit_delay = 80,        -- ms between paste and Enter
  claude_dir = nil,         -- default: $CLAUDE_CONFIG_DIR or ~/.claude
  backends = { nvim = true, tmux = true, zellij = true, kitty = true, wezterm = true },
  signs = true,             -- mark queued lines in the sign column
  virtual_text = true,      -- "󰚩 #2 context" after the first queued line
  ui = { border = "rounded", width = 0.6, max_preview = 15, icon = "󰚩" },
})
```

### Statusline

`require("relay").statusline()` returns `󰚩 3` (plus `→ session` when pinned), or `""`. For lualine:

```lua
lualine_x = { function() return require("relay").statusline() end, "encoding", "filetype" },
```

The `User RelayQueueChanged` autocmd fires whenever the queue changes.

### Highlights

`RelayTitle`, `RelayFooter`, `RelayKey`, `RelayMuted`, `RelayIndex`, `RelayPath`, `RelayMode`, `RelayNote`, `RelayWarn`, `RelaySign`, `RelayVirtText` — all linked to standard groups by default.

## How sessions are found

Nothing runs in the background. Each time you send, Relay:

1. reads Claude Code's live session registry (`~/.claude/sessions/*.json`: name, cwd, busy/idle), skipping stale entries whose pid now belongs to another process;
2. scans the process table for `claude` processes (on Linux straight from `/proc`, a few milliseconds, no subprocess), which also covers Claude versions without the registry;
3. finds the program that owns each session's terminal: the first ancestor process on a different tty. So Claude in tmux inside zellij inside kitty is reached through tmux, never through an outer layer;
4. asks only the terminals that actually host sessions for details (one `tmux list-panes` per tmux server, and so on), using the exact binary that runs the server, so versions always match.

Discovery takes a few milliseconds plus one short command per multiplexer that hosts a session.

Text is sent as a bracketed paste with control characters removed, so a snippet can never end the paste early or press keys in Claude.

## Health

`:checkhealth relay` shows what's supported on your machine and every live session with how it would be reached.

## Tests

```sh
nvim --headless --clean -l tests/run.lua
```

The end-to-end tests run fake Claude sessions (python3) in Neovim terminals; nothing is sent to real sessions.

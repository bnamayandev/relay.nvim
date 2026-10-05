local M = {}

---@param o table :command callback opts
---@param rest string arguments after the subcommand
local subcommands = {
  menu = function(o)
    require("relay").menu(o)
  end,
  open = function(o)
    require("relay").open(o)
  end,
  add = function(o, rest)
    require("relay").add(o, rest)
  end,
  file = function(_, rest)
    require("relay").add_file(rest)
  end,
  queue = function()
    require("relay").queue()
  end,
  send = function(o, rest)
    require("relay").send({ pick = o.bang, message = rest ~= "" and rest or nil })
  end,
  clear = function()
    require("relay").clear()
  end,
  restore = function()
    require("relay").restore()
  end,
  target = function(_, rest)
    if rest == "clear" or rest == "none" then
      require("relay").unpin()
    else
      require("relay").target()
    end
  end,
  sessions = function()
    require("relay").sessions()
  end,
  note = function()
    require("relay").note()
  end,
  preview = function()
    require("relay").preview()
  end,
}

function M.run(o)
  local sub, rest = o.args:match("^%s*(%S+)%s*(.-)%s*$")
  if not sub then
    -- the action menu, for the range or the cursor line
    return require("relay").menu(o)
  end
  local fn = subcommands[sub]
  if not fn then
    return require("relay.util").error("Unknown :Relay subcommand: " .. sub)
  end
  fn(o, rest)
end

function M.complete(arg_lead, cmdline)
  local words = vim.split(vim.trim(cmdline:gsub("^%A*%a*", "", 1)), "%s+", { trimempty = true })
  if #words > 1 or (#words == 1 and arg_lead == "") then
    if words[1] == "target" then
      return vim.tbl_filter(function(c)
        return c:find(arg_lead, 1, true) == 1
      end, { "clear" })
    end
    return {}
  end
  local names = vim.tbl_keys(subcommands)
  table.sort(names)
  return vim.tbl_filter(function(name)
    return name:find(arg_lead, 1, true) == 1
  end, names)
end

return M

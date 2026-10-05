if vim.g.loaded_relay then
  return
end
vim.g.loaded_relay = true

if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify("relay.nvim requires Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Relay", function(o)
  require("relay.commands").run(o)
end, {
  nargs = "*",
  range = true,
  bang = true,
  desc = "Relay: send code to Claude Code",
  complete = function(arg_lead, cmdline)
    return require("relay.commands").complete(arg_lead, cmdline)
  end,
})

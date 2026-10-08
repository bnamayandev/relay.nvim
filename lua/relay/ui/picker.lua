-- Choosing from a list (a session, an agent to start) with the picker set in `config.picker`.
-- Every picker is called like vim.ui.select.
local config = require("relay.config")
local util = require("relay.util")

local M = {}

---@alias relay.SelectFn fun(items: any[], opts: table, on_choice: fun(item: any|nil, idx: integer|nil))

--- A label as text plus telescope highlights; `format_item(item, true)` may return chunks.
---@param label string|{ [1]: string, [2]: string|nil }[]
local function flatten(label)
  if type(label) ~= "table" then
    return tostring(label), {}
  end
  local text, hls = "", {}
  for _, chunk in ipairs(label) do
    if chunk[2] then
      hls[#hls + 1] = { { #text, #text + #chunk[1] }, chunk[2] }
    end
    text = text .. chunk[1]
  end
  return text, hls
end

--- telescope has no vim.ui.select of its own (that's the telescope-ui-select extension).
---@type relay.SelectFn
local function telescope(items, opts, on_choice)
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local format_item = opts.format_item or tostring
  local results = {}
  for i, item in ipairs(items) do
    local text, hls = flatten(format_item(item, true))
    results[i] = { item = item, idx = i, text = text, hls = hls }
  end
  local chosen, done
  require("telescope.pickers")
    .new({}, {
      prompt_title = opts.prompt,
      finder = require("telescope.finders").new_table({
        results = results,
        entry_maker = function(r)
          return {
            value = r,
            ordinal = r.text,
            display = function()
              return r.text, r.hls
            end,
          }
        end,
      }),
      sorter = require("telescope.config").values.generic_sorter({}),
      attach_mappings = function(buf)
        actions.select_default:replace(function()
          chosen = action_state.get_selected_entry()
          actions.close(buf)
        end)
        -- runs for every way of closing, so a cancel reports nil like vim.ui.select
        actions.close:enhance({
          post = function()
            if done then
              return
            end
            done = true
            local r = chosen and chosen.value
            vim.schedule(function()
              on_choice(r and r.item, r and r.idx)
            end)
          end,
        })
        return true
      end,
    })
    :find()
end

---@type table<string, fun(): relay.SelectFn|nil>
local PICKERS = {
  select = function()
    return vim.ui.select
  end,
  snacks = function()
    return require("snacks").picker.select
  end,
  telescope = function()
    require("telescope")
    return telescope
  end,
  ["fzf-lua"] = function()
    return require("fzf-lua.providers.ui_select").ui_select
  end,
  ["mini.pick"] = function()
    return require("mini.pick").ui_select
  end,
}

--- The function of the picker `name`, or nil when it isn't installed.
---@param name string
---@return relay.SelectFn|nil
function M.get(name)
  local ok, fn = pcall(PICKERS[name] or PICKERS.select)
  return ok and fn or nil
end

local warned = {}

--- Like vim.ui.select, with the picker set in `config.picker` (vim.ui.select when it isn't
--- installed).
---@param items any[]
---@param opts { prompt?: string, kind?: string, format_item?: fun(item: any, chunks?: boolean): string|table }
---@param on_choice fun(item: any|nil, idx: integer|nil)
function M.select(items, opts, on_choice)
  local picker = config.options.picker
  if type(picker) == "function" then
    return picker(items, opts, on_choice)
  end
  local fn = M.get(picker)
  if not fn then
    if not warned[picker] then
      warned[picker] = true
      util.warn(("picker %q isn't installed, using vim.ui.select"):format(picker))
    end
    fn = vim.ui.select
  end
  fn(items, opts, on_choice)
end

return M

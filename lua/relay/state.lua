-- Small bits of runtime state shared between modules.
local M = {}

---@type { pid: integer, start: string|nil, label: string, cwd: string|nil }|nil
M.pinned = nil

--- pid of the session that received the last send (sorted first in pickers)
---@type integer|nil
M.last_pid = nil

--- cwd of the last session that received something (used for message previews)
---@type string|nil
M.last_cwd = nil

return M

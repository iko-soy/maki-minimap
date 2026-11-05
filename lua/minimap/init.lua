local Runtime = require("minimap.runtime")

local runtime = Runtime.new(maki)
local M = {}

function M.setup(opts)
  return runtime:setup(opts)
end

function M.toggle()
  return runtime:toggle()
end

function M.next()
  return runtime:navigate(1)
end

function M.previous()
  return runtime:navigate(-1)
end

function M.stop()
  return runtime:stop()
end

return M

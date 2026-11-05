package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  "./tests/?.lua",
  package.path,
}, ";")

require("core_spec")
require("render_spec")
require("lifecycle_spec")
require("helpers").run()

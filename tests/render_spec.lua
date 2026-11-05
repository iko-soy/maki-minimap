local t = require("helpers")
local render = require("minimap.render")

local function text(line)
  local parts = {}
  for _, span in ipairs(line) do
    parts[#parts + 1] = span[1]
  end
  return table.concat(parts)
end

function t.test_rail_composition()
  local drawn = render.build({
    { topline = 1 },
    { topline = 100 },
  }, { topline = 1, line_count = 100, height = 20 }, 5, 4)
  t.eq(#drawn.lines, 5)
  t.eq(text(drawn.lines[1]), " ● ▐")
  t.eq(text(drawn.lines[2]), "    ")
  t.eq(text(drawn.lines[5]), " ●  ")
  t.eq(drawn.width, 4)
  t.eq(drawn.thumb, { top = 1, height = 1 })
end

function t.test_widths_and_bottom_thumb()
  local anchors = { { topline = 100 } }
  local view = { topline = 81, line_count = 100, height = 20 }
  t.eq(text(render.build(anchors, view, 1, 3).lines[1]), "● ▐")
  t.eq(text(render.build(anchors, view, 1, 4).lines[1]), " ● ▐")
  t.eq(text(render.build(anchors, view, 1, 5).lines[1]), " ●  ▐")
end

function t.test_empty_and_zero_rows()
  local empty = render.build({}, { topline = 1, line_count = 0, height = 0 }, 0, 4)
  t.eq(empty.lines, {})
  t.eq(empty.thumb, { top = 0, height = 0 })
  local no_history = render.build({ { topline = 1 } }, { topline = 1, line_count = 0, height = 3 }, 3, 4)
  t.eq(text(no_history.lines[1]), "    ")
  t.eq(no_history.thumb.height, 0)
end

function t.test_collisions_and_signatures()
  local view = { topline = 1, line_count = 1000, height = 10 }
  local first = render.build({ { topline = 1 }, { topline = 2 } }, view, 2, 4)
  t.eq(text(first.lines[1]), " ● ▐")
  t.eq(first.signature, "4:2:1:1:1,1")
  local same = render.build({ { topline = 1 }, { topline = 2 } }, view, 2, 4)
  t.eq(first.signature, same.signature)
  local changed = render.build(
    { { topline = 1 }, { topline = 2 } },
    { topline = 991, line_count = 1000, height = 10 },
    2,
    4
  )
  t.ok(first.signature ~= changed.signature)
end

return t

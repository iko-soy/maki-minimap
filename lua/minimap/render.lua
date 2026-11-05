local core = require("minimap.core")

local M = {}

local DEFAULT_WIDTH = 4

function M.build(anchors, view, rail_rows, width)
  rail_rows = math.max(0, math.floor(tonumber(rail_rows) or 0))
  width = math.max(3, math.min(5, math.floor(tonumber(width) or DEFAULT_WIDTH)))
  local line_count = math.max(0, math.floor(tonumber(view and view.line_count) or 0))
  local markers = {}
  local marker_rows = {}
  for _, anchor in ipairs(anchors or {}) do
    local row = core.marker_row(anchor, rail_rows, line_count)
    if row then
      markers[row] = true
      marker_rows[#marker_rows + 1] = row
    end
  end
  table.sort(marker_rows)

  local thumb = core.viewport_thumb(view, rail_rows)
  local marker_column = width >= 4 and 2 or 1
  local lines = {}
  for row = 1, rail_rows do
    local in_thumb = thumb.height > 0 and row >= thumb.top and row < thumb.top + thumb.height
    lines[row] = {
      { string.rep(" ", marker_column - 1) },
      { markers[row] and "●" or " ", markers[row] and "foreground" or "dim" },
      { string.rep(" ", width - marker_column - 1) },
      { in_thumb and "▐" or " ", in_thumb and "item_selected" or "dim" },
    }
  end

  local signature =
    string.format("%d:%d:%d:%d:%s", width, rail_rows, thumb.top, thumb.height, table.concat(marker_rows, ","))
  return { lines = lines, signature = signature, width = width, thumb = thumb }
end

return M

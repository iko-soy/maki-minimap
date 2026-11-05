local M = {}

local function whole(value, fallback)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    return fallback
  end
  return math.floor(value)
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function preview(text)
  text = tostring(text or ""):gsub("%s+", " ")
  return text:match("^%s*(.-)%s*$")
end

local function message_source_text(message)
  if type(message.display_text) == "string" then
    return message.display_text
  end
  if type(message.content) ~= "table" then
    return ""
  end
  local blocks = {}
  for _, block in ipairs(message.content) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      blocks[#blocks + 1] = block.text
    end
  end
  return table.concat(blocks, "\n")
end

function M.extract_prompts(messages)
  local prompts = {}
  for index, message in ipairs(messages or {}) do
    if message.role == "user" and (message.kind == nil or message.kind == "turn") and message.display_text ~= "" then
      local source_text = message_source_text(message)
      prompts[#prompts + 1] = {
        message_index = index,
        role = "user",
        preview = preview(source_text),
        source_text = source_text,
      }
    end
  end
  return prompts
end

function M.exact_anchors(anchors)
  local prompts = {}
  for _, anchor in ipairs(anchors or {}) do
    local message_index = whole(anchor.message_index, 0)
    if anchor.role == "user" and message_index > 0 then
      prompts[#prompts + 1] = {
        message_index = message_index,
        role = "user",
        preview = tostring(anchor.preview or ""),
        topline = math.max(1, whole(anchor.topline, 1)),
        height = math.max(0, whole(anchor.height, 0)),
        exact = true,
      }
    end
  end
  return prompts
end

function M.proportional_anchors(prompts, message_count, line_count)
  message_count = math.max(0, whole(message_count, 0))
  line_count = math.max(0, whole(line_count, 0))
  local anchors = {}
  for _, prompt in ipairs(prompts or {}) do
    local fraction = message_count == 0 and 0 or clamp((prompt.message_index - 1) / message_count, 0, 1)
    anchors[#anchors + 1] = {
      message_index = prompt.message_index,
      role = prompt.role,
      preview = prompt.preview,
      topline = math.max(1, whole(line_count * fraction + 0.5, 0) + 1),
      height = 0,
      exact = false,
    }
  end
  return anchors
end

function M.clamp_topline(topline, line_count, viewport_height)
  line_count = math.max(0, whole(line_count, 0))
  viewport_height = math.max(1, whole(viewport_height, 1))
  topline = math.max(1, whole(topline, 1))
  local last = math.max(1, line_count - viewport_height + 1)
  return clamp(topline, 1, last)
end

function M.marker_row(anchor, rail_rows, line_count)
  rail_rows = math.max(0, whole(rail_rows, 0))
  line_count = math.max(0, whole(line_count, 0))
  if rail_rows == 0 or line_count == 0 then
    return nil
  end
  if line_count == 1 or rail_rows == 1 then
    return 1
  end
  local topline = clamp(whole(anchor.topline, 1), 1, line_count)
  local row = math.floor((topline - 1) * (rail_rows - 1) / (line_count - 1) + 0.5) + 1
  return clamp(row, 1, rail_rows)
end

function M.viewport_thumb(view, rail_rows)
  rail_rows = math.max(0, whole(rail_rows, 0))
  local line_count = math.max(0, whole(view and view.line_count, 0))
  if rail_rows == 0 or line_count == 0 then
    return { top = 0, height = 0 }
  end
  local viewport_height = clamp(whole(view and view.height, 0), 0, line_count)
  local thumb_height = clamp(math.floor(viewport_height * rail_rows / line_count + 0.5), 1, rail_rows)
  if viewport_height == 0 then
    thumb_height = 1
  end
  local last_topline = math.max(0, line_count - viewport_height)
  local topline = clamp(whole(view and view.topline, 1) - 1, 0, last_topline)
  local available = rail_rows - thumb_height
  local top = last_topline == 0 and 0 or math.floor(topline * available / last_topline + 0.5)
  return {
    top = clamp(top, 0, available) + 1,
    height = thumb_height,
  }
end

function M.navigation_target(anchors, current_topline, direction, selected_index)
  local count = #(anchors or {})
  if count == 0 then
    return nil, nil
  end
  if selected_index and selected_index >= 1 and selected_index <= count then
    local index = selected_index + direction
    if index >= 1 and index <= count then
      return anchors[index], index
    end
    return nil, nil
  end
  current_topline = math.max(1, whole(current_topline, 1))
  if direction > 0 then
    for index, anchor in ipairs(anchors) do
      if anchor.topline > current_topline then
        return anchor, index
      end
    end
  else
    for index = count, 1, -1 do
      if anchors[index].topline < current_topline then
        return anchors[index], index
      end
    end
  end
  return nil, nil
end

return M

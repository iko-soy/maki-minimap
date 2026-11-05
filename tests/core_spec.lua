local t = require("helpers")
local core = require("minimap.core")

function t.test_prompt_extraction()
  local messages = {
    { role = "user", display_text = "  hello\nworld  " },
    { role = "user", kind = "observation", display_text = "notice" },
    { role = "assistant", kind = "turn", display_text = "answer" },
    { role = "user", kind = "turn", display_text = "" },
    {
      role = "user",
      kind = "turn",
      content = {
        { type = "image" },
        { type = "text", text = "text\tfrom content" },
      },
    },
    { role = "user", kind = "context_update", display_text = "facts" },
  }
  t.eq(core.extract_prompts(messages), {
    { message_index = 1, role = "user", preview = "hello world", source_text = "  hello\nworld  " },
    { message_index = 5, role = "user", preview = "text from content", source_text = "text\tfrom content" },
  })
  t.eq(core.extract_prompts(nil), {})
end

function t.test_exact_anchor_conversion()
  local anchors = core.exact_anchors({
    { message_index = 2, role = "assistant", preview = "answer", topline = 10, height = 4 },
    { message_index = 3, role = "user", preview = "prompt", topline = 20, height = 3 },
    { message_index = 0, role = "user", preview = "invalid" },
    { message_index = 4, role = "user", preview = "clamped", topline = 0, height = -2 },
  })
  t.eq(anchors, {
    { message_index = 3, role = "user", preview = "prompt", topline = 20, height = 3, exact = true },
    { message_index = 4, role = "user", preview = "clamped", topline = 1, height = 0, exact = true },
  })
end

function t.test_proportional_anchors_are_documented_approximations()
  local prompts = core.extract_prompts({
    { role = "user", kind = "turn", display_text = "one" },
    { role = "assistant", kind = "turn", display_text = "answer" },
    { role = "user", kind = "turn", display_text = "two" },
    { role = "assistant", kind = "turn", display_text = "answer" },
  })
  local anchors = core.proportional_anchors(prompts, 4, 100)
  t.eq(#anchors, 2)
  t.eq(anchors[1].topline, 1)
  t.eq(anchors[2].topline, 51)
  t.eq(anchors[1].exact, false)
  t.eq(anchors[1].height, 0)
  t.eq(core.proportional_anchors(prompts, 0, 0)[1].topline, 1)
end

function t.test_scroll_clamping()
  t.eq(core.clamp_topline(500, 100, 20), 81)
  t.eq(core.clamp_topline(-20, 100, 20), 1)
  t.eq(core.clamp_topline(4, 10, 20), 1)
  t.eq(core.clamp_topline(4, 0, 0), 1)
  t.eq(core.clamp_topline(4, 100, 0), 4)
  t.eq(core.clamp_topline(500, 100, 0), 100)
end

function t.test_marker_placement()
  t.eq(core.marker_row({ topline = 1 }, 11, 101), 1)
  t.eq(core.marker_row({ topline = 51 }, 11, 101), 6)
  t.eq(core.marker_row({ topline = 101 }, 11, 101), 11)
  t.eq(core.marker_row({ topline = 999 }, 11, 101), 11)
  t.eq(core.marker_row({ topline = 1 }, 0, 101), nil)
  t.eq(core.marker_row({ topline = 1 }, 10, 0), nil)
  t.eq(core.marker_row({ topline = 1 }, 10, 1), 1)
end

function t.test_viewport_thumb_geometry()
  t.eq(core.viewport_thumb({ topline = 1, line_count = 1000, height = 100 }, 20), { top = 1, height = 2 })
  t.eq(core.viewport_thumb({ topline = 501, line_count = 1000, height = 100 }, 20), { top = 11, height = 2 })
  t.eq(core.viewport_thumb({ topline = 901, line_count = 1000, height = 100 }, 20), { top = 19, height = 2 })
  t.eq(core.viewport_thumb({ topline = 1, line_count = 10, height = 20 }, 5), { top = 1, height = 5 })
  t.eq(core.viewport_thumb({ topline = 1, line_count = 100, height = 0 }, 5), { top = 1, height = 1 })
  t.eq(core.viewport_thumb({ topline = 1, line_count = 0, height = 20 }, 5), { top = 0, height = 0 })
  t.eq(core.viewport_thumb({ topline = 1, line_count = 100, height = 20 }, 0), { top = 0, height = 0 })
end

function t.test_navigation_boundaries_and_rapid_selection()
  local anchors = {
    { message_index = 1, topline = 1 },
    { message_index = 3, topline = 20 },
    { message_index = 5, topline = 40 },
  }
  local target, index = core.navigation_target(anchors, 1, 1, nil)
  t.eq(index, 2)
  t.eq(target.message_index, 3)
  target, index = core.navigation_target(anchors, 1, 1, index)
  t.eq(index, 3)
  t.eq(target.message_index, 5)
  target, index = core.navigation_target(anchors, 1, -1, index)
  t.eq(index, 2)
  t.eq(target.message_index, 3)
  t.eq(core.navigation_target(anchors, 1, -1, nil), nil)
  t.eq(core.navigation_target(anchors, 40, 1, nil), nil)
  t.eq(core.navigation_target({}, 1, 1, nil), nil)
end

function t.test_long_history()
  local messages = {}
  for index = 1, 10000 do
    messages[index] = index % 10 == 1 and { role = "user", kind = "turn", display_text = "prompt " .. index }
      or { role = "assistant", kind = "turn", display_text = "answer" }
  end
  local prompts = core.extract_prompts(messages)
  t.eq(#prompts, 1000)
  local anchors = core.proportional_anchors(prompts, #messages, 1000000)
  t.eq(#anchors, 1000)
  t.eq(anchors[1].topline, 1)
  t.eq(anchors[1000].topline, 999001)
  for rail_rows = 0, 50 do
    for _, anchor in ipairs(anchors) do
      local row = core.marker_row(anchor, rail_rows, 1000000)
      if rail_rows == 0 then
        t.eq(row, nil)
      else
        t.ok(row >= 1 and row <= rail_rows)
      end
    end
  end
end

return t

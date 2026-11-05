local t = require("helpers")
local fake = require("fake_host")
local Runtime = require("minimap.runtime")

local function runtime(exact, opts)
  local host = fake.new(exact)
  local instance = Runtime.new(host)
  t.ok(instance:setup(opts))
  return host, instance
end

function t.test_window_options_and_change_only_redraw()
  local host, instance = runtime(false)
  t.ok(instance:refresh())
  t.eq(#host.windows, 1)
  t.eq(host.windows[1].opts, {
    split = "right",
    width = 4,
    border = "none",
    focus = false,
    session = "s1",
  })
  t.ok(host.bufs[1].scratch)
  t.eq(host.bufs[1].writes, 1)
  t.eq(host.message_reads, 1)
  t.eq(#instance.sessions.s1.anchors, 3)
  t.eq(instance.sessions.s1.anchors[1].exact, false)

  local cached_anchors = instance.sessions.s1.anchors
  t.ok(instance:refresh())
  t.ok(cached_anchors == instance.sessions.s1.anchors)
  t.eq(host.bufs[1].writes, 1)
  t.eq(host.message_reads, 1)
  host.view.topline = 21
  t.ok(instance:refresh())
  t.eq(host.bufs[1].writes, 2)
  t.eq(host.message_reads, 1)
  host.view.line_count = 200
  t.ok(instance:refresh())
  t.eq(host.message_reads, 1)

  host.messages_by_session.s1[#host.messages_by_session.s1 + 1] = {
    role = "user",
    kind = "turn",
    display_text = "four",
  }
  host.fire("TurnStart", { session_id = "s1" })
  t.ok(instance:refresh())
  t.eq(host.message_reads, 2)
  t.eq(#instance.sessions.s1.prompts, 4)
  t.eq(#host.scroll_requests, 0)
end

function t.test_rewind_refreshes_only_on_a_restored_prompt()
  local host, instance = runtime(false)
  t.ok(instance:refresh())
  host.fire("InputChanged", { session_id = "s1", text = "typing", cursor_only = false })
  t.ok(instance:refresh())
  t.eq(host.message_reads, 1)

  host.messages_by_session.s1 = { host.messages_by_session.s1[1] }
  host.fire("InputChanged", { session_id = "s1", text = "two", cursor_only = false })
  t.ok(instance:refresh())
  t.eq(host.message_reads, 2)
  t.eq(#instance.sessions.s1.prompts, 1)
end

function t.test_repeated_toggle_preserves_bindings_without_duplicates()
  local host, instance = runtime(false)
  t.ok(instance:refresh())
  t.ok(instance:toggle())
  t.ok(not instance.enabled)
  t.ok(not host.windows[1].open)
  t.eq(host.cancel_count, 1)
  t.eq(#host.keymaps.del_calls, 0)
  t.eq(#host.keymaps.set_calls, 3)

  t.ok(instance:toggle())
  t.ok(instance.enabled)
  t.eq(#host.windows, 2)
  t.eq(#host.keymaps.set_calls, 3)
  t.eq(#host.autocmds, 6)
  t.eq(#host.spawned, 2)
  t.ok(instance:stop())
  t.eq(#host.keymaps.del_calls, 3)
end

function t.test_externally_closed_window_reopens_on_an_unchanged_tick()
  local host, instance = runtime(false)
  t.ok(instance:refresh())
  host.windows[1].open = false
  t.ok(instance:refresh())
  t.eq(#host.windows, 2)
  t.ok(host.windows[2].open)
end

function t.test_setup_and_reload_cleanup()
  local host, instance = runtime(false)
  t.ok(instance:refresh())
  t.ok(instance:setup())
  t.ok(not host.windows[1].open)
  t.eq(host.cancel_count, 1)
  t.eq(#host.keymaps.del_calls, 3)
  t.ok(instance:refresh())
  t.eq(#host.windows, 2)
  host.fire("SessionEnd", { session_id = "s1", reason = "reload" })
  t.ok(not host.windows[2].open)
  t.eq(host.cancel_count, 2)
  t.eq(#host.keymaps.del_calls, 6)
end

function t.test_session_windows_have_explicit_owners()
  local host, instance = runtime(false)
  t.ok(instance:refresh())
  host.current_id = "s2"
  host.fire("SessionFocusChanged", { session_id = "s2" })
  host.fire("TaskFocusChanged", { session_id = "s2", id = "main" })
  t.ok(instance:refresh())
  t.eq(#host.windows, 2)
  t.eq(host.windows[1].opts.session, "s1")
  t.eq(host.windows[2].opts.session, "s2")

  host.current_id = "s1"
  host.fire("SessionFocusChanged", { session_id = "s1" })
  host.fire("TaskFocusChanged", { session_id = "s1", id = "main" })
  t.ok(instance:refresh())
  t.eq(#host.windows, 2)
  t.ok(host.windows[1].open)
end

function t.test_fallback_subagent_hides_instead_of_misnavigating()
  local host, instance = runtime(false)
  t.ok(instance:refresh())
  host.tasks = { { id = "main", focused = false }, { id = "task1", focused = true } }
  host.fire("TaskFocusChanged", { session_id = "s1", id = "task1" })
  t.ok(instance:refresh())
  t.ok(not instance.sessions.s1.visible)
  t.ok(not host.windows[1].visible)
  t.eq(host.message_reads, 1)
  local ok, err = instance:navigate(1)
  t.eq(ok, nil)
  t.contains(err, "main chat")

  host.tasks = { { id = "main", focused = true } }
  host.fire("TaskFocusChanged", { session_id = "s1", id = "main" })
  t.ok(instance:refresh())
  t.ok(instance.sessions.s1.visible)
  t.ok(host.windows[1].visible)
end

function t.test_exact_anchors_revision_and_subagent_support()
  local host, instance = runtime(true)
  t.ok(instance:refresh())
  t.eq(host.anchor_reads, 1)
  t.eq(host.message_reads, 0)
  t.eq(#instance.sessions.s1.anchors, 3)
  t.ok(instance:refresh())
  t.eq(host.anchor_reads, 1)
  host.view.topline = 10
  t.ok(instance:refresh())
  t.eq(host.anchor_reads, 1)
  host.view.anchor_revision = "r2"
  t.ok(instance:refresh())
  t.eq(host.anchor_reads, 2)
  host.view.width = 90
  t.ok(instance:refresh())
  t.eq(host.anchor_reads, 3)

  host.tasks = { { id = "main", focused = false }, { id = "task1", focused = true } }
  host.fire("TaskFocusChanged", { session_id = "s1", id = "task1" })
  t.ok(instance:refresh())
  t.eq(host.anchor_reads, 4)
  t.ok(instance.sessions.s1.visible)
  t.eq(instance.sessions.s1.anchor_task, "task1")
end

function t.test_exact_false_forces_the_documented_fallback()
  local host, instance = runtime(true, { exact = false })
  t.ok(instance:refresh())
  t.eq(host.anchor_reads, 0)
  t.eq(host.message_reads, 1)
  t.eq(instance.sessions.s1.anchors[1].exact, false)
  t.ok(instance:navigate(1))
  t.eq(host.scroll_requests[1], { topline = 41 })
end

function t.test_fallback_rapid_navigation_uses_proportional_rows()
  local host, instance = runtime(false)
  t.ok(instance:refresh())
  t.ok(instance:navigate(1))
  t.ok(instance:navigate(1))
  t.ok(instance:navigate(-1))
  t.eq(#host.scroll_requests, 3)
  t.eq(host.scroll_requests[1], { topline = 41 })
  t.eq(host.scroll_requests[2], { topline = 81 })
  t.eq(host.scroll_requests[3], { topline = 41 })
  t.eq(host.scroll_requests[1].message_index, nil)
end

function t.test_manual_scroll_before_poll_clears_rapid_selection()
  local host, instance = runtime(false)
  t.ok(instance:refresh())
  t.ok(instance:navigate(1))
  t.ok(instance:navigate(1))
  host.view.topline = 1
  t.ok(instance:navigate(1))
  t.eq(host.scroll_requests[3], { topline = 41 })
end

function t.test_exact_navigation_uses_message_targets()
  local host, instance = runtime(true)
  t.ok(instance:refresh())
  t.ok(instance:navigate(1))
  t.ok(instance:navigate(1))
  t.ok(instance:navigate(-1))
  t.eq(host.scroll_requests[1], { message_index = 2 })
  t.eq(host.scroll_requests[2], { message_index = 4 })
  t.eq(host.scroll_requests[3], { message_index = 2 })
  t.eq(host.scroll_requests[1].topline, nil)
end

function t.test_permission_error_is_clear_and_throttled()
  local host, instance = runtime(false)
  host.permission_error = "permission denied: session_read"
  local ok, err = instance:refresh()
  t.eq(ok, nil)
  t.contains(err, "permission denied")
  t.eq(#host.flashes, 1)
  t.ok(not host.windows[1].visible)
  instance:refresh()
  t.eq(#host.flashes, 1)

  host.permission_error = nil
  t.ok(instance:refresh())
  t.ok(host.windows[1].visible)
end

function t.test_unavailable_ui_is_an_error_without_a_window()
  local host, instance = runtime(false)
  host.view_error = "no interactive UI attached"
  local ok, err = instance:refresh()
  t.eq(ok, nil)
  t.contains(err, "no interactive UI")
  t.eq(#host.windows, 0)
end

function t.test_polling_is_throttled_and_stops_on_cancel()
  local host, instance = runtime(false)
  host.run_poll()
  t.eq(host.sleep_ms, { 225 })
  t.eq(host.message_reads, 1)
  t.eq(#host.spawned, 1)
end

function t.test_session_teardown_closes_only_that_session()
  local host, instance = runtime(false)
  t.ok(instance:refresh())
  host.current_id = "s2"
  host.fire("SessionFocusChanged", { session_id = "s2" })
  host.fire("TaskFocusChanged", { session_id = "s2", id = "main" })
  t.ok(instance:refresh())
  host.fire("SessionEnd", { session_id = "s2", reason = "delete" })
  t.eq(instance.sessions.s2, nil)
  t.ok(not host.windows[2].open)
  t.ok(instance.sessions.s1 ~= nil)
  t.eq(host.cancel_count, 0)
end

function t.test_empty_history_and_disabled_setup()
  local host = fake.new(false)
  host.messages_by_session.s1 = {}
  host.view = { topline = 1, line_count = 0, height = 0, width = 80 }
  local instance = Runtime.new(host)
  t.ok(instance:setup({ enabled = false }))
  t.eq(#host.spawned, 0)
  local ok, err = instance:navigate(1)
  t.eq(ok, nil)
  t.contains(err, "disabled")
  t.ok(instance:toggle())
  t.eq(#host.bufs[1].lines, 0)
  t.eq(#instance.sessions.s1.anchors, 0)
end

return t

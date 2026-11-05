local core = require("minimap.core")
local render = require("minimap.render")

local Runtime = {}
Runtime.__index = Runtime

local MAIN_TASK = "main"
local DEFAULT_POLL_MS = 225
local MIN_POLL_MS = 200
local MAX_POLL_MS = 250
local DEFAULT_WIDTH = 4
local MIN_WIDTH = 3
local MAX_WIDTH = 5
local HISTORY_EVENTS = {
  "TurnStart",
  "TurnEnd",
  "TurnError",
  "AutoCompacting",
  "CompactionDone",
  "SessionReset",
}
local LAYOUT_EVENTS = { "ToolStart", "ToolDone", "TaskStatusChanged" }

local function call(fn, ...)
  local ok, value, err = pcall(fn, ...)
  if not ok then
    return nil, value
  end
  return value, err
end

local function clamp_whole(value, low, high, fallback)
  value = tonumber(value) or fallback
  return math.max(low, math.min(high, math.floor(value)))
end

local function window_open(state)
  if not state.win then
    return false
  end
  local ok, open = pcall(state.win.is_open, state.win)
  return ok and open or false
end

function Runtime.new(host)
  return setmetatable({
    host = host,
    sessions = {},
    autocmds = {},
    keymaps = {},
    enabled = false,
    refreshing = false,
    config = { width = DEFAULT_WIDTH, poll_ms = DEFAULT_POLL_MS },
  }, Runtime)
end

function Runtime:exact()
  return self.config.exact ~= false and self.host.fn and type(self.host.fn.transcript_anchors) == "function"
end

function Runtime:report(err)
  err = tostring(err or "unknown minimap error")
  if self.last_error == err then
    return nil, err
  end
  self.last_error = err
  if self.host.log and self.host.log.error then
    pcall(self.host.log.error, "minimap: " .. err)
  end
  if self.host.ui and self.host.ui.flash then
    pcall(self.host.ui.flash, "minimap: " .. err)
  end
  return nil, err
end

function Runtime:state(session_id)
  local state = self.sessions[session_id]
  if not state then
    state = { id = session_id, history_dirty = true, refresh_dirty = true }
    self.sessions[session_id] = state
  end
  return state
end

function Runtime:close_session(session_id)
  local state = self.sessions[session_id]
  if state and state.win then
    pcall(state.win.close, state.win)
  end
  self.sessions[session_id] = nil
  if self.current_session == session_id then
    self.current_session = nil
  end
end

function Runtime:close_resources()
  if self.poller then
    pcall(self.poller.cancel, self.poller)
    self.poller = nil
  end
  for session_id in pairs(self.sessions) do
    self:close_session(session_id)
  end
  self.current_session = nil
  self.last_error = nil
end

function Runtime:cleanup()
  self:close_resources()
  for _, id in ipairs(self.autocmds) do
    pcall(self.host.api.del_autocmd, id)
  end
  self.autocmds = {}
  for _, binding in ipairs(self.keymaps) do
    pcall(self.host.keymap.del, binding.modes, binding.lhs)
  end
  self.keymaps = {}
end

function Runtime:stop()
  self.enabled = false
  self:cleanup()
  return true
end

function Runtime:listen(events, callback)
  local id = self.host.api.create_autocmd(events, { callback = callback })
  self.autocmds[#self.autocmds + 1] = id
end

function Runtime:register_autocmds()
  self:listen(HISTORY_EVENTS, function(ev)
    if not self.enabled then
      return
    end
    local state = self.sessions[ev.data.session_id]
    if state then
      state.history_dirty = true
      state.refresh_dirty = true
      state.selected = nil
    end
  end)
  self:listen(LAYOUT_EVENTS, function(ev)
    if self.enabled then
      local state = self.sessions[ev.data.session_id]
      if state then
        state.refresh_dirty = true
      end
    end
  end)
  self:listen("InputChanged", function(ev)
    if not self.enabled or ev.data.source ~= nil or ev.data.cursor_only then
      return
    end
    local state = self.sessions[ev.data.session_id]
    if not state or not state.prompts then
      return
    end
    for _, prompt in ipairs(state.prompts) do
      if prompt.source_text == ev.data.text then
        state.history_dirty = true
        state.refresh_dirty = true
        state.selected = nil
        break
      end
    end
  end)
  self:listen("SessionFocusChanged", function(ev)
    if not self.enabled then
      return
    end
    self.current_session = nil
    local state = self:state(ev.data.session_id)
    state.task = nil
    state.history_dirty = true
    state.refresh_dirty = true
    state.selected = nil
  end)
  self:listen("TaskFocusChanged", function(ev)
    if not self.enabled then
      return
    end
    local state = self:state(ev.data.session_id)
    state.task = ev.data.id
    state.history_dirty = true
    state.refresh_dirty = true
    state.selected = nil
  end)
  self:listen("SessionEnd", function(ev)
    self:close_session(ev.data.session_id)
    local reason = ev.data.reason
    if reason == "reload" or reason == "shutdown" or reason == "replaced" or reason == "completed" then
      self:cleanup()
    end
  end)
end

function Runtime:register_command(name, description, handler)
  self.host.api.register_command({
    name = name,
    description = description,
    handler = function()
      local ok, err = handler(self)
      if not ok then
        self:report(err)
      end
    end,
  })
end

function Runtime:register_commands()
  self:register_command("minimap", "Toggle the chat-history minimap", Runtime.toggle)
  self:register_command("minimap-next", "Jump to the next user prompt", function(self)
    return self:navigate(1)
  end)
  self:register_command("minimap-prev", "Jump to the previous user prompt", function(self)
    return self:navigate(-1)
  end)
end

function Runtime:bind(lhs, description, handler)
  if not lhs then
    return
  end
  local modes = { "n", "i" }
  self.host.keymap.set(modes, lhs, function()
    local ok, err = handler(self)
    if not ok then
      self:report(err)
    end
  end, { desc = description })
  self.keymaps[#self.keymaps + 1] = { modes = modes, lhs = lhs }
end

function Runtime:setup(opts)
  self:cleanup()
  opts = opts or {}
  local keys = opts.keys or {}
  self.config = {
    width = clamp_whole(opts.width, MIN_WIDTH, MAX_WIDTH, DEFAULT_WIDTH),
    poll_ms = clamp_whole(opts.poll_ms, MIN_POLL_MS, MAX_POLL_MS, DEFAULT_POLL_MS),
    exact = opts.exact,
  }
  self.enabled = opts.enabled ~= false
  self:register_commands()
  self:register_autocmds()
  self:bind(keys.toggle == nil and "<M-m>" or keys.toggle, "Toggle minimap", Runtime.toggle)
  self:bind(keys.next == nil and "<M-n>" or keys.next, "Next user prompt", function(self)
    return self:navigate(1)
  end)
  self:bind(keys.previous == nil and "<M-p>" or keys.previous, "Previous user prompt", function(self)
    return self:navigate(-1)
  end)
  if self.enabled then
    return self:start()
  end
  return true
end

function Runtime:start()
  if self.poller then
    return true
  end
  local ok, task = pcall(self.host.async.spawn, function()
    while self.enabled do
      self:refresh()
      local slept = pcall(self.host.async.sleep, self.config.poll_ms)
      if not slept then
        return
      end
    end
  end)
  if not ok then
    return self:report(task)
  end
  self.poller = task
  return true
end

function Runtime:toggle()
  if self.enabled then
    self.enabled = false
    self:close_resources()
    return true
  end
  self.enabled = true
  local ok, err = self:start()
  if not ok then
    return nil, err
  end
  return self:refresh()
end

function Runtime:open_window(state)
  local ok, buf, win = pcall(function()
    local buf = self.host.ui.buf({ scratch = true })
    local win = self.host.ui.open_win(buf, {
      split = "right",
      width = self.config.width,
      border = "none",
      focus = false,
      session = state.id,
    })
    return buf, win
  end)
  if not ok then
    return nil, buf
  end
  state.buf = buf
  state.win = win
  state.visible = true
  state.signature = nil
  return true
end

function Runtime:focused_task(state)
  local tasks, err = call(self.host.task.list)
  if not tasks then
    return nil, err or "could not read task focus"
  end
  for _, task in ipairs(tasks) do
    if task.focused then
      return task.id
    end
  end
  return MAIN_TASK
end

function Runtime:load_exact_anchors(state)
  local anchors, err = call(self.host.fn.transcript_anchors)
  if not anchors then
    return nil, err or "transcript anchors are unavailable"
  end
  state.anchors = core.exact_anchors(anchors)
  state.anchor_task = state.task
  state.history_dirty = false
  state.selected = nil
  return true
end

function Runtime:load_fallback_prompts(state)
  local messages, err = call(self.host.session.messages, { session = state.id })
  if not messages then
    return nil, err or "session messages are unavailable"
  end
  state.prompts = core.extract_prompts(messages)
  state.message_count = #messages
  state.anchor_task = MAIN_TASK
  state.anchor_line_count = nil
  state.history_dirty = false
  state.selected = nil
  return true
end

function Runtime:refresh_inner()
  if not self.enabled then
    return true
  end
  local session_id, err = call(self.host.session.current)
  if not session_id then
    return nil, err or "no focused session"
  end
  local state = self:state(session_id)
  if self.current_session ~= session_id then
    self.current_session = session_id
    state.task = nil
    state.history_dirty = true
    state.refresh_dirty = true
    state.selected = nil
  end
  if not state.task then
    local task, task_err = self:focused_task(state)
    if not task then
      return nil, task_err
    end
    state.task = task
  end

  local view
  view, err = call(self.host.fn.winsaveview)
  if not view then
    return nil, err or "transcript viewport is unavailable"
  end
  local layout_changed = state.last_line_count ~= view.line_count
    or state.last_width ~= view.width
    or state.last_anchor_revision ~= view.anchor_revision
  local viewport_changed = not state.view
    or state.view.topline ~= view.topline
    or state.view.height ~= view.height
    or state.view.auto_scroll ~= view.auto_scroll
  if not state.refresh_dirty and not layout_changed and not viewport_changed and window_open(state) then
    return true
  end

  local exact = self:exact()
  if not exact and state.task ~= MAIN_TASK then
    if state.win and state.visible then
      state.win:hide()
      state.visible = false
    end
    state.view = view
    state.refresh_dirty = false
    state.last_line_count = view.line_count
    state.last_width = view.width
    state.last_anchor_revision = view.anchor_revision
    return true
  end

  if not window_open(state) then
    local ok, open_err = self:open_window(state)
    if not ok then
      return nil, open_err
    end
  elseif not state.visible then
    state.win:show()
    state.visible = true
  end

  if exact then
    local revision_changed = view.anchor_revision ~= nil and state.last_anchor_revision ~= view.anchor_revision
    local legacy_layout_changed = view.anchor_revision == nil and state.last_line_count ~= view.line_count
    if
      state.history_dirty
      or not state.anchors
      or state.anchor_task ~= state.task
      or state.last_width ~= view.width
      or revision_changed
      or legacy_layout_changed
    then
      local ok, anchor_err = self:load_exact_anchors(state)
      if not ok then
        return nil, anchor_err
      end
    end
  else
    local history_shrank = state.last_line_count ~= nil and view.line_count < state.last_line_count
    if state.history_dirty or not state.prompts or history_shrank then
      local ok, history_err = self:load_fallback_prompts(state)
      if not ok then
        return nil, history_err
      end
    end
    if state.anchor_line_count ~= view.line_count then
      state.anchors = core.proportional_anchors(state.prompts, state.message_count, view.line_count)
      state.anchor_line_count = view.line_count
    end
  end

  if state.selected and state.expected_topline and view.topline ~= state.expected_topline then
    state.selected = nil
  end
  local drawn = render.build(state.anchors, view, view.height, self.config.width)
  if state.signature ~= drawn.signature then
    state.buf:set_lines(drawn.lines)
    state.signature = drawn.signature
  end
  state.view = view
  state.refresh_dirty = false
  state.last_line_count = view.line_count
  state.last_width = view.width
  state.last_anchor_revision = view.anchor_revision
  return true
end

function Runtime:refresh()
  if not self.enabled or self.refreshing then
    return true
  end
  self.refreshing = true
  local ok, result, err = pcall(self.refresh_inner, self)
  self.refreshing = false
  if not ok then
    result, err = nil, result
  end
  if not result then
    local state = self.current_session and self.sessions[self.current_session]
    if state and state.win and state.visible then
      pcall(state.win.hide, state.win)
      state.visible = false
    end
    return self:report(err)
  end
  self.last_error = nil
  return true
end

function Runtime:navigate_inner(direction)
  if not self.enabled then
    return nil, "minimap is disabled; run /minimap first"
  end
  local session_id, err = call(self.host.session.current)
  if not session_id then
    return nil, err or "no focused session"
  end
  local state = self.sessions[session_id]
  if not state or not state.anchors or not state.task then
    local ok, refresh_err = self:refresh()
    if not ok then
      return nil, refresh_err
    end
    state = self.sessions[session_id]
  end
  if not state then
    return nil, "minimap is not ready"
  end
  if not self:exact() and state.task ~= MAIN_TASK then
    return nil, "approximate minimap navigation is only available in the main chat"
  end
  if state.anchor_task ~= state.task then
    local ok, refresh_err = self:refresh()
    if not ok then
      return nil, refresh_err
    end
  end

  local view
  view, err = call(self.host.fn.winsaveview)
  if not view then
    return nil, err or "transcript viewport is unavailable"
  end
  if state.selected and state.expected_topline and view.topline ~= state.expected_topline then
    state.selected = nil
  end
  if not self:exact() and state.anchor_line_count ~= view.line_count then
    state.anchors = core.proportional_anchors(state.prompts, state.message_count, view.line_count)
    state.anchor_line_count = view.line_count
  end
  local target, index = core.navigation_target(state.anchors, view.topline, direction, state.selected)
  if not target then
    return nil, direction > 0 and "no next user prompt" or "no previous user prompt"
  end
  local topline = core.clamp_topline(target.topline, view.line_count, view.height)
  local request = self:exact() and { message_index = target.message_index } or { topline = topline }
  local ok
  ok, err = call(self.host.fn.winrestview, request)
  if not ok then
    return nil, err or "could not scroll the transcript"
  end
  state.selected = index
  state.expected_topline = topline
  return true
end

function Runtime:navigate(direction)
  local ok, result, err = pcall(self.navigate_inner, self, direction)
  if not ok then
    result, err = nil, result
  end
  if not result then
    return self:report(err)
  end
  self.last_error = nil
  return true
end

return Runtime

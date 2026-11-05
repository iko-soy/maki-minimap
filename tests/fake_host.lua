local H = {}

local function messages()
  return {
    { role = "user", display_text = "one" },
    { role = "assistant", kind = "turn", display_text = "answer one" },
    { role = "user", display_text = "two" },
    { role = "assistant", kind = "turn", display_text = "answer two" },
    { role = "user", display_text = "three" },
  }
end

function H.new(exact)
  local host = {
    current_id = "s1",
    messages_by_session = { s1 = messages(), s2 = messages() },
    tasks = { { id = "main", focused = true } },
    view = { topline = 1, line_count = 100, height = 20, width = 80, anchor_revision = "r1" },
    anchors = {
      { message_index = 2, role = "user", preview = "one", topline = 20, height = 3 },
      { message_index = 3, role = "assistant", preview = "answer", topline = 30, height = 5 },
      { message_index = 4, role = "user", preview = "two", topline = 40, height = 2 },
      { message_index = 5, role = "user", preview = "three", topline = 80, height = 4 },
    },
    windows = {},
    bufs = {},
    commands = {},
    autocmds = {},
    keymaps = { set_calls = {}, del_calls = {} },
    spawned = {},
    scroll_requests = {},
    flashes = {},
    logs = {},
    sleep_ms = {},
    message_reads = 0,
    anchor_reads = 0,
    cancel_count = 0,
    session = {},
    task = {},
    fn = {},
    ui = {},
    api = {},
    keymap = {},
    async = {},
    log = {},
  }

  host.session.current = function()
    if host.current_error then
      return nil, host.current_error
    end
    return host.current_id
  end
  host.session.messages = function(opts)
    if host.permission_error then
      error(host.permission_error)
    end
    host.message_reads = host.message_reads + 1
    return host.messages_by_session[opts.session]
  end
  host.task.list = function()
    if host.task_error then
      return nil, host.task_error
    end
    return host.tasks
  end
  host.fn.winsaveview = function()
    if host.view_error then
      return nil, host.view_error
    end
    local view = {}
    for key, value in pairs(host.view) do
      view[key] = value
    end
    return view
  end
  host.fn.winrestview = function(request)
    host.scroll_requests[#host.scroll_requests + 1] = request
    if request.message_index then
      for _, anchor in ipairs(host.anchors) do
        if anchor.message_index == request.message_index then
          host.view.topline = anchor.topline
          break
        end
      end
    else
      host.view.topline = request.topline
    end
    return true
  end
  if exact then
    host.fn.transcript_anchors = function()
      if host.anchor_error then
        return nil, host.anchor_error
      end
      host.anchor_reads = host.anchor_reads + 1
      return host.anchors
    end
  end

  host.ui.buf = function(opts)
    local buf = { scratch = opts.scratch, writes = 0, lines = {} }
    function buf:set_lines(lines)
      self.writes = self.writes + 1
      self.lines = lines
    end
    host.bufs[#host.bufs + 1] = buf
    return buf
  end
  host.ui.open_win = function(buf, opts)
    local win = { opts = opts, buf = buf, open = true, visible = true, hide_count = 0, show_count = 0 }
    function win:is_open()
      return self.open
    end
    function win:hide()
      self.visible = false
      self.hide_count = self.hide_count + 1
    end
    function win:show()
      self.visible = true
      self.show_count = self.show_count + 1
    end
    function win:close()
      self.open = false
      self.visible = false
    end
    host.windows[#host.windows + 1] = win
    return win
  end
  host.ui.flash = function(message)
    host.flashes[#host.flashes + 1] = message
  end
  host.log.error = function(message)
    host.logs[#host.logs + 1] = message
  end

  host.api.register_command = function(spec)
    host.commands[spec.name] = spec
  end
  host.api.create_autocmd = function(events, opts)
    local entry = { id = #host.autocmds + 1, events = events, callback = opts.callback, active = true }
    host.autocmds[#host.autocmds + 1] = entry
    return entry.id
  end
  host.api.del_autocmd = function(id)
    for _, entry in ipairs(host.autocmds) do
      if entry.id == id then
        entry.active = false
      end
    end
  end
  host.keymap.set = function(modes, lhs, handler, opts)
    host.keymaps.set_calls[#host.keymaps.set_calls + 1] = {
      modes = modes,
      lhs = lhs,
      handler = handler,
      opts = opts,
    }
  end
  host.keymap.del = function(modes, lhs)
    host.keymaps.del_calls[#host.keymaps.del_calls + 1] = { modes = modes, lhs = lhs }
  end

  host.async.spawn = function(fn)
    local task = { fn = fn, cancelled = false }
    function task:cancel()
      if not self.cancelled then
        self.cancelled = true
        host.cancel_count = host.cancel_count + 1
      end
    end
    host.spawned[#host.spawned + 1] = task
    return task
  end
  host.async.sleep = function(ms)
    host.sleep_ms[#host.sleep_ms + 1] = ms
    error("test poll stopped")
  end

  function host.fire(event, data)
    local snapshot = {}
    for _, entry in ipairs(host.autocmds) do
      snapshot[#snapshot + 1] = entry
    end
    for _, entry in ipairs(snapshot) do
      local events = type(entry.events) == "table" and entry.events or { entry.events }
      for _, name in ipairs(events) do
        if entry.active and name == event then
          entry.callback({ data = data })
          break
        end
      end
    end
  end

  function host.run_poll()
    host.spawned[#host.spawned].fn()
  end

  return host
end

return H

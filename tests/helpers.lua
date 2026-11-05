local H = { cases = {} }

function H.test(name, fn)
  H.cases[#H.cases + 1] = { name = name, fn = fn }
end

local function inspect(value, seen)
  if type(value) ~= "table" then
    return string.format("%q", tostring(value))
  end
  seen = seen or {}
  if seen[value] then
    return "<cycle>"
  end
  seen[value] = true
  local parts = {}
  for key, item in pairs(value) do
    parts[#parts + 1] = "[" .. inspect(key, seen) .. "]=" .. inspect(item, seen)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function equal(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for key, value in pairs(a) do
    if not equal(value, b[key]) then
      return false
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end

function H.eq(actual, expected, message)
  if not equal(actual, expected) then
    error((message and message .. ": " or "") .. "expected " .. inspect(expected) .. ", got " .. inspect(actual), 2)
  end
end

function H.ok(value, message)
  if not value then
    error(message or "expected a truthy value", 2)
  end
end

function H.contains(text, part)
  H.ok(
    type(text) == "string" and text:find(part, 1, true) ~= nil,
    "expected " .. inspect(text) .. " to contain " .. inspect(part)
  )
end

function H.run()
  local names = {}
  for name, fn in pairs(H) do
    if type(name) == "string" and name:match("^test_") and type(fn) == "function" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    H.cases[#H.cases + 1] = { name = name, fn = H[name] }
  end

  local failed = 0
  for _, case in ipairs(H.cases) do
    local ok, err = xpcall(case.fn, debug.traceback)
    if ok then
      io.write("ok - ", case.name, "\n")
    else
      failed = failed + 1
      io.stderr:write("not ok - ", case.name, "\n", err, "\n")
    end
  end
  io.write(string.format("%d tests, %d failures\n", #H.cases, failed))
  if failed > 0 then
    os.exit(1)
  end
end

return H

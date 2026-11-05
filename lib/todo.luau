--!nonstrict
-- Shared to-do logic for the nightwatch75/todo file format:
--   { version, sort = "priority" | "manual", tasks = [ { id, text, priority, done } ] }
-- (a bare array of tasks is also understood and written back the same way)

local M = {}

function M.weight(p)
  if type(p) == "number" then
    return p
  end
  if type(p) == "string" then
    local s = string.lower(p)
    if s == "high" or s == "urgent" or s == "3" then
      return 3
    elseif s == "medium" or s == "med" or s == "normal" or s == "2" then
      return 2
    elseif s == "low" or s == "1" then
      return 1
    end
  end
  return 0
end

function M.path()
  return noctalia.expandPath(noctalia.getConfig("todo_file") or "~/Documents/Todo/todo.json")
end

local function empty(path)
  return { ok = false, path = path, items = {}, open = 0, done = 0 }
end

function M.load(path)
  local raw = noctalia.readFile(path)
  if raw == nil then
    return empty(path)
  end
  local data = noctalia.json.decode(raw)
  if data == nil then
    return empty(path)
  end
  local tasks = data.tasks
  if tasks == nil and data[1] ~= nil then
    tasks = data
  end
  tasks = tasks or {}

  -- one list: finished tasks stay where they are (checked), only delete removes them
  local all, open, finished = {}, 0, 0
  for i, t in ipairs(tasks) do
    local isDone = t.done == true
    if isDone then
      finished = finished + 1
    else
      open = open + 1
    end
    table.insert(all, {
      id = t.id ~= nil and tostring(t.id) or "",
      text = tostring(t.text or ""),
      pr = M.weight(t.priority),
      idx = i,
      done = isDone,
    })
  end
  if data.sort ~= "manual" then
    table.sort(all, function(a, b)
      if a.pr ~= b.pr then
        return a.pr > b.pr
      end
      return a.idx < b.idx
    end)
  end

  local shown = {}
  for i = 1, math.min(#all, 80) do
    table.insert(shown, all[i])
  end
  return { ok = true, path = path, items = shown, open = open, done = finished }
end

function M.find(tasks, ref)
  if ref.id ~= nil and ref.id ~= "" then
    for i, t in ipairs(tasks) do
      if tostring(t.id) == ref.id then
        return i
      end
    end
  end
  if tasks[ref.idx] ~= nil and tostring(tasks[ref.idx].text) == ref.text then
    return ref.idx
  end
  return nil
end

-- A priority value written the same way the plugin already writes them.
function M.priorityValue(tasks, w)
  local anyNumber = false
  for _, t in ipairs(tasks) do
    if t.priority ~= nil and M.weight(t.priority) == w then
      return t.priority
    end
    if type(t.priority) == "number" then
      anyNumber = true
    end
  end
  if anyNumber then
    return w
  end
  return ({ "low", "medium", "high" })[w]
end

-- Read -> let fn edit the tasks array -> write back. Returns true on success.
function M.mutate(path, fn)
  local data = nil
  local raw = noctalia.readFile(path)
  if raw ~= nil then
    data = noctalia.json.decode(raw)
  end
  if data == nil then
    data = { version = 2, sort = "priority", tasks = {} }
    local dir = string.match(path, "^(.*)/[^/]+$")
    if dir ~= nil then
      noctalia.mkdirAll(dir)
    end
  end
  local tasks = data.tasks
  if tasks == nil then
    if data[1] ~= nil then
      tasks = data
    else
      data.tasks = {}
      tasks = data.tasks
    end
  end
  fn(tasks)
  local out = noctalia.json.encode(data, true)
  if out == nil then
    return false
  end
  out = (string.gsub(out, '"tasks"%s*:%s*{%s*}', '"tasks": []'))
  local ok, err = noctalia.writeFile(path, out)
  if not ok then
    noctalia.notifyError("Dashboard", "Could not save to-do file: " .. tostring(err))
    return false
  end
  return true
end

return M

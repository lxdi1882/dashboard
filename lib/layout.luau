--!nonstrict
local Layout = {}

function Layout.defaults(compact)
  if compact then
    return { left = { "github", "system", "calendar", "screen" }, right = { "todo" }, hidden = {} }
  end
  return { left = { "github", "calendar", "screen" }, right = { "todo", "system" }, hidden = {} }
end

-- Repair old or partial files, keeping valid saved positions and adding any missing cards.
function Layout.copy(layout, compact)
  local defaults = Layout.defaults(compact)
  local out = { left = {}, right = {}, hidden = {} }
  local known = {}
  local seen = {}
  for _, side in ipairs({ "left", "right" }) do
    for _, id in ipairs(defaults[side]) do
      known[id] = true
    end
  end
  for _, side in ipairs({ "left", "right" }) do
    local cards = layout[side]
    if type(cards) == "table" then
      for _, id in ipairs(cards) do
        if type(id) == "string" and known[id] and not seen[id] then
          table.insert(out[side], id)
          seen[id] = true
        end
      end
    end
  end
  for _, side in ipairs({ "left", "right" }) do
    for _, id in ipairs(defaults[side]) do
      if not seen[id] then
        table.insert(out[side], id)
      end
      if type(layout.hidden) == "table" and layout.hidden[id] == true then
        out.hidden[id] = true
      end
    end
  end
  return out
end

function Layout.load(compact)
  local dir = noctalia.pluginDataDir()
  local raw = dir and noctalia.readFile(dir .. "/layout.json")
  local data = raw and noctalia.json.decode(raw)
  if type(data) == "table" and data.default ~= true then
    return Layout.copy(data, compact)
  end
  return nil
end

function Layout.save(layout)
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return false
  end
  local contents = noctalia.json.encode(layout or { default = true })
  if contents == nil then
    return false
  end
  local path = dir .. "/layout.json"
  local temp = path .. ".tmp"
  if not noctalia.writeFile(temp, contents) then
    return false
  end
  return noctalia.renameFile(temp, path)
end

return Layout

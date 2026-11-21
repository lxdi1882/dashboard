--!nonstrict
local Grid = {}

Grid.cols = 24
Grid.rows = 14
Grid.gap = 8
Grid.ids = { "github", "screen", "calendar", "todo", "system" }
Grid.cards = {
  github = { title = "GitHub", icon = "brand-github", minW = 218, minH = 104, rect = { x = 0, y = 0, w = 15, h = 5 } },
  screen = { title = "Screen Time", icon = "device-desktop", minW = 224, minH = 104, rect = { x = 8, y = 5, w = 7, h = 9 } },
  calendar = { title = "Calendar", icon = "calendar-event", minW = 208, minH = 104, rect = { x = 0, y = 5, w = 8, h = 9 } },
  todo = { title = "To-do", icon = "list-check", minW = 238, minH = 104, rect = { x = 15, y = 0, w = 9, h = 8 } },
  system = { title = "System", icon = "cpu", minW = 198, minH = 104, rect = { x = 15, y = 8, w = 9, h = 6 } },
}

function Grid.defaults()
  local layout = {}
  for _, id in ipairs(Grid.ids) do
    layout[id] = Grid.cards[id].rect
  end
  return layout
end

function Grid.minimum(id, width, height)
  local card = Grid.cards[id]
  return math.ceil((card.minW + Grid.gap) * Grid.cols / (width + Grid.gap)),
    math.ceil((card.minH + Grid.gap) * Grid.rows / (height + Grid.gap))
end

function Grid.fits(layout, id, r)
  if r.w < 1 or r.h < 1 or r.x < 0 or r.y < 0 or r.x + r.w > Grid.cols or r.y + r.h > Grid.rows then
    return false
  end
  for other, a in pairs(layout) do
    if other ~= id and r.x < a.x + a.w and a.x < r.x + r.w and r.y < a.y + a.h and a.y < r.y + r.h then
      return false
    end
  end
  return true
end

local function number(v)
  return type(v) == "number" and v >= 0 and v <= 64 and math.floor(v) == v
end

local function sanitize(layout)
  local placed = {}
  if type(layout) == "table" then
    for _, id in ipairs(Grid.ids) do
      local r = layout[id]
      if type(r) == "table" and number(r.x) and number(r.y) and number(r.w) and number(r.h)
          and Grid.fits(placed, id, r) then
        placed[id] = { x = r.x, y = r.y, w = r.w, h = r.h }
      end
    end
  end
  return placed
end

local function nearest(placed, id, r, w, h)
  local best, distance
  for y = 0, Grid.rows - h do
    for x = 0, Grid.cols - w do
      local d = math.abs(x - r.x) + math.abs(y - r.y)
      if distance == nil or d < distance then
        local nextRect = { x = x, y = y, w = w, h = h }
        if Grid.fits(placed, id, nextRect) then
          best, distance = nextRect, d
          if d == 0 then
            return best
          end
        end
      end
    end
  end
  return best
end

function Grid.reflow(layout, width, height)
  local placed = {}
  for _, id in ipairs(Grid.ids) do
    local r = layout[id]
    if r ~= nil then
      local mw, mh = Grid.minimum(id, width, height)
      if mw <= Grid.cols and mh <= Grid.rows then
        local w, h = math.max(mw, r.w), math.max(mh, r.h)
        if Grid.fits(placed, id, { x = r.x, y = r.y, w = w, h = h }) then
          placed[id] = { x = r.x, y = r.y, w = w, h = h }
        end
      end
    end
  end
  for _, id in ipairs(Grid.ids) do
    local r = layout[id]
    if r ~= nil and placed[id] == nil then
      local mw, mh = Grid.minimum(id, width, height)
      placed[id] = nearest(placed, id, r, math.max(mw, r.w), math.max(mh, r.h))
        or nearest(placed, id, r, mw, mh)
    end
  end
  return placed
end

function Grid.pixels(r, width, height, gap)
  local sx, sy = (width + gap) / Grid.cols, (height + gap) / Grid.rows
  local x = math.floor(r.x * sx + 0.5)
  local y = math.floor(r.y * sy + 0.5)
  return x, y, math.floor((r.x + r.w) * sx + 0.5) - x - gap,
    math.floor((r.y + r.h) * sy + 0.5) - y - gap
end

function Grid.place(id, x, y, w, h, child)
  -- A one-pixel row gives every card the same horizontal origin.
  return ui.row({ key = "anchor-" .. id, height = 1, align = "start" }, {
    ui.column({
      key = "tile-" .. id, width = w, height = h, translateX = x, translateY = y, clip = true,
    }, { child }),
  })
end

function Grid.load()
  local dir = noctalia.pluginDataDir()
  local raw = dir and noctalia.readFile(dir .. "/grid-layout.json")
  local data = raw and noctalia.json.decode(raw)
  local profiles = { monitors = {} }
  if type(data) == "table" then
    if type(data.default) == "table" then
      profiles.default = sanitize(data.default)
    end
    if type(data.monitors) == "table" then
      for name, layout in pairs(data.monitors) do
        if type(name) == "string" and type(layout) == "table" then
          profiles.monitors[name] = sanitize(layout)
        end
      end
    end
  end
  return profiles
end

function Grid.save(profiles)
  local dir = noctalia.pluginDataDir()
  local data = noctalia.json.encode(profiles)
  if dir == nil or data == nil then
    return false
  end
  local path = dir .. "/grid-layout.json"
  local temp = path .. ".tmp"
  if not noctalia.writeFile(temp, data) then
    return false
  end
  return noctalia.renameFile(temp, path)
end

return Grid

--!nonstrict
local Grid = require("./lib/grid.luau")

local DRAG_TYPE = "dashboard-grid-card"
local model, draft, context, feedback
local previewW, previewH
local render

local function save(asDefault)
  local nextModel = { monitors = table.clone(model.monitors), default = asDefault and draft or model.default }
  nextModel.monitors[context.monitor] = draft
  if Grid.save(nextModel) then
    noctalia.state.set("layout_saved", noctalia.nowMs())
    panel.close()
  else
    feedback = "Could not save the layout."
    render()
  end
end

function dropCard(payload, target)
  if draft == nil then
    return
  end
  local operation, id = string.match(payload, "^(%a+):(%a+)$")
  if Grid.cards[id] == nil then
    return
  end
  if target == "park" and operation == "move" then
    draft[id] = nil
    feedback = nil
    render()
    return
  end
  local x, y = string.match(target, "^(%d+):(%d+)$")
  if x == nil then
    return
  end
  x, y = tonumber(x), tonumber(y)
  local current = draft[id]
  local mw, mh = Grid.minimum(id, context.width, context.height)
  local r
  if operation == "move" then
    local w = current and current.w or mw
    local h = current and current.h or mh
    r = { x = math.min(x, Grid.cols - w), y = math.min(y, Grid.rows - h), w = w, h = h }
  elseif operation == "resize" and current ~= nil then
    r = { x = current.x, y = current.y, w = x + 1 - current.x, h = y + 1 - current.y }
  end
  if r == nil then
    return
  end
  if r.w < mw or r.h < mh then
    feedback = "That card needs more room."
  elseif not Grid.fits(draft, id, r) then
    feedback = "Cards can’t overlap."
  else
    draft[id] = r
    feedback = nil
  end
  render()
end

local function drag(id, operation, children, width)
  return ui.dragSource({
    key = operation .. "-" .. id, dragType = DRAG_TYPE, payload = operation .. ":" .. id,
    width = width, height = 20, previewAncestor = operation == "move" and 2 or 0,
  }, children)
end

local function tile(id, width)
  local info = Grid.cards[id]
  return ui.column({ flexGrow = 1, padding = 3, fill = "surface_container_high", radius = 6, border = "outline_variant", borderWidth = 1 }, {
    ui.row({ gap = 4, align = "center" }, {
      drag(id, "move", { ui.glyph({ name = "menu-2", size = 14, color = "primary" }) }, 22),
      ui.label({ text = info.title, fontSize = width >= 104 and 12 or 10, maxLines = 1, flexGrow = 1, color = "on_surface" }),
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.row({ justify = "end" }, {
      drag(id, "resize", { ui.glyph({ name = "arrows-maximize", size = 13, color = "on_surface_variant" }) }, 22),
    }),
  })
end

local function canvas()
  local nodes = {}
  local stepX = previewW / Grid.cols
  local stepY = previewH / Grid.rows
  for y = 0, Grid.rows - 1 do
    local targets = {}
    for x = 0, Grid.cols - 1 do
      local value = x .. ":" .. y
      table.insert(targets, ui.dropZone({
        key = "cell-" .. value, accepts = { DRAG_TYPE }, value = value, onDrop = "dropCard",
        width = stepX, height = stepY,
      }, { ui.box({ width = 1, height = 1, fill = "outline_variant" }) }))
    end
    table.insert(nodes, ui.row({ height = stepY }, targets))
  end
  for _, id in ipairs(Grid.ids) do
    if draft[id] ~= nil then
      local x, y, w, h = Grid.pixels(draft[id], previewW, previewH, 0)
      local offset = #nodes - Grid.rows
      table.insert(nodes, Grid.place(id, x, y - previewH - offset, w - 4, h - 4, tile(id, w - 4)))
    end
  end
  return ui.column({ key = "preview", width = previewW, height = previewH, clip = true, fill = "surface_container", radius = 8 }, nodes)
end

function render()
  local parked = {
    ui.label({ text = "Launcher", fontSize = 12, color = "on_surface_variant" }),
  }
  for _, id in ipairs(Grid.ids) do
    if draft[id] == nil then
      local info = Grid.cards[id]
      table.insert(parked, drag(id, "move", {
        ui.row({ gap = 4, align = "center" }, {
          ui.glyph({ name = info.icon, size = 14 }),
          ui.label({ text = info.title, fontSize = 12, maxLines = 1 }),
        }),
      }))
    end
  end
  local tray = ui.dropZone({
    key = "park", accepts = { DRAG_TYPE }, value = "park", onDrop = "dropCard", direction = "row",
    gap = 8, paddingH = 8, height = 34, align = "center",
  }, parked)
  panel.render(ui.column({ padding = 14, gap = 8, justify = "start" }, {
    ui.label({ text = "Edit dashboard · " .. context.monitor, fontSize = 18, fontWeight = "bold", color = "on_surface" }),
    ui.label({
      text = feedback or "Drag the top handle to move and the bottom corner to resize. Drop cards in the launcher to park them.",
      fontSize = 12, maxLines = 2, color = feedback and "error" or "on_surface_variant",
    }),
    canvas(),
    tray,
    ui.row({ gap = 6, align = "center" }, {
      ui.button({ text = "Reset", variant = "ghost", controlSize = "sm", onClick = function()
        draft = Grid.reflow(Grid.defaults(), context.width, context.height)
        feedback = nil
        render()
      end }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({ text = "Cancel", variant = "ghost", controlSize = "sm", onClick = function() panel.close() end }),
      ui.button({ text = "Use as default", variant = "outline", controlSize = "sm", onClick = function() save(true) end }),
      ui.button({ text = "Done", variant = "primary", controlSize = "sm", onClick = function() save(false) end }),
    }),
  }))
end

function onOpen()
  context = noctalia.state.get("grid_editor_context")
  if context == nil then
    for _, output in ipairs(noctalia.outputs()) do
      if output.focused then
        local scale = output.scale or 1
        context = { monitor = output.name, width = math.floor(output.width / scale * 0.85), height = math.floor(output.height / scale * 0.65) }
        break
      end
    end
  end
  context = context or { monitor = "default", width = 1000, height = 550 }
  model = Grid.load()
  local current = context.placed or model.monitors[context.monitor] or model.default or Grid.defaults()
  draft = Grid.reflow(current, context.width, context.height)
  previewW = math.min(744, math.max(312, math.floor(context.width / Grid.cols) * Grid.cols))
  previewH = 336
  feedback = nil
  render()
end

function onClose()
  draft = nil
end

--!nonstrict
local Grid = require("./lib/grid.luau")

local DRAG_TYPE = "dashboard-grid-card"
local model, draft, context, feedback
local previewW, previewH
local dropRows, resizeRows
local resizing
local render

local function sizeAt(id, x, y)
  local current = draft[id]
  return { x = current.x, y = current.y, w = x + 1 - current.x, h = y + 1 - current.y }
end

local function sizeProblem(id, r)
  local mw, mh = Grid.minimum(id, context.width, context.height)
  if r.w < mw or r.h < mh then
    return "Below the card’s minimum size"
  end
  if not Grid.fits(draft, id, r) then
    return "Overlaps another card"
  end
  return nil
end

local function previewSize(x, y)
  if resizing == nil then
    return
  end
  local r = sizeAt(resizing.id, x, y)
  if r.w ~= resizing.rect.w or r.h ~= resizing.rect.h then
    resizing.rect = r
    resizing.problem = sizeProblem(resizing.id, r)
    render()
  end
end

local function finishResize()
  if resizing ~= nil and resizing.problem == nil then
    draft[resizing.id] = resizing.rect
    resizing = nil
    render()
  end
end

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
  if operation == "move" then
    local nextLayout = Grid.move(draft, id, x, y, context.width, context.height)
    if nextLayout ~= nil then
      draft = nextLayout
      feedback = nil
    else
      feedback = "No room here. Try a different card or make space in the launcher."
    end
  elseif operation == "resize" and draft[id] ~= nil then
    local r = sizeAt(id, x, y)
    feedback = sizeProblem(id, r)
    if feedback == nil then
      draft[id] = r
    end
  end
  render()
end

local function drag(id, operation, children, width)
  return ui.dragSource({
    key = operation .. "-" .. id, dragType = DRAG_TYPE, payload = operation .. ":" .. id,
    width = width, height = 20, previewAncestor = operation == "move" and 2 or 0,
    tooltip = operation == "resize" and "Click to preview a new size, or drag the corner" or nil,
    onClick = operation == "resize" and function()
      feedback = nil
      resizing = { id = id, rect = draft[id] }
      render()
    end or nil,
  }, children)
end

local function tile(id, width)
  local info = Grid.cards[id]
  return ui.column({
    flexGrow = 1, padding = 3, fill = "surface_container_high", radius = 6, border = "outline_variant", borderWidth = 1,
    opacity = resizing ~= nil and resizing.id == id and 0.45 or 1,
  }, {
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

local function cells()
  local drops, hoverCells = {}, {}
  local stepX = previewW / Grid.cols
  local stepY = previewH / Grid.rows
  for y = 0, Grid.rows - 1 do
    local targets, handles = {}, {}
    for x = 0, Grid.cols - 1 do
      local value = x .. ":" .. y
      table.insert(targets, ui.dropZone({
        key = "cell-" .. value, accepts = { DRAG_TYPE }, value = value, onDrop = "dropCard",
        width = stepX, height = stepY,
      }, { ui.box({ width = 1, height = 1, fill = "outline_variant" }) }))
      table.insert(handles, ui.box({
        key = "resize-cell-" .. value, width = stepX, height = stepY,
        onHover = function(entered)
          if entered == "true" then
            previewSize(x, y)
          end
        end,
        onClick = function()
          previewSize(x, y)
          finishResize()
        end,
      }))
    end
    table.insert(drops, ui.row({ height = stepY }, targets))
    table.insert(hoverCells, ui.row({ height = stepY }, handles))
  end
  return drops, hoverCells
end

local function canvas()
  local nodes = resizing == nil and table.clone(dropRows) or { ui.box({ height = previewH, width = 1, fill = "surface/0" }) }
  local backgroundRows = #nodes
  for _, id in ipairs(Grid.ids) do
    if draft[id] ~= nil then
      local x, y, w, h = Grid.pixels(draft[id], previewW, previewH, 0)
      local offset = #nodes - Grid.rows
      table.insert(nodes, Grid.place(id, x, y - previewH - offset, w - 4, h - 4, tile(id, w - 4)))
    end
  end
  if resizing ~= nil then
    local r = resizing.rect
    local x, y, w, h = Grid.pixels(r, previewW, previewH, 0)
    local offset = #nodes - backgroundRows
    local color = resizing.problem == nil and "primary" or "error"
    if w > 4 and h > 4 then
      table.insert(nodes, Grid.place("resize-outline", x, y - previewH - offset, w - 4, h - 4,
        ui.column({ flexGrow = 1, radius = 6, border = color, borderWidth = 2, fill = color .. "/0.20" }, {})))
      offset = offset + 1
    end
    table.insert(nodes, Grid.place("resize-input", 0, -previewH - offset, previewW, previewH,
      ui.column({ flexGrow = 1 }, resizeRows)))
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
  local text = feedback or "Drag a card to move it. Click a bottom corner to preview a resize."
  local invalid = feedback ~= nil
  if resizing ~= nil then
    local _, _, width, height = Grid.pixels(resizing.rect, context.width, context.height, Grid.gap)
    text = string.format("Resize %s · %d × %d px · %s", Grid.cards[resizing.id].title, math.max(0, width), math.max(0, height),
      resizing.problem or "Click the grid to apply")
    invalid = resizing.problem ~= nil
  end
  local actions = {
    ui.button({ text = "Reset", variant = "ghost", controlSize = "sm", onClick = function()
      draft = Grid.reflow(Grid.defaults(), context.width, context.height)
      feedback = nil
      render()
    end }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({ text = "Cancel", variant = "ghost", controlSize = "sm", onClick = function() panel.close() end }),
    ui.button({ text = "Use as default", variant = "outline", controlSize = "sm", onClick = function() save(true) end }),
    ui.button({ text = "Done", variant = "primary", controlSize = "sm", onClick = function() save(false) end }),
  }
  if resizing ~= nil then
    actions = {
      ui.spacer({ flexGrow = 1 }),
      ui.button({ text = "Cancel resize", variant = "ghost", controlSize = "sm", onClick = function()
        resizing = nil
        render()
      end }),
      ui.button({ text = "Apply size", variant = "primary", controlSize = "sm", enabled = not invalid, onClick = finishResize }),
    }
  end
  panel.render(ui.column({ padding = 14, gap = 8, justify = "start" }, {
    ui.label({ text = "Edit dashboard · " .. context.monitor, fontSize = 18, fontWeight = "bold", color = "on_surface" }),
    ui.label({ text = text, fontSize = 12, maxLines = 1, color = invalid and "error" or "on_surface_variant" }),
    canvas(),
    tray,
    ui.row({ gap = 6, align = "center" }, actions),
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
  resizing = nil
  dropRows, resizeRows = cells()
  render()
end

function onClose()
  draft = nil
  resizing = nil
end

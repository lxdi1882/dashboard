--!nonstrict
local Layout = require("./lib/layout.luau")

local DRAG_TYPE = "dashboard-card"
local CARD_NAMES = { github = "GitHub", calendar = "Calendar", screen = "Screen Time", todo = "To-do", system = "System" }
local draft
local usesDefault
local saveFailed
local render

local function compactGraph()
  return noctalia.getConfig("graph_size") == "compact"
end

local function zone(side, before, empty)
  local target = side .. ":" .. (before or "")
  local props = {
    key = "drop-" .. target,
    accepts = { DRAG_TYPE },
    value = target,
    onDrop = "moveCard",
    height = empty and 48 or 4,
    expandOnDrag = not empty,
    hitSlop = empty and 0 or 12,
  }
  if empty then
    return ui.dropZone(props, {
      ui.label({ text = "Drop a card here", fontSize = 12, color = "on_surface_variant" }),
    })
  end
  return ui.dropZone(props)
end

local function column(side, title)
  local rows = {
    ui.label({ text = title, fontWeight = "bold", fontSize = 14, color = "on_surface" }),
  }
  for _, id in ipairs(draft[side]) do
    table.insert(rows, zone(side, id))
    local hidden = draft.hidden[id] == true
    table.insert(rows, ui.row({ key = "card-" .. id, paddingH = 6, gap = 6, align = "center", radius = 8, fill = "surface_container_high" }, {
      ui.dragSource({
        key = "drag-" .. id, dragType = DRAG_TYPE, payload = id,
        previewAncestor = 1, liftFromLayout = true, width = 24, height = 26,
      }, { ui.glyph({ name = "menu-2", size = 15, color = "primary" }) }),
      ui.label({ text = CARD_NAMES[id], maxLines = 1, flexGrow = 1, color = hidden and "on_surface_variant" or "on_surface" }),
      ui.button({
        key = "hide-" .. id, text = hidden and "Show" or "Hide", variant = "ghost", controlSize = "sm",
        onClick = function()
          draft.hidden[id] = not hidden or nil
          usesDefault = false
          saveFailed = false
          render()
        end,
      }),
    }))
  end
  table.insert(rows, zone(side, nil, #draft[side] == 0))
  return ui.column({ key = side, flexGrow = 1, gap = 3, padding = 10, radius = 12, fill = "surface_container" }, rows)
end

function moveCard(id, target)
  if draft == nil or CARD_NAMES[id] == nil then
    return
  end
  local side, before = string.match(target, "^(%a+):(.*)$")
  if (side ~= "left" and side ~= "right") or id == before then
    return
  end
  local destination = draft[side]
  local insertAt = #destination + 1
  if before ~= "" then
    for i, cardId in ipairs(destination) do
      if cardId == before then
        insertAt = i
        break
      end
    end
    if insertAt > #destination then
      return
    end
  end
  for _, source in ipairs({ draft.left, draft.right }) do
    for i, cardId in ipairs(source) do
      if cardId == id then
        if source == destination and i < insertAt then
          insertAt = insertAt - 1
        end
        if source ~= destination or i ~= insertAt then
          table.remove(source, i)
          table.insert(destination, insertAt, id)
          usesDefault = false
          saveFailed = false
          render()
        end
        return
      end
    end
  end
end

function render()
  if draft == nil then
    return
  end
  local rows = {
    ui.label({ text = "Arrange dashboard cards", fontSize = 19, fontWeight = "bold", color = "on_surface" }),
    ui.label({ text = "Drag the handle to reorder a card or move it across columns.", fontSize = 12, color = "on_surface_variant" }),
    ui.row({ gap = 12, flexGrow = 1 }, { column("left", "Left column"), column("right", "Right column") }),
  }
  if saveFailed then
    table.insert(rows, ui.label({ text = "Could not save the layout. Try again or cancel.", color = "error", fontSize = 12 }))
  end
  table.insert(rows, ui.row({ gap = 8, align = "center" }, {
    ui.button({
      key = "reset-layout", text = "Reset to default", variant = "ghost", controlSize = "sm",
      onClick = function()
        draft = Layout.defaults(compactGraph())
        usesDefault = true
        saveFailed = false
        render()
      end,
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({ key = "cancel-layout", text = "Cancel", variant = "ghost", controlSize = "sm", onClick = function() panel.close() end }),
    ui.button({
      key = "save-layout", text = "Save", variant = "primary", controlSize = "sm",
      onClick = function()
        local layout = not usesDefault and draft or nil
        if Layout.save(layout) then
          noctalia.state.set("layout_saved", noctalia.nowMs())
          panel.close()
        else
          saveFailed = true
          render()
        end
      end,
    }),
  }))
  panel.render(ui.column({ gap = 12, padding = 16, flexGrow = 1 }, rows))
end

function onOpen()
  local compact = compactGraph()
  local layout = Layout.load(compact)
  usesDefault = layout == nil
  draft = layout or Layout.defaults(compact)
  saveFailed = false
  render()
end

function onClose()
  draft = nil
end

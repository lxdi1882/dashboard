--!nonstrict
local Notes = {}

local dataDir = noctalia.pluginDataDir()
local stickyLoaded = false
local sticky = ""
local stickyError = nil
local draftError = nil
local drafts
local folder = ""
local page = 0
local hasNextPage = false
local entries = nil
local folderError = nil
local folderRequest = 0
local selection = nil
local saved = nil
local noteError = nil
local noteRequest = 0
local editorRevision = 0
local vaultRoot = nil
local showEditor = true
local saving = false
local status = nil

local function message(text)
  return ui.label({ text = text, fontSize = 12, color = "on_surface_variant", maxLines = 3 })
end

local function surface(props, children)
  props.fill = "surface_container"
  props.radius = 16
  props.clip = true
  return ui.column(props, children)
end

local function persist(name, text)
  if dataDir == nil or not noctalia.mkdirAll(dataDir) then return false end
  local path = dataDir .. "/" .. name
  local temp = path .. ".tmp"
  return noctalia.writeFile(temp, text) and noctalia.renameFile(temp, path)
end

local function stickyInput()
  if not stickyLoaded then
    stickyLoaded = true
    sticky = dataDir and noctalia.readFile(dataDir .. "/sticky-note.md") or ""
  end
  return ui.input({
    key = "dashboard-sticky-editor", value = sticky, multiline = true, flexGrow = 1,
    frameVisible = false, placeholder = "Write a quick note…", fontSize = 13,
    onChange = function(value)
      sticky = value
      stickyError = not persist("sticky-note.md", value) and "Sticky note could not be saved." or nil
    end,
  })
end

function Notes.card(title)
  local rows = {
    title,
    surface({ flexGrow = 1, paddingH = 4 }, { stickyInput() }),
  }
  if stickyError then table.insert(rows, message(stickyError)) end
  return surface({ flexGrow = 1, padding = 10, gap = 5 }, rows)
end

local function loadDrafts(root)
  local raw = dataDir and noctalia.readFile(dataDir .. "/vault-drafts.json")
  local value = raw and noctalia.json.decode(raw)
  if type(value) == "table" and value.root == root and type(value.notes) == "table" then
    return value.notes
  end
  return {}
end

local function persistDrafts()
  local encoded = noctalia.json.encode({ root = vaultRoot, notes = drafts })
  draftError = (encoded == nil or not persist("vault-drafts.json", encoded))
    and "Draft could not be saved locally." or nil
end

local function vaultCommand(operation, path, extra, callback)
  local plugin = noctalia.pluginDir()
  if plugin == nil or not noctalia.commandExists("python3") then
    callback({ error = "Browsing the vault needs Python 3." })
    return
  end
  local args = { "python3", plugin .. "/vaultnotes.py", operation, vaultRoot, path }
  for _, value in ipairs(extra or {}) do table.insert(args, value) end
  local started = noctalia.runAsync(args, function(result)
    local data = result.exitCode == 0 and not result.stdoutTruncated and noctalia.json.decode(result.stdout) or nil
    callback(type(data) == "table" and data or { error = "The vault operation could not finish." })
  end)
  if not started then callback({ error = "Could not start the vault helper." }) end
end

local function loadFolder(path, targetPage)
  folder = path
  page = targetPage or 0
  hasNextPage = false
  entries = nil
  folderError = nil
  folderRequest = folderRequest + 1
  local request = folderRequest
  vaultCommand("list", path, { tostring(page) }, function(data)
    if request ~= folderRequest then return end
    entries = data.ok and data.entries or {}
    hasNextPage = data.more == true
    folderError = data.error
    update()
  end)
end

local function readNote(path)
  selection = path
  saved = nil
  noteError = nil
  status = nil
  showEditor = true
  noteRequest = noteRequest + 1
  local request = noteRequest
  vaultCommand("read", path, nil, function(data)
    if request ~= noteRequest then return end
    saved = data.ok and data or nil
    noteError = data.error
    editorRevision = editorRevision + 1
    update()
  end)
end

local function saveNote(path)
  if saving or saved == nil then return end
  local draft = drafts[path]
  if draft == nil or draft.revision ~= saved.revision then return end
  if dataDir == nil or not noctalia.mkdirAll(dataDir) then
    status = "Could not prepare the vault save."
    update()
    return
  end
  local temp = dataDir .. "/vault-save-input"
  if not noctalia.writeFile(temp, draft.text) then
    status = "Could not prepare the vault save."
    update()
    return
  end
  local root = vaultRoot
  saving = true
  status = nil
  vaultCommand("save", path, { draft.revision, temp }, function(data)
    noctalia.removeFile(temp)
    saving = false
    if vaultRoot ~= root then
      update()
      return
    end
    if data.ok then
      local latest = drafts[path]
      if latest == draft then
        drafts[path] = nil
      elseif latest ~= nil then
        latest.revision = data.revision
      end
      persistDrafts()
      if selection == path then
        noteRequest = noteRequest + 1
        saved = { text = draft.text, revision = data.revision }
        status = "Saved to vault"
      end
    elseif selection == path then
      if data.conflict then
        readNote(path)
      else
        status = data.error or "Could not save the note."
      end
    end
    update()
  end)
  update()
end

local function openSticky()
  noteRequest = noteRequest + 1
  selection = nil
  showEditor = true
  update()
end

local function prepareVault()
  local setting = noctalia.getConfig("vault_path") or ""
  local root = setting == "" and "" or noctalia.expandPath(setting)
  if vaultRoot == root then return end
  vaultRoot = root
  noteRequest = noteRequest + 1
  drafts = loadDrafts(root)
  selection = nil
  folder = ""
  showEditor = true
  if root ~= "" then
    loadFolder("")
  else
    entries = {}
    folderError = "Set an Obsidian vault folder in Dashboard settings."
  end
end

local function browseRow(key, icon, label, selected, click)
  return ui.row({
    key = key, height = 32, paddingH = 8, gap = 8, align = "center", radius = 8,
    fill = selected and "primary_container" or "surface_container_high/0.55",
    onClick = click,
  }, {
    ui.glyph({ name = icon, size = 16, color = selected and "on_primary_container" or "primary" }),
    ui.label({
      text = label, fontSize = 12, flexGrow = 1, maxLines = 1,
      color = selected and "on_primary_container" or "on_surface",
    }),
  })
end

local function browser()
  local directory = folder ~= "" and string.match(folder, "([^/]+)$") or "Obsidian vault"
  local heading = {
    ui.label({ text = directory, fontSize = 13, fontWeight = "bold", maxLines = 1, flexGrow = 1, color = "on_surface" }),
  }
  if folder ~= "" then
    table.insert(heading, ui.button({
      key = "vault-parent", glyph = "arrow-up", variant = "ghost", controlSize = "sm", tooltip = "Parent folder",
      onClick = function()
        loadFolder(string.match(folder, "^(.*)/[^/]+$") or "")
        update()
      end,
    }))
  end
  if vaultRoot ~= "" then
    table.insert(heading, ui.button({
      key = "vault-refresh", glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = "Reload folder",
      onClick = function()
        loadFolder(folder, page)
        update()
      end,
    }))
  end
  local children = {}
  if folderError ~= nil then
    table.insert(children, message(folderError))
  elseif entries == nil then
    table.insert(children, message("Opening folder…"))
  elseif #entries == 0 then
    table.insert(children, message("No folders or Markdown notes here."))
  else
    for _, entry in ipairs(entries) do
      local path = folder == "" and entry.name or (folder .. "/" .. entry.name)
      local folderEntry = entry.kind == "folder"
      local label = folderEntry and entry.name or string.gsub(entry.name, "%.[mM][dD]$", "")
      if drafts[path] ~= nil then label = label .. " · Draft" end
      table.insert(children, browseRow("vault-" .. path, folderEntry and "folder" or "file-text", label, selection == path,
        function()
          if folderEntry then loadFolder(path) else readNote(path) end
          update()
        end))
    end
  end
  local rows = {
    browseRow("notes-select-sticky", "note", "Sticky note", selection == nil, openSticky),
    ui.separator({ thickness = 1, color = "outline_variant" }),
    ui.row({ height = 32, gap = 4, align = "center" }, heading),
    ui.scroll({ key = "vault-folder-" .. folder .. "-" .. page, flexGrow = 1, gap = 4 }, children),
  }
  if page > 0 or hasNextPage then
    local function pageButton(delta, label, enabled)
      return ui.button({
        key = "vault-page-" .. label, text = label, controlSize = "sm", variant = "ghost", enabled = enabled,
        onClick = function()
          if enabled then
            loadFolder(folder, page + delta)
            update()
          end
        end,
      })
    end
    table.insert(rows, ui.row({ gap = 6, height = 32, justify = "space_between" }, {
      pageButton(-1, "Previous", page > 0),
      pageButton(1, "Next", hasNextPage),
    }))
  end
  return rows
end

local function editor()
  if selection == nil then
    local children = {
      ui.label({ text = "Sticky note", fontSize = 15, fontWeight = "bold", color = "on_surface" }),
      stickyInput(),
      message(stickyError or "Saved as you type"),
    }
    return children
  end

  local path = selection
  local title = string.match(path, "([^/]+)$") or path
  local draft = drafts[path]
  local conflict = draft ~= nil and saved ~= nil and saved.revision ~= draft.revision
  local controls = {
    ui.label({ text = title, flexGrow = 1, fontSize = 15, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
  }
  if conflict or (noteError ~= nil and draft ~= nil) then
    table.insert(controls, ui.button({
      key = "vault-copy-draft", text = "Copy draft", variant = "ghost", controlSize = "sm",
      onClick = function()
        local current = drafts[path]
        if current then
          noctalia.copyToClipboard(current.text)
          status = "Draft copied"
          update()
        end
      end,
    }))
    table.insert(controls, ui.button({
      key = "vault-discard-draft", text = "Discard draft", variant = "ghost", controlSize = "sm",
      onClick = function()
        drafts[path] = nil
        persistDrafts()
        readNote(path)
        update()
      end,
    }))
  elseif saved ~= nil then
    table.insert(controls, ui.button({
      key = "vault-save", text = saving and "Saving…" or "Save", variant = "primary", controlSize = "sm",
      enabled = draft ~= nil and not saving, onClick = function() saveNote(path) end,
    }))
  end
  local children = { ui.row({ gap = 6, height = 32, align = "center" }, controls) }
  if saved ~= nil or draft ~= nil then
    local base = draft and draft.revision or saved.revision
    table.insert(children, ui.input({
      key = "vault-editor-" .. path .. "-" .. editorRevision, value = draft and draft.text or saved.text,
      multiline = true, flexGrow = 1, fontSize = 13, placeholder = "Write Markdown…",
      onChange = function(value)
        if selection ~= path then return end
        local previous = drafts[path]
        if saved ~= nil and value == saved.text and not saving then
          drafts[path] = nil
        else
          drafts[path] = { revision = previous and previous.revision or (saved and saved.revision) or base, text = value }
        end
        status = nil
        persistDrafts()
      end,
      onSubmit = function() saveNote(path) end,
    }))
  end
  local feedback = draftError or status or noteError
    or (conflict and "This file changed on disk. Your draft is still here.")
    or (saved == nil and "Opening note…")
    or (draft ~= nil and "Draft saved locally · Save to update the vault file")
    or "Markdown · Ctrl+Enter to save"
  table.insert(children, message(feedback))
  return children
end

function Notes.details(width, title)
  prepareVault()
  local wide = width >= 770
  local body
  if wide then
    local sidebarWidth = math.clamp(math.floor(width * 0.26), 200, 310)
    body = ui.row({ key = "notes-workspace-wide", flexGrow = 1, gap = 10 }, {
      surface({ width = sidebarWidth, padding = 10, gap = 6 }, browser()),
      surface({ width = width - sidebarWidth - 10, padding = 12, gap = 8 }, editor()),
    })
  else
    local back = ui.button({
      key = "notes-browse", text = showEditor and "Browse vault" or "Editor",
      glyph = showEditor and "folder" or "arrow-left", variant = "ghost", controlSize = "sm",
      onClick = function() showEditor = not showEditor; update() end,
    })
    local children = { back }
    for _, child in ipairs(showEditor and editor() or browser()) do table.insert(children, child) end
    body = surface({ key = "notes-workspace-compact", flexGrow = 1, padding = 10, gap = 6 }, children)
  end
  return ui.column({ flexGrow = 1, gap = 8 }, { title, body })
end

return Notes

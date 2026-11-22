--!nonstrict
local Notes = {}

local dataDir = noctalia.pluginDataDir()
local stickyLoaded = false
local sticky = ""
local stickyError = nil
local stickyModified = nil
local reading = true
local previewState = nil
local previewSerial = 0
local viewingAttachment = false
local asset = nil
local createKind = nil
local createName = ""
local createError = nil
local createRevision = 0
local creating = false
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
    local info = dataDir and noctalia.fileInfo(dataDir .. "/sticky-note.md")
    stickyModified = info and info.mtime or nil
  end
  return ui.input({
    key = "dashboard-sticky-editor", value = sticky, multiline = true, flexGrow = 1,
    frameVisible = false, placeholder = "Write a quick note…", fontSize = 13,
    onChange = function(value)
      sticky = value
      stickyError = not persist("sticky-note.md", value) and "Sticky note could not be saved." or nil
      if stickyError == nil then stickyModified = os.time() end
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

local function readNote(path, edit)
  viewingAttachment = false
  reading = not edit
  previewState = nil
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

local function readAttachment(path)
  selection = path
  viewingAttachment = true
  showEditor = true
  asset = nil
  noteError = nil
  noteRequest = noteRequest + 1
  local request = noteRequest
  vaultCommand("attachment", path, nil, function(data)
    if request ~= noteRequest then return end
    asset = data.ok and data.attachment or nil
    noteError = data.error
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
        saved = { text = draft.text, revision = data.revision, modified = data.modified }
        status = "Saved to vault"
      end
    elseif selection == path then
      if data.conflict then
        readNote(path, true)
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

local function startCreation(kind)
  createKind = kind
  createName = ""
  createError = nil
  createRevision = createRevision + 1
  update()
end

local function finishCreation(value)
  if createKind == nil or creating then return end
  local kind = createKind
  local path, root = folder, vaultRoot
  local name = value or createName
  name = string.match(name, "^%s*(.-)%s*$")
  if name == "" then
    createError = "Enter a name."
    update()
    return
  end
  creating = true
  vaultCommand("new-" .. kind, path, { name }, function(data)
    creating = false
    if root ~= vaultRoot then return end
    if not data.ok then
      createError = data.error or "Could not create the item."
    else
      createKind = nil
      createError = nil
      if folder == path then
        if kind == "folder" then
          loadFolder(data.relative)
        else
          loadFolder(path, page)
          readNote(data.relative, true)
        end
      end
    end
    update()
  end)
  update()
end

local function creationForm()
  local function kindButton(kind, label)
    return ui.button({
      key = "vault-new-" .. kind, text = label, controlSize = "sm",
      variant = createKind == kind and "primary" or "ghost", enabled = not creating,
      onClick = function() startCreation(kind) end,
    })
  end
  local children = {
    ui.row({ gap = 4 }, { kindButton("note", "Note"), kindButton("folder", "Folder") }),
    ui.row({ gap = 4 }, {
      ui.input({
        key = "vault-create-name-" .. createRevision, value = createName, height = 32, flexGrow = 1,
        placeholder = createKind == "folder" and "Folder name" or "Note title",
        focus = true, onChange = function(value) createName = value end, onSubmit = finishCreation,
      }),
      ui.button({
        key = "vault-create-submit", glyph = "check", height = 32, variant = "primary",
        tooltip = "Create in this folder", enabled = not creating, onClick = function() finishCreation() end,
      }),
    }),
  }
  if createError then table.insert(children, message(createError)) end
  return ui.column({ gap = 5 }, children)
end

local function openVaultSettings()
  if noctalia.runAsync({ "noctalia", "msg", "settings-open-plugin", "lat/dashboard" }) then
    noctalia.state.set("close_req", noctalia.nowMs())
  else
    noctalia.notifyError("Notes", "Could not open Dashboard settings.")
  end
end

function Notes.tools()
  return ui.row({ gap = 3 }, {
    ui.button({
      key = "notes-clipboard", glyph = "clipboard", variant = "ghost", controlSize = "sm",
      tooltip = "Clipboard history",
      onClick = function() noctalia.runAsync({ "noctalia", "msg", "panel-toggle", "clipboard" }) end,
    }),
    ui.button({
      key = "notes-settings", glyph = "settings", variant = "ghost", controlSize = "sm",
      tooltip = "Vault settings", onClick = openVaultSettings,
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
  if vaultRoot ~= "" and folderError == nil then
    table.insert(heading, ui.button({
      key = "vault-create", glyph = createKind and "x" or "plus", variant = "ghost", controlSize = "sm",
      tooltip = createKind and "Cancel creation" or "Create a note or folder",
      enabled = not creating, onClick = function()
        if createKind then
          createKind = nil
          update()
        else
          startCreation("note")
        end
      end,
    }))
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
    table.insert(children, ui.button({
      key = "vault-setup", text = "Set vault folder", variant = "primary", controlSize = "sm",
      onClick = openVaultSettings,
    }))
  elseif entries == nil then
    table.insert(children, message("Opening folder…"))
  elseif #entries == 0 then
    table.insert(children, message("This folder is empty."))
  else
    for _, entry in ipairs(entries) do
      local path = folder == "" and entry.name or (folder .. "/" .. entry.name)
      local folderEntry = entry.kind == "folder"
      local label = folderEntry and entry.name or string.gsub(entry.name, "%.[mM][dD]$", "")
      if drafts[path] ~= nil then label = label .. " · Draft" end
      local glyph = folderEntry and "folder" or (entry.kind == "attachment" and "paperclip" or "file-text")
      table.insert(children, browseRow("vault-" .. path, glyph, label, selection == path, function()
        if folderEntry then
          createKind = nil
          loadFolder(path)
        elseif entry.kind == "attachment" then
          readAttachment(path)
        else
          readNote(path)
        end
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
  if createKind then table.insert(rows, 4, creationForm()) end
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

local function openAttachment(relative)
  vaultCommand("attachment", relative, nil, function(data)
    if data.ok then
      noctalia.runAsync({ "xdg-open", data.attachment.path })
    else
      noctalia.notifyError("Notes", data.error or "Could not open the attachment.")
    end
  end)
end

local function linkRow(block, index)
  local icon = block.kind == "note" and "file-text" or (block.kind == "url" and "external-link" or "paperclip")
  return browseRow("notes-preview-link-" .. index, icon, block.title, false, function()
    if block.kind == "note" then
      readNote(block.relative)
    elseif block.kind == "url" then
      noctalia.runAsync({ "xdg-open", block.url })
    else
      openAttachment(block.relative)
    end
  end)
end

local function previewImage(block, width)
  return ui.image({
    path = block.path, width = math.max(1, math.min(width - 24, 590)), height = width < 500 and 208 or 290,
    radius = 9, fit = "contain", tooltip = "Open " .. block.title,
    onClick = function() openAttachment(block.relative) end,
  })
end

local function loadPreview(path, text)
  if previewState and previewState.path == path and previewState.text == text then return previewState end
  local state = { path = path, text = text }
  previewState = state
  if dataDir == nil or not noctalia.mkdirAll(dataDir) then
    state.error = "Could not prepare this preview."
    return state
  end
  previewSerial = previewSerial + 1
  local temp = dataDir .. "/vault-preview-" .. noctalia.nowMs() .. "-" .. previewSerial .. ".md"
  if not noctalia.writeFile(temp, text) then
    state.error = "Could not prepare this preview."
    return state
  end
  vaultCommand("preview", path, { temp }, function(data)
    noctalia.removeFile(temp)
    if previewState ~= state then return end
    state.data = data.ok and data or nil
    state.error = data.error
    update()
  end)
  return state
end

local function renderPreview(path, text, width)
  local view = loadPreview(path, text)
  local rows = {}
  if view.data == nil then
    table.insert(rows, message(view.error or "Rendering preview…"))
  else
    for i, block in ipairs(view.data.blocks or {}) do
      if block.kind == "markdown" then
        table.insert(rows, ui.markdown({ key = "notes-markdown-" .. i, text = block.text, width = math.max(1, width - 32) }))
      elseif block.kind == "attachment" and block.image then
        table.insert(rows, previewImage(block, width))
      else
        table.insert(rows, linkRow(block, i))
      end
    end
    local links = view.data.links or {}
    if #links > 0 then
      table.insert(rows, ui.label({ text = "Links in this note", fontSize = 13, fontWeight = "bold", color = "on_surface" }))
      for i, block in ipairs(links) do table.insert(rows, linkRow(block, "related-" .. i)) end
    end
    if #rows == 0 then table.insert(rows, message("This note is empty. Choose Edit to start writing.")) end
  end
  return ui.scroll({ key = "vault-preview-" .. path, flexGrow = 1, gap = 8 }, rows)
end

local function datedTitle(title, modified, width)
  local kids = {
    ui.label({
      text = title, maxWidth = modified and math.max(100, math.floor(width * 0.55)) or nil,
      maxLines = 1, fontSize = 15, fontWeight = "bold", color = "on_surface",
    }),
  }
  if modified ~= nil then
    table.insert(kids, ui.label({
      key = "notes-modified", text = os.date("%b %d, %Y", modified),
      fontSize = 11, color = "on_surface_variant", maxLines = 1,
    }))
  end
  return ui.row({ height = 24, gap = 8, align = "center" }, kids)
end

local function editor(width)
  if selection == nil then
    local input = stickyInput()
    local children = {
      datedTitle("Sticky note", stickyModified, width),
      input,
      message(stickyError or "Saved as you type"),
    }
    return children
  end

  local path = selection
  local title = string.match(path, "([^/]+)$") or path
  if viewingAttachment then
    local children = { datedTitle(title, asset and asset.modified, width) }
    if asset then
      if asset.image then table.insert(children, previewImage(asset, width)) end
      table.insert(children, linkRow(asset, "open-attachment"))
    else
      table.insert(children, message(noteError or "Opening attachment…"))
    end
    return children
  end
  local draft = drafts[path]
  local conflict = draft ~= nil and saved ~= nil and saved.revision ~= draft.revision
  local controls = {}
  if saved ~= nil or draft ~= nil then
    table.insert(controls, ui.button({
      key = "vault-reading-toggle", text = reading and "Edit" or "Read",
      glyph = reading and "pencil" or "book", variant = "ghost", controlSize = "sm",
      onClick = function()
        reading = not reading
        editorRevision = editorRevision + 1
        update()
      end,
    }))
  end
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
  elseif saved ~= nil and not reading then
    table.insert(controls, ui.button({
      key = "vault-save", text = saving and "Saving…" or "Save", variant = "primary", controlSize = "sm",
      enabled = draft ~= nil and not saving, onClick = function() saveNote(path) end,
    }))
  end
  local children = { datedTitle(title, saved and saved.modified, width) }
  if #controls > 0 then table.insert(children, ui.row({ gap = 4, height = 32, align = "center" }, controls)) end
  if (saved ~= nil or draft ~= nil) and reading then
    table.insert(children, renderPreview(path, draft and draft.text or saved.text, width))
  elseif saved ~= nil or draft ~= nil then
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
    or (not reading and "Markdown · Ctrl+Enter to save")
  if feedback then table.insert(children, message(feedback)) end
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
      surface({ width = width - sidebarWidth - 10, padding = 12, gap = 6 }, editor(width - sidebarWidth - 10)),
    })
  else
    local back = ui.button({
      key = "notes-browse", text = showEditor and "Browse vault" or "Editor",
      glyph = showEditor and "folder" or "arrow-left", variant = "ghost", controlSize = "sm",
      onClick = function() showEditor = not showEditor; update() end,
    })
    local children = { back }
    for _, child in ipairs(showEditor and editor(width) or browser()) do table.insert(children, child) end
    body = surface({ key = "notes-workspace-compact", flexGrow = 1, padding = 10, gap = 6 }, children)
  end
  return ui.column({ flexGrow = 1, gap = 8 }, { title, body })
end

return Notes

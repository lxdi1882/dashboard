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
local search = { text = "", query = "", revision = 0 }
local drafts
local folder = ""
local page = 0
local hasNextPage = false
local entries = nil
local folderError = nil
local folderIdentity, folderDeleteTarget, folderDeleteFeedback
local folderRequest = 0
local selection = nil
local saved = nil
local noteError = nil
local noteRequest = 0
local editorRevision = 0
local vaultRoot = nil
local showEditor = true
local saving = false
local confirmDelete, deleting
local status = nil
local paneMotion = {}

function Notes.resetMotion()
  paneMotion = {}
end

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

local function stickyInput(height)
  if not stickyLoaded then
    stickyLoaded = true
    sticky = dataDir and noctalia.readFile(dataDir .. "/sticky-note.md") or ""
    local info = dataDir and noctalia.fileInfo(dataDir .. "/sticky-note.md")
    stickyModified = info and info.mtime or nil
  end
  return ui.input({
    key = "dashboard-sticky-editor", value = sticky, multiline = true,
    height = height, flexGrow = height and 0 or 1,
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
  folderIdentity, folderDeleteTarget, folderDeleteFeedback = nil, nil, nil
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
    folderIdentity = data.folder_id
    folderError = data.error
    update()
  end)
end

local function readNote(path, edit)
  confirmDelete = nil
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
  confirmDelete = nil
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
  if saving or deleting or confirmDelete or selection ~= path or saved == nil then return end
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
  confirmDelete = nil
  status = nil
  selection = nil
  showEditor = true
  update()
end

local function insideFolder(path, parent)
  return path ~= nil and string.sub(path, 1, #parent + 1) == parent .. "/"
end

local function deleteItem(path, folderId)
  if saving or deleting or creating then return end
  local isFolder = folderId ~= nil
  local root = vaultRoot
  local parent = string.match(path, "^(.*)/[^/]+$") or ""
  local function matches(item)
    return item == path or (isFolder and insideFolder(item, path))
  end
  deleting = path
  confirmDelete, folderDeleteTarget, folderDeleteFeedback = nil, nil, nil
  vaultCommand(isFolder and "delete-folder" or "delete", path, { folderId or saved.revision }, function(data)
    deleting = nil
    if root ~= vaultRoot then
      update()
      return
    end
    if data.ok then
      local changed = false
      for draftPath in pairs(drafts) do
        if matches(draftPath) then
          drafts[draftPath] = nil
          changed = true
        end
      end
      if changed then persistDrafts() end
      if matches(selection) then
        noteRequest = noteRequest + 1
        previewState = nil
        saved = nil
        selection = nil
        status = isFolder and "Folder moved to Trash" or "Note moved to Trash"
      end
      if isFolder and matches(folder) then
        createKind = nil
        loadFolder(parent)
        folderDeleteFeedback = "Folder moved to Trash"
      elseif folder == parent then
        loadFolder(folder, page)
      end
      if search.query ~= "" then
        search.results, search.error, search.more = nil, nil, false
        search.runAt = noctalia.nowMs()
      end
    elseif isFolder then
      if folder == path then
        if data.conflict then loadFolder(path, page) end
        folderDeleteFeedback = data.conflict and "This folder was replaced. Review it before deleting."
          or data.error or "Could not move this folder to Trash."
      end
    elseif selection == path then
      if data.conflict then
        readNote(path, not reading)
        status = "This note changed on disk. Review it before deleting."
      else
        status = data.error or "Could not move this note to Trash."
      end
    end
    update()
  end)
  update()
end

local function deleteNote(path)
  if confirmDelete == path and path == selection and saved ~= nil then
    deleteItem(path)
  end
end

local function prepareVault()
  local setting = noctalia.getConfig("vault_path") or ""
  local root = setting == "" and "" or noctalia.expandPath(setting)
  if vaultRoot == root then return end
  vaultRoot = root
  search = { text = "", query = "", revision = search.revision + 1 }
  noteRequest = noteRequest + 1
  drafts = loadDrafts(root)
  confirmDelete, folderIdentity, folderDeleteTarget, folderDeleteFeedback = nil, nil, nil, nil
  status = nil
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
  if createKind == nil or creating or deleting then return end
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

local function setSearch(value, submit)
  local state = search
  local wasEmpty = state.query == ""
  local hadResults = state.results ~= nil or state.error ~= nil
  state.text = value
  local query = string.match(value, "^%s*(.-)%s*$")
  if query ~= state.query then
    folderDeleteTarget = nil
    state.query = query
    state.results = nil
    state.error = nil
    state.more = false
    state.runAt = query ~= "" and (noctalia.nowMs() + 250) or nil
  end
  if submit and query ~= "" and state.activeQuery ~= query then state.runAt = 0 end
  if submit or hadResults or wasEmpty ~= (query == "") then update() end
end

local function runSearch()
  local state = search
  if state.busy or not state.runAt or noctalia.nowMs() < state.runAt then return end
  local query = state.query
  state.runAt = nil
  state.busy = true
  state.activeQuery = query
  vaultCommand("search", "", { query }, function(data)
    if state ~= search then return end
    state.busy = false
    state.activeQuery = nil
    if query == state.query and not state.runAt then
      state.results = data.ok and data.results or {}
      state.error = data.error
      state.more = data.more == true
    end
    update()
  end)
end

local function searchBar(width)
  local hasQuery = search.query ~= ""
  local children = {
    ui.input({
      key = "vault-search-" .. search.revision, value = search.text, height = 32,
      width = width - (hasQuery and 36 or 0),
      placeholder = "Search vault…",
      onChange = function(value) setSearch(value, false) end,
      onSubmit = function(value) setSearch(value, true) end,
    }),
  }
  if hasQuery then
    table.insert(children, ui.button({
      key = "vault-search-clear", glyph = "x", height = 32, width = 32,
      variant = "ghost", tooltip = "Clear vault search",
      onClick = function()
        search.revision = search.revision + 1
        setSearch("", true)
      end,
    }))
  end
  return ui.row({ width = width, height = 32, gap = 4, align = "center", clip = true }, children)
end

local function searchResults(width, height)
  runSearch()
  local rows = {}
  if search.error then
    table.insert(rows, message(search.error))
  elseif search.results == nil then
    table.insert(rows, message("Searching vault…"))
  elseif #search.results == 0 then
    table.insert(rows, message("No matches in this vault."))
  else
    for _, result in ipairs(search.results) do
      local path = result.relative
      local isNote = result.kind == "note"
      local parent = string.match(path, "^(.*)/[^/]+$") or "Vault"
      local selected = selection == path
      local resultWidth = math.max(1, width - 14)
      local textWidth = math.max(1, resultWidth - 35)
      local lines = {
        ui.label({ text = result.title, fontSize = 12, fontWeight = "bold", maxWidth = textWidth, maxLines = 1, color = selected and "on_primary_container" or "on_surface" }),
        ui.label({ text = parent, fontSize = 10, maxWidth = textWidth, maxLines = 1, color = "on_surface_variant" }),
      }
      if result.snippet ~= nil and result.snippet ~= "" then
        table.insert(lines, ui.label({ text = result.snippet, fontSize = 11, maxWidth = textWidth, maxLines = 1, color = "on_surface_variant" }))
      end
      table.insert(rows, ui.row({
        key = "vault-result-" .. path, width = resultWidth, height = #lines == 3 and 57 or 43, gap = 7,
        paddingH = 7, align = "center", radius = 8, clip = true,
        fill = selected and "primary_container" or "surface_container_high/0.55",
        onClick = function()
          if isNote then readNote(path) else readAttachment(path) end
          update()
        end,
      }, {
        ui.glyph({ name = isNote and "file-text" or "paperclip", size = 14, color = "primary" }),
        ui.column({ flexGrow = 1, gap = 1, justify = "center", clip = true }, lines),
      }))
    end
    if search.more then table.insert(rows, message("Refine your search for more results.")) end
  end
  return ui.scroll({ key = "vault-search-results-" .. search.query, width = width, height = math.max(1, height), gap = 4 }, rows)
end

local function browser(width, height)
  local rows = {
    browseRow("notes-select-sticky", "note", "Sticky note", selection == nil, openSticky),
    ui.separator({ thickness = 1, color = "outline_variant" }),
  }
  local remaining = height - 45
  if vaultRoot ~= "" then
    table.insert(rows, searchBar(width))
    remaining = remaining - 38
  end
  if search.query ~= "" then
    table.insert(rows, searchResults(width, remaining))
    return rows
  end

  local directory = folder ~= "" and string.match(folder, "([^/]+)$") or "Obsidian vault"
  if folderDeleteTarget ~= nil then
    local path, identity = folder, folderIdentity
    local warning = "Move this folder and everything in it to Trash?"
    for draftPath in pairs(drafts) do
      if insideFolder(draftPath, path) then
        warning = "Move this folder and everything in it to Trash? Unsaved edits inside will be discarded."
        break
      end
    end
    table.insert(rows, ui.column({ width = width, height = 28, align = "stretch" }, {
      ui.label({ text = directory, fontSize = 13, fontWeight = "bold", maxLines = 1 }),
    }))
    table.insert(rows, message(warning))
    table.insert(rows, ui.row({ height = 32, gap = 4, align = "center" }, {
      ui.button({
        key = "vault-folder-delete-confirm", text = "Move to Trash", variant = "destructive", controlSize = "sm",
        onClick = function()
          if folderDeleteTarget == path and folder == path and folderIdentity == identity then
            deleteItem(path, identity)
          end
        end,
      }),
      ui.button({
        key = "vault-folder-delete-cancel", text = "Cancel", variant = "ghost", controlSize = "sm",
        onClick = function() folderDeleteTarget = nil; update() end,
      }),
    }))
    return rows
  end
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
  if folder ~= "" and folderIdentity ~= nil then
    local path, identity = folder, folderIdentity
    table.insert(heading, ui.button({
      key = "vault-folder-delete", glyph = "trash", variant = "ghost", controlSize = "sm", tooltip = "Delete folder",
      enabled = not saving and not deleting and not creating,
      onClick = function()
        if folder ~= path or folderIdentity ~= identity or saving or deleting or creating then return end
        confirmDelete = nil
        folderDeleteTarget = path
        update()
      end,
    }))
  end
  if vaultRoot ~= "" and folderError == nil then
    table.insert(heading, ui.button({
      key = "vault-create", glyph = createKind and "x" or "plus", variant = "ghost", controlSize = "sm",
      tooltip = createKind and "Cancel creation" or "Create a note or folder",
      enabled = not creating and not deleting, onClick = function()
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
  table.insert(rows, ui.row({ height = 32, gap = 4, align = "center" }, heading))
  remaining = remaining - 38
  local feedback = deleting == folder and "Moving folder to Trash…" or folderDeleteFeedback
  if feedback ~= nil then
    table.insert(rows, ui.column({ height = 36 }, { message(feedback) }))
    remaining = remaining - 42
  end
  if createKind then
    table.insert(rows, creationForm())
    remaining = remaining - (createError and 106 or 75)
  end
  local pageControls = page > 0 or hasNextPage
  table.insert(rows, ui.scroll({
    key = "vault-folder-" .. folder .. "-" .. page,
    width = width, height = math.max(1, remaining - (pageControls and 38 or 0)), gap = 4,
  }, children))
  if pageControls then
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
    path = block.path, width = math.max(1, math.min(width - 16, 590)), height = width < 500 and 208 or 290,
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
        table.insert(rows, ui.markdown({ key = "notes-markdown-" .. i, text = block.text, width = math.max(1, width - 16) }))
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
      text = title, maxWidth = math.max(1, width - (modified and 108 or 0)),
      maxLines = 1, fontSize = 15, fontWeight = "bold", color = "on_surface",
    }),
  }
  if modified ~= nil then
    table.insert(kids, ui.label({
      key = "notes-modified", text = os.date("%b %d, %Y", modified),
      fontSize = 11, color = "on_surface_variant", maxLines = 1,
    }))
  end
  return ui.row({ width = width, height = 24, gap = 8, align = "center", clip = true }, kids)
end

local function editorFeedback(text)
  return ui.label({
    text = text or "", height = 28, fontSize = 11, color = "on_surface_variant", maxLines = 2,
  })
end

local function editor(width, height)
  if selection == nil then
    local input = stickyInput(math.max(1, height - 64))
    return { datedTitle("Sticky note", stickyModified, width), input, editorFeedback(draftError or status or stickyError or "Saved as you type") }
  end

  local path = selection
  local title = string.match(path, "([^/]+)$") or path
  if viewingAttachment then
    local rows = {}
    if asset then
      if asset.image then table.insert(rows, previewImage(asset, width)) end
      table.insert(rows, linkRow(asset, "open-attachment"))
    else
      table.insert(rows, message(noteError or "Opening attachment…"))
    end
    return {
      datedTitle(title, asset and asset.modified, width),
      ui.scroll({ key = "vault-attachment-" .. path, width = width, height = math.max(1, height - 30), gap = 8 }, rows),
    }
  end
  local draft = drafts[path]
  local conflict = draft ~= nil and saved ~= nil and saved.revision ~= draft.revision
  local controls = {}
  local confirming = confirmDelete == path
  local moving = deleting ~= nil and (deleting == path or insideFolder(path, deleting))
  if not confirming and (saved ~= nil or draft ~= nil) then
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
  if not confirming and not moving and (conflict or (noteError ~= nil and draft ~= nil)) then
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
  elseif not confirming and not moving and saved ~= nil and not reading then
    table.insert(controls, ui.button({
      key = "vault-save", text = saving and "Saving…" or "Save", variant = "primary", controlSize = "sm",
      enabled = draft ~= nil and not saving and not deleting, onClick = function() saveNote(path) end,
    }))
  end
  if confirming then
    table.insert(controls, ui.button({
      key = "vault-delete-confirm", text = "Move to Trash", glyph = "trash", variant = "destructive", controlSize = "sm",
      onClick = function() deleteNote(path) end,
    }))
    table.insert(controls, ui.button({
      key = "vault-delete-cancel", text = "Cancel", variant = "ghost", controlSize = "sm",
      onClick = function() confirmDelete = nil; update() end,
    }))
  elseif saved ~= nil and not moving then
    table.insert(controls, ui.spacer({ flexGrow = 1 }))
    table.insert(controls, ui.button({
      key = "vault-delete", glyph = "trash", tooltip = "Delete note", variant = "ghost", controlSize = "sm",
      enabled = not saving and not deleting and not creating,
      onClick = function()
        if selection ~= path or saving or deleting or creating then return end
        folderDeleteTarget = nil
        confirmDelete = path
        update()
      end,
    }))
  end
  local contentHeight = math.max(1, height - 102)
  local children = {
    datedTitle(title, saved and saved.modified, width),
    ui.row({ gap = 4, height = 32, align = "center" }, controls),
  }
  local content
  if (saved ~= nil or draft ~= nil) and reading then
    content = renderPreview(path, draft and draft.text or saved.text, width)
  elseif saved ~= nil or draft ~= nil then
    local base = draft and draft.revision or saved.revision
    content = ui.input({
      key = "vault-editor-" .. path .. "-" .. editorRevision, value = draft and draft.text or saved.text,
      multiline = true, flexGrow = 1, focus = true, enabled = not confirming and not moving,
      fontSize = 13, placeholder = "Write Markdown…",
      onChange = function(value)
        if selection ~= path or (deleting ~= nil and (deleting == path or insideFolder(path, deleting))) then return end
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
    })
  end
  -- Fill a bounded viewport so the native reader and editor receive an exact height.
  table.insert(children, ui.column({
    key = "vault-document-viewport", width = width, height = contentHeight, clip = true,
  }, content and { content } or {}))
  local feedback = (confirming and (draft and "Move this note to Trash? Unsaved edits will be discarded." or "Move this note to Trash?"))
    or (moving and "Moving note to Trash…")
    or draftError or status or noteError
    or (conflict and "This file changed on disk. Your draft is still here.")
    or (saved == nil and "Opening note…")
    or (draft ~= nil and "Draft saved locally · Save to update the vault file")
    or (not reading and "Markdown · Ctrl+Enter to save")
  table.insert(children, editorFeedback(feedback))
  return children
end

local function browserView()
  if folderDeleteTarget ~= nil then return "confirm-folder:" .. folder end
  if search.query ~= "" then return "search" end
  if entries ~= nil then return "folder:" .. page .. ":" .. folder end
end

local function editorView()
  if selection == nil then return "sticky" end
  if confirmDelete == selection then return "confirm-note:" .. selection end
  if viewingAttachment then
    if asset or noteError then return "attachment:" .. selection end
  elseif not reading then
    if saved or drafts[selection] or noteError then return "edit:" .. selection end
  elseif noteError or (previewState and (previewState.data or previewState.error)) then
    return "read:" .. selection
  end
end

local function animatePane(slot, view, width, height, children, progress)
  local state = paneMotion[slot]
  if not state then
    state = {}
    paneMotion[slot] = state
  end
  if view == nil then
    state.started = nil
  elseif state.view ~= view then
    state.started = state.view and noctalia.nowMs()
    state.view = view
  end
  return function()
    local remaining = state.started and progress and (1 - progress(noctalia.nowMs() - state.started)) or 0
    if remaining <= 0 then state.started = nil end
    return ui.column({ width = width, height = height, clip = true }, {
      ui.column({ key = "notes-pane-" .. slot, width = width, height = height, gap = 6,
        opacity = 1 - 0.26 * remaining, translateY = 5 * remaining,
      }, children),
    }), remaining > 0
  end
end

function Notes.details(width, height, title, progress)
  prepareVault()
  local wide = width >= 770
  local paneHeight = math.max(1, height - 40)
  local drawBody
  if wide then
    local sidebarWidth = math.clamp(math.floor(width * 0.26), 200, 310)
    local editorWidth = width - sidebarWidth - 10
    local sidebarRows = browser(sidebarWidth - 20, paneHeight - 20)
    local editorRows = editor(editorWidth - 24, paneHeight - 24)
    local drawBrowser = animatePane("browser", browserView(), sidebarWidth - 20, paneHeight - 20, sidebarRows, progress)
    local drawEditor = animatePane("editor", editorView(), editorWidth - 24, paneHeight - 24, editorRows, progress)
    drawBody = function()
      local sidebar, sidebarMoving = drawBrowser()
      local document, documentMoving = drawEditor()
      return ui.row({ key = "notes-workspace-wide", width = width, height = paneHeight, gap = 10, clip = true }, {
        surface({ width = sidebarWidth, height = paneHeight, padding = 10 }, { sidebar }),
        surface({ width = editorWidth, height = paneHeight, padding = 12 }, { document }),
      }), sidebarMoving or documentMoving
    end
  else
    local back = ui.button({
      key = "notes-browse", text = showEditor and "Browse vault" or "Editor",
      glyph = showEditor and "folder" or "arrow-left", variant = "ghost", controlSize = "sm",
      onClick = function()
        confirmDelete, folderDeleteTarget = nil, nil
        showEditor = not showEditor
        update()
      end,
    })
    local contentWidth, contentHeight = width - 20, math.max(1, paneHeight - 58)
    local rows = showEditor and editor(contentWidth, contentHeight) or browser(contentWidth, contentHeight)
    local view
    if showEditor then view = editorView() else view = browserView() end
    local drawPane = animatePane("compact", view, contentWidth, contentHeight, rows, progress)
    drawBody = function()
      local pane, moving = drawPane()
      return surface({
        key = "notes-workspace-compact", width = width, height = paneHeight, padding = 10, gap = 6,
      }, { back, pane }), moving
    end
  end
  local heading = ui.column({ height = 32 }, { title })
  local function draw()
    local body, moving = drawBody()
    return ui.column({ width = width, height = height, gap = 8, clip = true }, { heading, body }), moving
  end
  local tree, moving = draw()
  return tree, moving and draw or nil
end

return Notes

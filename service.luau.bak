--!nonstrict
-- lat/dashboard service: collects data for the dashboard layer and handles IPC.
--   noctalia msg plugin lat/dashboard:data all toggle   (also: show | hide | refresh)

noctalia.setUpdateInterval(5000)

local Todo = require("./lib/todo.luau")

local tick = 0
local lastGithub = 0
local visible = false
local closeAskedAt = 0
local DAY_MS = 86400000

------------------------------------------------------------------ helpers

local function stateHome()
  local h = noctalia.getenv("XDG_STATE_HOME")
  if h == nil or h == "" then
    h = noctalia.expandPath("~/.local/state")
  end
  return h
end

local function readJson(path, cb)
  local accepted = noctalia.readFileAsync(path, function(contents, err)
    if contents == nil then
      cb(nil)
      return
    end
    cb(noctalia.json.decode(contents))
  end)
  if not accepted then
    cb(nil)
  end
end

local function copyList(t)
  local c = {}
  for i, v in ipairs(t) do
    c[i] = v
  end
  return c
end

------------------------------------------------------------------ profile

local function refreshProfile()
  local user = noctalia.getenv("USER") or "you"
  local name = noctalia.getConfig("name_override")
  if name == nil or name == "" then
    name = user
  end
  local avatar = ""
  local candidates = {}
  local p = noctalia.getConfig("avatar_path")
  if p ~= nil and p ~= "" then
    table.insert(candidates, noctalia.expandPath(p))
  end
  table.insert(candidates, "/var/lib/AccountsService/icons/" .. user)
  for _, full in ipairs(candidates) do
    if noctalia.fileExists(full) then
      avatar = full
      break
    end
  end
  noctalia.state.set("profile", { name = name, avatar = avatar })
end

------------------------------------------------------------------ uptime

local function refreshUptime()
  noctalia.readFileAsync("/proc/uptime", function(contents, err)
    if contents == nil then
      return
    end
    local secs = tonumber(string.match(contents, "^(%d+)"))
    if secs ~= nil then
      noctalia.state.set("uptime", secs)
    end
  end)
end

------------------------------------------------------------------ screen time
-- Parsing Noctalia's screen_time.json is done by screentime.py (next to this
-- script) so the work happens outside the plugin VM, which has a small CPU
-- budget per callback. The helper prints a tiny JSON summary.

local iconCache = {}
local iconBudget = 6 -- new icon lookups allowed per refresh, keeps the callback fast
local function iconFor(app)
  if iconCache[app] == nil then
    if iconBudget <= 0 then
      return ""
    end
    iconBudget = iconBudget - 1
    iconCache[app] = noctalia.appIconPath(app, 24) or ""
  end
  return iconCache[app]
end

local screenBusy = false
local screenLimit = 12
local screenAgain = false

local function refreshScreenTime()
  if screenBusy then
    return
  end
  if not noctalia.commandExists("python3") then
    noctalia.state.set("screen", { ok = false, noPython = true })
    return
  end
  local dir = noctalia.pluginDir()
  if dir == nil then
    return
  end
  local file = stateHome() .. "/noctalia/screen_time.json"
  screenBusy = true
  local started = noctalia.runAsync({ "python3", dir .. "/screentime.py", file, tostring(screenLimit) }, function(result)
    screenBusy = false
    if result.exitCode ~= 0 then
      noctalia.log("screentime.py failed: " .. tostring(result.stderr))
      noctalia.state.set("screen", { ok = false, sample = "helper error: " .. string.sub(tostring(result.stderr), 1, 200) })
      return
    end
    local r = noctalia.json.decode(result.stdout)
    if r == nil then
      noctalia.state.set("screen", { ok = false, sample = "helper returned unreadable output" })
      return
    end
    if r.ok == true and r.apps ~= nil then
      iconBudget = 6
      for _, a in ipairs(r.apps) do
        local iconName = (a.icon ~= nil and a.icon ~= "") and a.icon or a.id
        local path = iconFor(iconName)
        if path == "" and iconName ~= a.id then
          path = iconFor(a.id)
        end
        a.icon = path
      end
    end
    noctalia.state.set("screen", r)
    if screenAgain then
      screenAgain = false
      refreshScreenTime()
    end
  end)
  if not started then
    screenBusy = false
  end
end

------------------------------------------------------------------ calendar

local function refreshCalendar()
  local ev = noctalia.calendarEvents()
  if ev == nil then
    noctalia.state.set("events", { synced = false, items = {} })
    return
  end
  local now = noctalia.nowMs()
  local list = {}
  for _, e in ipairs(ev) do
    if e.endMs > now and e.startMs < now + 10 * DAY_MS then
      table.insert(list, e)
    end
  end
  table.sort(list, function(a, b)
    if a.allDay ~= b.allDay then
      return a.allDay
    end
    return a.startMs < b.startMs
  end)
  -- keep chronological by day, all-day first within a day
  table.sort(list, function(a, b)
    local da = os.date("%Y-%m-%d", math.floor(a.startMs / 1000))
    local db = os.date("%Y-%m-%d", math.floor(b.startMs / 1000))
    if da ~= db then
      return da < db
    end
    if a.allDay ~= b.allDay then
      return a.allDay
    end
    return a.startMs < b.startMs
  end)
  local items = {}
  for i = 1, math.min(#list, 30) do
    local e = list[i]
    table.insert(items, {
      title = e.title or "",
      startMs = e.startMs,
      endMs = e.endMs,
      allDay = e.allDay == true,
      color = e.colorHex or "",
      url = e.url or "",
      location = e.location or "",
    })
  end
  noctalia.state.set("events", { synced = true, items = items })
end

------------------------------------------------------------------ to-do (see lib/todo.luau)

local function refreshTodo()
  noctalia.state.set("todo", Todo.load(Todo.path()))
end

------------------------------------------------------------------ GitHub graph

local function publishGithub(list, user, total)
  if #list == 0 then
    return
  end
  local y, m, d = string.match(list[1].date, "(%d+)-(%d+)-(%d+)")
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local pad = os.date("*t", t).wday - 1 -- weeks start on Sunday, like GitHub

  local weeks, col = {}, {}
  for _ = 1, pad do
    table.insert(col, { l = -1, c = 0, d = "" })
  end
  local best, run, maxDay = 0, 0, 0
  for _, c in ipairs(list) do
    local count = c.count or 0
    table.insert(col, { l = c.level or 0, c = count, d = c.date })
    if #col == 7 then
      table.insert(weeks, col)
      col = {}
    end
    if count > 0 then
      run = run + 1
      if run > best then
        best = run
      end
    else
      run = 0
    end
    if count > maxDay then
      maxDay = count
    end
  end
  if #col > 0 then
    while #col < 7 do
      table.insert(col, { l = -1, c = 0, d = "" })
    end
    table.insert(weeks, col)
  end

  local streak = 0
  local i = #list
  if (list[i].count or 0) == 0 then
    i = i - 1
  end
  while i >= 1 and (list[i].count or 0) > 0 do
    streak = streak + 1
    i = i - 1
  end

  local sum = 0
  for _, c in ipairs(list) do
    sum = sum + (c.count or 0)
  end

  noctalia.state.set("gh", {
    ok = true,
    user = user,
    weeks = weeks,
    total = total or sum,
    streak = streak,
    best = best,
    maxDay = maxDay,
    today = list[#list].count or 0,
  })
end

local function cachePath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/github.json"
end

local function refreshCommits()
  local user = noctalia.getConfig("github_user")
  if user == nil or user == "" then
    return
  end
  local year = os.date("%Y")
  local q = noctalia.string.urlEncode("author:" .. user .. " author-date:>=" .. year .. "-01-01")
  noctalia.http({
    url = "https://api.github.com/search/commits?per_page=1&q=" .. q,
    method = "GET",
    headers = { "Accept: application/vnd.github+json", "User-Agent: noctalia-dashboard" },
    follow_redirects = true,
  }, function(res)
    if not res.ok or res.status ~= 200 then
      return
    end
    local data = noctalia.json.decode(res.body)
    if data == nil or type(data.total_count) ~= "number" then
      return
    end
    noctalia.state.set("gh_commits", { ok = true, n = math.floor(data.total_count), year = year, user = user })
  end)
end

local function refreshGithub()
  local user = noctalia.getConfig("github_user")
  if user == nil or user == "" then
    return
  end
  local url = "https://github-contributions-api.jogruber.de/v4/" .. noctalia.string.urlEncode(user) .. "?y=last"
  local started = noctalia.http({
    url = url,
    method = "GET",
    headers = { "Accept: application/json" },
    follow_redirects = true,
  }, function(res)
    local current = noctalia.state.get("gh")
    local function fail(msg)
      lastGithub = noctalia.nowMs() - 25 * 60000 -- retry in ~5 minutes
      noctalia.state.set("gh_done", noctalia.nowMs())
      if current == nil or current.ok ~= true then
        noctalia.state.set("gh", { ok = false, err = msg })
      end
    end
    if not res.ok or res.status ~= 200 then
      fail("HTTP " .. tostring(res.status))
      return
    end
    local data = noctalia.json.decode(res.body)
    if data == nil or type(data.contributions) ~= "table" then
      fail("bad response")
      return
    end
    local total = nil
    if type(data.total) == "table" then
      total = data.total.lastYear
    end
    publishGithub(data.contributions, user, total)
    noctalia.state.set("gh_done", noctalia.nowMs())
    refreshCommits()
    local p = cachePath()
    if p ~= nil then
      noctalia.writeFile(p, noctalia.json.encode({ user = user, total = total, contributions = data.contributions }))
    end
  end)
  if not started then
    lastGithub = noctalia.nowMs() - 25 * 60000
  end
end

local function loadGithubCache()
  local p = cachePath()
  if p == nil then
    return
  end
  readJson(p, function(data)
    if data == nil or type(data.contributions) ~= "table" then
      return
    end
    if data.user ~= noctalia.getConfig("github_user") then
      return
    end
    if noctalia.state.get("gh") == nil then
      publishGithub(data.contributions, data.user, data.total)
    end
  end)
end

------------------------------------------------------------------ orchestration

local function refreshAll()
  refreshProfile()
  refreshUptime()
  refreshTodo()
  refreshCalendar()
  if visible then
    refreshScreenTime()
  end
end

local function setVisible(v)
  visible = v
  closeAskedAt = 0
  if not v then
    screenLimit = 12
  end
  noctalia.state.set("visible", v)
  noctalia.log("dashboard: " .. (v and "show" or "hide"))
  if v then
    refreshAll()
    noctalia.layer.show("screen")
  else
    noctalia.layer.hide("screen")
  end
end

-- ask the layer to play its close animation; it answers with close_req when done
local function requestClose()
  closeAskedAt = noctalia.nowMs()
  noctalia.state.set("anim_close", closeAskedAt)
end

function onIpc(event, payload)
  noctalia.log("dashboard ipc '" .. tostring(event) .. "' (visible=" .. tostring(visible) .. ")")
  if event == "toggle" then
    if visible then
      requestClose()
    else
      setVisible(true)
    end
  elseif event == "show" then
    setVisible(true)
  elseif event == "hide" then
    if visible then
      requestClose()
    end
  elseif event == "refresh" then
    refreshAll()
    lastGithub = 0
  end
end

-- the layer asks the service to close it, so this script stays the single owner of the open/closed flag
noctalia.state.watch("close_req", function(_)
  if visible then
    setVisible(false)
  end
end)

noctalia.state.watch("refresh_req", function(_)
  refreshAll()
  lastGithub = 0
end)

-- the layer edits the to-do file itself and asks for a re-read afterwards
noctalia.state.watch("screen_more_req", function(_)
  screenLimit = 40
  if screenBusy then
    screenAgain = true
  else
    refreshScreenTime()
  end
end)

noctalia.state.watch("gh_req", function(_)
  lastGithub = noctalia.nowMs()
  refreshGithub()
end)

noctalia.state.watch("todo_req", function(_)
  refreshTodo()
end)

function update()
  tick = tick + 1
  -- safety net: if the layer never answered the close request, hide anyway
  if visible and closeAskedAt > 0 and noctalia.nowMs() - closeAskedAt > 2500 then
    setVisible(false)
  end
  refreshUptime()
  if tick % 3 == 1 then
    refreshTodo()
  end
  -- screen time is the heavy one: only while the dashboard is open, about every 30s
  if tick % 6 == 2 and visible then
    refreshScreenTime()
  end
  if tick % 6 == 1 then
    refreshCalendar()
  end
  local now = noctalia.nowMs()
  if now - lastGithub > 30 * 60000 then
    lastGithub = now
    refreshGithub()
  end
end

-- startup
noctalia.state.set("visible", false)
loadGithubCache()
refreshAll()

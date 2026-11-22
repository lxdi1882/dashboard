--!nonstrict
-- lat/dashboard layer: full-screen overlay drawn with Noctalia palette roles only.

noctalia.setUpdateInterval(1000)
noctalia.log("dashboard layer started")

local Todo = require("./lib/todo.luau")
local Layout = require("./lib/layout.luau")
local Calendar = require("./lib/calendar.luau")
local Notes = require("./lib/notes.luau")

local function compactGraph()
  return noctalia.getConfig("graph_size") == "compact"
end

local Grid = require("./lib/grid.luau")
local profiles = Grid.load()
local activeGrid
noctalia.state.watch("layout_saved", function()
  profiles = Grid.load()
  activeGrid = nil
  update()
end)

------------------------------------------------------------------ shared state

local gh = noctalia.state.get("gh")
local todo = noctalia.state.get("todo")
local screen = noctalia.state.get("screen")
local events = noctalia.state.get("events")
local uptimeSec = noctalia.state.get("uptime")
local profile = noctalia.state.get("profile")
local weather = noctalia.state.get("weather")
local gridCache = nil
local gridKey = ""
local hoverDay = nil -- { d = "YYYY-MM-DD", c = count }
local ghLoading = false
local ghLoadingSince = 0
local loadingMore = false
local loadingSince = 0

noctalia.state.watch("gh", function(v)
  gh = v
  gridCache = nil
end)
noctalia.state.watch("todo", function(v) todo = v end)
noctalia.state.watch("screen", function(v)
  screen = v
  if loadingMore and (v == nil or v.expanded == true or (v.hidden or 0) == 0) then
    loadingMore = false
  end
end)
noctalia.state.watch("events", function(v) events = v end)
noctalia.state.watch("uptime", function(v) uptimeSec = v end)
noctalia.state.watch("profile", function(v) profile = v end)
noctalia.state.watch("weather", function(v) weather = v end)
local ghCommits = noctalia.state.get("gh_commits")
noctalia.state.watch("gh_commits", function(v) ghCommits = v end)
noctalia.state.watch("gh_done", function(_) ghLoading = false end)

------------------------------------------------------------------ actions

-- Animate from the current opacity so an interrupted fade can reverse smoothly.
local ANIM_MS = 170
local motionSpeed = noctalia.getSetting("shell.animation.speed")
local motionScale = 1
if noctalia.getSetting("shell.animation.enabled") == false then
  motionScale = 0
elseif type(motionSpeed) == "number" and motionSpeed > 0 then
  motionScale = 1 / motionSpeed
end

local function easeOut(elapsed, duration)
  if duration <= 0 or elapsed >= duration then return 1 end
  local t = math.clamp(elapsed / duration, 0, 1)
  return 1 - (1 - t) ^ 3
end

local viewMotion
local function animateView(distance, fade)
  if motionScale > 0 then
    viewMotion = { start = noctalia.nowMs(), distance = distance, fade = fade }
    layer.setNeedsFrameTick(true)
  end
end
local animStart = noctalia.nowMs()
local animFrom = 0
local animStarted = false
local closeToken = 0
local layoutCache = nil
if motionScale > 0 then layer.setNeedsFrameTick(true) end

local function animProgress()
  local target = closeToken == 0 and 1 or 0
  local duration = ANIM_MS * motionScale * math.abs(target - animFrom)
  local elapsed = animStarted and (noctalia.nowMs() - animStart) or 0
  return animFrom + (target - animFrom) * easeOut(elapsed, duration)
end

local function closeDash()
  noctalia.state.set("close_req", noctalia.nowMs())
end

noctalia.state.watch("anim_close", function(v)
  if v ~= nil and v ~= closeToken then
    animFrom = animProgress()
    closeToken = v
    animStarted = true
    animStart = noctalia.nowMs()
    layer.setNeedsFrameTick(true)
  end
end)

local function openUrl(url)
  if url ~= nil and url ~= "" then
    noctalia.runAsync({ "xdg-open", url })
    closeDash()
  end
end

local function refresh()
  noctalia.state.set("refresh_req", noctalia.nowMs())
end

local function setHover(d, c)
  if hoverDay == nil or hoverDay.d ~= d then
    hoverDay = { d = d, c = c }
    update()
  end
end

local function clearHover(d)
  if hoverDay ~= nil and hoverDay.d == d then
    hoverDay = nil
    update()
  end
end

------------------------------------------------------------------ formatting

local function fmtDur(sec)
  sec = math.floor(sec or 0)
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  if h > 0 then
    return h .. "h " .. m .. "m"
  end
  if m > 0 then
    return m .. "m"
  end
  return (sec > 0) and "<1m" or "0m"
end

local function fmtUptime(sec)
  sec = math.floor(sec or 0)
  local d = math.floor(sec / 86400)
  local h = math.floor((sec % 86400) / 3600)
  local m = math.floor((sec % 3600) / 60)
  if d > 0 then
    return d .. "d " .. h .. "h"
  end
  if h > 0 then
    return h .. "h " .. m .. "m"
  end
  return m .. "m"
end

local function greeting()
  local h = os.date("*t").hour
  if h < 5 then
    return "Burning the midnight oil"
  elseif h < 12 then
    return "Good morning"
  elseif h < 18 then
    return "Good afternoon"
  end
  return "Good evening"
end

local function dateToTime(key)
  local y, m, d = string.match(key, "(%d+)-(%d+)-(%d+)")
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

------------------------------------------------------------------ small UI pieces

local maximizedCard = nil
local systemSession = 0
local calendarSelection = nil
local calendarPane = "month"

local function requestCalendarMonth(month)
  noctalia.state.set("calendar_month_req", { month = month, at = noctalia.nowMs() })
end
local screenHover = nil
local githubFeed = "commits"
local ghRepos = noctalia.state.get("gh_repos")
noctalia.state.watch("gh_repos", function(v) ghRepos = v end)

local function maximize(id)
  if maximizedCard == id then return end
  animateView(id == nil and -8 or 10, 0.34)
  if id == "system" or maximizedCard == "system" then systemSession = systemSession + 1 end
  maximizedCard = id
  screenHover = nil
  if id == "github" then
    githubFeed = "commits"
    noctalia.state.set("gh_repos_req", { at = noctalia.nowMs(), force = false })
  elseif id == "calendar" then
    calendarSelection = nil
    calendarPane = "month"
    requestCalendarMonth(os.date("%Y-%m-01"))
  end
  update()
end

local function sectionTitle(glyph, text, right, action, id)
  local children = {
    ui.glyph({ name = glyph, size = 18, color = "primary" }),
    ui.label({ text = text, fontSize = 15, fontWeight = "bold", color = "on_surface", maxLines = 1, flexGrow = 1 }),
  }
  if right ~= nil then
    table.insert(children, ui.label({ text = right, fontSize = 12, color = "on_surface_variant", maxLines = 1, maxWidth = 140 }))
  end
  if action ~= nil then
    table.insert(children, action)
  end
  if id ~= nil then
    local expanded = maximizedCard == id
    table.insert(children, ui.button({
      key = "expand-" .. id,
      text = expanded and "Back" or nil,
      glyph = expanded and "arrow-left" or "arrows-maximize",
      variant = "ghost",
      controlSize = "sm",
      tooltip = expanded and "Back to dashboard" or ("Maximize " .. text),
      onClick = function()
        maximize(not expanded and id or nil)
      end,
    }))
  end
  return ui.row({ gap = 8, align = "center" }, children)
end

local function card(props, children)
  props.fill = "surface_container"
  props.radius = 18
  props.padding = props.padding or 16
  props.gap = props.gap or 10
  props.border = "outline_variant/0.5"
  props.borderWidth = 1
  return ui.column(props, children)
end

local function stat(value, caption)
  return ui.column({ gap = 2 }, {
    ui.label({ text = value, fontSize = 18, fontWeight = "bold", color = "on_surface" }),
    ui.label({ text = caption, fontSize = 11, color = "on_surface_variant" }),
  })
end

------------------------------------------------------------------ GitHub graph + hover details

local function levelColor(l, mode, dark)
  if l <= 0 then
    if mode == "github" then
      return dark and "#161b22" or "#ebedf0"
    end
    return "surface_container_high"
  end
  if l > 4 then
    l = 4
  end
  if mode == "github" then
    if dark then
      return ({ "#0e4429", "#006d32", "#26a641", "#39d353" })[l]
    end
    return ({ "#9be9a8", "#40c463", "#30a14e", "#216e39" })[l]
  end
  return ({ "primary/0.30", "primary/0.50", "primary/0.75", "primary" })[l]
end

local function buildGrid(cell, gap, first, last, palette, dark)
  local cols = {}
  for wi = first, last do
    local week = gh.weeks[wi]
    local cells = {}
    for di, c in ipairs(week) do
      if c.l < 0 then
        table.insert(cells, ui.box({ key = "p" .. wi .. "-" .. di, width = cell, height = cell, fill = "surface_container/0" }))
      else
        table.insert(cells, ui.box({
          key = "d" .. c.d,
          width = cell,
          height = cell,
          radius = math.max(2, math.floor(cell / 4)),
          fill = levelColor(c.l, palette, dark),
          tooltip = c.c .. (c.c == 1 and " contribution" or " contributions") .. " · " .. os.date("%a, %b %d", dateToTime(c.d)),
          onHover = function(state)
            if state == "true" then
              setHover(c.d, c.c)
            else
              clearHover(c.d)
            end
          end,
          onClick = function()
            openUrl("https://github.com/" .. tostring(noctalia.getConfig("github_user")) .. "?tab=overview&from=" .. c.d .. "&to=" .. c.d)
          end,
        }))
      end
    end
    table.insert(cols, ui.column({ key = "w" .. wi, gap = gap, align = "start" }, cells))
  end
  return ui.row({ gap = gap, align = "start" }, cols)
end

local function ghRefreshButton()
  if ghLoading and os.time() - ghLoadingSince > 15 then
    ghLoading = false
  end
  if ghLoading then
    local dots = string.rep(".", os.time() % 3 + 1)
    return ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "loader-2", size = 14, color = "primary" }),
      ui.label({ text = "Updating" .. dots, fontSize = 11, color = "on_surface_variant" }),
    })
  end
  return ui.button({
    glyph = "refresh",
    variant = "ghost",
    controlSize = "sm",
    tooltip = "Refresh GitHub data",
    onClick = function()
      ghLoading = true
      ghLoadingSince = os.time()
      noctalia.state.set("gh_req", noctalia.nowMs())
      if maximizedCard == "github" then
        noctalia.state.set("gh_repos_req", { at = noctalia.nowMs(), force = true })
      end
      update()
    end,
  })
end

local githubPage = 0

local function githubActivity(width, height)
  local gap, minCell = 2, 8
  local weeks = #gh.weeks
  local expanded = maximizedCard == "github"
  local capacity = math.floor((width + gap) / (minCell + gap))
  local paged = expanded and capacity < weeks
  local showStats = height >= 230
  local budget = height - 92 - (showStats and 44 or 0) - (paged and 35 or 0)
  local maxCell = math.floor((budget - 6 * gap) / 7)
  if weeks == 0 or capacity < 1 or maxCell < minCell then
    return nil
  end

  local density = noctalia.getConfig("graph_size") == "compact" and 9 or 12
  local visible = expanded and math.min(weeks, capacity) or math.min(weeks,
    math.floor((width + gap) / (math.min(maxCell, density) + gap)))
  local cell = math.min(maxCell, expanded and 16 or 14, math.floor((width + gap) / visible) - gap)
  local lastPage = math.floor((weeks - 1) / visible)
  local page = expanded and math.min(githubPage, lastPage) or 0
  local last = weeks - visible * page
  local first = math.max(1, last - visible + 1)
  return { gap = gap, cell = cell, first = first, last = last, page = page, lastPage = lastPage, stats = showStats }
end

local function githubWeeklyTrend()
  local entries = {}
  local peak = 1
  for i = math.max(1, #gh.weeks - 7), #gh.weeks do
    local count, first = 0, nil
    for _, day in ipairs(gh.weeks[i]) do
      if day.l >= 0 then
        first = first or day.d
        count = count + day.c
      end
    end
    if first ~= nil then
      table.insert(entries, { count = count, label = i == #gh.weeks and "This week" or os.date("%b %d", dateToTime(first)) })
      peak = math.max(peak, count)
    end
  end
  local bars = {}
  for _, entry in ipairs(entries) do
    table.insert(bars, ui.column({ flexGrow = 1, gap = 4, align = "center" }, {
      ui.label({ text = tostring(entry.count), fontSize = 11, maxLines = 1, color = "on_surface_variant" }),
      ui.box({ width = 20, height = math.max(2, math.floor(58 * entry.count / peak)), radius = 3, fill = "primary/0.65" }),
      ui.label({ text = entry.label, fontSize = 10, maxLines = 1, color = "on_surface_variant" }),
    }))
  end
  return ui.column({ gap = 7 }, {
    sectionTitle("chart-bar", "Weekly contributions"),
    ui.row({ gap = 6, align = "end" }, bars),
  })
end

local function githubRepoRows(width, user)
  local current = ghRepos and ghRepos.user == user and ghRepos or nil
  local rows = {}
  local items = current and current.items or {}
  if #items == 0 then
    local message = "Loading recent repositories…"
    if user == "" then
      message = "Set a GitHub username to see repositories."
    elseif current ~= nil then
      message = current.ok and "No public repositories found." or "Couldn’t load repositories. Try refreshing."
    end
    return { ui.label({ text = message, fontSize = 12, maxLines = 2, color = "on_surface_variant" }) }
  end
  for _, repo in ipairs(items) do
    local meta = {}
    if repo.language ~= "" then table.insert(meta, repo.language) end
    if repo.pushed ~= "" then table.insert(meta, "Pushed " .. os.date("%b %d", dateToTime(repo.pushed))) end
    local text = {
      ui.label({ text = repo.name, fontSize = 13, fontWeight = "bold", maxLines = 1, flexGrow = 1, color = "on_surface" }),
      ui.label({ text = table.concat(meta, " · "), maxWidth = math.max(80, math.floor(width * 0.42)), maxLines = 1,
        fontSize = 11, color = "on_surface_variant" }),
    }
    local detail = { ui.row({ gap = 6, align = "center" }, text) }
    if repo.description ~= "" then
      table.insert(detail, ui.label({
        text = repo.description, maxWidth = math.max(1, width - 66), maxLines = 1, fontSize = 11, color = "on_surface_variant",
      }))
    end
    table.insert(rows, ui.row({
      key = repo.url, gap = 7, paddingH = 7, paddingV = 4, radius = 8, align = "center",
      fill = "surface_container_high", onClick = function() openUrl(repo.url) end,
    }, {
      ui.glyph({ name = "folder", size = 15, color = "primary" }),
      ui.column({ gap = 2, flexGrow = 1 }, detail),
      ui.glyph({ name = "external-link", size = 12, color = "on_surface_variant" }),
    }))
  end
  return rows
end

local function githubReposSection(width, user)
  return ui.column({ gap = 5 }, {
    sectionTitle("folder", "Recently pushed repositories"),
    ui.column({ gap = 4 }, githubRepoRows(width, user)),
  })
end

local function githubCard(width, height, embedded)
  local inner = width - 24
  local expanded = maximizedCard == "github"
  if not expanded then
    githubPage = 0
  end
  local caption = "GitHub"
  local user = noctalia.getConfig("github_user") or ""
  if inner >= 360 and user ~= "" then
    caption = "GitHub · " .. tostring(user)
  end
  local heading = embedded and sectionTitle("chart-bar", "Contributions") or sectionTitle("brand-github", caption, nil, ghRefreshButton(), "github")
  local contents = { heading }
  if gh == nil or gh.ok ~= true then
    table.insert(contents, ui.label({
      text = gh == nil and "Loading contributions…" or "Couldn’t load contributions. Retrying soon.",
      fontSize = 12, maxLines = 2, maxWidth = inner,
      color = gh == nil and "on_surface_variant" or "error",
    }))
    return card({ width = width, flexGrow = 1, padding = 10, gap = 5 }, contents)
  end

  local activity = githubActivity(inner, height)
  if activity == nil then
    table.insert(contents, ui.label({
      text = tostring(gh.total) .. " contributions this year",
      fontSize = 15, fontWeight = "bold", maxLines = 1, color = "on_surface",
    }))
    table.insert(contents, ui.label({
      text = tostring(gh.today) .. " today  ·  " .. tostring(gh.streak) .. " day streak",
      fontSize = 12, maxLines = 1, color = "on_surface_variant",
    }))
    return card({ width = width, flexGrow = 1, padding = 10, gap = 5 }, contents)
  end

  local palette = noctalia.getConfig("graph_palette")
  local dark = noctalia.isDarkMode()
  local key = table.concat({ activity.cell, activity.gap, activity.first, activity.last, tostring(palette), tostring(dark) }, "|")
  if gridCache == nil or gridKey ~= key then
    gridCache = buildGrid(activity.cell, activity.gap, activity.first, activity.last, palette, dark)
    gridKey = key
  end

  local count = activity.last - activity.first + 1
  local period = activity.first == 1 and activity.last == #gh.weeks and "Past year"
    or ("Last " .. count .. " weeks")
  if activity.page > 0 then
    local a, b = gh.weeks[activity.first], gh.weeks[activity.last]
    for _, day in ipairs(a) do
      if day.l >= 0 then
        period = os.date("%b %d", dateToTime(day.d))
        break
      end
    end
    for i = #b, 1, -1 do
      if b[i].l >= 0 then
        period = period .. " – " .. os.date("%b %d", dateToTime(b[i].d))
        break
      end
    end
  end
  local detail = period
  if hoverDay ~= nil then
    detail = os.date("%a, %b %d", dateToTime(hoverDay.d)) .. " · " .. hoverDay.c
      .. (hoverDay.c == 1 and " contribution" or " contributions")
  end
  local labels = { ui.label({ text = detail, fontSize = 12, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }) }
  if inner >= 420 then
    local legend = { ui.label({ text = "Less", fontSize = 10, color = "on_surface_variant" }) }
    for l = 0, 4 do
      table.insert(legend, ui.box({ width = 9, height = 9, radius = 2, fill = levelColor(l, palette, dark) }))
    end
    table.insert(legend, ui.label({ text = "More", fontSize = 10, color = "on_surface_variant" }))
    table.insert(labels, ui.row({ gap = 3, align = "center" }, legend))
  end
  table.insert(contents, ui.row({ align = "center", gap = 8 }, labels))
  table.insert(contents, gridCache)

  if expanded and activity.lastPage > 0 then
    local function pageButton(text, direction, enabled)
      return ui.button({
        text = text, variant = "ghost", controlSize = "sm", enabled = enabled,
        onClick = function()
          githubPage = math.clamp(activity.page + direction, 0, activity.lastPage)
          hoverDay = nil
          update()
        end,
      })
    end
    table.insert(contents, ui.row({ gap = 6 }, {
      pageButton("Older", 1, activity.page < activity.lastPage),
      pageButton("Newer", -1, activity.page > 0),
    }))
  end

  if activity.stats then
    local stats = {
      stat(tostring(gh.total), "past year"),
      stat(tostring(gh.streak) .. "d", "streak"),
    }
    if embedded and gh.recentWeek ~= nil then
      table.insert(stats, stat(tostring(gh.recentWeek), "last 7 days"))
      if inner >= 310 then
        table.insert(stats, stat(tostring(gh.activeDays) .. "/30", "active days"))
      end
      if inner >= 420 then
        table.insert(stats, stat(tostring(gh.recentMonth), "last 30 days"))
      end
    elseif inner >= 280 then
      table.insert(stats, stat(tostring(gh.today), "today"))
    end
    if inner >= (embedded and 590 or 365) then
      table.insert(stats, stat(tostring(gh.best) .. "d", "longest"))
      table.insert(stats, stat(tostring(gh.maxDay), "best day"))
    end
    if not embedded and inner >= 475 and ghCommits ~= nil and ghCommits.ok == true and ghCommits.user == user then
      table.insert(stats, stat(tostring(ghCommits.n), "commits · " .. ghCommits.year))
    end
    table.insert(contents, ui.row({ gap = inner >= 440 and 16 or 9, align = "end" }, stats))
  end
  if embedded and height >= 423 and inner >= 500 then
    table.insert(contents, ui.separator({ thickness = 1, color = "outline_variant/0.5", spacing = 4 }))
    table.insert(contents, githubWeeklyTrend())
    if height >= 530 then
      table.insert(contents, ui.separator({ thickness = 1, color = "outline_variant/0.5", spacing = 4 }))
      table.insert(contents, githubReposSection(inner, user))
    end
  end
  return card({ width = width, flexGrow = 1, padding = 12, gap = 6 }, contents)
end

local function githubCommitsCard(width, user, tabbed)
  local current = ghCommits and ghCommits.user == user and ghCommits.year == os.date("%Y") and ghCommits or nil
  local items = current and current.items or {}
  local caption = current and current.ok and (tostring(current.n) .. " in " .. current.year) or nil
  local rows = {}
  if #items == 0 then
    local message
    if user == "" then
      message = "Set a GitHub username to see recent commits."
    elseif current == nil then
      message = "Loading recent commits…"
    elseif not current.ok then
      message = "GitHub couldn’t load recent commits. Try refreshing."
    else
      message = "No public commits found this year."
    end
    table.insert(rows, ui.label({ text = message, fontSize = 12, maxLines = 2, color = "on_surface_variant" }))
  end

  for _, commit in ipairs(items) do
    local date = commit.date ~= "" and os.date("%b %d", dateToTime(commit.date)) or ""
    table.insert(rows, ui.row({
      key = commit.url, gap = 8, paddingH = 8, paddingV = 5, radius = 8, align = "center",
      fill = "surface_container_high", onClick = function() openUrl(commit.url) end,
    }, {
      ui.glyph({ name = "git-commit", size = 16, color = "primary" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = commit.title, maxWidth = width - 72, maxLines = 1, fontSize = 13, color = "on_surface" }),
        ui.label({ text = commit.repo .. (date ~= "" and (" · " .. date) or ""), maxWidth = width - 72, maxLines = 1,
          fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.glyph({ name = "external-link", size = 13, color = "on_surface_variant" }),
    }))
  end
  local heading = sectionTitle("git-commit", "Recent public commits", caption)
  if tabbed then
    local function tab(id, text)
      return ui.button({
        text = text, controlSize = "sm", variant = githubFeed == id and "primary" or "ghost",
        onClick = function()
          if githubFeed ~= id then
            githubFeed = id
            animateView(3, 0.15)
            update()
          end
        end,
      })
    end
    heading = ui.row({ gap = 6 }, { tab("commits", "Commits"), tab("repos", "Repositories") })
    if githubFeed == "repos" then
      rows = githubRepoRows(width, user)
    end
  end
  return card({ flexGrow = 1, padding = 10, gap = 6 }, {
    heading,
    ui.scroll({ flexGrow = 1, gap = 5 }, rows),
  })
end

local function githubDetails(width, height)
  local user = noctalia.getConfig("github_user") or ""
  local inner = width - 24
  local sideBySide = inner >= 1110 and height >= 370
  local body
  if sideBySide then
    local activityWidth = math.floor((inner - 10) * 0.64)
    local commitsWidth = inner - 10 - activityWidth
    body = ui.row({ flexGrow = 1, gap = 10 }, {
      ui.column({ width = activityWidth }, { githubCard(activityWidth, height - 54, true) }),
      ui.column({ width = commitsWidth }, { githubCommitsCard(commitsWidth, user, height - 54 < 530) }),
    })
  else
    local activityHeight = height >= 330 and math.clamp(math.floor((height - 54) * 0.53), 198, 245)
      or math.floor(math.max(0, height - 54) * 0.45)
    body = ui.column({ flexGrow = 1, gap = 8 }, {
      ui.column({ height = activityHeight, clip = true }, { githubCard(inner, activityHeight, true) }),
      githubCommitsCard(inner, user, true),
    })
  end
  return card({ width = width, flexGrow = 1, padding = 12, gap = 8 }, {
    sectionTitle("brand-github", user ~= "" and ("GitHub · " .. user) or "GitHub", nil, ghRefreshButton(), "github"),
    body,
  })
end

------------------------------------------------------------------ agenda (grouped by day)

local function calendarEventRow(event, day, index, compact)
  local time
  if event.allDay then
    time = "All day"
  else
    local start, finish = Calendar.dayBounds(day)
    local from = os.date("%H:%M", math.floor(event.startMs / 1000))
    local untilTime = os.date("%H:%M", math.floor(event.endMs / 1000))
    if event.startMs < start then
      time = event.endMs >= finish and "Ongoing" or ("Until " .. untilTime)
    else
      time = event.endMs >= finish and ("From " .. from) or (from .. "–" .. untilTime)
    end
  end
  local accent = event.color ~= nil and event.color ~= "" and event.color or "primary"
  local link = event.url or ""
  local title = event.title ~= "" and event.title or "Untitled event"
  local text = {
    ui.label({ text = title, fontSize = 13, fontWeight = "bold", color = "on_surface", maxLines = compact and 1 or 2 }),
    ui.label({ text = time, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
  }
  if not compact and event.location ~= nil and event.location ~= ""
      and not string.match(event.location, "^https?://") then
    table.insert(text, ui.label({ text = event.location, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
  end
  local children = {
    ui.box({ width = 3, height = compact and 27 or 35, radius = 2, fill = accent }),
    ui.column({ gap = 0, flexGrow = 1, clip = true }, text),
  }
  if link ~= "" then table.insert(children, ui.glyph({ name = "external-link", size = 14, color = "on_surface_variant" })) end
  return ui.row({
    key = "calendar-event-" .. tostring(event.id or "") .. "-" .. index,
    gap = 9, paddingH = 8, paddingV = compact and 4 or 7, align = "center",
    radius = 8, fill = "surface_container_high",
    onClick = link ~= "" and function() openUrl(link) end or nil,
    tooltip = link ~= "" and "Open event link" or nil,
  }, children)
end

local function calendarAgenda(day, items, empty, compact)
  local rows = {}
  if #items == 0 then
    table.insert(rows, ui.label({ text = empty, fontSize = 12, color = "on_surface_variant", maxLines = 2 }))
  else
    for index, event in ipairs(items) do
      table.insert(rows, calendarEventRow(event, day, index, compact))
    end
  end
  return ui.scroll({ key = "calendar-agenda-" .. day, flexGrow = 1, gap = 5 }, rows)
end

local function todayCalendar(today, height)
  local synced = events ~= nil and events.synced == true
  local items = synced and Calendar.eventsOn(events.items, today) or {}
  local kids = { sectionTitle("calendar-event", "Calendar", "Today", nil, "calendar") }
  if synced and #items > 0 and height < 142 then
    local first = items[1]
    local title = first.title ~= "" and first.title or "Untitled event"
    local time = first.allDay and "All day" or os.date("%H:%M", math.floor(first.startMs / 1000))
    local extra = #items > 1 and (" · +" .. (#items - 1) .. " more") or ""
    table.insert(kids, ui.label({ text = title, height = 19, fontSize = 13, fontWeight = "bold", color = "on_surface", maxLines = 1 }))
    table.insert(kids, ui.label({ text = time .. extra, height = 16, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
  else
    table.insert(kids, calendarAgenda(today, items, synced and "Nothing scheduled today" or "Calendar not synced", true))
  end
  return card({ flexGrow = 1, padding = 10, gap = 4 }, kids)
end

local function selectCalendarDay(day, openAgenda)
  local previous = calendarSelection or os.date("%Y-%m-%d")
  calendarSelection = day
  if Calendar.monthStart(previous) ~= Calendar.monthStart(day) then
    requestCalendarMonth(Calendar.monthStart(day))
  end
  if openAgenda then calendarPane = "agenda" end
  update()
end

local function calendarMonthGrid(width, height, month, selected, today, items, openAgenda)
  local pad = 10
  local gap = 4
  local usable = width - 2 * pad
  local cellWidth = math.max(1, math.floor((usable - 6 * gap) / 7))
  local cellHeight = math.clamp(math.floor((height - 104) / 6), 22, 71)
  local headers = {}
  for _, name in ipairs({ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }) do
    table.insert(headers, ui.column({ width = cellWidth, height = 18, align = "center", justify = "center" }, {
      ui.label({ text = name, fontSize = 11, baseline = "inkCentered", color = "on_surface_variant" }),
    }))
  end
  local weeks = {}
  local day = Calendar.gridStart(month)
  for week = 1, 6 do
    local cells = {}
    for weekday = 1, 7 do
      local key = day
      day = Calendar.shiftDay(day, 1)
      local active = key == selected
      local inMonth = Calendar.monthStart(key) == month
      local isToday = key == today
      local dayEvents = Calendar.eventsOn(items, key)
      local markers = {}
      for i = 1, math.min(3, #dayEvents) do
        local color = dayEvents[i].color
        table.insert(markers, ui.box({
          width = 4, height = 4, radius = 2,
          fill = color ~= nil and color ~= "" and color or "primary",
        }))
      end
      local dateLabel = os.date("%A, %B %d", dateToTime(key))
      local eventCount = #dayEvents
      if eventCount > 0 then
        dateLabel = dateLabel .. " · " .. eventCount .. (eventCount == 1 and " event" or " events")
      end
      table.insert(cells, ui.column({
        key = "calendar-day-" .. key, width = cellWidth, height = cellHeight, radius = 8,
        gap = cellHeight >= 36 and 3 or 1, align = "center", justify = "center",
        tooltip = dateLabel, onClick = function() selectCalendarDay(key, openAgenda) end,
      }, {
        ui.column({
          width = math.min(30, cellWidth), height = cellHeight >= 36 and 24 or 17,
          radius = 7, align = "center", justify = "center",
          fill = active and "primary" or "surface/0",
          border = isToday and not active and "primary" or nil, borderWidth = isToday and not active and 1 or nil,
        }, {
          ui.label({
            text = tostring(tonumber(string.sub(key, 9, 10))), fontSize = cellHeight >= 36 and 14 or 12,
            baseline = "inkCentered", fontWeight = (active or isToday) and "bold" or "normal",
            color = active and "on_primary" or (inMonth and "on_surface" or "on_surface_variant/0.68"),
          }),
        }),
        ui.row({ height = 4, gap = 3, align = "center", justify = "center" }, markers),
      }))
    end
    table.insert(weeks, ui.row({ key = "calendar-week-" .. week, height = cellHeight, gap = gap, justify = "center" }, cells))
  end

  local function changeMonth(delta)
    local nextMonth = Calendar.shiftMonth(month, delta)
    selectCalendarDay(nextMonth == Calendar.monthStart(today) and today or nextMonth, false)
  end
  local function arrow(delta, glyph, tooltip)
    return ui.button({
      key = delta < 0 and "calendar-prev-month" or "calendar-next-month",
      glyph = glyph, width = 32, height = 32, variant = "ghost", tooltip = tooltip,
      onClick = function() changeMonth(delta) end,
    })
  end
  local weeksView = height < 236 and ui.scroll({ gap = gap, flexGrow = 1 }, weeks)
    or ui.column({ gap = gap }, weeks)
  return card({ key = "calendar-month", width = width, height = height, padding = pad, gap = 6, clip = true }, {
    ui.row({ height = 32, gap = 6, align = "center" }, {
      arrow(-1, "chevron-left", "Previous month"),
      ui.label({
        key = "calendar-month-label", text = os.date("%B %Y", dateToTime(month)),
        fontSize = 17, fontWeight = "bold", flexGrow = 1, textAlign = "center", maxLines = 1,
      }),
      arrow(1, "chevron-right", "Next month"),
    }),
    ui.row({ height = 18, gap = gap, justify = "center" }, headers),
    weeksView,
  })
end

local function calendarDetails(width, height, today, selected)
  local month = Calendar.monthStart(selected)
  local synced = events ~= nil and events.synced == true
  local loaded = synced and events.month == month
  local monthItems = loaded and events.monthItems or {}
  local selectedItems = Calendar.eventsOn(loaded and monthItems or (synced and events.items or {}), selected)
  local empty = not synced and "Calendar not synced" or not loaded and "Loading events…" or "Nothing scheduled"
  local wide = width >= 700 and height >= 325
  local stacked = not wide and height >= 480
  local tabbed = not wide and not stacked
  local paneHeight = math.max(1, height - (tabbed and 78 or 40))
  local monthWidth = wide and math.floor((width - 10) * 0.58) or width
  local monthHeight = stacked and math.floor((paneHeight - 8) * 0.64) or paneHeight

  local function agenda(widthHint, heightHint)
    return card({ key = "calendar-day-agenda", width = widthHint, height = heightHint, padding = 10, gap = 7, clip = true }, {
      ui.label({
        key = "calendar-selected-day", text = (selected == today and "Today · " or "") .. os.date("%a, %b %d", dateToTime(selected)),
        fontSize = 15, fontWeight = "bold", color = "on_surface", maxLines = 1,
      }),
      calendarAgenda(selected, selectedItems, empty, false),
    })
  end
  local todayButton = ui.button({
    key = "calendar-today", text = "Today", variant = "ghost", controlSize = "sm", tooltip = "Jump to today",
    onClick = function()
      if tabbed then calendarPane = "month" end
      selectCalendarDay(today, false)
    end,
  })
  local kids = { sectionTitle("calendar-event", "Calendar", nil, todayButton, "calendar") }

  if tabbed then
    local function tab(id, label)
      return ui.button({
        key = "calendar-tab-" .. id, text = label, controlSize = "sm",
        variant = calendarPane == id and "primary" or "ghost",
        onClick = function()
          calendarPane = id
          update()
        end,
      })
    end
    table.insert(kids, ui.row({ height = 30, gap = 6 }, { tab("month", "Month"), tab("agenda", "Agenda") }))
    if calendarPane == "agenda" then
      table.insert(kids, agenda(width, paneHeight))
    else
      table.insert(kids, calendarMonthGrid(monthWidth, monthHeight, month, selected, today, monthItems, true))
    end
  elseif wide then
    table.insert(kids, ui.row({ height = paneHeight, gap = 10 }, {
      calendarMonthGrid(monthWidth, monthHeight, month, selected, today, monthItems, false),
      agenda(width - monthWidth - 10, paneHeight),
    }))
  else
    table.insert(kids, calendarMonthGrid(monthWidth, monthHeight, month, selected, today, monthItems, false))
    table.insert(kids, agenda(width, paneHeight - monthHeight - 8))
  end
  return ui.column({ width = width, height = height, gap = 8 }, kids)
end


------------------------------------------------------------------ screen time (mirrors Noctalia's own Screen Time tab)


local screenRange = "today" -- "today" | "3d" | "14d"
local screenDay = nil -- date opened from the 3-day or 14-day chart
local screenSel = nil -- date and hour of the selected hourly bar
local screenDetailsTab = "apps"
local highlightPeriod = 1
local highlight = { fraction = 0, from = 0, target = 0, started = 0 }
local HIGHLIGHT_ANIM_MS = 160

local function stepHighlight()
  local duration = HIGHLIGHT_ANIM_MS * motionScale * math.abs(highlight.target - highlight.from)
  local progress = easeOut(noctalia.nowMs() - highlight.started, duration)
  highlight.fraction = highlight.from + (highlight.target - highlight.from) * progress
  return highlight.fraction ~= highlight.target
end

local function resetHighlight()
  highlight.id = nil
  highlight.from = 0
  highlight.fraction = 0
  highlight.target = 0
end
local screenSite = nil
local screenSiteDay = nil

local function openScreenSite(domain)
  if screenSite ~= domain then animateView(3, 0.15) end
  screenSite = domain
  screenSiteDay = nil
  update()
end

local function siteIcon(icon, size)
  if icon ~= nil and icon ~= "" then
    return ui.image({ path = icon, width = size, height = size, fit = "contain" })
  end
  return ui.glyph({ name = "world", size = size, color = "primary" })
end
local RANGES = {
  { k = "today", label = "Today", n = 1 },
  { k = "3d", label = "3 days", n = 3 },
  { k = "14d", label = "14 days", n = 14 },
}

local CHART_H = 84
local HERO_FS = 28

local APP_COLORS = {
  "#6AA9F5", "#F3AD65", "#64C9A5", "#DB89CE", "#C7C96F", "#9A98ED",
  "#F4818D", "#6BC3DB", "#DBB895", "#89C475", "#BD9AF4", "#DF8C65",
}
local OTHER_COLOR = "outline_variant"

local function screenAppColors(apps, extraApps)
  local colors, used = {}, {}
  local all = table.clone(apps)
  local known = {}
  for _, app in ipairs(apps) do
    known[app.id] = true
  end
  for _, app in ipairs(extraApps or {}) do
    if not known[app.id] then
      table.insert(all, app)
      known[app.id] = true
    end
  end
  for _, app in ipairs(all) do
    local hash = 0
    for i = 1, #app.id do
      hash = (hash * 31 + string.byte(app.id, i)) % #APP_COLORS
    end
    local slot = hash + 1
    for offset = 0, #APP_COLORS - 1 do
      local candidate = (hash + offset) % #APP_COLORS + 1
      if not used[candidate] then
        slot = candidate
        break
      end
    end
    colors[app.id] = APP_COLORS[slot]
    used[slot] = true
  end
  return colors
end

-- Layers can report hover events even when the shell does not show a tooltip.
local function screenSegment(width, height, color, id, text, x, onClick)
  return ui.box({
    key = id,
    width = width,
    height = height,
    fill = color,
    onClick = onClick,
    onHover = function(state)
      if state == "true" then
        if screenHover == nil or screenHover.id ~= id then
          screenHover = { id = id, text = text, color = color, x = x }
          update()
        end
      elseif screenHover ~= nil and screenHover.id == id then
        screenHover = nil
        update()
      end
    end,
  })
end

local function bar(bucket, maxSec, width, key, selected, onClick, apps, colors, x)
  local children = {}
  if selected then
    table.insert(children, ui.box({ width = width, height = 2, fill = "on_surface" }))
    table.insert(children, ui.box({ width = width, height = 2, fill = "surface/0" }))
  end

  if bucket.sec <= 0 then
    table.insert(children, ui.box({ width = width, height = 2, fill = "surface_container_high" }))
  else
    local height = math.max(3, math.floor(CHART_H * bucket.sec / maxSec))
    local seconds = 0
    for _, duration in pairs(bucket.by) do
      seconds = seconds + duration
    end
    local total = math.max(seconds, bucket.sec)
    local usedSeconds, pixels = 0, 0
    for _, app in ipairs(apps) do
      local duration = bucket.by[app.id] or 0
      if duration > 0 then
        usedSeconds = usedSeconds + duration
        local edge = math.floor(height * usedSeconds / total + 0.5)
        if edge > pixels then
          table.insert(children, screenSegment(width, edge - pixels, colors[app.id],
            bucket.key .. ":" .. app.id, app.name .. " · " .. fmtDur(duration), x, onClick))
          pixels = edge
        end
      end
    end
    if pixels < height then
      table.insert(children, screenSegment(width, height - pixels, OTHER_COLOR,
        bucket.key .. ":_other", "Other apps · " .. fmtDur(total - usedSeconds), x, onClick))
    end
  end

  return ui.column({
    key = key, width = width, height = CHART_H + 4, justify = "end",
    tooltip = bucket.tip, onClick = onClick,
  }, children)
end

local function rangeSum(n)
  local sums, total = {}, 0
  local days = screen.days
  for i = math.max(1, #days - n + 1), #days do
    for id, v in pairs(days[i].by) do
      sums[id] = (sums[id] or 0) + v
    end
    total = total + days[i].sec
  end
  return sums, total
end

-- segmented control
local function rangeToggle(compact)
  local pills = {}
  for _, r in ipairs(RANGES) do
    local active = r.k == screenRange
    table.insert(pills, ui.row({
      key = "rg" .. r.k,
      flexGrow = 1,
      justify = "center",
      paddingV = compact and 4 or 6,
      radius = 9,
      fill = active and "primary" or "surface_container_high/0",
      onClick = function()
        if screenRange ~= r.k and maximizedCard == "screen" then animateView(3, 0.15) end
        screenRange = r.k
        screenDay = nil
        screenSel = nil
        screenHover = nil
        update()
      end,
    }, {
      ui.label({
        text = r.label,
        height = compact and 17 or nil, fontSize = 12,
        fontWeight = active and "bold" or "normal",
        color = active and "on_primary" or "on_surface_variant",
      }),
    }))
  end
  return ui.row({ height = compact and 32 or nil, gap = 2, padding = 3, radius = 12, fill = "surface_container_high" }, pills)
end

local function screenMessage(text, innerW, color)
  return ui.label({ text = text, fontSize = 12, color = color or "on_surface_variant", maxLines = 4, maxWidth = innerW })
end



-- labels under the chart, each one sitting under the first bar of its group
local function axisRow(bars, width, gap, step, compact)
  local cells = {}
  for i = 1, #bars, step do
    local b = bars[i]
    local barsInGroup = math.min(step, #bars - i + 1)
    local segW = barsInGroup * width + (barsInGroup - 1) * gap
    local lines = {
      ui.box({ width = 1, height = 4, fill = "outline_variant" }),
      ui.label({
        text = b.top or "",
        height = compact and 14 or nil, maxWidth = segW,
        fontSize = segW < 33 and 10 or 11,
        fontWeight = b.today and "bold" or "normal",
        color = b.today and "primary" or "on_surface",
        maxLines = 1,
      }),
    }
    if b.sub ~= nil and segW >= 20 then
      table.insert(lines, ui.label({
        text = b.sub,
        height = compact and 14 or nil, maxWidth = segW,
        fontSize = 10,
        color = b.today and "primary" or "on_surface_variant",
        maxLines = 1,
      }))
    end
    table.insert(cells, ui.column({ key = "ax" .. i, width = segW, gap = 4, align = "start", clip = true }, lines))
  end
  return ui.row({ gap = gap, align = "start" }, cells)
end

local function screenCard(innerW, chartOnly)
  local rows = {}
  local model = {
    title = sectionTitle("device-desktop", "Screen time", nil, nil, "screen"),
    rows = rows, apps = {},
  }
  local listRows = {}
  local listTitle = nil
  local otherSec = 0
  local screenFocus = maximizedCard == "screen"
  local controls

  if screen == nil then
    table.insert(rows, screenMessage("Loading…", innerW))
  elseif screen.ok ~= true then
    if screen.noPython then
      table.insert(rows, screenMessage("Screen time needs python3. Install it with: sudo pacman -S python", innerW))
    elseif screen.missing then
      table.insert(rows, screenMessage("No screen time file yet. Turn on Screen Time in Noctalia settings and use your apps for a bit.", innerW))
    else
      table.insert(rows, screenMessage("Couldn't read Noctalia's screen time file format.", innerW))
      table.insert(rows, ui.label({ text = tostring(screen.sample or ""), fontSize = 10, color = "on_surface", maxLines = 8, maxWidth = innerW }))
    end
  else
    local range = RANGES[1]
    for _, r in ipairs(RANGES) do
      if r.k == screenRange then
        range = r
      end
    end
    local sums, total = rangeSum(range.n)
    local detailDay = nil
    if screenDay ~= nil then
      for i = math.max(1, #screen.days - range.n + 1), #screen.days do
        if screen.days[i].d == screenDay then
          detailDay = screen.days[i]
          break
        end
      end
    end
    local hourly = range.k == "today" or detailDay ~= nil
    local dayLabel
    if detailDay ~= nil then
      sums, total = detailDay.by, detailDay.sec
      dayLabel = os.date("%a, %b %d", dateToTime(detailDay.d))
      controls = ui.button({
        text = "Back to " .. string.lower(range.label),
        glyph = "arrow-left",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          if screenFocus then animateView(-3, 0.15) end
          screenDay = nil
          screenSel = nil
          screenHover = nil
          update()
        end,
      })
    else
      controls = rangeToggle(not screenFocus)
    end
    table.insert(rows, controls)

    local dailyApps = screen.apps
    local scope
    if screen.usageScopes ~= nil then
      local scopeKey = detailDay and detailDay.d or (range.k == "today" and screen.days[#screen.days].d or range.k)
      scope = screen.usageScopes[scopeKey]
      if scope ~= nil then
        sums = scope.by
        dailyApps = {}
        for _, id in ipairs(scope.ids) do
          local app = screen.usageApps[id]
          if app ~= nil then
            table.insert(dailyApps, app)
          end
        end
      end
    end
    local hourlyApps = screen.hourApps or dailyApps
    local chartApps = hourly and hourlyApps or dailyApps
    local colors = screenAppColors(dailyApps, screen.hourApps)

    -- 2. bars data (each bar carries its own axis label)
    local bars = {}
    local HOUR_LABELS = { [0] = "12 AM", [6] = "6 AM", [12] = "12 PM", [18] = "6 PM" }
    if hourly then
      local day = detailDay or screen.days[#screen.days]
      local todayHours = day == screen.days[#screen.days] and screen.hours or nil
      if (todayHours ~= nil and #todayHours == 24) or day.hours ~= nil then
        for i = 1, 24 do
          local h = todayHours and todayHours[i]
          local by = h and h.by or (day.hours and day.hours["h" .. (i - 1)]) or {}
          local sec = h and h.sec or 0
          if h == nil then
            for _, duration in pairs(by) do
              sec = sec + duration
            end
          end
          local hour = string.format("%02d:00", i - 1)
          table.insert(bars, {
            sec = sec,
            by = by,
            tip = hour .. " · " .. fmtDur(sec),
            name = hour,
            label = string.format("%s–%02d:00", hour, i % 24),
            key = day.d .. "T" .. hour,
            top = HOUR_LABELS[i - 1],
          })
        end
      end
    else
      for i = math.max(1, #screen.days - range.n + 1), #screen.days do
        local d = screen.days[i]
        local label = d.label .. " " .. string.sub(d.d, 9, 10)
        table.insert(bars, {
          sec = d.sec,
          by = scope and scope.buckets and scope.buckets[d.d] or d.by,
          tip = label .. " · " .. fmtDur(d.sec),
          label = label,
          key = d.d,
          top = tostring(tonumber(string.sub(d.d, 9, 10))),
          sub = d.label,
          today = (i == #screen.days),
        })
      end
    end

    local maxSec, peakIdx = 0, 0
    local selectedBar = nil
    for i, b in ipairs(bars) do
      if b.sec > maxSec then
        maxSec = b.sec
        peakIdx = i
      end
      if b.key == screenSel then
        selectedBar = b
      end
    end
    if selectedBar ~= nil then
      sums, total = selectedBar.by, selectedBar.sec
    end

    -- 3. hero number + one supporting stat
    local statLabel, statValue
    if hourly then
      statLabel, statValue = "peak hour", (peakIdx > 0) and bars[peakIdx].name or "–"
    else
      statLabel, statValue = "daily avg", fmtDur(total / range.n)
    end
    local heroLabel = "total · " .. (dayLabel or string.lower(range.label))
    if selectedBar ~= nil then
      local n = 0
      for id, v in pairs(sums) do
        if id ~= "_other" and v > 0 then
          n = n + 1
        end
      end
      statLabel, statValue = "apps used", tostring(n)
      heroLabel = "total · " .. selectedBar.label
    end
    table.insert(rows, ui.row({ align = "end", gap = 8 }, {
      ui.column({ gap = 0 }, {
        ui.label({
          text = fmtDur(total), height = not screenFocus and (HERO_FS + 6) or nil,
          fontSize = HERO_FS, fontWeight = "bold", color = "on_surface",
        }),
        ui.label({ text = heroLabel, height = not screenFocus and 14 or nil, fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.spacer({ flexGrow = 1 }),
      ui.column({ gap = 0, align = "end" }, {
        ui.label({
          text = statValue, height = not screenFocus and 20 or nil, fontSize = 15,
          fontWeight = "bold", color = "on_surface", textAlign = "right",
        }),
        ui.label({
          text = statLabel, height = not screenFocus and 14 or nil,
          fontSize = 11, color = "on_surface_variant", textAlign = "right",
        }),
      }),
    }))

    -- 4. chart + aligned axis
    if #bars > 0 then
      local inset = screenFocus and 14 or 8
      local labelGap = screenFocus and 12 or 6
      local plotWidth = math.max(1, innerW - inset * 2)
      local gap = plotWidth < 240 and 2 or ((#bars > 14) and 3 or 4)
      local width = math.max(1, math.min(48, math.floor((plotWidth - (#bars - 1) * gap) / #bars)))
      local axisWidth = #bars * width + (#bars - 1) * gap
      local cols = {}
      for i, b in ipairs(bars) do
        local function selectBar()
          if not hourly then
            if screenFocus then animateView(3, 0.15) end
            screenHover = nil
            screenDay = b.key
            screenSel = nil
          elseif screenSel == b.key then
            screenSel = nil
          else
            screenSel = b.key
          end
          update()
        end
        local x = inset + (i - 1) * (width + gap) + width / 2
        table.insert(cols, bar(b, maxSec, width, "sb" .. i, b == selectedBar, selectBar, chartApps, colors, x))
      end
      local step = 1
      if hourly then
        step = 6
      elseif width < 30 then
        step = 2
      end
      model.chartIndex = #rows + 1
      table.insert(rows, ui.column({ paddingH = inset, paddingV = screenFocus and 7 or 5, align = "start" }, {
        ui.row({ width = axisWidth, gap = gap, align = "end" }, cols),
        ui.box({ width = axisWidth, height = 1, fill = "outline_variant/0.5" }),
        ui.box({ key = "axis-label-gap", width = 1, height = labelGap, fill = "surface/0" }),
        axisRow(bars, width, gap, step, not screenFocus),
      }))
      if screen.mixed and hourly and not chartOnly then
        table.insert(rows, ui.label({ text = "Hourly bars show apps", fontSize = 11, color = "on_surface_variant" }))
      end
    elseif detailDay ~= nil then
      table.insert(rows, screenMessage("No hourly data recorded for this day.", innerW))
    else
      table.insert(rows, screenMessage("No activity recorded for this range yet.", innerW))
    end

    if chartOnly then return model end

    -- 5. app list with matching chart colors
    local list = {}
    otherSec = sums["_other"] or 0
    if selectedBar ~= nil then
      listTitle = selectedBar.label .. " · apps used"
    elseif detailDay ~= nil then
      listTitle = dayLabel .. (screen.mixed and " · apps and sites" or " · apps used")
    elseif range.k == "today" then
      listTitle = screen.mixed and "Apps and sites today" or "Apps used today"
    else
      listTitle = (screen.mixed and "Apps and sites · " or "Apps used · ") .. string.lower(range.label)
        .. (screenFocus and "" or " (tap a bar to pick a day)")
    end
    local listApps = selectedBar ~= nil and hourlyApps or dailyApps
    for _, a in ipairs(listApps) do
      if (sums[a.id] or 0) > 0 then
        table.insert(list, { a = a, sec = sums[a.id] })
      end
    end
    table.sort(list, function(x, y)
      return x.sec > y.sec
    end)
    if #list > 0 then
      
      
      local top = math.max(list[1].sec, 1)
      for i = 1, #list do
        local e = list[i]
        local lead
        if e.a.icon ~= nil and e.a.icon ~= "" then
          lead = ui.image({ path = e.a.icon, width = 22, height = 22, fit = "contain" })
        else
          lead = ui.glyph({ name = "app-window", size = 20, color = "on_surface_variant" })
        end
        local canOpenSite = screenFocus and screen.sites ~= nil and e.a.domain ~= nil
        table.insert(listRows, ui.row({
          key = "usage-" .. e.a.id, gap = 10, align = "center",
          onClick = canOpenSite and function()
            openScreenSite(e.a.domain)
          end or nil,
        }, {
          lead,
          ui.column({ gap = 4, flexGrow = 1 }, {
            ui.row({ align = "center", gap = 6 }, {
              ui.box({ width = 8, height = 8, radius = 4, fill = colors[e.a.id] }),
              ui.label({ text = e.a.name, fontSize = 12, color = "on_surface", maxLines = 1, flexGrow = 1 }),
              ui.label({ text = fmtDur(e.sec) .. (screenFocus and ("  ·  " .. string.format("%d%%", math.floor(100 * e.sec / math.max(total, 1) + 0.5))) or ""), fontSize = 12, fontWeight = "bold", color = "on_surface" }),
            }),
            ui.progress({ progress = e.sec / top, fill = "primary/0.40", track = "surface_container_high", radius = 3, height = 4 }),
          }),
          canOpenSite and ui.glyph({ name = "chevron-right", size = 14, color = "on_surface_variant" }) or nil,
        }))
      end
    end
    if otherSec > 0 then
      table.insert(listRows, ui.row({ gap = 6, align = "center" }, {
        ui.box({ width = 8, height = 8, radius = 4, fill = OTHER_COLOR }),
        ui.label({ text = "Other apps", fontSize = 12, color = "on_surface_variant", flexGrow = 1 }),
        ui.label({ text = fmtDur(otherSec), fontSize = 12, color = "on_surface_variant" }),
      }))
    end
  end

  local apps = model.apps
  if listTitle ~= nil then
    table.insert(apps, ui.label({ text = listTitle, fontSize = 12, fontWeight = "bold", color = "on_surface_variant", maxLines = 1 }))
    if #listRows == 0 then
      table.insert(listRows, ui.label({ text = "Nothing recorded for this period.", fontSize = 12, color = "on_surface_variant" }))
    end
    table.insert(apps, ui.scroll({ gap = 8, flexGrow = 1 }, listRows))
    local hidden = otherSec
    if loadingMore and os.time() - loadingSince > 20 then
      loadingMore = false
    end
    if loadingMore then
      local dots = string.rep(".", os.time() % 3 + 1)
      table.insert(apps, ui.row({ gap = 8, align = "center", justify = "center", paddingV = 7 }, {
        ui.glyph({ name = "loader-2", size = 16, color = "primary" }),
        ui.label({ text = "Loading more apps" .. dots, fontSize = 12, color = "on_surface_variant" }),
      }))
    elseif hidden > 0 and not (screen ~= nil and screen.expanded) then
      table.insert(apps, ui.row({
        key = "more-apps",
        gap = 6,
        align = "center",
        justify = "center",
        paddingV = 7,
        radius = 10,
        fill = "surface_container_high",
        onClick = function()
          loadingMore = true
          loadingSince = os.time()
          noctalia.state.set("screen_more_req", noctalia.nowMs())
          update()
        end,
      }, {
        ui.glyph({ name = "chevron-down", size = 15, color = "primary" }),
        ui.label({ text = "Show more apps (+" .. fmtDur(hidden) .. " in smaller ones)", fontSize = 12, color = "on_surface" }),
      }))
    end
  end
  return model
end

local function toggleHighlight(id)
  stepHighlight()
  if highlight.id ~= id then
    resetHighlight()
    highlight.id = id
  end
  highlight.from = highlight.fraction
  highlight.target = 1 - highlight.target
  highlight.started = noctalia.nowMs()
  if stepHighlight() then layer.setNeedsFrameTick(true) end
  update()
end

local function highlightDetails(item, width)
  local history = item.history or {}
  local height = #history > 0 and 84 or 28
  local rows = {}
  if #history > 0 then
    local peak, active = history[1], 0
    for _, day in ipairs(history) do
      if day.sec >= peak.sec then peak = day end
      if day.sec > 0 then active = active + 1 end
    end

    local summary
    if highlightPeriod == 1 then
      local yesterday = history[#history - 1]
      summary = yesterday and yesterday.recorded and ("Yesterday · " .. fmtDur(yesterday.sec)) or "No screen time recorded yesterday"
    else
      summary = string.format("Peak %s · %s   ·   Used on %d of %d days",
        os.date("%a, %b %d", dateToTime(peak.date)), fmtDur(peak.sec), active, #history)
    end
    table.insert(rows, ui.label({
      key = "highlight-summary", text = summary, fontSize = 11, maxLines = 2, height = 30,
      color = "on_surface_variant",
    }))

    local bars = {}
    local gap = 3
    local barW = math.max(1, math.floor((width - 20 - (#history - 1) * gap) / #history))
    for _, day in ipairs(history) do
      local status = day.recorded and fmtDur(day.sec) or "No screen time recorded"
      table.insert(bars, ui.column({
        key = "highlight-day-" .. day.date, width = barW, height = 24, justify = "end",
        tooltip = os.date("%a, %b %d", dateToTime(day.date)) .. " · " .. status,
      }, {
        ui.box({
          width = barW, height = math.max(2, math.floor(24 * day.sec / math.max(1, peak.sec))),
          radius = 2, fill = day.sec > 0 and "primary" or "outline_variant",
        }),
      }))
    end
    table.insert(rows, ui.row({ gap = gap, align = "end" }, bars))
    table.insert(rows, ui.row({ gap = 4 }, {
      ui.label({
        text = os.date("%b %d", dateToTime(history[1].date)), fontSize = 11,
        color = "on_surface_variant", flexGrow = 1,
      }),
      ui.label({ text = "Today", fontSize = 11, color = "on_surface_variant" }),
    }))
  else
    table.insert(rows, ui.label({
      text = "Daily breakdown unavailable", fontSize = 11, color = "on_surface_variant",
    }))
  end

  if item.domain ~= nil then
    height = height + 34
    table.insert(rows, ui.row({}, {
      ui.button({
        key = "highlight-site-" .. item.id, text = "View site trend", glyph = "arrow-right",
        variant = "ghost", controlSize = "sm",
        onClick = function() openScreenSite(item.domain) end,
      }),
    }))
  end
  return ui.column({ height = height, paddingH = 10, paddingV = 3, gap = 4 }, rows), height
end

local function screenHighlights(width)
  local periods = screen.highlights
  if periods == nil or periods[highlightPeriod] == nil then
    return {}
  end
  local report = periods[highlightPeriod]
  local buttons = {}
  for i, label in ipairs({ "Today", "7 days", "14 days" }) do
    table.insert(buttons, ui.button({
      key = "highlight-period-" .. i,
      text = label, flexGrow = 1, controlSize = "sm",
      variant = highlightPeriod == i and "primary" or "ghost",
      onClick = function()
        if highlightPeriod ~= i then
          highlightPeriod = i
          resetHighlight()
          openScreenSite(nil)
        end
      end,
    }))
  end
  local rows = {
    sectionTitle("chart-bar", "Usage highlights", report.total > 0 and (fmtDur(report.total) .. " total") or nil),
    ui.row({ gap = 4, align = "center" }, buttons),
  }
  local items = report.items or {}
  if #items == 0 or report.total <= 0 then
    table.insert(rows, ui.label({ text = "No screen time recorded for this period.", fontSize = 12, color = "on_surface_variant" }))
    return rows
  end

  for i, item in ipairs(items) do
    local expanded = highlight.id == item.id and highlight.target == 1
    local label = (expanded and "Hide" or "Show") .. " details for " .. item.name
    local click = function() toggleHighlight(item.id) end
    local share = math.floor(100 * item.sec / report.total + 0.5)
    local icon = item.icon ~= nil and item.icon ~= ""
      and ui.image({ path = item.icon, width = 16, height = 16, fit = "contain" })
      or ui.glyph({ name = item.domain and "world" or "app-window", size = 16, color = "on_surface_variant" })
    local children = {
      ui.row({ key = "highlight-summary-" .. item.id, gap = 6, align = "center", paddingH = 8, onClick = click }, {
        ui.label({ text = tostring(i), minWidth = 12, fontSize = 11, color = "on_surface_variant" }),
        icon,
        ui.label({ text = item.name, maxLines = 1, flexGrow = 1, fontSize = 12, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = fmtDur(item.sec) .. " · " .. share .. "%", fontSize = 12, color = "on_surface_variant" }),
        ui.button({
          key = "highlight-toggle-" .. item.id, glyph = expanded and "chevron-up" or "chevron-down",
          tooltip = label, variant = "ghost", controlSize = "sm", onClick = click,
        }),
      }),
    }
    if highlight.id == item.id and highlight.fraction > 0 then
      local detail, height = highlightDetails(item, width)
      local visibleHeight = math.floor(height * highlight.fraction)
      if visibleHeight > 0 then
        table.insert(children, ui.column({ key = "highlight-details-" .. item.id, height = visibleHeight, clip = true }, { detail }))
      end
    end
    table.insert(rows, ui.column({
      key = "highlight-" .. item.id, radius = 8, clip = true, fill = "surface_container_high",
    }, children))
  end
  return rows
end

local function screenChart(innerW, chartIndex, rows, compact)
  local gap = compact and 6 or 10
  if chartIndex == nil then
    return ui.column({ gap = gap }, rows)
  end

  -- Reserve the same space with or without a readout so hovering cannot move the bars.
  local hover = screenHover
  local readout = ui.box({ width = 1, height = 22, fill = "surface/0" })
  if hover ~= nil then
    local width = math.min(176, math.max(1, innerW))
    local left = math.clamp(math.floor(hover.x - width / 2), 0, math.max(0, innerW - width))
    readout = ui.row({ height = 22, align = "center" }, {
      ui.box({ width = left, height = 1, fill = "surface/0" }),
      ui.row({ width = width, height = 22, paddingH = 6, gap = 6, align = "center",
        fill = "surface_container_high", radius = 6 }, {
        ui.box({ width = 8, height = 8, radius = 4, fill = hover.color }),
        ui.label({ text = hover.text, fontSize = 12, color = "on_surface", maxLines = 1, flexGrow = 1 }),
      }),
    })
  end

  local visibleRows = table.clone(rows)
  visibleRows[chartIndex] = ui.column({ gap = 3 }, { readout, rows[chartIndex] })
  return ui.column({ gap = gap }, visibleRows)
end

local function screenSiteTrend(width, trend, calendar)
  local before, count, peak = 0, 0, 1
  for i, sec in ipairs(trend.seconds) do
    if i < #calendar and calendar[i].recorded then
      before = before + sec
      count = count + 1
    end
    peak = math.max(peak, sec)
  end

  local today = #calendar
  local chartW = math.max(1, width - 20)
  local gap = chartW >= 290 and 5 or 3
  local barW = math.max(2, math.floor((chartW - (#calendar - 1) * gap) / #calendar))
  local bars = {}
  for i, day in ipairs(calendar) do
    local sec = trend.seconds[i] or 0
    local fill = not day.recorded and "surface_container"
      or (i == today and "primary" or (sec > 0 and "primary/0.6" or "surface_container_high"))
    table.insert(bars, ui.column({
      key = "site-day-" .. day.date, width = barW, height = 62, justify = "end",
      onHover = function(entered)
        if entered == "true" and screenSiteDay ~= i then
          screenSiteDay = i
          update()
        elseif entered == "false" and screenSiteDay == i then
          screenSiteDay = nil
          update()
        end
      end,
    }, { ui.box({ width = barW, height = math.max(3, math.floor(58 * sec / peak)), radius = 3, fill = fill }) }))
  end

  local point = screenSiteDay and calendar[screenSiteDay]
  local label = "Daily time recorded by Brave"
  if point ~= nil then
    local day = os.date("%b %d", dateToTime(point.date))
    label = day .. " · " .. (point.recorded and fmtDur(trend.seconds[screenSiteDay]) or "No browser data")
  end
  local heading = ui.row({ gap = 6, align = "center" }, {
    ui.button({
      key = "close-site-trend", glyph = "arrow-left", text = "Back", variant = "ghost", controlSize = "sm",
      onClick = function() openScreenSite(nil) end,
    }),
    siteIcon(trend.icon, 16),
    ui.label({ text = trend.name or screenSite, fontSize = 13, fontWeight = "bold", maxLines = 1, flexGrow = 1, color = "on_surface" }),
  })
  local stats = ui.row({ gap = 14, align = "start" }, {
    stat(calendar[today].recorded and fmtDur(trend.seconds[today]) or "–", "Today"),
    stat(count > 0 and fmtDur(math.floor(before / count + 0.5)) or "–", "Prior daily average"),
  })
  local first = os.date("%b %d", dateToTime(calendar[1].date))
  return { heading, ui.scroll({ flexGrow = 1, gap = 8 }, {
    stats,
    ui.label({
      text = count > 0 and ("Average across " .. count .. (count == 1 and " day" or " days") .. " with browser data")
        or "The average appears after another day is recorded.",
      fontSize = 11, maxLines = 2, color = "on_surface_variant",
    }),
    ui.column({ paddingH = 6, paddingV = 6, gap = 8 }, {
      ui.label({ text = label, fontSize = 12, maxLines = 1, color = "on_surface_variant" }),
      ui.row({ width = #calendar * barW + (#calendar - 1) * gap, gap = gap, align = "end" }, bars),
      ui.row({ gap = 4, align = "center" }, {
        ui.label({ text = first, fontSize = 11, color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = "Today", fontSize = 11, color = "on_surface_variant" }),
      }),
    }),
  }) }
end

local function activeSiteTrend(width)
  local data = screen.sites
  local trend = screenSite and data and data.trends and data.trends[screenSite]
  if trend ~= nil and data.calendar ~= nil and #data.calendar > 0 then
    return screenSiteTrend(width, trend, data.calendar)
  end
  return nil
end

local function screenTab(id, text, active)
  return ui.button({
    key = "screen-tab-" .. id, text = text, controlSize = "sm", variant = active and "primary" or "ghost",
    onClick = function()
      if screenDetailsTab ~= id then
        screenDetailsTab = id
        animateView(3, 0.15)
        openScreenSite(nil)
      end
    end,
  })
end

local function renderScreenCard(innerW, model, sidebarWidth)
  local inGrid = maximizedCard ~= "screen"
  local chart = screenChart(innerW, model.chartIndex, model.rows, inGrid)
  local children = { model.title }
  if inGrid or #model.apps == 0 then
    table.insert(children, chart)
    for _, node in ipairs(model.apps) do
      table.insert(children, node)
    end
    local compact = inGrid or CHART_H < 84
    return card({ flexGrow = 1, padding = compact and 10 or 16, gap = compact and 6 or 10 }, children)
  end

  local highlights = screenHighlights(sidebarWidth and (sidebarWidth - 18) or innerW)
  local siteDetail = activeSiteTrend(sidebarWidth and (sidebarWidth - 24) or (innerW - 4))
  if sidebarWidth ~= nil then
    local sidebar = {}
    if #highlights > 0 then
      table.insert(sidebar, card({ padding = 8, gap = 5 }, highlights))
    end
    table.insert(sidebar, card({ flexGrow = 1, padding = 10, gap = 6 }, siteDetail or model.apps))
    table.insert(children, ui.row({ flexGrow = 1, gap = 10 }, {
      ui.column({ width = innerW + 24, clip = true }, { card({ flexGrow = 1, padding = 12, gap = 8 }, { chart }) }),
      ui.column({ width = sidebarWidth, gap = 8 }, sidebar),
    }))
  else
    table.insert(children, chart)
    local showHighlights = screenDetailsTab == "highlights" and #highlights > 0
    if siteDetail ~= nil then
      for _, node in ipairs(siteDetail) do
        table.insert(children, node)
      end
    else
      if #highlights > 0 then
        table.insert(children, ui.row({ gap = 6 }, {
          screenTab("apps", "Apps", not showHighlights),
          screenTab("highlights", "Highlights", showHighlights),
        }))
      end
      if showHighlights then
        table.insert(children, ui.scroll({ gap = 5, flexGrow = 1 }, highlights))
      else
        for _, node in ipairs(model.apps) do
          table.insert(children, node)
        end
      end
    end
  end
  return card({ flexGrow = 1, padding = 12, gap = 8 }, children)
end




------------------------------------------------------------------ system

------------------------------------------------------------------ CPU governor (needs /usr/local/bin/set-governor + sudoers rule)

local GOV_DIR = "/sys/devices/system/cpu/cpu0/cpufreq/"
local govList
local govCurrent
local govBusy = false
local nextGovernorRead = 0

local function readGovernor()
  local raw = noctalia.readFile(GOV_DIR .. "scaling_governor")
  return raw and noctalia.string.trim(raw) or nil
end

local function setGovernor(mode)
  if govBusy then return end
  govBusy = true
  local started = noctalia.runAsync({ "sudo", "-n", "/usr/local/bin/set-governor", mode }, function(result)
    govBusy = false
    govCurrent = readGovernor() or govCurrent
    nextGovernorRead = noctalia.nowMs() + 5000
    if result.exitCode ~= 0 then
      noctalia.notifyError("Dashboard", "Could not set governor: " .. tostring(result.stderr))
    elseif govCurrent ~= mode then
      noctalia.notifyError("Dashboard", "The CPU governor could not be confirmed.")
    end
    update()
  end)
  if not started then
    govBusy = false
    noctalia.notifyError("Dashboard", "Could not start the CPU governor helper.")
  end
  update()
end

local function governorButton(compact)
  if govList == nil then
    govList = {}
    local available = noctalia.readFile(GOV_DIR .. "scaling_available_governors") or ""
    for mode in string.gmatch(available, "%S+") do table.insert(govList, mode) end
  end
  if #govList == 0 then return nil end
  local now = noctalia.nowMs()
  if not govBusy and now >= nextGovernorRead then
    govCurrent = readGovernor() or govCurrent
    nextGovernorRead = now + 5000
  end
  local nextMode = govList[1]
  for i, mode in ipairs(govList) do
    if mode == govCurrent then
      nextMode = govList[i % #govList + 1]
      break
    end
  end
  local label = govBusy and "Switching…" or (govCurrent or "Unknown")
  return ui.button({
    key = "governor-cycle", glyph = "arrows-exchange", text = (compact and "" or "Governor · ") .. label,
    controlSize = "sm", variant = "ghost", enabled = not govBusy and #govList > 1,
    tooltip = #govList > 1 and ("CPU governor · next: " .. nextMode) or "Only one CPU governor is available",
    onClick = function()
      if #govList > 1 then setGovernor(nextMode) end
    end,
  })
end

local disk
local nextDiskRead = 0

local function systemDisk()
  local now = noctalia.nowMs()
  if now >= nextDiskRead then
    disk = noctalia.diskStats("/")
    nextDiskRead = now + 10000
  end
  return disk
end

local function monitorMessage()
  return ui.label({
    text = "System monitor is off. Enable [system.monitor] in your Noctalia config.",
    fontSize = 13, color = "on_surface_variant", maxLines = 3,
  })
end

local systemHistory = { cpu = {}, ram = {}, lastAt = 0 }

local function readSystemStats()
  local stats = noctalia.systemStats()
  if stats == nil then return nil end
  local now = noctalia.nowMs()
  if #systemHistory.cpu == 0 or now - systemHistory.lastAt >= 2000 then
    if now - systemHistory.lastAt > 5000 then
      table.clear(systemHistory.cpu)
      table.clear(systemHistory.ram)
    elseif #systemHistory.cpu >= 45 then
      table.remove(systemHistory.cpu, 1)
      table.remove(systemHistory.ram, 1)
    end
    systemHistory.lastAt = now
    table.insert(systemHistory.cpu, math.clamp(stats.cpu.usagePercent / 100, 0, 1))
    table.insert(systemHistory.ram, math.clamp(stats.ram.usagePercent / 100, 0, 1))
  end
  return stats
end

local function formatMemory(bytes)
  if bytes >= 1024 ^ 3 then return string.format("%.1f GiB", bytes / 1024 ^ 3) end
  return string.format("%.0f MiB", bytes / 1024 ^ 2)
end

local function systemUsageBar(percent, color)
  return ui.progress({
    progress = math.clamp(percent / 100, 0, 1),
    fill = percent >= 90 and "error" or color,
    track = "on_surface/0.12", height = 4, radius = 2,
  })
end

local function systemMetric(name, glyph, percent, color, width, tight)
  return ui.column({
    key = "system-summary-" .. name, width = width, padding = tight and 0 or 8,
    gap = 3, radius = 10, fill = tight and "surface/0" or "surface_container_high/0.65", clip = true,
  }, {
    ui.row({ gap = 5, height = 14, align = "center" }, {
      ui.glyph({ name = glyph, size = 13, color = color }),
      ui.label({ text = name, fontSize = 11, height = 14, baseline = "inkCentered", color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.label({
      text = string.format("%.0f%%", percent), height = tight and 23 or 27,
      fontSize = tight and 20 or 23, fontWeight = "bold", baseline = "inkCentered", color = "on_surface",
    }),
    systemUsageBar(percent, color),
  })
end

local function systemCard(width, height)
  local stats = readSystemStats()
  local rows = { sectionTitle("cpu", "System", nil, nil, "system") }
  local tight = height < 145
  local padH, padV, gap = 10, tight and 8 or 10, tight and 5 or 8
  local props = { flexGrow = 1, padding = 0, paddingH = padH, paddingV = padV, gap = gap, clip = true }
  if stats == nil then
    table.insert(rows, ui.label({
      text = "System monitor is off", height = 20, fontSize = 12, color = "on_surface_variant", maxLines = 1,
    }))
    return card(props, rows)
  end

  local storage = (width >= 338 or height >= 163) and systemDisk() or nil
  local inlineDisk = storage ~= nil and width >= 338
  local count = inlineDisk and 3 or 2
  local metricGap = 8
  local metricWidth = math.floor((width - padH * 2 - (count - 1) * metricGap) / count)
  local metrics = {
    systemMetric("CPU", "cpu", stats.cpu.usagePercent, "primary", metricWidth, tight),
    systemMetric("RAM", "device-desktop", stats.ram.usagePercent, "tertiary", metricWidth, tight),
  }
  if inlineDisk then
    table.insert(metrics, systemMetric("Disk", "device-floppy", storage.usagePercent, "secondary", metricWidth, tight))
  end
  table.insert(rows, ui.row({ key = "system-summary-metrics", gap = metricGap }, metrics))

  if storage ~= nil and not inlineDisk then
    local diskLabel = "System disk"
    if height >= 182 and storage.availableBytes ~= nil then
      diskLabel = formatMemory(storage.availableBytes) .. " free"
    end
    table.insert(rows, ui.column({ key = "system-summary-disk", gap = 4 }, {
      ui.row({ height = 16, gap = 6, align = "center" }, {
        ui.glyph({ name = "device-floppy", size = 13, color = "secondary" }),
        ui.label({ text = diskLabel, fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
        ui.label({ text = string.format("%.0f%% used", storage.usagePercent), fontSize = 11, color = "on_surface" }),
      }),
      systemUsageBar(storage.usagePercent, "secondary"),
    }))
  end

  if height >= 199 and stats.cpu.tempC ~= nil then
    local detail = string.format("%.0f°C CPU", stats.cpu.tempC)
    if stats.loadAvg and stats.loadAvg[1] ~= nil then
      detail = detail .. string.format(" · Load %.2f", stats.loadAvg[1])
    end
    table.insert(rows, ui.label({
      key = "system-summary-thermal", text = detail, height = 16,
      fontSize = 11, baseline = "inkCentered", color = "on_surface_variant", maxLines = 1,
    }))
  end
  if height >= 238 then
    local governor = governorButton(width < 240)
    if governor ~= nil then table.insert(rows, ui.row({ justify = "start" }, { governor })) end
  end
  return card(props, rows)
end

local systemView
local processSort = "cpu"

local function updateProcessList()
  if systemView == nil or systemView.session ~= systemSession then
    systemView = { session = systemSession, processesAt = 0 }
  end
  local view = systemView
  local now = noctalia.nowMs()
  if not view.busy and now >= view.processesAt then
    local dir = noctalia.pluginDir()
    view.processesAt = now + 4000
    if dir == nil or not noctalia.commandExists("python3") then
      view.error = "Process usage needs Python 3."
    else
      view.busy = true
      local started = noctalia.runAsync({ "python3", dir .. "/processusage.py" }, function(result)
        if maximizedCard ~= "system" or systemSession ~= view.session then return end
        view.busy = false
        local data = result.exitCode == 0 and noctalia.json.decode(result.stdout) or nil
        if type(data) == "table" and type(data.cpu) == "table" and type(data.ram) == "table" then
          view.processes = data
          view.error = nil
        else
          view.processes = nil
          view.error = "Process usage is temporarily unavailable."
        end
        update()
      end)
      if not started then
        view.busy = false
        view.processes = nil
        view.error = "Process usage is temporarily unavailable."
      end
    end
  end
  return view
end

local systemPlots = {}

local function systemPlot(name, color, values, percent, width, height)
  local current = #values < 2 and percent or nil
  local plot = systemPlots[name]
  if plot ~= nil and plot.at == systemHistory.lastAt and plot.current == current
      and plot.width == width and plot.height == height then
    return plot.node
  end

  local segments = {}
  if current ~= nil then
    local y = math.floor((height - 2) * (1 - math.clamp(current / 100, 0, 1)))
    table.insert(segments, ui.box({ width = width, height = 2, translateY = y, radius = 1, fill = color }))
  else
    local dx = math.max(1, width - 2) / (#values - 1)
    for i = 2, #values do
      local y1 = 1 + (height - 2) * (1 - values[i - 1])
      local y2 = 1 + (height - 2) * (1 - values[i])
      local dy = y2 - y1
      local length = math.sqrt(dx * dx + dy * dy) + 1
      -- Anchor each segment in a one-pixel row and rotate it about its midpoint.
      table.insert(segments, ui.row({ height = 1, align = "start" }, {
        ui.box({
          width = length, height = 2, radius = 1, fill = color,
          translateX = 1 + dx * (i - 1.5) - length / 2,
          translateY = (y1 + y2) / 2 - i + 1,
          rotation = math.deg(math.atan(dy / dx)),
        }),
      }))
    end
  end
  local node = ui.column({ key = "system-plot-" .. name, width = width, height = height, clip = true }, segments)
  systemPlots[name] = {
    at = systemHistory.lastAt, current = current, width = width, height = height, node = node,
  }
  return node
end

local function resourceGraph(name, color, values, percent, detail, width, graphHeight)
  local plot = systemPlot(name, color, values, percent, math.max(1, width - 22), graphHeight)
  local kids = {
    ui.row({ height = 27, gap = 8, align = "center" }, {
      ui.label({ text = name, fontSize = 13, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.label({
        text = string.format("%.0f%%", percent), fontSize = 19, fontWeight = "bold", color = "on_surface",
      }),
    }),
    plot,
  }
  if detail ~= nil then
    table.insert(kids, ui.label({ text = detail, height = 16, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
  end
  return card({ width = width, padding = 10, gap = 5, clip = true }, kids)
end

local processIcons = {}
local processIconCount = 0
local processIconBudget = 0
local nextProcessIconLookup = 0

local function processIcon(name)
  local path = processIcons[name]
  if path == nil and processIconBudget > 0 and processIconCount < 96
      and not string.find(name, "/", 1, true) then
    processIconBudget = processIconBudget - 1
    processIconCount = processIconCount + 1
    path = noctalia.appIconPath(name, 24) or ""
    processIcons[name] = path
  end
  if path ~= nil and path ~= "" then
    return ui.image({ path = path, width = 18, height = 18, fit = "contain" })
  end
  return ui.glyph({ name = "app-window", size = 17, color = "on_surface_variant" })
end

local function processTable(view, compact)
  local now = noctalia.nowMs()
  if now >= nextProcessIconLookup then
    processIconBudget = 2
    nextProcessIconLookup = now + 1000
  end
  local columnWidth = compact and 65 or 92
  local function sortButton(key, title, tooltip)
    local selected = processSort == key
    return ui.button({
      key = "sort-processes-" .. key, width = columnWidth, height = 27,
      glyph = selected and "arrow-down" or "arrows-sort", text = title, variant = selected and "primary" or "ghost",
      tooltip = tooltip, onClick = function()
        processSort = key
        update()
      end,
    })
  end
  local heading = ui.row({ gap = 6, align = "center", height = 28, paddingH = 6 }, {
    ui.label({
      text = "Apps and processes", fontSize = 13, fontWeight = "bold", color = "on_surface",
      flexGrow = 1, maxLines = 1,
    }),
    sortButton("cpu", "CPU", "Sort by recent CPU usage across all cores"),
    sortButton("ram", "RAM", "Sort by resident memory. Shared pages may count more than once."),
  })
  local rows = {}
  for _, item in ipairs(view.processes and view.processes[processSort] or {}) do
    local name = item.name .. (item.count > 1 and ("  ×" .. item.count) or "")
    table.insert(rows, ui.row({
      key = "system-process-" .. item.name, height = 29, gap = 6, align = "center",
      paddingH = 6, radius = 7, fill = "surface_container_high/0.65",
    }, {
      ui.column({ width = 20, height = 20, align = "center", justify = "center" }, { processIcon(item.name) }),
      ui.label({ text = name, fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 1 }),
      ui.column({ width = columnWidth, align = "end" }, {
        ui.label({ text = string.format("%.1f%%", item.cpu), fontSize = 12, color = "on_surface_variant" }),
      }),
      ui.column({ width = columnWidth, align = "end" }, {
        ui.label({ text = formatMemory(item.rss), fontSize = 12, color = "on_surface_variant" }),
      }),
    }))
  end
  if #rows == 0 then
    table.insert(rows, ui.label({
      text = view.error or (view.busy and "Sampling process usage…" or "No processes reported"),
      fontSize = 12, color = "on_surface_variant", maxLines = 2,
    }))
  end
  return card({ key = "system-processes", flexGrow = 1, padding = 8, gap = 6, clip = true }, {
    heading,
    ui.scroll({ key = "system-process-list-" .. processSort, flexGrow = 1, gap = 4 }, rows),
  })
end

local function systemDetails(width, height)
  local governor = governorButton(width < 630)
  local title = sectionTitle("cpu", "System", nil, governor, "system")
  local stats = readSystemStats()
  if stats == nil then
    return card({ flexGrow = 1, padding = 12 }, { title, monitorMessage() })
  end

  local view = updateProcessList()
  local compact = width < 650 or height < 350
  local graphW = math.floor((width - 10) / 2)
  local graphH = math.clamp(math.floor((height - 172) * 0.36), 28, 140)
  local cpuDetail, ramDetail
  if not compact then
    if stats.cpu.tempC ~= nil then cpuDetail = string.format("%.0f°C", stats.cpu.tempC) end
    if stats.loadAvg and stats.loadAvg[1] ~= nil then
      local load = string.format("Load %.2f", stats.loadAvg[1])
      cpuDetail = cpuDetail and (cpuDetail .. " · " .. load) or load
    end
    if stats.ram.usedMb ~= nil and stats.ram.totalMb ~= nil then
      ramDetail = formatMemory(stats.ram.usedMb * 1024 ^ 2) .. " used of " .. formatMemory(stats.ram.totalMb * 1024 ^ 2)
    end
    cpuDetail = cpuDetail or " "
    ramDetail = ramDetail or " "
  end

  local kids = {
    title,
    ui.row({ gap = 10 }, {
      resourceGraph("CPU", "primary", systemHistory.cpu, stats.cpu.usagePercent, cpuDetail, graphW, graphH),
      resourceGraph("RAM", "tertiary", systemHistory.ram, stats.ram.usagePercent, ramDetail, width - 10 - graphW, graphH),
    }),
  }
  local storage = not compact and systemDisk() or nil
  if storage ~= nil then
    local detail = string.format("System disk · %.0f%% used", storage.usagePercent)
    if storage.availableBytes ~= nil then detail = detail .. " · " .. formatMemory(storage.availableBytes) .. " available" end
    table.insert(kids, ui.label({ text = detail, height = 18, fontSize = 12, color = "on_surface_variant", maxLines = 1 }))
  end
  table.insert(kids, processTable(view, compact))
  return ui.column({ width = width, height = height, gap = compact and 6 or 9 }, kids)
end


------------------------------------------------------------------ to-do (fully editable; done tasks stay, checked)

local inputGen = 0
local pendingText = ""

local function reloadTodo()
  todo = Todo.load(Todo.path())
  noctalia.state.set("todo", todo)
  update()
end

local function addTask(text)
  text = noctalia.string.trim(text or pendingText or "")
  if text == "" then
    return
  end
  local saved = Todo.mutate(Todo.path(), function(tasks)
    local numericId = false
    for _, t in ipairs(tasks) do
      if type(t.id) == "number" then
        numericId = true
        break
      end
    end
    local id = numericId and noctalia.nowMs() or tostring(noctalia.nowMs())
    table.insert(tasks, { id = id, text = text, priority = Todo.priorityValue(tasks, 2), done = false })
  end)
  if saved then
    pendingText = ""
    inputGen = inputGen + 1
    reloadTodo()
  end
end

local function toggleTask(ref)
  Todo.mutate(Todo.path(), function(tasks)
    local i = Todo.find(tasks, ref)
    if i ~= nil then
      tasks[i].done = not (tasks[i].done == true)
    end
  end)
  reloadTodo()
end

local function deleteTask(ref)
  Todo.mutate(Todo.path(), function(tasks)
    local i = Todo.find(tasks, ref)
    if i ~= nil then
      table.remove(tasks, i)
    end
  end)
  reloadTodo()
end

local function cyclePriority(ref)
  Todo.mutate(Todo.path(), function(tasks)
    local i = Todo.find(tasks, ref)
    if i ~= nil then
      local nextWeight = (Todo.weight(tasks[i].priority) % 3) + 1
      tasks[i].priority = Todo.priorityValue(tasks, nextWeight)
    end
  end)
  reloadTodo()
end

local PRIORITY_NAMES = { [0] = "No priority", "Low", "Medium", "High" }
local todoFilter = "open"

local function todoPriority(task)
  if task.done then return "on_surface_variant" end
  if task.pr >= 3 then return "error" end
  if task.pr == 2 then return "tertiary" end
  if task.pr == 1 then return "secondary" end
  return "on_surface_variant"
end

local function todoRow(task, expanded, wide)
  local priority = PRIORITY_NAMES[task.pr] or "Custom priority"
  local tone = todoPriority(task)
  local children = {
    ui.button({
      key = "task-check-" .. task.idx, glyph = task.done and "circle-check-filled" or "circle",
      glyphSize = 18, variant = "ghost", controlSize = "sm", width = 32,
      tooltip = task.done and "Mark as open" or "Complete task",
      onClick = function() toggleTask(task) end,
    }),
    ui.label({
      text = task.text, fontSize = 13, fontWeight = task.done and "normal" or "medium",
      color = task.done and "on_surface_variant" or "on_surface", maxLines = expanded and 2 or 1, flexGrow = 1,
    }),
  }
  if expanded then
    table.insert(children, ui.row({
      height = 32, gap = 4, paddingH = 6, align = "center", radius = 8,
      fill = "surface_container_high", tooltip = priority .. " · Click to change priority",
      onClick = function() cyclePriority(task) end,
    }, {
      ui.glyph({ name = "flag", size = 15, color = tone }),
      wide and ui.label({ text = priority, fontSize = 11, color = "on_surface_variant" }) or nil,
    }))
    table.insert(children, ui.button({
      key = "task-remove-" .. task.idx, glyph = "trash", variant = "ghost", controlSize = "sm",
      width = 32, tooltip = "Remove task", onClick = function() deleteTask(task) end,
    }))
  elseif task.pr >= 3 then
    table.insert(children, ui.glyph({ name = "flag", size = 14, color = tone }))
  end
  return ui.row({
    key = "task-" .. task.idx, height = expanded and 40 or 34, gap = 4, paddingH = 4,
    align = "center", radius = 8, fill = "surface_container_high/0.65",
  }, children)
end

local function quickTaskInput()
  return ui.row({ height = 32, gap = 4, align = "center" }, {
    ui.input({
      key = "todo-in-" .. inputGen, value = pendingText, placeholder = "Add a task…", height = 32, flexGrow = 1,
      onChange = function(value) pendingText = value end, onSubmit = addTask,
    }),
    ui.button({
      key = "todo-add", glyph = "plus", height = 32, width = 32, variant = "primary",
      tooltip = "Add task", onClick = function() addTask(pendingText) end,
    }),
  })
end

local function todoCard(width, height, expanded)
  local loaded = todo ~= nil and todo.ok
  local count = loaded and (todo.open .. " open") or nil
  local children = { sectionTitle("list-check", "To do", not expanded and count or nil, nil, "todo") }
  if expanded or height >= 149 then table.insert(children, quickTaskInput()) end

  local rows = {}
  if loaded then
    local wide = width >= 490
    if expanded then
      local function tab(id, text)
        local active = todoFilter == id
        return ui.button({
          key = "todo-tab-" .. id, text = text, controlSize = "sm",
          variant = active and "primary" or "ghost", glyph = active and "check" or "",
          onClick = function()
            todoFilter = id
            update()
          end,
        })
      end
      table.insert(children, ui.row({ height = 32, gap = 6 }, {
        tab("open", "Open (" .. todo.open .. ")"),
        tab("done", "Completed (" .. todo.done .. ")"),
      }))
      for _, task in ipairs(todo.items) do
        if task.done == (todoFilter == "done") then table.insert(rows, todoRow(task, true, wide)) end
      end
    else
      local open = {}
      for _, task in ipairs(todo.items) do
        if not task.done and (todo.nextTask == nil or task.idx ~= todo.nextTask.idx) then table.insert(open, task) end
      end
      table.sort(open, function(a, b)
        if a.pr ~= b.pr then return a.pr > b.pr end
        return a.idx < b.idx
      end)
      if todo.nextTask ~= nil then table.insert(open, 1, todo.nextTask) end
      for _, task in ipairs(open) do table.insert(rows, todoRow(task, false, false)) end
    end
  end
  local empty = todo == nil and "Loading…"
    or not loaded and "Add your first task"
    or expanded and todoFilter == "done" and "No completed tasks"
    or "All caught up"
  if #rows == 0 then
    table.insert(children, ui.label({ text = empty, height = 21, fontSize = 12, color = "on_surface_variant", maxLines = 1 }))
  elseif expanded or height >= 174 then
    table.insert(children, ui.scroll({ key = "todo-list-" .. (expanded and todoFilter or "grid"), gap = 5, flexGrow = 1 }, rows))
  else
    table.insert(children, rows[1])
  end
  return card({ flexGrow = 1, padding = 10, gap = expanded and 8 or 5, clip = true }, children)
end

------------------------------------------------------------------ header

local function avatarNode(size, border)
  local radius = math.floor(size / 2)
  if profile ~= nil and profile.avatar ~= nil and profile.avatar ~= "" then
    return ui.image({
      path = profile.avatar, width = size, height = size, radius = radius, fit = "cover",
      border = border, borderWidth = 2,
    })
  end
  local name = profile and profile.name or ""
  local initial = name ~= "" and string.upper(string.sub(name, 1, 1)) or "?"
  return ui.column({
    width = size, height = size, radius = radius,
    fill = "primary_container", border = border, borderWidth = 2,
    align = "center", justify = "center",
  }, {
    ui.label({ text = initial, fontSize = 24, fontWeight = "bold", color = "on_primary_container" }),
  })
end

local nextUpDir = noctalia.pluginDataDir()
local nextUpPath = nextUpDir and (nextUpDir .. "/next-up-mode")
local nextUpMode = nextUpPath and noctalia.readFile(nextUpPath) == "task" and "task" or "event"

local function chooseNextUp(mode)
  if nextUpMode == mode then return end
  nextUpMode = mode
  if nextUpPath then
    local temp = nextUpPath .. ".tmp"
    if not noctalia.writeFile(temp, mode) or not noctalia.renameFile(temp, nextUpPath) then
      noctalia.notifyError("Dashboard", "Could not remember the Next up mode.")
    end
  end
  update()
end

local function nextEventPreview()
  if events == nil or not events.synced then return "Calendar unavailable" end
  local now = noctalia.nowMs()
  local today = os.date("%Y-%m-%d")
  local upcoming, allDay
  for _, event in ipairs(events.items) do
    if event.endMs > now then
      if event.startMs >= now and (upcoming == nil or event.startMs < upcoming.startMs) then
        upcoming = event
      elseif event.allDay and event.startMs < now
          and os.date("%Y-%m-%d", math.floor(event.startMs / 1000)) == today then
        allDay = allDay or event
      end
    end
  end

  local event = upcoming or allDay
  if event == nil then return "Nothing upcoming" end
  local start = math.floor(event.startMs / 1000)
  local day = os.date("%Y-%m-%d", start)
  local dateLabel = day == today and "Today" or os.date("%a, %b %d", start)
  if day == os.date("%Y-%m-%d", os.time() + 86400) then dateLabel = "Tomorrow" end
  local timeLabel = event.allDay and "All day" or os.date("%H:%M", start)
  return event.title ~= "" and event.title or "Untitled event", dateLabel .. " · " .. timeLabel
end

local function nextTaskPreview()
  if todo == nil or not todo.ok then return "To-do list unavailable" end
  local task = todo.nextTask
  if task == nil then return "No open tasks" end
  return task.text, PRIORITY_NAMES[task.pr] or "Custom priority"
end

-- Bound header text to the space between the banner's vertical padding edges.
local function headerLabel(props)
  props.baseline = "inkCentered"
  props.maxLines = 1
  return ui.label(props)
end

local function nextUpPreview(foreground, secondary, width)
  local title, detail
  if nextUpMode == "task" then
    title, detail = nextTaskPreview()
  else
    title, detail = nextEventPreview()
  end
  local showingTask = nextUpMode == "task"
  local mode = showingTask and "event" or "task"
  local tooltip = showingTask and "Show next event" or "Show priority task"
  return ui.column({ key = "next-up", width = width, gap = 1, justify = "center", clip = true }, {
    ui.row({ gap = 5, align = "center" }, {
      headerLabel({ text = showingTask and "Priority task" or "Next event", height = 14, fontSize = 11, color = secondary }),
      ui.row({
        key = "next-up-swap", width = 24, height = 23, align = "center", justify = "center",
        tooltip = tooltip, onClick = function() chooseNextUp(mode) end,
      }, {
        ui.glyph({ name = "arrows-exchange", size = 15, color = secondary }),
      }),
    }),
    headerLabel({ key = "next-up-title", text = title, height = 17, fontSize = 13, fontWeight = "bold", color = foreground }),
    headerLabel({ key = "next-up-detail", text = detail or "", height = 14, fontSize = 11, color = secondary }),
  })
end

local function profileIdentity(size, foreground, secondary, border, width)
  local stats = "Up " .. fmtUptime(uptimeSec)
  if screen ~= nil and screen.ok then stats = stats .. " · " .. fmtDur(screen.sec) .. " screen time" end
  return ui.row({
    key = "profile-identity", width = width, flexGrow = width == nil and 1 or 0,
    gap = 10, align = "center", clip = true,
  }, {
    avatarNode(size, border),
    ui.column({ gap = 1, flexGrow = 1, justify = "center", clip = true }, {
      headerLabel({ text = greeting() .. ",", height = 13, fontSize = 11, color = secondary }),
      headerLabel({
        text = profile and profile.name or "", height = size >= 50 and 28 or 24,
        fontSize = size >= 50 and 23 or 20, fontWeight = "bold", color = foreground,
      }),
      headerLabel({ key = "profile-stats", text = stats, height = 13, fontSize = 11, color = secondary }),
    }),
  })
end

-- WMO weather codes used in the shell's Open-Meteo cache.
local weatherConditions = {
  [0] = "clear", [1] = "clear", [2] = "partly", [3] = "cloudy",
  [45] = "fog", [48] = "fog",
  [51] = "drizzle", [53] = "drizzle", [55] = "drizzle", [56] = "ice", [57] = "ice",
  [61] = "rain", [63] = "rain", [65] = "rain", [66] = "ice", [67] = "ice",
  [71] = "snow", [73] = "snow", [75] = "snow", [77] = "snow",
  [80] = "showers", [81] = "showers", [82] = "showers", [85] = "snow", [86] = "snow",
  [95] = "storm", [96] = "storm", [97] = "storm", [99] = "storm",
}
local weatherStyles = {
  clear = { "sun", "Clear", "moon" },
  partly = { "cloud-sun", "Partly cloudy", "cloud-moon" },
  cloudy = { "cloud", "Overcast" },
  fog = { "cloud-fog", "Fog" },
  drizzle = { "cloud-rain", "Drizzle" },
  ice = { "cloud-snow", "Freezing rain" },
  rain = { "cloud-rain", "Rain" },
  showers = { "cloud-rain", "Showers" },
  snow = { "cloud-snow", "Snow" },
  storm = { "cloud-storm", "Thunderstorms" },
}

local function currentWeather(foreground, secondary, accent, detailed)
  local style = weatherStyles[weatherConditions[weather.code]]
  local glyph = style and (not weather.day and style[3] or style[1]) or "cloud"
  local readings = {
    headerLabel({
      key = "weather-temperature", text = weather.temperature .. "°" .. weather.unit,
      height = detailed and 27 or 22, fontSize = detailed and 22 or 17, fontWeight = "bold", color = foreground,
    }),
  }
  if detailed then
    local detail = style and style[2]
    if weather.low ~= nil and weather.high ~= nil then
      local range = weather.low .. "° / " .. weather.high .. "°"
      detail = detail and (detail .. " · " .. range) or range
    end
    if detail ~= nil then
      table.insert(readings, headerLabel({
        key = "weather-conditions", text = detail, height = 14, fontSize = 11, color = secondary,
      }))
    end
    if weather.city ~= nil then
      table.insert(readings, headerLabel({
        key = "weather-city", text = weather.city, height = 14, fontSize = 11, color = secondary,
      }))
    end
  end
  return ui.row({ key = "header-weather", width = detailed and 190 or 88, gap = 7, align = "center" }, {
    ui.glyph({ name = glyph, size = detailed and 30 or 22, color = accent }),
    ui.column({ flexGrow = 1, gap = 1, justify = "center", clip = true }, readings),
  })
end

local function header(width, height, monitor, stacked)
  local wallpaper = monitor and noctalia.wallpaperPath(monitor)
  local hasWallpaper = type(wallpaper) == "string" and wallpaper ~= ""
  local radius = 17
  local paddingH = stacked and 12 or (width >= 960 and 20 or 16)
  local paddingV = height >= 96 and 14 or 12
  if stacked then paddingV = height >= 144 and 12 or 8 end
  local foreground = hasWallpaper and "#ffffff" or "on_surface"
  local secondary = hasWallpaper and "#d4d9e3" or "on_surface_variant"
  local accent = hasWallpaper and "#e7ebf2" or "primary"
  local border = hasWallpaper and "#ffffff40" or "outline_variant"
  local gap = stacked and 8 or math.clamp(math.floor(width / 48), 14, 24)

  local showWeather = weather ~= nil and width >= 550
  local detailed = width >= 960
  local clockWidth = stacked and 92 or 123
  local showDate = width >= 390
  local clock = {
    headerLabel({
      key = "header-time", text = os.date("%H:%M"), height = stacked and 33 or 41,
      fontSize = stacked and 28 or 36, fontWeight = "bold", color = foreground, textAlign = "right",
    }),
  }
  if showDate then
    table.insert(clock, headerLabel({
      key = "header-date", text = os.date(stacked and "%a, %b %d" or "%A, %B %d"),
      height = 14, fontSize = stacked and 10 or 11, color = secondary, textAlign = "right", maxWidth = clockWidth,
    }))
  end
  local clockColumn = ui.column({ width = clockWidth, gap = 2, align = "end", justify = "center" }, clock)
  local closeButton = ui.button({
    key = "close-dashboard", width = 32, glyph = "x", variant = "ghost",
    controlSize = "sm", tooltip = "Close", onClick = closeDash,
  })

  local available = width - 2 * paddingH
  local identityWidth = not stacked and math.floor(available * 0.32) or nil
  local avatarSize = stacked and 44 or math.min(58, height - 2 * paddingV)
  local identity = profileIdentity(avatarSize, foreground, secondary, border, identityWidth)
  local weatherWidth = showWeather and ((detailed and 190 or 88) + gap) or 0
  local previewWidth = stacked and available or (available - identityWidth - clockWidth - 32 - weatherWidth - 1 - 4 * gap)
  local preview = nextUpPreview(foreground, secondary, math.max(1, previewWidth))
  local row = { identity }
  if not stacked then
    table.insert(row, ui.box({ width = 1, height = 36, fill = border }))
    table.insert(row, preview)
  end
  if showWeather then table.insert(row, currentWeather(foreground, secondary, accent, detailed)) end
  table.insert(row, clockColumn)
  table.insert(row, closeButton)

  local layers = {}
  local lift = hasWallpaper and -2 * height or 0
  if hasWallpaper then
    table.insert(layers, ui.image({
      key = "profile-wallpaper", path = wallpaper, width = width, height = height,
      fit = "cover", radius = radius, opacity = 0.38,
    }))
    table.insert(layers, ui.image({
      key = "header-fade", path = "assets/header-fade.png", width = width, height = height,
      fit = "stretch", radius = radius, translateY = -height,
    }))
  end

  if stacked then
    table.insert(layers, ui.column({
      key = "profile-content", height = height, translateY = lift,
      paddingH = paddingH, paddingV = paddingV, gap = 5, justify = "center",
    }, {
      ui.row({ height = 52, gap = gap, align = "center" }, row),
      ui.box({ height = 1, fill = border }),
      preview,
    }))
  else
    table.insert(layers, ui.row({
      key = "profile-content", height = height, translateY = lift,
      paddingH = paddingH, paddingV = paddingV, gap = gap, align = "center",
    }, row))
  end
  return ui.column({
    key = "dashboard-header", width = width, height = height, radius = radius, clip = true,
    fill = hasWallpaper and "#10141b" or "surface_container",
  }, layers)
end

local function footer()
  local editButton
  if maximizedCard == nil then
    editButton = ui.button({
      key = "edit-layout",
      text = "Edit layout",
      glyph = "layout-dashboard",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        if activeGrid ~= nil then
          noctalia.state.set("grid_editor_context", {
            monitor = activeGrid.monitor, width = activeGrid.width, height = activeGrid.height,
            placed = activeGrid.placed,
          })
          noctalia.togglePanel("lat/dashboard:layout")
        end
      end,
    })
  end
  local actions = {
    ui.button({
      text = "GitHub profile",
      glyph = "brand-github",
      variant = "ghost",
      controlSize = "sm",
      onClick = function() openUrl("https://github.com/" .. tostring(noctalia.getConfig("github_user"))) end,
    }),
    ui.spacer({ flexGrow = 1 }),
  }
  if editButton ~= nil then
    table.insert(actions, editButton)
  end
  table.insert(actions, ui.button({ text = "Refresh", glyph = "refresh", variant = "ghost", controlSize = "sm", onClick = refresh }))
  return ui.row({ gap = 8, align = "center" }, actions)
end

------------------------------------------------------------------ layout

local function outputGeometry()
  local name = layer.outputName()
  for _, o in ipairs(noctalia.outputs()) do
    if (name == nil and o.focused) or o.name == name then
      return o
    end
  end
  return nil
end

local function renderLayout(anim)
  local c = layoutCache
  local shift, fade = 0, 1
  if viewMotion ~= nil then
    local remaining = 1 - easeOut(noctalia.nowMs() - viewMotion.start, 165 * motionScale)
    shift = viewMotion.distance * remaining
    fade = 1 - viewMotion.fade * remaining
    if remaining == 0 then viewMotion = nil end
  end
  local viewport = ui.column({ key = "dashboard-viewport", height = c.bodyHeight, clip = true }, {
    ui.column({ flexGrow = 1, translateY = shift, opacity = fade }, { c.kids[3] }),
  })
  layer.render(ui.column({
    fill = string.format("scrim/%.2f", 0.55 * anim),
    flexGrow = 1,
    align = "center",
    justify = "center",
    onClick = closeDash,
  }, {
    ui.column({
      opacity = anim,
      translateY = 10 * (1 - anim),
      scale = 0.992 + 0.008 * anim,
      width = c.w,
      height = c.h,
      fill = "surface",
      radius = 26,
      padding = c.pad,
      gap = c.gap,
      border = "outline_variant",
      borderWidth = 1,
      onClick = function() end,
    }, { c.kids[1], c.kids[2], viewport, c.kids[4] }),
  }))
end

local agendaCache, screenCache, todoCache

local function cachedAgendaCard(width, height)
  local today = os.date("%Y-%m-%d")
  local expanded = maximizedCard == "calendar"
  local day = expanded and (calendarSelection or today) or today
  if agendaCache == nil or agendaCache.events ~= events or agendaCache.today ~= today or agendaCache.day ~= day
      or agendaCache.expanded ~= expanded or agendaCache.width ~= width or agendaCache.height ~= height
      or agendaCache.pane ~= calendarPane then
    agendaCache = {
      events = events, today = today, day = day, expanded = expanded, width = width, height = height, pane = calendarPane,
      node = expanded and calendarDetails(width, height, today, day) or todayCalendar(today, height),
    }
  end
  return agendaCache.node
end

local function cachedScreenCard(innerW, sidebarWidth, chartOnly)
  local screenFocus = maximizedCard == "screen"
  if loadingMore then
    -- The loading indicator and its timeout depend on the clock.
    screenCache = nil
    return renderScreenCard(innerW, screenCard(innerW, chartOnly), sidebarWidth)
  end
  local c = screenCache
  if c == nil or c.screen ~= screen or c.width ~= innerW or c.height ~= CHART_H
      or c.range ~= screenRange or c.day ~= screenDay or c.selection ~= screenSel or c.focus ~= screenFocus
      or c.chartOnly ~= chartOnly or c.heroSize ~= HERO_FS then
    c = {
      screen = screen, width = innerW, height = CHART_H,
      range = screenRange, day = screenDay, selection = screenSel, focus = screenFocus,
      chartOnly = chartOnly, heroSize = HERO_FS, model = screenCard(innerW, chartOnly),
    }
    screenCache = c
  end
  if c.node == nil or c.hover ~= screenHover or c.sidebarWidth ~= sidebarWidth or c.tab ~= screenDetailsTab
      or c.site ~= screenSite or c.siteDay ~= screenSiteDay or c.highlightPeriod ~= highlightPeriod
      or c.highlightId ~= highlight.id or c.highlightTarget ~= highlight.target or c.highlightFraction ~= highlight.fraction then
    c.hover = screenHover
    c.sidebarWidth = sidebarWidth
    c.tab = screenDetailsTab
    c.site = screenSite
    c.siteDay = screenSiteDay
    c.highlightPeriod = highlightPeriod
    c.highlightId = highlight.id
    c.highlightTarget = highlight.target
    c.highlightFraction = highlight.fraction
    c.node = renderScreenCard(innerW, c.model, sidebarWidth)
  end
  return c.node
end

local function cachedTodoCard(width, height)
  local expanded = maximizedCard == "todo"
  local filter = expanded and todoFilter or nil
  if todoCache == nil or todoCache.todo ~= todo or todoCache.width ~= width or todoCache.height ~= height
      or todoCache.inputGen ~= inputGen or todoCache.expanded ~= expanded or todoCache.filter ~= filter then
    todoCache = {
      todo = todo, width = width, height = height, inputGen = inputGen, expanded = expanded, filter = filter,
      node = todoCard(width, height, expanded),
    }
  end
  return todoCache.node
end

local function summaryCard(id, value, detail)
  local info = Grid.cards[id]
  local kids = {
    sectionTitle(info.icon, info.title, nil, nil, id),
    ui.label({ text = value, height = 22, fontSize = 17, fontWeight = "bold", maxLines = 1, color = "on_surface" }),
  }
  if detail ~= nil then
    table.insert(kids, ui.label({ text = detail, height = 16, fontSize = 12, maxLines = 1, color = "on_surface_variant" }))
  end
  return card({ flexGrow = 1, padding = 10, gap = 4 }, kids)
end

-- Allow for controls, the hover readout, and two rows of axis labels before sizing the plot.
local SCREEN_CHART_CHROME = 244
local SCREEN_MIN_PLOT = 28
local SCREEN_APP_SPACE = 128

local function gridCard(id, w, h)
  if id == "github" then
    return githubCard(w, h)
  elseif id == "screen" then
    local plotSpace = h - SCREEN_CHART_CHROME
    if w < 256 or plotSpace < SCREEN_MIN_PLOT then
      local today = screen and screen.ok and screen.highlights and screen.highlights[1]
      local top = today and today.items and today.items[1]
      local value = screen and screen.ok and (fmtDur(screen.sec) .. " today") or "No data yet"
      return summaryCard(id, value, top and ("Top · " .. top.name) or nil)
    end
    local hasListSpace = plotSpace >= SCREEN_MIN_PLOT + SCREEN_APP_SPACE
    CHART_H = math.min(84, plotSpace - (hasListSpace and SCREEN_APP_SPACE or 0))
    HERO_FS = h >= 340 and 28 or 20
    return cachedScreenCard(w - 32, nil, not hasListSpace)
  elseif id == "todo" then
    return cachedTodoCard(w, h)
  elseif id == "calendar" then
    return cachedAgendaCard(w, h)
  elseif id == "notes" then
    return Notes.card(sectionTitle("note", "Sticky note", nil, nil, "notes"))
  end
  return systemCard(w, h)
end

local function launcher(placed, width)
  local buttons = {}
  for _, id in ipairs(Grid.ids) do
    if placed[id] == nil then
      local info = Grid.cards[id]
      table.insert(buttons, ui.button({
        key = "launch-" .. id, glyph = info.icon, text = width >= 560 and info.title or nil,
        variant = "ghost", controlSize = "sm",
        onClick = function()
          maximize(id)
        end,
      }))
    end
  end
  return ui.row({ key = "card-launcher", height = 32, gap = 4, align = "center" }, buttons)
end

local function legacyGrid()
  local old = Layout.load(compactGraph())
  if old == nil then
    return Grid.defaults()
  end
  local migrated = {}
  local weights = { github = 5, screen = 7, calendar = 6, todo = 6, system = 5 }
  for index, side in ipairs({ "left", "right" }) do
    local ids = {}
    for _, id in ipairs(old[side]) do
      if not old.hidden[id] then
        table.insert(ids, id)
      end
    end
    local total = 0
    for _, id in ipairs(ids) do
      total = total + weights[id]
    end
    local used = 0
    for _, id in ipairs(ids) do
      local y = math.floor(used * Grid.rows / total)
      used = used + weights[id]
      local bottom = math.floor(used * Grid.rows / total)
      local w = Grid.cols / 2
      migrated[id] = { x = (index - 1) * w, y = y, w = w, h = bottom - y }
    end
  end
  return migrated
end

local legacy = legacyGrid()

local function gridLayout(monitor, width, height)
  if activeGrid == nil or activeGrid.monitor ~= monitor or activeGrid.width ~= width or activeGrid.totalHeight ~= height then
    local preferred = profiles.monitors[monitor] or profiles.default or legacy
    local placed = Grid.reflow(preferred, width, height)
    if profiles.version == 1 then Grid.placeNewNotes(placed, width, height) end
    local showLauncher = false
    for _, id in ipairs(Grid.ids) do
      if placed[id] == nil then
        showLauncher = true
        break
      end
    end
    local canvasHeight = height
    if showLauncher then
      canvasHeight = math.max(0, height - 38)
      placed = Grid.reflow(preferred, width, canvasHeight)
      if profiles.version == 1 then Grid.placeNewNotes(placed, width, canvasHeight) end
    end
    activeGrid = { monitor = monitor, width = width, height = canvasHeight, totalHeight = height, placed = placed, launcher = showLauncher }
  end
  local nodes = {}
  for _, id in ipairs(Grid.ids) do
    local r = activeGrid.placed[id]
    if r ~= nil then
      local x, y, w, h = Grid.pixels(r, width, activeGrid.height, Grid.gap)
      table.insert(nodes, Grid.place(id, x, y - #nodes, w, h, gridCard(id, w, h)))
    end
  end
  local kids = { ui.column({ key = "card-grid", width = width, height = activeGrid.height, clip = true }, nodes) }
  if activeGrid.launcher then
    table.insert(kids, launcher(activeGrid.placed, width))
  end
  return ui.column({ width = width, height = height, gap = 6 }, kids)
end

function update()
  local g = outputGeometry()
  local scale = (g ~= nil and g.scale ~= nil and g.scale > 0) and g.scale or 1
  local logicalW = g ~= nil and (g.width / scale) or 1280
  local logicalH = g ~= nil and (g.height / scale) or 800

  local sizes = {
    compact = { w = 0.62, h = 0.72, maxW = 980, maxH = 660 },
    normal = { w = 0.74, h = 0.80, maxW = 1120, maxH = 720 },
    large = { w = 0.93, h = 0.92, maxW = 1360, maxH = 860 },
  }
  local sz = sizes[noctalia.getConfig("window_size")] or sizes.large
  local cardW = math.min(math.floor(logicalW * 0.96), math.max(640, math.min(sz.maxW, math.floor(logicalW * sz.w))))
  local cardH = math.min(math.floor(logicalH * 0.96), math.max(470, math.min(sz.maxH, math.floor(logicalH * sz.h))))

  local short = cardH < 760
  CHART_H = math.clamp(math.floor((cardH - 430) / 4), 32, 84)
  HERO_FS = short and 20 or 28
  local pad, colGap = 22, 14
  if short then
    pad, colGap = 14, 10
  end
  local width = cardW - pad * 2
  local stackProfile = width < 690
  local headerHeight = short and 84 or 96
  if stackProfile then headerHeight = cardH < 500 and 136 or 144 end
  local height = math.max(0, cardH - 2 * pad - 3 * colGap - headerHeight - 36)
  local monitor = layer.outputName() or (g and g.name) or "default"

  local body, screenBody
  if maximizedCard == "screen" then
    local sidebarWidth = width >= 900 and height >= 460 and math.floor((width - 34) * 0.35) or nil
    HERO_FS = short and 26 or 32
    if sidebarWidth ~= nil then
      CHART_H = math.clamp(height - 286, 80, 374)
    else
      CHART_H = math.clamp(math.floor((height - 230) * 0.40), 26, 100)
    end
    local innerW = sidebarWidth and (width - 58 - sidebarWidth) or (width - 24)
    screenBody = function() return cachedScreenCard(innerW, sidebarWidth) end
    body = screenBody()
  elseif maximizedCard == "calendar" then
    body = cachedAgendaCard(width, height)
  elseif maximizedCard == "todo" then
    body = cachedTodoCard(width, height)
  elseif maximizedCard == "system" then
    body = systemDetails(width, height)
  elseif maximizedCard == "notes" then
    body = Notes.details(width, sectionTitle("note", "Notes", nil, Notes.tools(), "notes"))
  elseif maximizedCard == "github" then
    body = githubDetails(width, height)
  else
    body = gridLayout(monitor, width, height)
  end

  local kids = {
    ui.column({ height = headerHeight }, { header(width, headerHeight, g and g.name or layer.outputName(), stackProfile) }),
    ui.separator({ thickness = 1, color = "outline_variant/0.5" }),
    body,
    ui.column({ height = 32 }, { footer() }),
  }
  layoutCache = {
    w = cardW, h = cardH, pad = pad, gap = colGap, bodyHeight = height, kids = kids, screenBody = screenBody,
  }
  renderLayout(animProgress())
end

function onFrameTick(_deltaMs)
  if not animStarted then
    animStarted = true
    animStart = noctalia.nowMs()
  end
  local anim = animProgress()
  if closeToken ~= 0 and anim <= 0 then
    layer.setNeedsFrameTick(false)
    noctalia.state.set("close_done", closeToken)
    return
  end
  local before = highlight.fraction
  local revealing = stepHighlight()
  if layoutCache.screenBody and before ~= highlight.fraction then
    layoutCache.kids[3] = layoutCache.screenBody()
  end
  renderLayout(anim)
  if closeToken == 0 and anim >= 1 and not revealing and viewMotion == nil then
    layer.setNeedsFrameTick(false)
  end
end

update()

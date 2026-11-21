--!nonstrict
-- lat/dashboard layer: full-screen overlay drawn with Noctalia palette roles only.

noctalia.setUpdateInterval(1000)
noctalia.log("dashboard layer started")

local Todo = require("./lib/todo.luau")
local Layout = require("./lib/layout.luau")

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
local ghCommits = noctalia.state.get("gh_commits")
noctalia.state.watch("gh_commits", function(v) ghCommits = v end)
noctalia.state.watch("gh_done", function(_) ghLoading = false end)

------------------------------------------------------------------ actions

-- Animate from the current opacity so an interrupted fade can reverse smoothly.
local ANIM_MS = 150
local animStart = noctalia.nowMs()
local animFrom = 0
local animStarted = false
local closeToken = 0
local layoutCache = nil
layer.setNeedsFrameTick(true)

local function animProgress()
  local target = closeToken == 0 and 1 or 0
  local duration = ANIM_MS * math.abs(target - animFrom)
  if duration == 0 then
    return target
  end
  local elapsed = animStarted and (noctalia.nowMs() - animStart) or 0
  local t = math.min(1, math.max(0, elapsed / duration))
  local eased = 1 - (1 - t) ^ 3
  return animFrom + (target - animFrom) * eased
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
local screenHover = nil
local githubFeed = "commits"
local ghRepos = noctalia.state.get("gh_repos")
noctalia.state.watch("gh_repos", function(v) ghRepos = v end)

local function maximize(id)
  maximizedCard = id
  screenHover = nil
  if id == "github" then
    githubFeed = "commits"
    noctalia.state.set("gh_repos_req", { at = noctalia.nowMs(), force = false })
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

local function chip(glyph, text, onClick)
  return ui.row({
    gap = 6,
    align = "center",
    paddingH = 12,
    paddingV = 7,
    radius = 16,
    fill = "surface_container_high",
    onClick = onClick,
  }, {
    ui.glyph({ name = glyph, size = 15, color = "primary" }),
    ui.label({ text = text, fontSize = 13, color = "on_surface" }),
  })
end

local function stat(value, caption)
  return ui.column({ gap = 2 }, {
    ui.label({ text = value, fontSize = 18, fontWeight = "bold", color = "on_surface" }),
    ui.label({ text = caption, fontSize = 11, color = "on_surface_variant" }),
  })
end

local function meter(name, pct)
  pct = math.max(0, math.min(100, pct or 0))
  local fill = "primary"
  if pct >= 90 then
    fill = "error"
  elseif pct >= 70 then
    fill = "tertiary"
  end
  return ui.row({ gap = 10, align = "center" }, {
    ui.label({ text = name, fontSize = 13, color = "on_surface_variant", minWidth = 44 }),
    ui.progress({
      progress = pct / 100,
      fill = fill,
      track = "surface_container_high",
      radius = 4,
      height = 8,
      flexGrow = 1,
    }),
    ui.label({ text = string.format("%d%%", math.floor(pct + 0.5)), fontSize = 13, color = "on_surface", minWidth = 40 }),
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
          githubFeed = id
          update()
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

local function dayTitle(key)
  if key == os.date("%Y-%m-%d") then
    return "Today"
  end
  if key == os.date("%Y-%m-%d", os.time() + 86400) then
    return "Tomorrow"
  end
  return os.date("%A", dateToTime(key))
end

local function dayHeader(key, count)
  local isToday = key == os.date("%Y-%m-%d")
  local t = dateToTime(key)
  local sub = count > 0 and (count .. (count == 1 and " event" or " events")) or "Nothing scheduled"
  return ui.row({ gap = 10, align = "center", paddingV = 2 }, {
    ui.column({
      width = 42,
      height = 42,
      radius = 12,
      fill = isToday and "primary" or "surface_container_high",
      align = "center",
      justify = "center",
      gap = 0,
    }, {
      ui.label({ text = string.upper(os.date("%a", t)), fontSize = 9, color = isToday and "on_primary" or "on_surface_variant" }),
      ui.label({ text = os.date("%d", t), fontSize = 16, fontWeight = "bold", color = isToday and "on_primary" or "on_surface" }),
    }),
    ui.column({ gap = 0 }, {
      ui.label({ text = dayTitle(key) .. " · " .. os.date("%B %d", t), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = sub, fontSize = 11, color = "on_surface_variant" }),
    }),
  })
end

local function eventRow(e, i)
  local startSec = math.floor(e.startMs / 1000)
  local endSec = math.floor(e.endMs / 1000)
  local timeText = e.allDay and "All day" or (os.date("%H:%M", startSec) .. "–" .. os.date("%H:%M", endSec))
  local dot = (e.color ~= nil and e.color ~= "") and e.color or "primary"
  local link = e.url or ""
  local titleCol = {
    ui.label({ text = e.title, fontSize = 13, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
  }
  if e.location ~= nil and e.location ~= "" then
    table.insert(titleCol, ui.label({ text = e.location, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
  end
  local children = {
    ui.label({ text = timeText, fontSize = 12, color = "on_surface_variant", minWidth = 84 }),
    ui.box({ width = 3, height = 28, radius = 2, fill = dot }),
    ui.column({ gap = 1, flexGrow = 1 }, titleCol),
  }
  if link ~= "" then
    table.insert(children, ui.glyph({ name = "video", size = 16, color = "primary" }))
  end
  return ui.row({
    key = "e" .. i,
    gap = 10,
    align = "center",
    paddingH = 8,
    paddingV = 4,
    radius = 10,
    fill = "surface_container_high/0.6",
    onClick = link ~= "" and function() openUrl(link) end or nil,
    tooltip = link ~= "" and "Open meeting link" or nil,
  }, children)
end

local function agendaCard()
  local rows = {}
  if events == nil or events.synced ~= true then
    table.insert(rows, ui.label({
      text = "Calendar not synced yet. Add an account in Settings → Calendar.",
      fontSize = 13,
      color = "on_surface_variant",
      maxLines = 3,
    }))
  else
    -- group by local date, keeping order
    local order, groups = {}, {}
    for i, e in ipairs(events.items) do
      local key = os.date("%Y-%m-%d", math.floor(e.startMs / 1000))
      if groups[key] == nil then
        groups[key] = {}
        table.insert(order, key)
      end
      table.insert(groups[key], { e = e, i = i })
    end
    local todayKey = os.date("%Y-%m-%d")
    if groups[todayKey] == nil then
      table.insert(order, 1, todayKey)
      groups[todayKey] = {}
    end
    for gi, key in ipairs(order) do
      if gi > 1 then
        table.insert(rows, ui.separator({ thickness = 1, color = "outline_variant/0.4", spacing = 6 }))
      end
      table.insert(rows, dayHeader(key, #groups[key]))
      for _, item in ipairs(groups[key]) do
        table.insert(rows, eventRow(item.e, item.i))
      end
    end
  end
  return card({ flexGrow = 1 }, {
    sectionTitle("calendar-event", "Calendar", "next 10 days", nil, "calendar"),
    ui.scroll({ gap = 6, flexGrow = 1 }, rows),
  })
end

------------------------------------------------------------------ screen time (mirrors Noctalia's own Screen Time tab)


local screenRange = "today" -- "today" | "3d" | "14d"
local screenDay = nil -- date opened from the 3-day or 14-day chart
local screenSel = nil -- date and hour of the selected hourly bar
local screenDetailsTab = "apps"
local RANGES = {
  { k = "today", label = "Today", n = 1 },
  { k = "3d", label = "3 days", n = 3 },
  { k = "14d", label = "14 days", n = 14 },
}

local CHART_H = 84
local AVATAR = 68
local HERO_FS = 28

local APP_COLORS = {
  "#6AA9F5", "#F3AD65", "#64C9A5", "#DB89CE", "#C7C96F", "#9A98ED",
  "#F4818D", "#6BC3DB", "#DBB895", "#89C475", "#BD9AF4", "#DF8C65",
}
local OTHER_COLOR = "outline_variant"

local function screenAppColors(apps)
  local colors, used = {}, {}
  for _, app in ipairs(apps) do
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
local function rangeToggle()
  local pills = {}
  for _, r in ipairs(RANGES) do
    local active = r.k == screenRange
    table.insert(pills, ui.row({
      key = "rg" .. r.k,
      flexGrow = 1,
      justify = "center",
      paddingV = 6,
      radius = 9,
      fill = active and "primary" or "surface_container_high/0",
      onClick = function()
        screenRange = r.k
        screenDay = nil
        screenSel = nil
        screenHover = nil
        update()
      end,
    }, {
      ui.label({
        text = r.label,
        fontSize = 12,
        fontWeight = active and "bold" or "normal",
        color = active and "on_primary" or "on_surface_variant",
      }),
    }))
  end
  return ui.row({ gap = 2, padding = 3, radius = 12, fill = "surface_container_high" }, pills)
end

local function screenMessage(text, innerW, color)
  return ui.label({ text = text, fontSize = 12, color = color or "on_surface_variant", maxLines = 4, maxWidth = innerW })
end



-- labels under the chart, each one sitting under the first bar of its group
local function axisRow(bars, width, gap, step)
  local cells = {}
  for i = 1, #bars, step do
    local b = bars[i]
    local barsInGroup = math.min(step, #bars - i + 1)
    local segW = barsInGroup * width + (barsInGroup - 1) * gap
    local lines = {
      ui.box({ width = 1, height = 4, fill = "outline_variant" }),
      ui.label({
        text = b.top or "",
        maxWidth = segW,
        fontSize = segW < 33 and 10 or 11,
        fontWeight = b.today and "bold" or "normal",
        color = b.today and "primary" or "on_surface",
        maxLines = 1,
      }),
    }
    if b.sub ~= nil and segW >= 20 then
      table.insert(lines, ui.label({
        text = b.sub,
        maxWidth = segW,
        fontSize = 10,
        color = b.today and "primary" or "on_surface_variant",
        maxLines = 1,
      }))
    end
    table.insert(cells, ui.column({ key = "ax" .. i, width = segW, gap = 4, align = "start", clip = true }, lines))
  end
  return ui.row({ gap = gap, align = "start" }, cells)
end

local function screenCard(innerW)
  local rows = {}
  local listRows = {}
  local listTitle = nil
  local otherSec = 0
  local screenFocus = maximizedCard == "screen"
  local controls
  local chartIndex

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
    local colors = screenAppColors(screen.apps)
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
          screenDay = nil
          screenSel = nil
          screenHover = nil
          update()
        end,
      })
    else
      controls = rangeToggle()
    end
    table.insert(rows, controls)

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
          by = d.by,
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
        ui.label({ text = fmtDur(total), fontSize = HERO_FS, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = heroLabel, fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.spacer({ flexGrow = 1 }),
      ui.column({ gap = 0, align = "end" }, {
        ui.label({ text = statValue, fontSize = 15, fontWeight = "bold", color = "on_surface", textAlign = "right" }),
        ui.label({ text = statLabel, fontSize = 11, color = "on_surface_variant", textAlign = "right" }),
      }),
    }))

    -- 4. chart + aligned axis
    if #bars > 0 then
      local inset = screenFocus and 14 or 8
      local labelGap = screenFocus and 12 or 8
      local plotWidth = math.max(1, innerW - inset * 2)
      local gap = plotWidth < 240 and 2 or ((#bars > 14) and 3 or 4)
      local width = math.max(1, math.min(48, math.floor((plotWidth - (#bars - 1) * gap) / #bars)))
      local axisWidth = #bars * width + (#bars - 1) * gap
      local cols = {}
      for i, b in ipairs(bars) do
        local function selectBar()
          if not hourly then
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
        table.insert(cols, bar(b, maxSec, width, "sb" .. i, b == selectedBar, selectBar, screen.apps, colors, x))
      end
      local step = 1
      if hourly then
        step = 6
      elseif width < 30 then
        step = 2
      end
      chartIndex = #rows + 1
      table.insert(rows, ui.column({ paddingH = inset, paddingV = 7, align = "start" }, {
        ui.row({ width = axisWidth, gap = gap, align = "end" }, cols),
        ui.box({ width = axisWidth, height = 1, fill = "outline_variant/0.5" }),
        ui.box({ key = "axis-label-gap", width = 1, height = labelGap, fill = "surface/0" }),
        axisRow(bars, width, gap, step),
      }))
    elseif detailDay ~= nil then
      table.insert(rows, screenMessage("No hourly data recorded for this day.", innerW))
    else
      table.insert(rows, screenMessage("No activity recorded for this range yet.", innerW))
    end

    -- 5. app list with matching chart colors
    local list = {}
    otherSec = sums["_other"] or 0
    if selectedBar ~= nil then
      listTitle = selectedBar.label .. " · apps used"
    elseif detailDay ~= nil then
      listTitle = dayLabel .. " · apps used"
    elseif range.k == "today" then
      listTitle = "Apps used today"
    else
      listTitle = "Apps used · " .. string.lower(range.label) .. (screenFocus and "" or " (tap a bar to pick a day)")
    end
    for _, a in ipairs(screen.apps) do
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
        local brave = screenFocus and screen.sites ~= nil
          and string.find(string.lower(e.a.id), "brave", 1, true) ~= nil
        table.insert(listRows, ui.row({
          key = "sa" .. i, gap = 10, align = "center",
          onClick = brave and function()
            screenDetailsTab = "sites"
            update()
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
          brave and ui.glyph({ name = "chevron-right", size = 14, color = "on_surface_variant" }) or nil,
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

  local apps = {}
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
  return {
    title = sectionTitle("device-desktop", "Screen time", nil, nil, "screen"),
    rows = rows, chartIndex = chartIndex, apps = apps,
  }
end

local function screenHighlights()
  local cards = {}
  local labels = { "Today", "Last 7 days", "Last 14 days" }
  for i, stats in ipairs(screen.highlights or {}) do
    local children = { ui.label({ text = labels[i], fontSize = 11, color = "on_surface_variant" }) }
    if stats.total > 0 and stats.top ~= "" then
      table.insert(children, ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = stats.top, fontSize = 13, fontWeight = "bold", maxLines = 1, flexGrow = 1, color = "on_surface" }),
        ui.label({ text = fmtDur(stats.topSec) .. " · " .. math.floor(100 * stats.topSec / stats.total + 0.5) .. "%",
          fontSize = 12, maxLines = 1, color = "on_surface_variant" }),
      }))
      if stats.browserSec > 0 then
        table.insert(children, ui.label({
          text = math.floor(100 * stats.browserSec / stats.total + 0.5) .. "% browser time",
          fontSize = 11, maxLines = 1, color = "on_surface_variant",
        }))
        if stats.outside ~= "" then
          table.insert(children, ui.label({
            text = "Top outside browser · " .. stats.outside .. " " .. fmtDur(stats.outsideSec),
            fontSize = 11, maxLines = 1, color = "on_surface_variant",
          }))
        end
      end
    else
      table.insert(children, ui.label({ text = "No recorded activity", fontSize = 12, color = "on_surface_variant" }))
    end
    table.insert(cards, ui.column({ gap = 2, padding = 6, radius = 7, fill = "surface_container_high" }, children))
  end
  return cards
end

local function screenChart(innerW, chartIndex, rows)
  if chartIndex == nil then
    return ui.column({ gap = 10 }, rows)
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
  return ui.column({ gap = 10 }, visibleRows)
end

local function screenSites()
  local heading = "Sites today"
  local items = {}
  if screen.sites ~= nil then
    if screenDay ~= nil and screen.sites.days[screenDay] ~= nil then
      heading = "Sites · " .. os.date("%b %d", dateToTime(screenDay))
      items = screen.sites.days[screenDay]
    else
      if screenRange == "3d" then
        heading = "Sites · last 3 days"
      elseif screenRange == "14d" then
        heading = "Sites · last 14 days"
      end
      items = screen.sites.ranges[screenRange] or {}
    end
  end

  local rows = {}
  if #items == 0 then
    table.insert(rows, ui.label({
      text = screen.sites == nil and "Enable Dashboard Site Time in Brave to see site totals." or "No sites recorded for this period.",
      fontSize = 12, maxLines = 3, color = "on_surface_variant",
    }))
  end
  for _, item in ipairs(items) do
    table.insert(rows, ui.row({ key = "site-" .. item.domain, gap = 8, paddingH = 7, paddingV = 5,
      align = "center", radius = 7, fill = "surface_container_high" }, {
      item.icon ~= nil and item.icon ~= ""
        and ui.image({ path = item.icon, width = 16, height = 16, fit = "contain" })
        or ui.glyph({ name = "world", size = 16, color = "primary" }),
      ui.label({ text = item.domain, fontSize = 12, maxLines = 1, flexGrow = 1, color = "on_surface" }),
      ui.label({ text = fmtDur(item.sec), fontSize = 12, color = "on_surface_variant" }),
    }))
  end
  return {
    ui.label({ text = heading, fontSize = 12, fontWeight = "bold", color = "on_surface" }),
    ui.scroll({ gap = 5, flexGrow = 1 }, rows),
  }
end

local function screenTab(id, text, active)
  return ui.button({
    key = "screen-tab-" .. id, text = text, controlSize = "sm", variant = active and "primary" or "ghost",
    onClick = function()
      screenDetailsTab = id
      update()
    end,
  })
end

local function renderScreenCard(innerW, model, sidebarWidth)
  local chart = screenChart(innerW, model.chartIndex, model.rows)
  local children = { model.title }
  if maximizedCard ~= "screen" or #model.apps == 0 then
    table.insert(children, chart)
    for _, node in ipairs(model.apps) do
      table.insert(children, node)
    end
    return card({ flexGrow = 1, padding = CHART_H < 84 and 10 or 16, gap = CHART_H < 84 and 6 or 10 }, children)
  end

  local highlights = screenHighlights()
  if sidebarWidth ~= nil then
    local sidebar = {}
    if #highlights > 0 then
      table.insert(highlights, 1, sectionTitle("chart-bar", "Usage highlights"))
      table.insert(sidebar, card({ padding = 8, gap = 5 }, highlights))
    end
    local showSites = screenDetailsTab == "sites"
    local details = { ui.row({ gap = 6 }, { screenTab("apps", "Apps", not showSites), screenTab("sites", "Sites", showSites) }) }
    for _, node in ipairs(showSites and screenSites() or model.apps) do
      table.insert(details, node)
    end
    table.insert(sidebar, card({ flexGrow = 1, padding = 10, gap = 6 }, details))
    table.insert(children, ui.row({ flexGrow = 1, gap = 10 }, {
      ui.column({ width = innerW + 24, clip = true }, { card({ flexGrow = 1, padding = 12, gap = 8 }, { chart }) }),
      ui.column({ width = sidebarWidth, gap = 8 }, sidebar),
    }))
  else
    table.insert(children, chart)
    local showHighlights = screenDetailsTab == "highlights" and #highlights > 0
    local showSites = screenDetailsTab == "sites"
    local tabs = { screenTab("apps", "Apps", not showHighlights and not showSites), screenTab("sites", "Sites", showSites) }
    if #highlights > 0 then
      table.insert(tabs, screenTab("highlights", "Highlights", showHighlights))
    end
    table.insert(children, ui.row({ gap = 6 }, tabs))
    if showHighlights then
      table.insert(children, ui.scroll({ gap = 5, flexGrow = 1 }, highlights))
    else
      for _, node in ipairs(showSites and screenSites() or model.apps) do
        table.insert(children, node)
      end
    end
  end
  return card({ flexGrow = 1, padding = 12, gap = 8 }, children)
end




------------------------------------------------------------------ system

------------------------------------------------------------------ CPU governor (needs /usr/local/bin/set-governor + sudoers rule)

local GOV_DIR = "/sys/devices/system/cpu/cpu0/cpufreq/"
local govList = nil
local govCurrent = nil
local nextGovernorRead = 0
local GOV_TIPS = {
  performance = "Max clock speed, most power use",
  powersave = "Lowest clock speed, saves power",
  schedutil = "Scales with load (scheduler driven)",
  ondemand = "Jumps up fast under load",
  conservative = "Scales up and down gradually",
  userspace = "Speed set by a program",
}

local function readGovernors()
  local raw = noctalia.readFile(GOV_DIR .. "scaling_available_governors")
  local list = {}
  if raw ~= nil then
    for g in string.gmatch(raw, "%S+") do
      table.insert(list, g)
    end
  end
  return list
end

local function readGovernor()
  local raw = noctalia.readFile(GOV_DIR .. "scaling_governor")
  if raw == nil then
    return nil
  end
  return noctalia.string.trim(raw)
end

local function setGovernor(g)
  govCurrent = g
  noctalia.runAsync({ "sudo", "-n", "/usr/local/bin/set-governor", g }, function(result)
    govCurrent = readGovernor()
    nextGovernorRead = noctalia.nowMs() + 5000
    if result.exitCode ~= 0 then
      noctalia.notifyError("Dashboard", "Could not set governor: " .. tostring(result.stderr))
    end
    update()
  end)
  update()
end

local function governorRow()
  if govList == nil then
    govList = readGovernors()
  end
  if #govList == 0 then
    return nil
  end
  local now = noctalia.nowMs()
  if now >= nextGovernorRead then
    govCurrent = readGovernor() or govCurrent
    nextGovernorRead = now + 5000
  end
  local lines = {}
  for first = 1, #govList, 3 do
    local pills = {}
    for i = first, math.min(first + 2, #govList) do
      local g = govList[i]
      local active = (g == govCurrent)
      table.insert(pills, ui.row({
        key = "gov-" .. g,
        flexGrow = 1,
        justify = "center",
        paddingV = 6,
        radius = 9,
        fill = active and "primary" or "surface_container_high",
        tooltip = GOV_TIPS[g] or g,
        onClick = function()
          if not active then
            setGovernor(g)
          end
        end,
      }, {
        ui.label({
          text = string.upper(string.sub(g, 1, 1)) .. string.sub(g, 2),
          fontSize = 12,
          fontWeight = active and "bold" or "normal",
          color = active and "on_primary" or "on_surface",
          maxLines = 1,
        }),
      }))
    end
    table.insert(lines, ui.row({ gap = 6 }, pills))
  end
  return ui.column({ gap = 6 }, {
    ui.label({ text = "CPU governor", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.column({ gap = 6 }, lines),
  })
end

local disk
local nextDiskRead = 0

local function systemCard(showGovernor)
  local stats = noctalia.systemStats()
  local rows = {}
  if stats == nil then
    table.insert(rows, ui.label({
      text = "System monitor is off. Enable [system.monitor] in your Noctalia config.",
      fontSize = 13,
      color = "on_surface_variant",
      maxLines = 3,
    }))
  else
    table.insert(rows, meter("CPU", stats.cpu.usagePercent))
    table.insert(rows, meter("RAM", stats.ram.usagePercent))
    local now = noctalia.nowMs()
    if now >= nextDiskRead then
      disk = noctalia.diskStats("/")
      nextDiskRead = now + 10000
    end
    if disk ~= nil then
      table.insert(rows, meter("Disk", disk.usagePercent))
    end
    local extra = {}
    if stats.cpu.tempC ~= nil then
      table.insert(extra, string.format("CPU %d°C", math.floor(stats.cpu.tempC + 0.5)))
    end
    if stats.loadAvg ~= nil and stats.loadAvg[1] ~= nil then
      table.insert(extra, string.format("load %.2f", stats.loadAvg[1]))
    end
    if #extra > 0 then
      table.insert(rows, ui.label({ text = table.concat(extra, "  ·  "), fontSize = 11, color = "on_surface_variant" }))
    end
  end
  local gov = showGovernor ~= false and governorRow() or nil
  if gov ~= nil then
    table.insert(rows, gov)
  end
  return card({ flexGrow = 1 }, {
    sectionTitle("cpu", "System", nil, nil, "system"),
    ui.column({ gap = 10 }, rows),
  })
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

local function todoRow(t, textW)
  local pc = "on_surface_variant"
  if not t.done then
    if t.pr >= 3 then
      pc = "error"
    elseif t.pr == 2 then
      pc = "tertiary"
    elseif t.pr == 1 then
      pc = "secondary"
    end
  end
  return ui.row({
    key = "t" .. t.idx,
    gap = 4,
    align = "center",
    paddingH = 6,
    paddingV = 3,
    radius = 12,
    fill = t.done and "surface_container_high/0.5" or "surface_container_high",
  }, {
    ui.button({
      glyph = t.done and "circle-check-filled" or "circle",
      glyphSize = 18,
      variant = t.done and "primary" or "ghost",
      controlSize = "sm",
      tooltip = t.done and "Mark as not done" or "Mark as done",
      onClick = function() toggleTask(t) end,
    }),
    ui.label({
      text = t.text,
      fontSize = 14,
      color = t.done and "on_surface_variant" or "on_surface",
      opacity = t.done and 0.65 or 1,
      maxLines = 2,
      maxWidth = textW,
      flexGrow = 1,
    }),
    ui.row({
      paddingH = 6,
      paddingV = 6,
      radius = 8,
      tooltip = "Priority: " .. (PRIORITY_NAMES[t.pr] or "Custom") .. " (click to change)",
      onClick = function() cyclePriority(t) end,
    }, {
      ui.glyph({ name = "flag", size = 16, color = pc }),
    }),
    ui.button({
      glyph = "trash",
      glyphSize = 16,
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Remove",
      onClick = function() deleteTask(t) end,
    }),
  })
end

local function todoCard(textWidth)
  local rows = {}
  local right = nil
  if todo == nil then
    table.insert(rows, ui.label({ text = "Loading…", fontSize = 13, color = "on_surface_variant" }))
  elseif todo.ok ~= true then
    table.insert(rows, ui.label({
      text = "No to-do file yet. Add your first task and it will be created at " .. tostring(todo.path) .. ".",
      fontSize = 12,
      color = "on_surface_variant",
      maxLines = 4,
      maxWidth = textWidth,
    }))
  else
    right = todo.open .. " open · " .. todo.done .. " done"
    if #todo.items == 0 then
      table.insert(rows, ui.label({ text = "All clear. Nothing on your list.", fontSize = 13, color = "on_surface_variant" }))
    end
    for _, t in ipairs(todo.items) do
      table.insert(rows, todoRow(t, textWidth))
    end
  end
  return card({ flexGrow = 1 }, {
    sectionTitle("list-check", "To do", right, nil, "todo"),
    ui.input({
      key = "todo-in-" .. inputGen,
      placeholder = "Add a task and press Enter…",
      focus = true,
      onChange = function(value) pendingText = value end,
      onSubmit = function(value) addTask(value) end,
    }),
    ui.scroll({ gap = 6, flexGrow = 1 }, rows),
  })
end

------------------------------------------------------------------ header

local function avatarNode()
  if profile ~= nil and profile.avatar ~= nil and profile.avatar ~= "" then
    return ui.image({ path = profile.avatar, width = AVATAR, height = AVATAR, radius = math.floor(AVATAR / 2), fit = "cover" })
  end
  local initial = "?"
  if profile ~= nil and profile.name ~= nil and profile.name ~= "" then
    initial = string.upper(string.sub(profile.name, 1, 1))
  end
  return ui.column({
    width = AVATAR,
    height = AVATAR,
    radius = math.floor(AVATAR / 2),
    fill = "primary_container",
    align = "center",
    justify = "center",
  }, {
    ui.label({ text = initial, fontSize = 28, fontWeight = "bold", color = "on_primary_container" }),
  })
end

local function header(width)
  local name = (profile ~= nil and profile.name) or ""
  local screenText = (screen ~= nil and screen.ok == true) and (fmtDur(screen.sec) .. " screen time") or "Screen time"
  return ui.row({ gap = 16, align = "center" }, {
    avatarNode(),
    ui.column({ gap = 6, justify = "center" }, {
      ui.label({ text = greeting() .. ",", fontSize = 13, color = "on_surface_variant" }),
      ui.label({ text = name, fontSize = 26, fontWeight = "bold", color = "on_surface" }),
    }),
    ui.row({ gap = 8, align = "center", visible = width >= 630 }, {
      chip("clock", "Up " .. fmtUptime(uptimeSec), nil),
      chip("device-desktop", screenText, nil),
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.column({ gap = 2, align = "end", justify = "center" }, {
      ui.label({ text = os.date("%H:%M"), fontSize = 40, fontWeight = "bold", color = "primary", textAlign = "right" }),
      ui.label({ text = os.date("%A, %B %d"), fontSize = 13, color = "on_surface_variant", textAlign = "right" }),
    }),
    ui.button({ glyph = "x", variant = "ghost", tooltip = "Close", onClick = closeDash }),
  })
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
  layer.render(ui.column({
    fill = string.format("scrim/%.2f", 0.55 * anim),
    flexGrow = 1,
    align = "center",
    justify = "center",
    onClick = closeDash,
  }, {
    ui.column({
      opacity = anim,
      width = c.w,
      height = c.h,
      fill = "surface",
      radius = 26,
      padding = c.pad,
      gap = c.gap,
      border = "outline_variant",
      borderWidth = 1,
      onClick = function() end,
    }, c.kids),
  }))
end

local agendaCache, screenCache, todoCache

local function cachedAgendaCard()
  local today = os.date("%Y-%m-%d")
  local expanded = maximizedCard == "calendar"
  if agendaCache == nil or agendaCache.events ~= events or agendaCache.day ~= today or agendaCache.expanded ~= expanded then
    agendaCache = { events = events, day = today, expanded = expanded, node = agendaCard() }
  end
  return agendaCache.node
end

local function cachedScreenCard(innerW, sidebarWidth)
  local screenFocus = maximizedCard == "screen"
  if loadingMore then
    -- The loading indicator and its timeout depend on the clock.
    screenCache = nil
    return renderScreenCard(innerW, screenCard(innerW), sidebarWidth)
  end
  local c = screenCache
  if c == nil or c.screen ~= screen or c.width ~= innerW or c.height ~= CHART_H
      or c.range ~= screenRange or c.day ~= screenDay or c.selection ~= screenSel or c.focus ~= screenFocus then
    c = {
      screen = screen, width = innerW, height = CHART_H,
      range = screenRange, day = screenDay, selection = screenSel, focus = screenFocus,
      model = screenCard(innerW),
    }
    screenCache = c
  end
  if c.node == nil or c.hover ~= screenHover or c.sidebarWidth ~= sidebarWidth or c.tab ~= screenDetailsTab then
    c.hover = screenHover
    c.sidebarWidth = sidebarWidth
    c.tab = screenDetailsTab
    c.node = renderScreenCard(innerW, c.model, sidebarWidth)
  end
  return c.node
end

local function cachedTodoCard(textWidth)
  local expanded = maximizedCard == "todo"
  if todoCache == nil or todoCache.todo ~= todo or todoCache.width ~= textWidth
      or todoCache.inputGen ~= inputGen or todoCache.expanded ~= expanded then
    todoCache = { todo = todo, width = textWidth, inputGen = inputGen, expanded = expanded, node = todoCard(textWidth) }
  end
  return todoCache.node
end

local function summaryCard(id, value, detail)
  local info = Grid.cards[id]
  local kids = {
    sectionTitle(info.icon, info.title, nil, nil, id),
    ui.label({ text = value, fontSize = 17, fontWeight = "bold", maxLines = 1, color = "on_surface" }),
  }
  if detail ~= nil then
    table.insert(kids, ui.label({ text = detail, fontSize = 12, maxLines = 1, color = "on_surface_variant" }))
  end
  return card({ flexGrow = 1, padding = 10, gap = 4 }, kids)
end

local function gridCard(id, w, h)
  if id == "github" then
    return githubCard(w, h)
  elseif id == "screen" then
    if w < 256 or h < 278 then
      local value = screen and screen.ok and fmtDur(screen.sec) or "No data yet"
      return summaryCard(id, value, "Screen time today")
    end
    CHART_H = math.clamp(math.floor((h - 185) * 0.5), 30, 84)
    HERO_FS = h >= 340 and 28 or 20
    return cachedScreenCard(w - 32)
  elseif id == "todo" then
    if h < 160 then
      local detail = todo and todo.ok and (todo.open .. " open · " .. todo.done .. " done") or "To-do list"
      return summaryCard(id, detail)
    end
    return cachedTodoCard(math.max(48, w - 146))
  elseif id == "calendar" then
    if h < 159 then
      local detail = events and events.synced and (#events.items .. " upcoming events") or "Calendar not synced"
      return summaryCard(id, detail)
    end
    return cachedAgendaCard()
  end
  if w < 210 or h < 151 then
    local stats = noctalia.systemStats()
    local detail = stats and string.format("CPU %.0f%% · RAM %.0f%%", stats.cpu.usagePercent, stats.ram.usagePercent) or "System monitor is off"
    return summaryCard(id, detail)
  end
  return systemCard(w >= 240 and h >= 270)
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
  AVATAR = short and 48 or 68
  HERO_FS = short and 20 or 28
  local pad, colGap = 22, 14
  if short then
    pad, colGap = 14, 10
  end
  local width = cardW - pad * 2
  local headerHeight = short and 68 or 78
  local height = math.max(0, cardH - 2 * pad - 3 * colGap - headerHeight - 36)
  local monitor = layer.outputName() or (g and g.name) or "default"

  local body
  if maximizedCard == "screen" then
    local sidebarWidth = width >= 900 and height >= 460 and math.floor((width - 34) * 0.35) or nil
    HERO_FS = short and 26 or 32
    if sidebarWidth ~= nil then
      CHART_H = math.clamp(height - 286, 80, 374)
      body = cachedScreenCard(width - 58 - sidebarWidth, sidebarWidth)
    else
      CHART_H = math.clamp(math.floor((height - 230) * 0.40), 26, 100)
      body = cachedScreenCard(width - 24)
    end
  elseif maximizedCard == "calendar" then
    body = cachedAgendaCard()
  elseif maximizedCard == "todo" then
    body = cachedTodoCard(math.max(48, width - 146))
  elseif maximizedCard == "system" then
    body = systemCard()
  elseif maximizedCard == "github" then
    body = githubDetails(width, height)
  else
    body = gridLayout(monitor, width, height)
  end

  local kids = {
    ui.column({ height = headerHeight }, { header(width) }),
    ui.separator({ thickness = 1, color = "outline_variant/0.5" }),
    body,
    ui.column({ height = 32 }, { footer() }),
  }
  layoutCache = { w = cardW, h = cardH, pad = pad, gap = colGap, kids = kids }
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
  renderLayout(anim)
  if closeToken == 0 and anim >= 1 then
    layer.setNeedsFrameTick(false)
  end
end

update()

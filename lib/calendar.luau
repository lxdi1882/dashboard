--!nonstrict
-- Calendar dates use local civil days, so month navigation survives daylight-saving changes.
local Calendar = {}

local function parts(key)
  local y, m, d = string.match(key, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  return tonumber(y), tonumber(m), tonumber(d)
end

function Calendar.shiftDay(key, days)
  local y, m, d = parts(key)
  return os.date("%Y-%m-%d", os.time({ year = y, month = m, day = d + days, hour = 12 }))
end

function Calendar.shiftMonth(key, months)
  local y, m = parts(key)
  return os.date("%Y-%m-01", os.time({ year = y, month = m + months, day = 1, hour = 12 }))
end

function Calendar.monthStart(key)
  return string.sub(key, 1, 7) .. "-01"
end

function Calendar.gridStart(month)
  local y, m = parts(month)
  local weekday = tonumber(os.date("%w", os.time({ year = y, month = m, day = 1, hour = 12 })))
  return Calendar.shiftDay(month, -weekday)
end

function Calendar.dayBounds(key)
  local y, m, d = parts(key)
  return os.time({ year = y, month = m, day = d, hour = 0, min = 0, sec = 0 }) * 1000,
    os.time({ year = y, month = m, day = d + 1, hour = 0, min = 0, sec = 0 }) * 1000
end

function Calendar.eventDays(event)
  if event.firstDay ~= nil and event.lastDay ~= nil then return event.firstDay, event.lastDay end
  local start = math.floor(event.startMs / 1000)
  local finish = math.floor(event.endMs / 1000)
  if event.allDay then
    -- Date-only events may arrive at UTC or local midnight. Their end date is exclusive.
    local utc = os.date("!%H:%M:%S", start) == "00:00:00"
    local format = utc and "!%Y-%m-%d" or "%Y-%m-%d"
    local first = os.date(format, start)
    local last = Calendar.shiftDay(os.date(format, finish), -1)
    return first, last >= first and last or first
  end
  local first = os.date("%Y-%m-%d", start)
  local last = os.date("%Y-%m-%d", math.floor((math.max(event.endMs, event.startMs + 1) - 1) / 1000))
  return first, last
end

function Calendar.eventsOn(items, key)
  local result = {}
  for _, event in ipairs(items or {}) do
    local first, last = Calendar.eventDays(event)
    if first <= key and key <= last then table.insert(result, event) end
  end
  return result
end

return Calendar

const host = "io.github.lxdi1882.dashboard_sites";
const heartbeat = "dashboard-site-time";
const maxSample = 45_000;
const exportInterval = 30_000;
const iconRefresh = 7 * 24 * 60 * 60 * 1000;
let pending = Promise.resolve();
let nextExport = 0;

function serial(task) {
  const result = pending.then(() => task());
  pending = result.catch(() => {});
  return result;
}

async function load() {
  const { siteTime } = await chrome.storage.local.get("siteTime");
  return siteTime ?? { enabled: false, profile: crypto.randomUUID(), days: {}, active: null, connected: false };
}

async function save(state) {
  await chrome.storage.local.set({ siteTime: state });
}

function localDate(ms) {
  const date = new Date(ms);
  return [date.getFullYear(), String(date.getMonth() + 1).padStart(2, "0"),
    String(date.getDate()).padStart(2, "0")].join("-");
}

function trim(state, now) {
  const oldest = new Date(now);
  oldest.setDate(oldest.getDate() - 13);
  const cutoff = localDate(oldest.getTime());
  for (const day of Object.keys(state.days)) {
    if (day < cutoff) {
      delete state.days[day];
      if (state.hours) delete state.hours[day];
    }
  }
  for (const [domain, recheck] of Object.entries(state.icons ?? {})) {
    if (recheck <= now) delete state.icons[domain];
  }
}

function finishSample(state, now) {
  if (!state.active) return;
  const { domain, since } = state.active;
  const end = Math.min(now, since + maxSample);
  let cursor = since;
  while (cursor < end) {
    const local = new Date(cursor);
    const intoHour = local.getMinutes() * 60_000 + local.getSeconds() * 1000 + local.getMilliseconds();
    const stop = Math.min(end, cursor + 3_600_000 - intoHour);
    const day = localDate(cursor);
    const sites = state.days[day] ??= {};
    const ownTime = Object.hasOwn(sites, domain) ? sites[domain] : 0;
    sites[domain] = ownTime + stop - cursor;
    const hourlySites = (state.hours ??= {})[day] ??= Object.create(null);
    if (!Object.hasOwn(hourlySites, domain)) hourlySites[domain] = Array(24).fill(0);
    hourlySites[domain][local.getHours()] += stop - cursor;
    if (Object.keys(sites).length > 128) {
      state.days[day] = Object.fromEntries(Object.entries(sites).sort((a, b) => b[1] - a[1]).slice(0, 128));
      for (const name of Object.keys(hourlySites)) {
        if (!Object.hasOwn(state.days[day], name)) delete hourlySites[name];
      }
    }
    cursor = stop;
  }
  state.active = null;
}

function domainOf(value) {
  try {
    const url = new URL(value);
    if (url.protocol === "https:" || url.protocol === "http:") {
      const name = url.hostname.replace(/\.$/, "");
      if (name.length <= 253 && /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/i.test(name)) return name;
    }
  } catch {
    // Restricted or incomplete tabs may not expose a URL.
  }
  return null;
}

async function foregroundPage() {
  if ((await chrome.idle.queryState(60)) === "locked") return null;
  const window = await chrome.windows.getLastFocused();
  if (!window?.focused || window.incognito) return null;
  const [tab] = await chrome.tabs.query({ active: true, windowId: window.id });
  const domain = tab?.incognito ? null : domainOf(tab?.url);
  return domain ? { domain, url: tab.url, hasIcon: Boolean(tab.favIconUrl) } : null;
}

async function cachedIcon(page) {
  try {
    const url = new URL(chrome.runtime.getURL("/_favicon/"));
    url.searchParams.set("pageUrl", page.url);
    url.searchParams.set("size", "32");
    const response = await fetch(url);
    if (!response.ok) return null;
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length === 0 || bytes.length > 32_768) return null;
    return { domain: page.domain, png: btoa(String.fromCharCode(...bytes)) };
  } catch {
    return null;
  }
}

async function exportTotals(state, { force = false, page = null, clear = false } = {}) {
  const now = Date.now();
  if (!force && now < nextExport) return false;
  nextExport = now + exportInterval;
  // Bound the native message size even with long hostnames and 14 days of data.
  const hours = Object.fromEntries(Object.entries(state.hours ?? {}).map(([day, sites]) => [
    day, Object.fromEntries(Object.entries(sites)
      .sort(([a], [b]) => (state.days[day]?.[b] ?? 0) - (state.days[day]?.[a] ?? 0)).slice(0, 64)),
  ]));
  const message = { profile: state.profile, days: state.days, hours, clearIcons: clear };
  try {
    if (page?.hasIcon && !(Object.hasOwn(state.icons ?? {}, page.domain))
        && (await chrome.permissions.contains({ permissions: ["favicon"] }))) {
      const icon = await cachedIcon(page);
      if (icon) message.icon = icon;
      (state.icons ??= {})[page.domain] = now + (icon ? iconRefresh : 300_000);
    }
    const result = await chrome.runtime.sendNativeMessage(host, message);
    state.connected = result?.ok === true;
    if (!state.connected && message.icon) delete state.icons[page.domain];
  } catch {
    state.connected = false;
    if (message.icon) delete state.icons[page.domain];
  }
  return true;
}

async function updateSample(reset = false, stop = false, forceExport = false) {
  const state = await load();
  if (!state.enabled) return;
  const now = Date.now();
  if (!reset) finishSample(state, now);
  const page = stop ? null : await foregroundPage().catch(() => null);
  state.active = page ? { domain: page.domain, since: now } : null;
  trim(state, now);
  await save(state);
  if (await exportTotals(state, { force: reset || forceExport, page })) await save(state);
}

async function ensureHeartbeat() {
  if (!(await chrome.alarms.get(heartbeat))) {
    await chrome.alarms.create(heartbeat, { periodInMinutes: 0.5 });
  }
}

async function status(action) {
  const state = await load();
  if (action === "start") {
    if (!(await chrome.permissions.contains({ permissions: ["tabs"] }))) {
      return { enabled: false, connected: false };
    }
    await exportTotals(state, { force: true });
    if (state.connected) {
      state.enabled = true;
      await ensureHeartbeat();
      const page = await foregroundPage().catch(() => null);
      state.active = page ? { domain: page.domain, since: Date.now() } : null;
    }
    await save(state);
  } else if (action === "pause" || action === "revoke") {
    finishSample(state, Date.now());
    state.enabled = false;
    await save(state);
    await chrome.alarms.clear(heartbeat);
    await exportTotals(state, { force: true });
    await save(state);
  } else if (action === "clear") {
    const now = Date.now();
    state.days = {};
    state.hours = {};
    state.icons = {};
    if (state.active) state.active.since = now;
    await save(state);
    await exportTotals(state, { force: true, clear: true });
    await save(state);
  }
  return { enabled: state.enabled, connected: state.connected };
}

function schedule(task) {
  serial(task).catch(() => {});
}

chrome.runtime.onStartup.addListener(() => schedule(async () => {
  if ((await load()).enabled) {
    await ensureHeartbeat();
    await updateSample(true);
  }
}));
chrome.runtime.onInstalled.addListener(() => schedule(async () => {
  if ((await load()).enabled) {
    await ensureHeartbeat();
    await updateSample(true);
  }
}));
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === heartbeat) schedule(updateSample);
});
chrome.windows.onFocusChanged.addListener(id => {
  schedule(() => updateSample(false, id === chrome.windows.WINDOW_ID_NONE));
});
chrome.tabs.onActivated.addListener(() => schedule(updateSample));
chrome.tabs.onUpdated.addListener((_, change, tab) => {
  if (tab.active && change.url !== undefined) schedule(updateSample);
});
chrome.idle.onStateChanged.addListener(state => {
  schedule(() => updateSample(false, state === "locked"));
});
chrome.permissions.onAdded.addListener(added => {
  if (added.permissions?.includes("favicon")) schedule(() => updateSample(false, false, true));
});
chrome.permissions.onRemoved.addListener(removed => {
  if (removed.permissions?.includes("tabs")) schedule(() => status("revoke"));
});
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id !== chrome.runtime.id || !["status", "start", "pause", "clear"].includes(message?.action)) return false;
  serial(() => status(message.action)).then(reply, () => reply({ error: true }));
  return true;
});

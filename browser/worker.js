const host = "io.github.lxdi1882.dashboard_sites";
const heartbeat = "dashboard-site-time";
const maxSample = 45_000;
const exportInterval = 30_000;
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
    if (day < cutoff) delete state.days[day];
  }
}

function finishSample(state, now) {
  if (!state.active) return;
  const { domain, since } = state.active;
  const end = Math.min(now, since + maxSample);
  let cursor = since;
  while (cursor < end) {
    const midnight = new Date(cursor);
    midnight.setHours(24, 0, 0, 0);
    const stop = Math.min(end, midnight.getTime());
    const day = localDate(cursor);
    const sites = state.days[day] ??= {};
    const ownTime = Object.hasOwn(sites, domain) ? sites[domain] : 0;
    sites[domain] = ownTime + stop - cursor;
    if (Object.keys(sites).length > 128) {
      state.days[day] = Object.fromEntries(Object.entries(sites).sort((a, b) => b[1] - a[1]).slice(0, 128));
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

async function foregroundDomain() {
  if ((await chrome.idle.queryState(60)) === "locked") return null;
  const window = await chrome.windows.getLastFocused();
  if (!window?.focused || window.incognito) return null;
  const [tab] = await chrome.tabs.query({ active: true, windowId: window.id });
  return tab?.incognito ? null : domainOf(tab?.url);
}

async function exportTotals(state, force = false) {
  const now = Date.now();
  if (!force && now < nextExport) return;
  nextExport = now + exportInterval;
  try {
    const result = await chrome.runtime.sendNativeMessage(host, {
      profile: state.profile,
      days: state.days,
    });
    state.connected = result?.ok === true;
  } catch {
    state.connected = false;
  }
}

async function updateSample(reset = false, stop = false) {
  const state = await load();
  if (!state.enabled) return;
  const now = Date.now();
  if (!reset) finishSample(state, now);
  state.active = null;
  if (!stop) {
    const domain = await foregroundDomain().catch(() => null);
    if (domain) state.active = { domain, since: now };
  }
  trim(state, now);
  await save(state);
  const connected = state.connected;
  await exportTotals(state, reset);
  if (state.connected !== connected) await save(state);
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
    await exportTotals(state, true);
    if (state.connected) {
      state.enabled = true;
      await ensureHeartbeat();
      const domain = await foregroundDomain().catch(() => null);
      state.active = domain ? { domain, since: Date.now() } : null;
    }
    await save(state);
  } else if (action === "pause" || action === "revoke") {
    finishSample(state, Date.now());
    state.enabled = false;
    await save(state);
    await chrome.alarms.clear(heartbeat);
    await exportTotals(state, true);
    await save(state);
  } else if (action === "clear") {
    const now = Date.now();
    state.days = {};
    if (state.active) state.active.since = now;
    await save(state);
    await exportTotals(state, true);
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
chrome.permissions.onRemoved.addListener(removed => {
  if (removed.permissions?.includes("tabs")) schedule(() => status("revoke"));
});
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id !== chrome.runtime.id || !["status", "start", "pause", "clear"].includes(message?.action)) return false;
  serial(() => status(message.action)).then(reply, () => reply({ error: true }));
  return true;
});

const toggle = document.querySelector("#toggle");
const clear = document.querySelector("#clear");
const statusLine = document.querySelector("#status");
let enabled = false;

async function run(action) {
  toggle.disabled = clear.disabled = true;
  try {
    const result = await chrome.runtime.sendMessage({ action });
    if (result?.error || !result) throw new Error();
    enabled = result.enabled;
    toggle.textContent = enabled ? "Pause tracking" : "Start tracking";
    if (action !== "status" && !result.connected) {
      statusLine.textContent = "Dashboard bridge unavailable. Install it using the project README.";
    } else if (enabled) {
      statusLine.textContent = result.connected ? "Tracking foreground domains locally." : "Tracking locally. Dashboard bridge disconnected.";
    } else {
      statusLine.textContent = "Tracking paused. Only domain totals are stored.";
    }
  } catch {
    statusLine.textContent = "Could not contact the tracker.";
  } finally {
    toggle.disabled = clear.disabled = false;
  }
}

toggle.addEventListener("click", async () => {
  if (enabled) {
    await run("pause");
  } else {
    try {
      const allowed = await chrome.permissions.request({ permissions: ["tabs"] });
      if (allowed) await run("start");
      else statusLine.textContent = "Tab access is needed to read the active domain.";
    } catch {
      statusLine.textContent = "Could not request tab access.";
    }
  }
});

clear.addEventListener("click", () => {
  if (window.confirm("Clear recorded website totals for this profile?")) run("clear");
});

run("status");

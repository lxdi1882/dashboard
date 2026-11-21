
## CPU governor buttons (optional)

The System card can switch the CPU governor. Changing it needs root, so it needs a one-time setup on each machine:

1. Create /usr/local/bin/set-governor, owned by root, with this content:

```sh
#!/bin/sh
g="$1"
for a in $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors); do
  if [ "$a" = "$g" ]; then
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$g" > "$f"; done
    exit 0
  fi
done
echo "invalid governor" >&2
exit 1
```

2. Make it executable: `sudo chmod 755 /usr/local/bin/set-governor`
3. Allow it without a password. Run `sudo visudo -f /etc/sudoers.d/set-governor` and add this line, using your username:

```
YOUR_USER ALL=(root) NOPASSWD: /usr/local/bin/set-governor
```

Without this, the buttons show an error notification. The governor resets on reboot.

## Brave site time (optional)

The maximized Screen Time card has a **Sites** tab for the selected day or date range. Site totals are a breakdown of Brave usage and are collected separately from Noctalia’s app totals.

1. From this checkout, run `python3 browser/native-host.py --install`. If Brave uses a custom user data directory or you have multiple Brave editions, pass the directory after `--install`. In `brave://version`, it is the directory containing the profile listed under **Profile Path**.
2. Open `brave://extensions`, enable **Developer mode**, click **Load unpacked**, and select the `browser` directory in this checkout.
3. Open **Dashboard Site Time** from the extensions menu and click **Start tracking**. Accept the tab access prompt. Dashboard Site Time stays paused until you start it.

The companion counts time on an HTTP(S) domain while Brave has focus and the screen is unlocked. It stores only domain totals locally, with no page paths, titles, or search terms. Private windows are excluded. The dashboard shows up to 14 days of totals. Use **Enable site icons** in the popup to show favicons cached by Brave. The dashboard uses a globe until Brave has supplied an icon. Use **Pause tracking** or **Clear site totals** from the extension popup. The dashboard refreshes the site list along with its normal screen-time data.

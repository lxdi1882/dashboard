
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

#!/bin/bash
# Keeps adb attached to the phone's reverse tunnels (127.0.0.1:7555).
# The phone re-opens its tunnel by itself (~/.tunnel/tunnel.sh in Termux) after a router
# restart or a network change; this re-runs "adb connect" whenever a tunnel's listener exists
# but adb doesn't show the device as "device". Added 05/10/2026.
ADB=/home/user/.local/bin/adb
while true; do
  for p in 7555; do
    if ss -ltn "sport = :$p" | grep -q LISTEN; then
      st=$(timeout 10 "$ADB" -s 127.0.0.1:$p get-state 2>/dev/null)
      if [ "$st" != "device" ]; then
        timeout 10 "$ADB" disconnect 127.0.0.1:$p >/dev/null 2>&1
        timeout 10 "$ADB" connect 127.0.0.1:$p >/dev/null 2>&1
        echo "$(date '+%F %T') reconnect $p -> $(timeout 10 "$ADB" -s 127.0.0.1:$p get-state 2>&1)"
      fi
    fi
  done
  sleep 20
done

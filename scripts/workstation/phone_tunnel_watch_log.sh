#!/bin/bash
# Logs the phone tunnel's state every 15 s (for checking the nightly router restart).
# Usage: phone_tunnel_watch_log.sh [seconds]
OUT=/home/user/phone_tunnel_watch_$(date +%F).log
end=$(( $(date +%s) + ${1:-2700} ))
while [ $(date +%s) -lt $end ]; do
  l=$(ss -ltn 'sport = :7555' | grep -c LISTEN)
  s=$(timeout 8 /home/user/.local/bin/adb -s 127.0.0.1:7555 shell echo ok 2>&1 | tr -d '\r' | head -1)
  net=$(timeout 5 ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 && echo up || echo DOWN)
  echo "$(date '+%T') internet=$net L7555=$l adb7555=$s" >> "$OUT"
  sleep 15
done

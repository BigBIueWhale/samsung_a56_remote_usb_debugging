#!/data/data/com.termux/files/usr/bin/bash
# The phone's adb tunnel: workstation 127.0.0.1:7555 -> phone 127.0.0.1:5555. Reconnects forever.
# Key login (~/.tunnel/id_tunnel), allowed by the workstation ONLY to listen on 127.0.0.1:7555.
# Tolerates 5 minutes of silence (15 s x 20), so the nightly 3-4 minute router restart only pauses it.
D="$HOME/.tunnel"; LOG="$D/log"
while true; do
  for HOST in 172.30.77.1 ronenzyroff.com; do
    echo "$(date '+%F %T') connect $HOST" >> "$LOG"
    ssh -T -i "$D/id_tunnel" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o PubkeyAuthentication=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=20 -o ConnectTimeout=15 \
        -o HostKeyAlias=ronenzyroff.com -o StrictHostKeyChecking=accept-new \
        -o ExitOnForwardFailure=no \
        -R 7555:127.0.0.1:5555 "user@$HOST" < /dev/null >> "$LOG" 2>&1
    rc=$?
    echo "$(date '+%F %T') exit $rc ($HOST)" >> "$LOG"
    tail -n 400 "$LOG" > "$LOG.t" 2>/dev/null && mv "$LOG.t" "$LOG"
    if [ "$rc" -eq 75 ]; then sleep 2; continue 2; fi   # an old dead session was ended: reconnect now
    sleep 5
  done
  sleep 10
done

#!/data/data/com.termux/files/usr/bin/bash
# Installer for the phone's self-healing adb tunnel (run in Termux, in a new session).
#   bash install.sh keygen   -> makes the phone's own key (~/.tunnel/id_tunnel) and prints the public key.
#                               Put that line, with the restrictions, into the workstation's
#                               /etc/ssh/phone_tunnel_authorized_keys (see ../workstation/).
#   bash install.sh start    -> installs tunnel.sh next to the key and starts it (nohup, wake lock).
HERE="$(cd "$(dirname "$0")" && pwd)"
D="$HOME/.tunnel"; mkdir -p "$D"; chmod 700 "$D"
case "$1" in
keygen)
  [ -f "$D/id_tunnel" ] || ssh-keygen -q -t ed25519 -N "" -C "a56-termux-adb-tunnel" -f "$D/id_tunnel"
  cat "$D/id_tunnel.pub" ;;
start)
  cp "$HERE/tunnel.sh" "$D/tunnel.sh"; chmod 700 "$D/tunnel.sh"
  termux-wake-lock
  pkill -f "$D/tunnel.sh" 2>/dev/null
  nohup bash "$D/tunnel.sh" >/dev/null 2>&1 &
  sleep 12; tail -n 4 "$D/log" ;;
*) echo "usage: bash install.sh keygen|start" ;;
esac

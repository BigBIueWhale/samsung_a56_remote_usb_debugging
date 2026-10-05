# Self-healing tunnels (since 05/10/2026)

**Why:** the home router is switched off for up to ~3 minutes just before 05:00 every night (a Shabbat clock that "refreshes" it).
- Before this change, that killed the phone's SSH tunnel for good. The phone's `ssh` gave up after ~90 s and nothing restarted it.
- On the workstation, sshd kept the dead session, and with it port 7555, for hours. So even a manual restart failed with `remote port forwarding failed for listen port 7555`.
- The owner asked for the link to survive this unattended, at home and at work.

## What runs now

| Where | What |
|---|---|
| **Phone, Termux** | Two independent loops, `~/.tunnel/loop.sh 7555` and `~/.tunnel/loop.sh 7556`, started with `nohup` under `termux-wake-lock`. Each one reconnects forever. |
| **Workstation, sshd** | `/etc/ssh/sshd_config.d/20-phone-tunnel-keepalive.conf`: `ClientAliveInterval 15`, `ClientAliveCountMax 6`. A session that doesn't answer for ~90 s is closed and its forwarded port freed. |
| **Workstation, adb** | The user service `phone-adb-reconnect.service` runs `~/.local/bin/phone_adb_reconnect.sh`. Every 20 s it re-runs `adb connect` for any port whose listener exists but isn't `device`. |

**How each phone loop works:**
- It tries `user@172.30.77.1` first, which goes over WireGuard and survives Wi-Fi/5G switches, then `user@ronenzyroff.com`.
- It uses `ServerAliveInterval 15`, `ServerAliveCountMax 6` and `ExitOnForwardFailure yes`. If its port is still held, it exits and retries until sshd frees the port.
- It logs to `~/.tunnel/log_<port>`.
- **Password:** the loops log in with the account password stored on the phone in `~/.tunnel/pw` (chmod 600, inside Termux's private storage), fed through `~/.tunnel/askpass.sh` with `SSH_ASKPASS_REQUIRE=force`. The owner chose this over changing the server to key logins.

**Two ports, same phone:** `127.0.0.1:7555` and `127.0.0.1:7556` both lead to the phone's adbd on `127.0.0.1:5555`. If one is down, use the other: `adb -s 127.0.0.1:7556 …`.

## Tested (05/10/2026 04:42)

- The 7556 loop connected over WireGuard (the workstation saw `172.30.77.2 → 172.30.77.1:22`), and adb answered `ok`.
- The old manual 7555 session was ended on the workstation. The 7555 loop retook the port in 20 s, and adb answered `ok` on it.

## Operating notes

- **After a phone reboot,** adbd's port 5555 is gone, as before. Redo the Wireless-debugging bootstrap (README §8), then start the loops again in Termux:

  ```
  termux-wake-lock
  nohup bash ~/.tunnel/loop.sh 7556 >/dev/null 2>&1 &
  nohup bash ~/.tunnel/loop.sh 7555 >/dev/null 2>&1 &
  ```

- **Stop:** `pkill -f .tunnel/loop.sh` in Termux.
- **Check from the workstation:**
  - `ss -ltn | grep -E '7555|7556'`;
  - `adb -s 127.0.0.1:7555 shell echo ok`;
  - `systemctl --user status phone-adb-reconnect`.
- **If WireGuard's endpoint IP ever changed** (it hasn't across the nightly restarts), the phone's WireGuard app might need a toggle. That's the owner's to do.

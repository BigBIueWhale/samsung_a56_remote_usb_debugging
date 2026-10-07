# Briefing for an AI agent controlling the Galaxy A56

*This file is written to you, the AI agent (Claude Code, Codex, or similar),
running on the owner's Ubuntu workstation (`ronenzyroff.com`). The owner will
point you here. Read all of it before touching the phone.*

> **Update 2026-10-05: the tunnel heals itself.** Termux runs `~/.tunnel/tunnel.sh`, a loop that logs in with a phone-only restricted key and holds **127.0.0.1:7555**.
> - **It survives up to 5 minutes of silence** without dropping (the nightly router restart is up to ~4 minutes).
> - **If a session dies anyway,** the phone's newest connection takes over the port.
> - **adb re-attaches itself** (`phone-adb-reconnect.service`).
> - **So before telling the owner anything, wait up to 5–10 minutes** and check `journalctl -t phone_tunnel --since -15min`.
> - Design and rules: [docs/self-healing-tunnels.md](docs/self-healing-tunnels.md).
> - **Never run `/usr/local/sbin/phone_tunnel_takeover` by hand:** with a wrong PID it ends the live session (it happened once, while testing).

## 1. What changed

**Before:** the phone was plugged into this workstation by **USB**. `adb` saw
it as a USB device, and the connection only broke if someone pulled the cable.

**Now:**

- **There is no cable.** The phone is on **5G mobile data**, somewhere else.
- **It appears on this workstation as `127.0.0.1:7555`.** That local port is a
  reverse SSH tunnel that the **phone itself** opened from Termux to this
  workstation's SSH server. It leads to the phone's adb daemon on the phone's
  `127.0.0.1:5555`, which runs in "legacy TCP mode".
- **You get the same adb capabilities as over USB:** shell, input,
  screencap, install, pull and push.
- **But the link is fragile, and only the human can repair it.** Nothing on
  this workstation can re-open it, because the phone has to start the
  connection. The full design is in [README.md](README.md).

## 2. How to address the phone

Always target it explicitly, in every command:

```sh
export ANDROID_SERIAL=127.0.0.1:7555     # or pass: adb -s 127.0.0.1:7555 ...
```

If `adb devices` doesn't list it yet, run `adb connect 127.0.0.1:7555` first.
Never rely on "the only device". A USB device or a stale entry could also be
listed.

## 3. Working over this link

- **Wrap every adb call in a timeout,** for example
  `timeout 30 adb -s 127.0.0.1:7555 shell ...`. A dead mobile link often hangs
  instead of failing.
- **Prefer short, one-shot commands** over long interactive `adb shell`
  sessions. Batch related steps into one call, for example
  `adb shell 'cmd1 && cmd2'`: every round trip crosses 5G.
- **Expect lower speed.** Screenshots (`adb exec-out screencap -p > s.png`)
  take seconds, not milliseconds. Large `pull`, `push` or `install` operations
  are slow and use the owner's mobile data, so avoid them unless needed.
- **Check state after anything that failed midway.** If a command failed or
  timed out, you don't know whether it took effect on the phone. After
  reconnecting, check the current state (screenshot, UI dump) before
  continuing. Never blindly repeat an action that may already have happened.
- **Check which app is in front immediately before every tap or keystroke**
  (`dumpsys window | grep -m1 mCurrentFocus`). The owner may be using the
  phone at the same moment, and an app can come to the front between two of
  your commands. Bring apps forward with `am start` only.
- **Never send input while RustDesk (`com.carriez.flutter_hbb`) is in front.**
  The phone's RustDesk is a *client* to the owner's computers: a tap there can
  start a remote session, and keystrokes in a session go to that computer.
  Leave it running in the background (bring your app forward with `am start`)
  and return to it with `am start` only. On 2026-10-07 at 12:13 an agent sent a
  tap, six digits and Back while RustDesk had come to the front; the tap most
  likely started a connection to the owner's computer, and where the digits
  went couldn't be proved.

## 4. Never do these (they cut the link, and only the human can restore it)

- **`adb reboot`** in any form. A reboot closes port 5555, and restoring it
  needs the human, a Wi-Fi network, and Wireless debugging.
- **`adb usb` or `adb tcpip <anything>`.** Both restart the phone's adb daemon
  and break the tunnel's target port.
- **Turning off USB debugging, Wireless debugging, or Developer options,** by
  any means. That includes `settings put global adb_enabled 0`,
  `settings put global development_settings_enabled 0`, or tapping them in
  Settings.
  - **Why USB debugging matters:** it is what keeps the adb daemon alive
    without Wi-Fi.
- **Cutting the phone's connectivity:** airplane mode, disabling mobile data
  (`svc data disable`, `cmd connectivity airplane-mode enable`), or turning
  Wi-Fi on or off. Also changing APN or network settings, or touching the
  **WireGuard** app or VPN settings.
- **Stopping, clearing, uninstalling, or restricting Termux
  (`com.termux`).** That includes `am force-stop com.termux`, `pm clear`,
  battery restrictions, and closing it from Recents. **The tunnel lives inside
  Termux.**
- **Approving security prompts.** Never tap "Allow USB debugging?", "Allow
  wireless debugging on this network?", or any other authorization dialog on
  the owner's behalf. Those are the owner's decisions. The same goes for
  entering or guessing the phone's lock-screen PIN.
- **Changing this workstation's networking** to "fix" connectivity: the SSH
  server configuration, firewall rules, the `mobile-wireguard` containers, or
  routes. Those are the owner's security boundaries.

## 5. How to tell whether the phone is connected

Run this check before starting work, and again whenever an adb command errors,
times out, or behaves oddly:

```sh
ss -ltn 'sport = :7555'                               # A: is the tunnel's listener present?
timeout 15 adb connect 127.0.0.1:7555                 # B: (re)attach
timeout 15 adb -s 127.0.0.1:7555 get-state            # C: expect "device"
timeout 20 adb -s 127.0.0.1:7555 shell echo ok        # D: expect "ok"
```

**Healthy** means A shows a `LISTEN` line on `127.0.0.1:7555`, C prints
`device`, and D prints `ok`.

This check was first run by an agent (Claude Code CLI) on 2026-09-28, and was
healthy on the first try. Its output is in
[`logs/workstation-session.txt`](logs/workstation-session.txt).
- A single `adb shell` round trip took 0.05–0.10 s.
- A full screenshot took about 2 s and 0.4 MB of mobile data.

**When it isn't healthy,** try B, C and D again **at most 3 times, about 10
seconds apart**. If it's still unhealthy:

- **Stop all phone operations.** Don't keep retrying in a loop, and don't try
  workarounds from section 4.
- **Tell the owner:**
  - what you were doing;
  - the last step you *know* completed;
  - which case below matches;
  - the exact instructions for that case, copied from below.
- **Then wait** for the owner to say the link is back. After that, run the
  check again and re-verify the phone's state before resuming.

## 6. Diagnosis, and what to tell the owner

### Case 1: no listener on `127.0.0.1:7555` (check A is empty)

**Meaning:** the SSH tunnel from the phone is down. Termux was closed or
frozen, the phone switched networks, the 5G connection dropped, or the owner
stopped it.

**Tell the owner:**

> The phone's tunnel to the workstation is down. Please, on the phone:
>
> 1. Open **Termux** (open a new session from the left drawer if the current one is busy).
> 2. Run:
>
>    ```
>    termux-wake-lock
>    nohup bash ~/.tunnel/tunnel.sh >/dev/null 2>&1 &
>    ```
>
>    It logs in with the phone's key by itself; no password is needed. Its log is `~/.tunnel/log`.
> 3. Tell me to continue.
>
> *(Fallback, the original manual way, still works: `ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -R 7555:127.0.0.1:5555 user@172.30.77.1` with the account password.)*

**Since 2026-10-05, "port already taken" fixes itself:** a new tunnel session ends the dead one holding 7555 (`journalctl -t phone_tunnel` shows "ended stale session"). The manual steps below are only for the password fallback.

**Freeing the port yourself (agent).** This is allowed. It ends only a dead
session of the same `user` account, and changes no configuration.
1. `ps -eo pid,user,lstart,etime,cmd | grep "sshd: user" | grep -v grep`
2. Pick the old tunnel session: the one started when the previous tunnel was
   opened.
3. `ps --ppid <pid>` must list **nothing**. A session with a shell under it is
   someone's interactive login: **never** end that one.
4. `kill <pid>`, then confirm `ss -ltn 'sport = :7555'` is empty, and run
   `adb disconnect 127.0.0.1:7555`.
5. Ask the owner to rerun the ssh command.

Worked example:
[README §9.1](README.md#91-a-stale-tunnel-after-a-network-drop-2026-09-28).

### Case 2: the listener exists, but adb can't reach the phone

This means check A is fine, but B, C or D fail: `Connection refused`,
`closed`, `offline`, `no devices/emulators found`, or a protocol error.

**Meaning:** the tunnel is up, but nothing answers on the phone's port 5555.
Most likely **the phone rebooted**, which resets legacy TCP mode, or **USB
debugging was turned off**.

**Tell the owner:**

> The tunnel is up, but the phone's adb port 5555 isn't answering. It probably
> rebooted. Please, on the phone:
>
> 1. Check **Settings → Developer options → USB debugging** is **on**.
> 2. Connect to **any Wi-Fi network as a client**. Your own hotspot doesn't
>    count; a friend's hotspot or any Wi-Fi does.
> 3. Turn on **Wireless debugging**. Tap **Allow** if asked about the network.
> 4. Tap the words **Wireless debugging** and read **IP address & Port**.
> 5. In Termux, using those values:
>
>    ```
>    adb connect <IP>:<PORT>
>    adb -s <IP>:<PORT> tcpip 5555
>    ```
>
>    Expect `restarting in TCP mode port: 5555`.
> 6. Check it with `adb connect 127.0.0.1:5555` and `adb devices`. Expect
>    `127.0.0.1:5555  device`.
> 7. You can leave Wi-Fi now. Restart the ssh tunnel if it dropped (Case 1
>    commands), then tell me to continue.

**If you have made a tunnel before and there is no listener at all,** treat it
as Case 1 first. The owner will find out from Termux whether port 5555 also
needs restoring.

### Case 3: `unauthorized`

**Meaning:** the phone is showing an **"Allow USB debugging?"** prompt for this
workstation's key, or the authorization was revoked.

**Tell the owner:**

> The phone is asking whether to trust this workstation. On the phone, tick
> **Always allow from this computer** and tap **Allow**, then tell me to
> continue.

Don't tap it yourself. You can't while unauthorized anyway, and you must not
while authorized.

### Case 4: commands hang or time out, but the listener exists (state may stay `device`, or flip to `offline`)

**Meaning:** weak or congested mobile signal, or a half-dead tunnel.

**Tell the owner:**

> The connection to the phone is unstable (timeouts). Please check the phone's
> signal. If it stays bad, restart the tunnel in Termux: **Ctrl+C**, then run
> the ssh command again. Turning **WireGuard on** first (and using
> `user@172.30.77.1`) makes the tunnel survive network switches.

**Seen on 2026-09-28:** `get-state` kept saying `device` while every `adb
shell` timed out. The SSH leg had died silently. When the owner restarted
the tunnel, it hit `remote port forwarding failed`, because the old session
still held 7555. The fix is under Case 1, "Freeing the port yourself".

## 7. When the owner says "continue"

1. Run the section 5 check again.
2. Take a fresh screenshot or UI dump. The phone may have changed while you
   were disconnected: the screen may be locked, or a different app may be in
   front.
3. Resume from the **last step you verified**, not the last step you
   attempted.

If the screen is locked, ask the owner to unlock it. Never try to unlock it
yourself.

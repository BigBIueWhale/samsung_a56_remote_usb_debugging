# Briefing for an AI agent controlling the Galaxy A56

*This file is written to you, the AI agent (Claude Code, Codex, or similar),
running on the owner's Ubuntu workstation (`ronenzyroff.com`). The owner will
point you here. Read all of it before touching the phone.*

> **Update 2026-11-09: one recovery card.** When the link is down, give the owner [the card in §6](#the-recovery-card-give-this-to-the-owner) word for word, and nothing else.
> - **Its first line says Wireless debugging OFF is normal.** The owner finds it off every time the link drops and suspects it, but Android turns it off whenever the phone isn't on Wi-Fi, and the link never uses it.
> - **Most drops are Android killing Termux while the phone stays up** (23/10, 29/10, 06/11 and 09/11/2026 in `dumpsys activity exit-info com.termux`); the phone rebooted on 27/10 and 08/11. What sends the kill isn't known.
> - **Part A of the card fixes a killed Termux** (tested 09/11/2026). Part B, the Wi-Fi bootstrap, is only for a reboot.

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
- **Never send input while a call is ringing or active, or while the call
  screen is in front.** Check `dumpsys telephony.registry | grep -m1
  mCallState` (0 = idle) together with the foreground app before every input;
  an incoming call can take the screen between your check and your keystroke.
  On 2026-10-07 at 15:40 an Enter sent about 8 seconds after a call began
  ringing may have answered it (the call was "answered from the call screen" at
  that second and lasted 86 seconds with nobody speaking).

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

**When it drops, and why.** While it's down, the workstation's journal gives the
time the last tunnel session ended:

```sh
journalctl --since -24h | grep -E 'Accepted publickey for user from 172.30.77|Session [0-9]+ logged out'
```

Once it's back, one command says which case it was:

```sh
timeout 30 adb -s 127.0.0.1:7555 shell 'uptime; getprop service.adb.tcp.port; dumpsys activity exit-info com.termux | grep -m6 -E "timestamp=|reason="'
```

- **Termux was killed, the phone stayed up:** an exit-info `timestamp=` at the
  drop time, with `reason=2 (SIGNALED)` or `reason=3 (LOW_MEMORY)`, and an
  `uptime` older than the drop.
- **The phone rebooted:** `uptime` starts after the drop (and the owner needed
  part B of the card to bring port 5555 back).
- The logcat buffers reach back only about an hour, so they can't name the
  killer later.

## 6. Diagnosis, and what to tell the owner

### The recovery card (give this to the owner)

Cases 1, 2 and 4 below all end in this card. Copy it to the owner as it is.
**Tested 09/11/2026 12:09–12:10:** Termux had been killed at 00:45:24, and
part A alone brought the link back.

> **Wireless debugging OFF is normal. Ignore it.** Android switches it off
> whenever the phone isn't on Wi-Fi. The link doesn't use it; it uses adb port
> 5555, which stays open until the phone reboots.
>
> **A. In Termux** (open a new session from the left drawer if the current one
> is busy):
>
> ```
> termux-wake-lock
> pkill -f .tunnel/tunnel.sh
> pkill -f .tunnel/id_tunnel
> nohup bash ~/.tunnel/tunnel.sh >/dev/null 2>&1 &
> adb connect 127.0.0.1:5555
> adb devices
> ```
>
> - **`127.0.0.1:5555  device`:** done; skip B. An extra `emulator-5554
>   device` line is the same phone. "daemon not running; starting now" and
>   the silent `pkill` lines are normal.
> - **`Connection refused` / `failed to connect`:** the phone rebooted. Do B.
> - **`unauthorized`:** on the phone, tick "Always allow" and tap Allow, then
>   run the last two lines again.
>
> **B. Only after a reboot: reopen port 5555**
>
> 1. Settings → Developer options: **USB debugging** on.
> 2. Join **any Wi-Fi as a client**. Another phone's hotspot works, even with
>    no internet; this phone's own hotspot doesn't.
> 3. **Wireless debugging** on; at "Allow wireless debugging on this network?"
>    tick "Always allow on this network" and tap Allow. Tap the **words**
>    "Wireless debugging" and read **IP address & Port**.
> 4. In Termux: `adb connect IP:PORT`, then `adb -s IP:PORT tcpip 5555`.
>    Expect `restarting in TCP mode port: 5555`. Only if it says
>    `failed to authenticate`: pair once ([README Step 5](README.md#step-5--pair-termuxs-adb-with-the-phone),
>    split screen), then repeat.
> 5. `adb connect 127.0.0.1:5555` and `adb devices`: expect
>    `127.0.0.1:5555  device`. Then turn Wi-Fi off.
>
> **C. Check.** After 30 seconds, `tail -3 ~/.tunnel/log`. Holding = the last
> line is `connect 172.30.77.1` and no `exit` line appears after it a minute
> later. (When Android kills Termux, the loop dies without writing `exit`.)

### Case 1: no listener on `127.0.0.1:7555` (check A is empty)

**Meaning:** the phone's loop isn't connected: Termux was killed, the phone
rebooted, or it has no network. **Give the owner the card.**

A dead old session holding 7555 fixes itself since 2026-10-05: the new
connection ends it (`journalctl -t phone_tunnel` shows the takeover). Only if
that ever fails, free the port by hand as in
[README §9.1](README.md#91-a-stale-tunnel-after-a-network-drop-2026-09-28),
and never end a session with a shell under it.

### Case 2: the listener exists, but adb can't reach the phone

Check A is fine, but B, C or D fail: `Connection refused`, `closed`,
`offline`, `no devices/emulators found`, or a protocol error.

**Meaning:** nothing answers on the phone's port 5555. Most likely **the phone
rebooted**, or USB debugging was turned off. **Give the owner the card;** part
B will be needed.

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
> signal. If it stays bad, run part A of the card (it restarts the tunnel).

**Seen on 2026-09-28:** `get-state` kept saying `device` while every `adb
shell` timed out. The SSH leg had died silently. When the owner restarted
the tunnel, it hit `remote port forwarding failed`, because the old session
still held 7555. Since 2026-10-05 the new connection takes the port over by
itself.

## 7. When the owner says "continue"

1. Run the section 5 check again.
2. Take a fresh screenshot or UI dump. The phone may have changed while you
   were disconnected: the screen may be locked, or a different app may be in
   front.
3. Resume from the **last step you verified**, not the last step you
   attempted.

If the screen is locked, ask the owner to unlock it. Never try to unlock it
yourself.

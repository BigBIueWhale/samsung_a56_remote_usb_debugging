# Research notes: how Android's adb behaves, and why each step works

This page collects the research behind the steps in the main
[README](../README.md). It was gathered on 2026-09-28 in two ways:

- **Source code.** Android Open Source Project (AOSP) code, read through GitHub
  mirrors because `android.googlesource.com` and `cs.android.com` were not
  reachable from the research environment.
  - Where no AOSP mirror existed, the LineageOS forks were used. Branch
    `lineage-23.2` is based on Android 16 QPR2 and `lineage-24.0` on Android 17.
  - Every source link below pins a tag or branch, and the quoted lines were
    downloaded and checked again while writing this page.
- **Field reports.** Reports from people who did similar things. Items marked
  **[snippet]** could only be read as search-result excerpts, because the proxy
  blocked the page. Treat those as less certain.

The phone itself (Samsung Galaxy A56 5G) was not instrumented. Everything about
its behaviour here is either what we observed in the session (screenshots and
Termux output) or what the source code implies.

Contents:

1. [Where adb listens on the phone](#1-where-adb-listens-on-the-phone)
2. [Wireless debugging requires Wi-Fi and turns itself off](#2-wireless-debugging-requires-wi-fi-and-turns-itself-off)
3. [Legacy TCP mode (`adb tcpip 5555`)](#3-legacy-tcp-mode-adb-tcpip-5555)
4. [Why USB debugging must stay on](#4-why-usb-debugging-must-stay-on)
5. [Android does not firewall adbd](#5-android-does-not-firewall-adbd)
6. [Service discovery (mDNS) and manual IP:port](#6-service-discovery-mdns-and-manual-ipport)
7. [Authorization lifetime](#7-authorization-lifetime)
8. [Samsung and Google policy features](#8-samsung-and-google-policy-features)
9. [Field reports](#9-field-reports)
10. [Known risks and pending changes](#10-known-risks-and-pending-changes)

---

## 1. Where adb listens on the phone

`adbd` is the adb daemon on the phone. Every kind of adb listener it opens binds
to **all interfaces**: Wi-Fi, mobile data, a VPN tunnel, and the phone's own
loopback address `127.0.0.1`. That's why Termux on the phone could reach it at
`127.0.0.1`. **Confidence: high.**

| Listener | Code | What it shows |
|---|---|---|
| Wireless debugging (TLS) server | [`daemon/adb_wifi.cpp` L198](https://github.com/mirror/platform_packages_modules_adb/blob/android-16.0.0_r4/daemon/adb_wifi.cpp#L198) | `sTlsServer = new TlsServer(0);`. Port 0 means the kernel picks a random free port, so the port changes every time Wireless debugging starts (45245 in our session). |
| | [L89](https://github.com/mirror/platform_packages_modules_adb/blob/android-16.0.0_r4/daemon/adb_wifi.cpp#L89) | `unique_fd fd(network_inaddr_any_server(port_, SOCK_STREAM, &err));` |
| | [L137](https://github.com/mirror/platform_packages_modules_adb/blob/android-16.0.0_r4/daemon/adb_wifi.cpp#L137) | `adb_socket_accept(fd, nullptr, nullptr)`. There is no filtering by peer address. |
| The "any" helper | [`libcutils/socket_inaddr_any_server_unix.cpp` L32-L43](https://github.com/aosp-mirror/platform_system_core/blob/android-16.0.0_r3/libcutils/socket_inaddr_any_server_unix.cpp#L32-L43) | `/* open listen() port on any interface */` … `addr.sin6_addr = in6addr_any;`. This is a dual-stack IPv6 socket, so it accepts IPv4 too. |
| Pairing server (runs in `system_server`) | [`com_android_server_adb_AdbDebuggingManager.cpp` L75-L76](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r3/services/core/jni/com_android_server_adb_AdbDebuggingManager.cpp#L75-L76) | `pairing_server_new_no_cert(..., 0)`. Port 0 again, so the pairing port is random each time (46285 in our session). |
| | [`pairing_connection/pairing_server.cpp` L230](https://github.com/mirror/platform_packages_modules_adb/blob/android-16.0.0_r4/pairing_connection/pairing_server.cpp#L230) | `server_fd_.reset(socket_inaddr_any_server(port_, SOCK_STREAM));` |
| Legacy TCP mode (`adb tcpip N`) | [`socket_spec.cpp` L374](https://github.com/mirror/platform_packages_modules_adb/blob/android-16.0.0_r4/socket_spec.cpp#L374) | `result = network_inaddr_any_server(port, SOCK_STREAM, error);` |

The same `TlsServer(0)` and `network_inaddr_any_server` pattern has been in
place from Android 11 through Android 17 (LineageOS `lineage-24.0`, August 2026).

## 2. Wireless debugging requires Wi-Fi and turns itself off

This is what [screenshot 01](../screenshots/01-wireless-debugging-refused-on-5g.jpg)
shows: "Please connect to a Wi-Fi network" while the phone was on 5G.
**Confidence: high for Android 11-16.**

Source: [`AdbDebuggingManager.java` (android-16.0.0_r3)](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r3/services/core/java/com/android/server/adb/AdbDebuggingManager.java).

- **It must be a Wi-Fi client connection.** Mobile data doesn't count, and
  neither does the phone's own hotspot.
  [L1369-L1371](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r3/services/core/java/com/android/server/adb/AdbDebuggingManager.java#L1369-L1371):
  `if (wifiInfo == null || wifiInfo.getNetworkId() == -1) { Slog.i(TAG, "Not connected to any wireless network. Not enabling adbwifi."); ...`
- **Each network must be approved, identified by its BSSID** (the access
  point's hardware address, not its name). This produces the dialog in
  [screenshots 02-03](../screenshots/02-allow-wireless-debugging-on-this-network.jpg).
  - [L1403-L1410](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r3/services/core/java/com/android/server/adb/AdbDebuggingManager.java#L1403-L1410):
    `if (mAdbKeyStore.isTrustedNetwork(bssid)) { return true; }` … `startConfirmationForNetwork(ssid, bssid);`
  - Ticking "Always allow on this network" stores the BSSID:
    [L1123](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r3/services/core/java/com/android/server/adb/AdbDebuggingManager.java#L1123)
    `mAdbKeyStore.addTrustedNetwork(bssid);`
- **It turns itself off automatically** when Wi-Fi is disabled, when Wi-Fi
  disconnects, or when the BSSID changes (for example, roaming to another
  access point with the same name).
  [L648-L699](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r3/services/core/java/com/android/server/adb/AdbDebuggingManager.java#L648-L699)
  logs `"Wifi disabled. Disabling adbwifi."`, `"Network disconnected. Disabling adbwifi."`
  and `"Detected wifi network change. Disabling adbwifi."`. A VPN going up or
  down doesn't trigger this; only Wi-Fi events do.
- **Newer versions add automatic reconnection.**
  - Android 16 QPR2 has a feature flag, `allow_adb_wifi_reconnect` ("Allow
    wireless debugging to auto connect on trusted networks."), in
    [`adb_flags.aconfig`](https://github.com/LineageOS/android_frameworks_base/blob/lineage-23.2/services/core/java/com/android/server/adb/adb_flags.aconfig).
    It was not verified whether Samsung's build turns it on.
  - Android 17 also trusts networks by name (SSID):
    [`AdbKeyStore.java` L323-L328 (lineage-24.0)](https://github.com/LineageOS/android_frameworks_base/blob/lineage-24.0/services/core/java/com/android/server/adb/AdbKeyStore.java#L323-L328).
  - Google's "ADB Wi-Fi 2.0" announcement (Android 17 with platform-tools
    37.0.0) describes the same re-enable-on-trusted-network behaviour.
    **[snippet]**

**Hotspot hosting doesn't count.** When the phone hosts its own hotspot,
`getNetworkId()` is `-1`, so the setting reverts. Only rooted phones with
LSPosed modules get around this (for example `io.drsr.hotspotadb`,
`nowifi-adb`). That's why we needed a *friend's* hotspot. **[snippet]**

## 3. Legacy TCP mode (`adb tcpip 5555`)

This older mode is not tied to Wi-Fi, which is why the final setup uses it.
**Confidence: high for the code paths; medium-high that it survives network
changes, which was confirmed in our session (Step 8).**

- **The exact message we saw** comes from
  [`daemon/restart_service.cpp` L64-L65](https://github.com/mirror/platform_packages_modules_adb/blob/android-16.0.0_r4/daemon/restart_service.cpp#L64-L65):
  `SetProperty("service.adb.tcp.port", ...)` and
  `WriteFdFmt(fd.get(), "restarting in TCP mode port: %d\n", port);`.
  adbd then restarts and listens on that port.
- **It is lost on reboot.** Properties named `service.*` are not persistent.
  - adbd reads `service.adb.tcp.port` first and then `persist.adb.tcp.port`
    ([`daemon/main.cpp` L277-L279](https://github.com/mirror/platform_packages_modules_adb/blob/android-16.0.0_r4/daemon/main.cpp#L277-L279)).
  - Setting the persistent variant requires root.
- **How to undo it without rebooting:** `adb usb` sets the property back to 0
  ([L70](https://github.com/mirror/platform_packages_modules_adb/blob/android-16.0.0_r4/daemon/restart_service.cpp#L70)).
- **It doesn't react to network changes.** adbd has no network-change hook,
  and `kick_all_tcp_tls_transports()` only closes TLS (Wireless debugging)
  connections, not legacy TCP ones. So the port stays up across
  Wi-Fi → 5G → Wi-Fi until reboot.
- **It needs no cable.** The `tcpip:5555` command can be sent over an existing
  Wireless debugging connection, which is exactly what Step 6 did.
- **Its wire protocol is not encrypted.** Legacy TCP adb authenticates the
  computer with its RSA key, which is why the phone shows "Allow USB
  debugging?". It does not encrypt the traffic. In this setup the plain adb
  traffic only ever travels over the phone's loopback address and the
  workstation's loopback address. Between them it rides inside the encrypted
  SSH connection.

## 4. Why USB debugging must stay on

Wireless debugging switches itself off when the phone leaves Wi-Fi. If adbd
stopped at that moment, port 5555 would close with it. It doesn't stop,
because of
[`AdbService.java` L392-L393 (lineage-23.2)](https://github.com/LineageOS/android_frameworks_base/blob/lineage-23.2/services/core/java/com/android/server/adb/AdbService.java#L392-L393):

```java
private void stopAdbd() {
    if (!mIsAdbUsbEnabled && !mIsAdbWifiEnabled) {
```

adbd is only stopped when **both** USB debugging and Wireless debugging are
off. Keeping "USB debugging" on keeps adbd, and therefore port 5555, alive on
5G. This was confirmed in the session (Step 8 of the README: Wi-Fi off, and
`127.0.0.1:5555` still connected). **Confidence: high.**

## 5. Android does not firewall adbd

These points explain why adb worked over the phone's loopback address and why
it would also work over a VPN tunnel interface. **Confidence: high for AOSP.
OEM (Samsung) hooks were not verifiable.**

- **The per-app network restrictions skip system processes.**
  - Android applies these restrictions (doze, standby, restricted, background,
    the Android 16 local-network protection) through BPF programs.
  - All of them exempt UIDs below 10000; adbd runs as `shell` (UID 2000):
    [`bpf/progs/netd.h` L274-L277](https://github.com/LineageOS/android_packages_modules_Connectivity/blob/lineage-23.2/bpf/progs/netd.h#L274-L277)
    `// MAX_SYSTEM_UID is AID_NOBODY == 9999, while AID_APP_START == 10000`.
  - The owner match returns `PASS` for system UIDs before anything else:
    [`netd.c` L481-L501](https://github.com/LineageOS/android_packages_modules_Connectivity/blob/lineage-23.2/bpf/progs/netd.c#L481-L501).
- **The Android 14+ VPN "ingress discard" doesn't apply to the tunnel itself.**
  It only drops packets addressed to a VPN address that arrive on a
  **non-VPN** interface; the VPN interface is the allowed one:
  [`netd.c` L458-L463](https://github.com/LineageOS/android_packages_modules_Connectivity/blob/lineage-23.2/bpf/progs/netd.c#L458-L463).
- **Replies leave through the interface the connection came in on.** netd
  marks incoming packets with their network, and init turns on mark
  reflection for replies:
  - [`RouteController.cpp` L476-L489](https://github.com/LineageOS/android_system_netd/blob/lineage-23.2/server/RouteController.cpp#L476-L489)
  - [`init.rc` L301-L305](https://github.com/aosp-mirror/platform_system_core/blob/android-16.0.0_r3/rootdir/init.rc#L301-L305):
    `fwmark_reflect 1`, `tcp_fwmark_accept 1`

## 6. Service discovery (mDNS) and manual IP:port

adb normally finds phones automatically using mDNS. The phone advertises two
services: `_adb-tls-connect._tcp` and `_adb-tls-pairing._tcp`.

mDNS is link-local multicast (`224.0.0.251`), so it never crosses a routed
tunnel such as WireGuard or SSH. Typing `IP:port` by hand always works; see the
adb client help text,
[`client/commandline.cpp` L113-L116](https://github.com/mirror/platform_packages_modules_adb/blob/android-16.0.0_r4/client/commandline.cpp#L113-L116):

```
 connect HOST[:PORT]      connect to a device via TCP/IP [default port=5555]
 pair HOST[:PORT] [PAIRING CODE]
```

That's why every command in the README spells out the IP and port.
**Confidence: high.**

## 7. Authorization lifetime

- **The default is 7 days.** Android revokes an adb authorization if that
  computer hasn't connected for 7 days:
  [`Settings.java` L17203](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r3/core/java/android/provider/Settings.java#L17203)
  `DEFAULT_ADB_ALLOWED_CONNECTION_TIME = 604800000` (milliseconds, which is
  7 days).
- **Wireless-debugging pairings use the same key store,** so the same timeout
  applies to them.
- **The Developer options toggle turns it off.** "Disable adb authorization
  timeout" sets the value to 0, which means never revoke. It was already on in
  [screenshot 01](../screenshots/01-wireless-debugging-refused-on-5g.jpg).
- **Removing authorizations yourself:** "Revoke USB debugging authorizations"
  removes every authorized computer. A single wireless pairing can be removed
  with its gear icon under "Paired devices".

## 8. Samsung and Google policy features

- **Galaxy A56 software.**
  - The phone launched in March 2025 with One UI 7 (Android 15).
  - One UI 8 (Android 16) arrived in late September 2025, and One UI 8.5
    (Android 16 QPR2) around May-June 2026.
  - The One UI 9 (Android 17) beta was open in September 2026.
  - These dates are **[snippet]**-level (sammyfans and similar sites). The
    exact build on this phone was not recorded; see Settings → About phone →
    Software information.
- **Samsung Auto Blocker** (Settings → Security and privacy → Auto Blocker).
  - It is on by default for phones launched with One UI 6.1.1 or later, which
    includes the A56.
  - It blocks "commands by USB cable" and greys out USB debugging.
  - A KeyMapper issue (June 2026) reports that it also prevents Wireless
    debugging from staying on:
    [keymapperorg/KeyMapper#2155](https://github.com/keymapperorg/KeyMapper/issues/2155).
  - **Confidence: medium-high. [snippet] for Samsung's own pages.**
  - In our session USB debugging was already on and worked, so Auto Blocker
    was evidently not blocking it.
- **Samsung Identity Check** (One UI 7+, if enabled) may require biometrics to
  open Developer options away from trusted places. **[snippet]**
- **Android 16 Advanced Protection** does not currently disable adb.
  - Google's documented feature list
    ([developer.android.com](https://developer.android.com/privacy-and-security/advanced-protection-mode))
    and the Android 16 QPR2 code have no adb hook.
  - Strings in Google Play Services 26.25.31 hint that it may restrict
    Developer options in the future. **[snippet]**

## 9. Field reports

The same technique has been reported working over Tailscale, which on Android
uses the same system VPN API as the official WireGuard app:

- **Legacy `tcpip 5555` over Tailscale on LTE:**
  - simonsafar.com, "adb superpowers" (2022) **[snippet]**
  - [gist by shehbajdhillon](https://gist.github.com/shehbajdhillon/2ddcd702ed41fc1fa45bfc0075918c12):
    USB is needed "once per reboot"
  - [Genymobile/scrcpy#6708](https://github.com/Genymobile/scrcpy/issues/6708)
    (March 2026)
- **Wireless debugging over a VPN while the phone is on Wi-Fi:**
  - kxxt.dev, "Full-Featured Tailscale on Android": "could only be enabled if
    the device is connected to Wi-Fi (you cannot enable it even if you start a
    hotspot on your phone)… it actually listens on other network interfaces as
    well." **[snippet]**
  - XDA thread
    [adb-wireless-debugging-through-vpn](https://xdaforums.com/t/adb-wireless-debugging-through-vpn.4699623/)
    **[snippet]**
- **Official WireGuard app on a non-rooted phone.** It uses the userspace
  `GoBackend` through Android's `VpnService`
  ([WireGuard/wireguard-android](https://github.com/WireGuard/wireguard-android)).
  Incoming packets are accepted only from addresses in the peer's
  `AllowedIPs`.
- No first-hand report was found for the specific combination we used: legacy
  TCP mode on the phone, a Termux `ssh -R` reverse tunnel, and adb on the
  workstation. The session itself confirmed everything up to the tunnel being
  established (see the README's status section).

## 10. Known risks and pending changes

- **CVE-2026-0073** is a wireless-adb authentication bypass in
  `adbd_tls_verify_cert`.
  - It affects Android 14, 15 and 16 before the 2026-05-01 security patch
    level, per the public PoC
    [adityatelange/poc-CVE-2026-0073](https://github.com/adityatelange/poc-CVE-2026-0073)
    **[snippet]**.
  - adbd is updated as a Google Play system (Mainline) module, so the fix can
    arrive separately from the monthly patch level.
  - Keep the phone updated. Leave Wireless debugging off when you're not
    bootstrapping; it switches itself off anyway when you leave Wi-Fi.
- **Binding to Wi-Fi only (proposal).** After that CVE, a Google engineer
  proposed binding wireless adb only to the Wi-Fi interface (`wlan0`) in
  July 2026 **[snippet]** (Android Authority coverage of the Google Issue
  Tracker discussion). It had not shipped as of the latest source read
  (`lineage-24.0`).
  - If it ships for Wireless debugging, the bootstrap in Step 6 still works,
    because that step connects to the Wi-Fi address (`172.20.10.10`).
  - If it is extended to legacy TCP mode, `127.0.0.1:5555` would stop working
    and this setup would need rethinking.
- **Port 5555 listens on every network the phone joins,** including public
  Wi-Fi and possibly the carrier's IPv6. A stranger can't get in without you
  tapping "Allow" on the phone. Deny any "Allow USB debugging?" prompt you
  didn't cause. Close the port with a reboot, `adb usb`, or by turning off
  USB debugging.

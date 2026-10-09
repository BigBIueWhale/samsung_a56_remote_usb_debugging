# adb's own listener on the workstation: UDP 5353 (found 2026-10-10)

## In short

- **What:** the **adb server on the workstation** opens UDP port **5353** on every interface (`0.0.0.0:5353`, four sockets). This isn't the phone's adbd; it's the adb program on the computer. It uses that port to discover phones that advertise Wireless debugging (mDNS).
  - It is **on by default.** Nobody enabled it.
  - **This setup never uses it.** The phone is reached at `127.0.0.1:7555`, and mDNS can't cross the tunnel anyway ([why](android-research.md#6-service-discovery-mdns-and-manual-ipport)).
- **Why it matters:** the workstation is internet-facing ([personal_server](https://github.com/BigBIueWhale/personal_server)'s DMZ posture). Anyone on the internet can send UDP to port 5353. Every such packet is parsed inside the adb server, which:
  - runs as the workstation account;
  - holds the phone's adb connection.
- **Verdict:** **no way in was found.**
  - adb sends no reply.
  - Fake announcements can't make adb connect anywhere.
  - The parser is memory-safe Rust.
  - **Three availability bugs** remain (below). At worst, a remote sender can stop discovery or grow the adb server's memory.
- **Fix: applied on 2026-10-10.** The adb server now starts with **`ADB_MDNS=0`**, so nothing listens on 5353 any more. [How, and the check](#the-fix-adb_mdns0).

## How it was found

personal_server's `verify_network_security.py` flagged it, once per socket:

```
[FAIL] UNEXPECTED: Port 5353/udp listening on 0.0.0.0
       Process: adb (PID: 96123)
```

```
$ ss -ulnp | grep adb
UNCONN 0 0   0.0.0.0:5353   0.0.0.0:*   users:(("adb",pid=96123,fd=19))
UNCONN 0 0   0.0.0.0:5353   0.0.0.0:*   users:(("adb",pid=96123,fd=18))
UNCONN 0 0   0.0.0.0:5353   0.0.0.0:*   users:(("adb",pid=96123,fd=17))
UNCONN 0 0   0.0.0.0:5353   0.0.0.0:*   users:(("adb",pid=96123,fd=15))
UNCONN 0 0 127.0.0.1:40923  0.0.0.0:*   users:(("adb",pid=96123,fd=7))
```

The `127.0.0.1:40923` socket is loopback-only. It is adb's internal wake-up channel ([`zero_config_driver_channel.rs`](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/zero_config_driver_channel.rs#120)).

## What was audited

- **The binary:** `~/.local/bin/adb`, `adb version` = **37.0.0-14910828** (platform-tools 37.0.0).
  - Its sha256 is `00108217733707a40debfc92c86d4232fd6e68870be5966515d74c071193ea90`. The same hash applies to:
    - the running process image (`/proc/<pid>/exe`);
    - the `adb` inside Google's `platform-tools_r37.0.0-linux.zip`, downloaded from dl.google.com.
  - Google's repository manifest now lists only 37.0.1. The zip's sha1 (`bcf323933980a59dccc3f14c339aed5fb2171163`) matches the one recorded in the AUR's 37.0.0 package.
  - **Conclusion:** an unmodified Google build.
- **The source:** AOSP `platform/packages/modules/adb` at [`ad269d7d`](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34) (main, 2026-02-11). This is not a release tag.
  - Distinctive strings from the files below appear in the binary. Examples:
    - the thread name `libadbmdns_zero_config_driver`;
    - `ADB mdns is starting`;
    - `ERROR: mdns discovery disabled`;
    - the file names `adbmdns_bridge.rs` and `zero_config.rs`.
  - DNS parsing comes from the `simple-dns` crate. It was read at **0.11.2**, as vendored in AOSP's [`android-crates-io` @ `1f5e95c`](https://android.googlesource.com/platform/external/rust/android-crates-io/+/1f5e95cd6e996995023c9c0f7df0f15a8a43269e/crates/simple-dns). The binary doesn't print its crate version.
- **Which code owns port 5353:** the **Rust `libadbmdns`** library. It is the default backend.
  - Open Screen (C++) is used only with `ADB_MDNS_OPENSCREEN=1` ([`mdns_utils.cpp` L86-89](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/mdns_utils.cpp#86), [`transport_mdns.cpp` L134-140](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/transport_mdns.cpp#134)).
  - The running server has no `ADB_*` variables in its environment.
- **Method:**
  - A source read (by a Claude Opus 5.5 subagent), with each point below re-checked against the source.
  - A live probe: four unicast DNS-SD queries to port 5353, including adb's own service types. adb sent **no reply**.
  - **No fuzzing.** The workstation has no compiler toolchain, and nothing was installed. So the three bugs below are **read from the source, not reproduced.**

## The bugs

| # | What a remote sender can do | Effect | Severity |
|---|---|---|---|
| 1 | Send one announcement with a NUL byte in a name | adb's discovery thread panics and stops | Low |
| 2 | Flood address records with made-up names | adb server memory grows with no limit | Low–medium |
| 3 | Send a tiny packet that claims 65,535 records | A large, short-lived allocation per packet | Low |

None of them reaches adb's connection to the phone or runs code.

### 1. One packet stops discovery (NUL byte → `unwrap()` panic)

- **The code:** before every discovery event, the Rust side turns names into C strings with `unwrap()` ([`adbmdns_bridge.rs` L94-96](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/adbmdns_bridge.rs#94)):
  ```rust
  let instance_str = CString::new(instance_name).unwrap();
  let service_str = CString::new(service_type).unwrap();
  let hostname_str = CString::new(hostname).unwrap();
  ```
  `CString::new` fails when its input contains a NUL byte, and `unwrap()` then panics.
- **Why a NUL gets that far:**
  - `simple-dns` accepts any byte in a label and only checks its length ([`name.rs` L213-215](https://android.googlesource.com/platform/external/rust/android-crates-io/+/1f5e95cd6e996995023c9c0f7df0f15a8a43269e/crates/simple-dns/src/dns/name.rs#213): "Parsing allow invalid characters in the label").
  - Labels become strings with `String::from_utf8_lossy` ([`name.rs` L432-437](https://android.googlesource.com/platform/external/rust/android-crates-io/+/1f5e95cd6e996995023c9c0f7df0f15a8a43269e/crates/simple-dns/src/dns/name.rs#432)), which keeps NUL because NUL is valid UTF-8.
  - The instance name and the host name both come from the packet.
- **The same file already has the safe version:** `cstring_from_str` ([L68-75](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/adbmdns_bridge.rs#68)) logs a warning and uses an empty string instead of panicking. The event path doesn't use it.
- **Preconditions:** the announcement must be for one of adb's service types, which are public: `_adb._tcp`, `_adb-tls-connect._tcp`, `_adb-tls-pairing._tcp` ([`zero_config.rs` L117-119](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/zero_config.rs#117)).
- **Effect:** the panic happens on the Rust thread `libadbmdns_zero_config_driver` ([L175-183](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/adbmdns_bridge.rs#175)), before any C++ code is called. The build unwinds on panic: the binary has unwind tables and `__rust_panic_cleanup`. So only that thread ends. Discovery stops, while the adb server and `127.0.0.1:7555` keep working. This setup doesn't use discovery, so it loses nothing.

### 2. Unbounded memory from address records

- **The code:**
  - PTR, SRV and TXT records are kept only for adb's own service types ([`zero_config.rs` L249](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/zero_config.rs#249), [L266](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/zero_config.rs#266), [L300](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/zero_config.rs#300)).
  - **A and AAAA records are kept for any name** ([L275-284](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/zero_config.rs#275)).
- **No limit:**
  - There is no cap on the number of stored records anywhere in `zero_config.rs` or `store.rs`.
  - Each record lives for the TTL in the packet, which can be up to 2³² − 1 seconds (about 136 years).
  - The store is emptied only when the network changes ([L198-202](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/zero_config.rs#198)).
- **Effect:** a sustained flood of unique names grows the adb server's memory until the server restarts or the network changes. On a shared workstation, that memory comes out of everything else.

### 3. Pre-allocation from a count in the packet

- **The code:** `simple-dns` reserves room for as many records as the packet header claims, before parsing any of them ([`packet.rs` L144](https://android.googlesource.com/platform/external/rust/android-crates-io/+/1f5e95cd6e996995023c9c0f7df0f15a8a43269e/crates/simple-dns/src/dns/packet.rs#144)):
  ```rust
  let mut section_items = Vec::with_capacity(items_count as usize);
  ```
- **Effect:** a header claiming 65,535 records makes the parser reserve memory for that many records, then fail on the first one and free it. The cost is extra allocation work per packet, with nothing kept.

### Why internet packets are treated like LAN packets

- **The code:** the receive loop calls `recv()`, which doesn't even return the sender's address ([`zero_config_driver.rs` L174](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/zero_config_driver.rs#174)).
- **Effect:** a unicast packet from the internet to port 5353 is handled exactly like a multicast announcement from the LAN.
- **What the standard says:** RFC 6762 §11 ("Source Address Check") says to ignore responses that don't come from the local link. This one design choice is what lets bugs 1–3 be reached from the internet.

### A latent mismatch (harmless today)

- **The mismatch:** the Rust side passes the IPv4 **byte** count (`raw_v4s.len()`, [`adbmdns_bridge.rs` L126](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/adbmdns_bridge.rs#126)). The C++ side names the same value `numIPV4s`, as if it were an address count.
- **Why it's harmless:** the C++ side only checks `numIPV4s > 0` and reads the first 4 bytes ([`adbmdns.cpp` L101-102](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/adbmdns.cpp#101)).
- **When it would matter:** a future change that loops over `numIPV4s` addresses would read 4× past the buffer.
- **The other fields match:** IPv6 is passed as an address count with 16 bytes each, and TXT entries carry explicit lengths.

## Checked and not a problem

- **No code execution path was found.**
  - Parsing and record handling are safe Rust.
  - The only `unsafe` is the hand-off to C++ ([`adbmdns_bridge.rs` L120-133](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/adbmdns_bridge.rs#120)).
  - The C++ receiver copies only what it is given ([`adbmdns.cpp` L91-111](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/adbmdns.cpp#91)).
- **No reply, so no information leak and no reflection.** `libadbmdns` only sends its own multicast queries; it has no responder. The live probe got nothing back.
- **No auto-connect from a fake announcement.**
  - By default, auto-connect is limited to `adb-tls-connect` ([`adb_mdns.cpp` L43-48](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/adb_mdns.cpp#43)), and only for paired hosts: "Don't try to auto-connect if not in the keystore" ([`transport_mdns.cpp` L80](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/transport_mdns.cpp#80)).
  - The workstation has no paired Wireless-debugging hosts (no `~/.android/adb_known_hosts.pb`), because Termux did the pairing ([Step 5](../README.md#step-5--pair-termuxs-adb-with-the-phone)).
- **Four sockets, one exposure.** It's one process and one parser. The driver binds one socket for each usable interface: up, not loopback, not link-local ([`zero_config_driver.rs` L113-123](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/zero_config_driver.rs#113), [L146](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/adbmdns/zero_config_driver.rs#146)).

## The fix: `ADB_MDNS=0`

- **The switch:** discovery starts only when `ADB_MDNS` is unset or isn't `0`:
  - `is_enabled()` is defined at [`mdns_utils.cpp` L77-79](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/mdns_utils.cpp#77);
  - it is checked at server start, [`main.cpp` L136-138](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/main.cpp#136).

  ```cpp
  bool is_enabled() {
      return !getenv("ADB_MDNS") || strcmp(getenv("ADB_MDNS"), "0") != 0;
  }
  ```
  With `ADB_MDNS=0` no 5353 socket is ever created. The variable isn't in `adb --help` or the online docs.
- **`ADB_MDNS_OPENSCREEN` is not an off switch.** It only picks the backend ([`mdns_utils.cpp` L81-89](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/mdns_utils.cpp#81)).
- **The catch:** the adb server reads the variable once, at start. It inherits the environment of whichever `adb` command first finds no server running. That could be the reconnect service (every 20 s), an agent, or a terminal. So set it everywhere adb can start:
  1. **The reconnect service:** in `~/.config/systemd/user/phone-adb-reconnect.service`, under `[Service]`, add
     ```
     Environment=ADB_MDNS=0
     ```
     then run `systemctl --user daemon-reload && systemctl --user restart phone-adb-reconnect`.
  2. **Terminals and agents:** add `export ADB_MDNS=0` to `~/.bashrc` (interactive shells) and `~/.profile` (login shells, SSH, and the desktop session).
  3. **Restart the server once, from a shell that already has the variable,** so no other `adb` command can start a server without it first:
     ```
     export ADB_MDNS=0
     adb kill-server && adb start-server && adb connect 127.0.0.1:7555
     ```
     If `connect` loses a race with the reconnect service, the service attaches the phone within ~20 s anyway.
- **Verify:**
  ```
  ss -uanp | grep adb                      # nothing: adb has no UDP sockets at all
  adb mdns check                           # ERROR: mdns discovery disabled
  P=$(ss -ltnpH 'sport = :5037' | grep -o 'pid=[0-9]*' | cut -d= -f2)
  tr '\0' '\n' < /proc/$P/environ | grep ADB_MDNS                    # ADB_MDNS=0
  ```
  `adb mdns check` prints that exact message when discovery is off ([`transport_mdns.cpp` L150-152](https://android.googlesource.com/platform/packages/modules/adb/+/ad269d7d8b925f8e1a98c099d6f71ab211e9de34/client/transport_mdns.cpp#150)).
- **It costs nothing here.** The phone is always reached by IP:port through the tunnel.

### Applied on the workstation (2026-10-10, 02:42)

- **Steps 1–3 were done as written above.** The service file in [`scripts/workstation/`](../scripts/workstation/phone-adb-reconnect.service) now has the `Environment=` line.
- **The check afterwards:**
  ```
  $ ss -uanp | grep -c adb
  0
  $ adb mdns check
  ERROR: mdns discovery disabled
  $ tr '\0' '\n' < /proc/2507013/environ | grep ADB_      # the server on 127.0.0.1:5037
  ADB_MDNS=0
  $ adb devices -l
  127.0.0.1:7555         device product:a56xnaxx model:SM_A566B device:a56x transport_id:2
  ```
- **The phone link was back within seconds.** `adb -s 127.0.0.1:7555 shell getprop ro.product.model` returned `SM-A566B`.

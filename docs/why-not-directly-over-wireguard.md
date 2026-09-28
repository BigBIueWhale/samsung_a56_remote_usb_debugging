# Why the workstation can't just `adb connect` to the phone through WireGuard

This page records the analysis behind a design decision in the main
[README](../README.md). The phone was already connected to the workstation with
WireGuard, using
[BigBIueWhale/mobile-egress-wireguard](https://github.com/BigBIueWhale/mobile-egress-wireguard).
It seemed natural for the workstation to reach back to the phone through that
tunnel. It can't, and the reason is a deliberate choice in that repository, not
a limitation of WireGuard or Android.

All links below point at the exact commits that were read:

- mobile-egress-wireguard at
  [`35c2261`](https://github.com/BigBIueWhale/mobile-egress-wireguard/tree/35c2261a8a819090f1440059fd12c097af9485c7)
- personal_server at
  [`421dd38`](https://github.com/BigBIueWhale/personal_server/tree/421dd38cd570ea5737c995856c31bb4f471f548d)

## First, a correction about `127.0.0.1`

It's tempting to think a phone on the VPN can open a website served on the
workstation's `127.0.0.1`. It can't. On the phone, `127.0.0.1` always means the
phone itself. Through the tunnel, the phone can reach:

- **Workstation services bound to all interfaces (`0.0.0.0`).** Reach them at
  the workstation's LAN IP, or at `172.30.77.1`, the workstation's own address
  on the VPN project's Docker network.
- **Services listening on the `haggai_computer` container's `127.0.0.1`.**
  Reach them at `172.30.77.3`, a special mapping that project provides. Its
  README says so explicitly: "Literal `127.0.0.1` on a VPN client still means
  that client itself"
  ([README.md L126-L127](https://github.com/BigBIueWhale/mobile-egress-wireguard/blob/35c2261a8a819090f1440059fd12c097af9485c7/README.md#L126-L127)).

## Tracing a connection from the workstation to the phone

The phone's tunnel address is `10.77.0.2` (the first client in `10.77.0.0/24`).
Suppose an agent on the workstation runs `adb connect 10.77.0.2:<port>`. The
attempt fails at every layer:

1. **The workstation has no route to `10.77.0.0/24`.** The WireGuard interface
   `wg0` doesn't live on the host. It lives inside the `mobile-wireguard`
   container's own network namespace. The host only knows the Docker network
   `172.30.77.0/29`
   ([compose.yaml L107](https://github.com/BigBIueWhale/mobile-egress-wireguard/blob/35c2261a8a819090f1440059fd12c097af9485c7/compose.yaml#L107)).
   A packet to `10.77.0.2` therefore goes to the home router and dies there.
2. **Adding a route wouldn't help.** Suppose someone added
   `10.77.0.0/24 via 172.30.77.2`. The container's forward chain drops by
   default
   ([vpn.nft L25](https://github.com/BigBIueWhale/mobile-egress-wireguard/blob/35c2261a8a819090f1440059fd12c097af9485c7/container/vpn.nft#L25)).
   Toward phones it only allows **replies** to connections the phone started:
   `ct state established,related`
   ([vpn.nft L40-L41](https://github.com/BigBIueWhale/mobile-egress-wireguard/blob/35c2261a8a819090f1440059fd12c097af9485c7/container/vpn.nft#L40-L41)).
   A new connection attempt (TCP SYN) is dropped.
3. **Running adb inside the VPN container's namespace wouldn't help either.**
   The outgoing SYN would leave, because the output chain accepts everything
   ([vpn.nft L45](https://github.com/BigBIueWhale/mobile-egress-wireguard/blob/35c2261a8a819090f1440059fd12c097af9485c7/container/vpn.nft#L45)).
   But the phone's SYN-ACK would be dropped: the input chain accepts only ICMP
   ping from `wg0`
   ([vpn.nft L20-L21](https://github.com/BigBIueWhale/mobile-egress-wireguard/blob/35c2261a8a819090f1440059fd12c097af9485c7/container/vpn.nft#L20-L21)).
4. **Other routes are closed too.**
   - **Another enrolled VPN device (for example a laptop):** there is no
     forward rule from `wg0` back into `wg0`, so it is dropped.
   - **The Haggai container:** it may only send replies to flows that the
     phone started
     ([vpn.nft L34-L35](https://github.com/BigBIueWhale/mobile-egress-wireguard/blob/35c2261a8a819090f1440059fd12c097af9485c7/container/vpn.nft#L34-L35)).

WireGuard itself would carry packets in both directions:

- The server knows the phone's latest endpoint.
- `PersistentKeepalive = 25` keeps the mobile carrier's NAT mapping open.
- The phone profile's `AllowedIPs = 0.0.0.0/0, ::/0` accepts any inner source
  address.

So the "one-way" behaviour comes entirely from routing and the nftables policy,
and it is intentional.

## What opening it would take, and why we didn't

Making the reverse direction work would need both of these:

- **A route on the host.** That is a global host change, which this project
  explicitly promises never to make.
- **New firewall rules** that accept new connections toward phones.

Either change widens the security model. Anything able to use that path could
start connecting to ports on every enrolled phone, including the phone's adb
daemon, whose only protection is key authorization.

A process with Docker access on the workstation could technically rewire this
itself. Docker-group membership is root-equivalent, and the project's
SECURITY.md says the container is "defense in depth, not a boundary against a
hostile host kernel or root-equivalent Docker operator". That would be a
deliberate reconfiguration, never an accident.

## The approach we used instead

We kept the VPN's one-way design and made **the phone** start the connection.
Termux on the phone runs `ssh -R` to the workstation's existing SSH server, and
the workstation's adb connects back through that SSH connection.

Connections that start on the phone are exactly what both the VPN and the
public internet allow, so nothing had to be opened. The SSH server is described
in [personal_server](https://github.com/BigBIueWhale/personal_server/blob/421dd38cd570ea5737c995856c31bb4f471f548d/scripts/05_install_openssh_server.sh):

- **Always listening on port 22:** socket-activated OpenSSH on `0.0.0.0:22`,
  IPv4 only
  ([L81](https://github.com/BigBIueWhale/personal_server/blob/421dd38cd570ea5737c995856c31bb4f471f548d/scripts/05_install_openssh_server.sh#L81)).
- **Password only, one account:** keys off
  ([L103-L106](https://github.com/BigBIueWhale/personal_server/blob/421dd38cd570ea5737c995856c31bb4f471f548d/scripts/05_install_openssh_server.sh#L103-L106)).
- **Port forwarding at OpenSSH defaults:** nothing sets `AllowTcpForwarding` or
  `DisableForwarding`, so `ssh -R` is allowed. `GatewayPorts` is also left at
  its default of `no`, so the forwarded port opens only on the workstation's
  `127.0.0.1`.
- **Reachable from the internet** through the router's DMZ (personal_server
  README, "DMZ" section).

## Using WireGuard for the SSH leg (optional)

With WireGuard **on**, point ssh at `user@172.30.77.1`. That is the
workstation's address on the VPN's internal Docker network, fixed by
[compose.yaml](https://github.com/BigBIueWhale/mobile-egress-wireguard/blob/35c2261a8a819090f1440059fd12c097af9485c7/compose.yaml#L107)
and checked at
[entrypoint.sh L43](https://github.com/BigBIueWhale/mobile-egress-wireguard/blob/35c2261a8a819090f1440059fd12c097af9485c7/container/entrypoint.sh#L43).

Benefits of using the tunnel for SSH:

- **Survives network switches.** The SSH session keeps working when the phone
  moves between Wi-Fi and mobile data, because the tunnel addresses don't
  change.
- **Gets through port-22 blocks.** It works on networks that block outgoing
  port 22, because WireGuard uses UDP/443.

With WireGuard **off**, use the public name `user@ronenzyroff.com`.

**Don't mix the two.** With WireGuard on, `ronenzyroff.com` makes the traffic
leave through the home router and come straight back in. That works only if the
router supports NAT loopback.

Neither audit will complain about the forwarded port:

- The VPN project's host audit exempts loopback listeners
  ([audit-host.sh L24](https://github.com/BigBIueWhale/mobile-egress-wireguard/blob/35c2261a8a819090f1440059fd12c097af9485c7/scripts/audit-host.sh#L24)).
- personal_server's verifier only flags external listeners
  ([verify_network_security.py L95](https://github.com/BigBIueWhale/personal_server/blob/421dd38cd570ea5737c995856c31bb4f471f548d/network_security/verify_network_security.py#L95)).

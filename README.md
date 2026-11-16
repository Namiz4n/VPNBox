# VPNBox

Bash helpers for installing and managing a **OpenVPN** server, a
**WireGuard** server, and a set of first-party VPN/proxy tools on a
Linux VPS. Everything is designed to be run as `root` on a fresh Debian
or Ubuntu system.

## Status

| Part | CI coverage | Real-VPS notes |
|------|-------------|----------------|
| OpenVPN (`install_openvpn.sh`) | ShellCheck strict | Upstream installer; tested manually. |
| WireGuard (`wireguard-install.sh`) | ShellCheck error-only | Switched public-IP detection from `http://` to `https://`; embedded sysctl tuning file directly in-tree instead of downloading from hwdsl2/vpn-extras (no external network dependency). Copyright/license header left untouched. |
| OpenConnect (`tools/ocserv.sh`) | ShellCheck + `ocserv --test-config` | Verified in CI. |
| MTProto (`tools/mtproto.sh`) | ShellCheck strict | Binary pinned; SHA-256 verified at install time. |
| WARP (`tools/warp.sh`) | ShellCheck strict | Cloudflare official repo; install-time smoke tested. |
| PPTP (`tools/pptp.sh`) | ShellCheck + dry-run structural checks | `pptpd` removed from Ubuntu 24.04+ repos; the tool detects this and refuses. |
| L2TP/IPsec (`tools/l2tp.sh`) | **ShellCheck strict** + **real strongSwan starter** + **real xl2tpd startup** | Config is now generated from the official man pages. CI runs `/usr/lib/ipsec/starter --nofork --debug-all` and `xl2tpd -D` against the *exact* generated files and fails on any unknown keyword / parse error. Windows/iOS/Android compatibility is **not yet tested on real clients**; users behind NAT may need the `EnableTransportModeDirectAccess` registry tweak (see below). |
| GRE (`tools/gre.sh`) | **ShellCheck strict** + dry-run mirror-assertion + netns functional ping + multiple-tunnel collision check | Functional netns test requires `ip_gre`; on runners where the module is unavailable the test is skipped with a warning but the dry-run check still runs. Multiple-tunnel isolation is asserted. |

Where a header says "verified in CI", the assertion ran against the
real software (not just grepped strings). Where it says "dry-run", the
script produced config that passed structural checks but was not fed to
the live daemon.

## Quick start

```bash
sudo bash <(curl -Ls https://raw.githubusercontent.com/Namiz4n/VPNBox/refs/heads/main/main.sh)
```

Pick a menu item. Each tool can also be run standalone:

```bash
sudo bash tools/ocserv.sh        # guided install or management menu
sudo bash tools/pptp.sh
sudo bash tools/l2tp.sh
sudo bash tools/gre.sh
```

Run a tool with **no arguments** to get a guided install (or a short
management menu when it is already installed). Subcommands remain
available for power users; `-h` / `--help` prints usage.

## Menu

| # | Tool | What it installs |
|---|------|------------------|
| 1 | OpenVPN | The pinned angristan OpenVPN installer (URL + commit in `install_openvpn.sh`) |
| 2 | WireGuard | The standalone `wireguard-install.sh` in this repo |
| 3 | OpenConnect | `ocserv` (OpenConnect VPN server) + `ocpasswd` user database |
| 4 | MTProto proxy | A pinned `mtg` binary (9seconds/mtg, SHA-256 verified) behind a systemd unit |
| 5 | Cloudflare WARP | The Cloudflare WARP client from Cloudflare's official repo |
| 6 | PPTP | `pptpd` (MS-CHAPv2 + 128-bit MPPE) |
| 7 | L2TP/IPsec | `strongSwan` + `xl2tpd` + `ppp` (PSK road-warrior) |
| 8 | GRE | An `iproute2` GRE P2P tunnel + systemd persistence |
| 0 | Quit | — |

## Supported OS (per tool)

- **Debian / Ubuntu only** (the tool detects the distro and refuses
  otherwise): `ocserv.sh`, `pptp.sh`, `l2tp.sh`, `gre.sh`.
- **Debian/Ubuntu + RHEL/Fedora/CentOS**: `warp.sh`.
- **`install_openvpn.sh` and `wireguard-install.sh`**: whatever their
  upstream installers support (OpenVPN's pinned installer targets
  Debian/Ubuntu; the WireGuard installer targets Debian/Ubuntu).

`pptpd` is **not shipped on Ubuntu 24.04+**; the PPTP tool detects that
and refuses to install, pointing you at L2TP/IPsec instead.

## Client setup notes

### L2TP/IPsec (menu 7)

Clients connect using the server's public IP, the PSK shown at install
time, and the username/password printed once during the initial
wizard.

- **Windows**: from behind NAT some Windows builds drop the L2TP/IPsec
  tunnel unless the registry key
  `HKLM\SYSTEM\CurrentControlSet\Services\PolicyAgent\EnableTransportModeDirectAccess`
  (DWORD) is set to `1`. Without it the connection either fails to
  negotiate Phase 1 or drops shortly after. See Microsoft documentation
  on IKE transport mode for details.
- **iOS / Android**: the native L2TP/IPsec clients work out of the box
  with the PSK configuration produced by this tool (transport-mode ESP,
  UDP 500/4500, IPSec Saref disabled).
- **Multiple clients behind one NAT**: the L2TP-over-IPsec model shares
  a single SPI per IPsec SA. Only ONE client behind a given NAT box
  can be connected at a time. For multiple simultaneous clients behind
  one NAT router, use WireGuard or OpenConnect instead.
- **Firewall**: expose **UDP 500 and UDP 4500** on the VPS; do **not**
  open UDP 1701 — L2TP rides inside the IPsec tunnel.

### GRE (menu 8)

GRE is a plaintext point-to-point layer-3 tunnel. Both ends must run
this tool independently; the generator prints the exact peer command
you paste into the other server.

1. On Server A run: `sudo bash tools/gre.sh add mytun --remote <B-public-IP>`
2. The script prints a peer command like:
   `bash tools/gre.sh add mytun --local <B-public-IP> --remote <A-public-IP> ...`
3. On Server B paste and run that printed command.
4. Both ends auto-derive mirrored inner `/30` addresses deterministically
   (the side with the lower public IP takes `.1`, the other takes `.2`),
   so no manual address coordination is needed.

**Important**: GRE traffic is **not encrypted**. Use it only between
servers you trust (same datacentre, VPN-backbone, etc.). For untrusted
underlays, wrap the link in IPsec or use WireGuard/OpenVPN instead.

## Security notes

- **PPTP is a broken protocol** (weak MPPE key handling). The installer
  refuses to proceed unless you explicitly confirm
  (`yes`, or `--auto --i-understand-pptp-is-insecure`).
- **GRE is NOT encrypted.** Traffic is plaintext on the underlay. Use it
  only inside a trusted network. (GRE-over-IPsec secure mode is not
  implemented.)
- **L2TP is only safe with IPsec.** This tool always wraps L2TP in
  IPsec (UDP 500/4500); UDP 1701 is never exposed publicly.
- **Everything runs as `root`.** Back up your server before using these
  tools; the tools take timestamped config backups and roll back on
  failure, but a fresh server is still the safest starting point.

## License

See `LICENSE`.

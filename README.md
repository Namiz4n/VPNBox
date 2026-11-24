# 📦 VPNBox

**Modular VPN & proxy installers for your VPS — bash-only, clean-room built, rigorously tested.**

| | |
|---|---|
| **CI** | [![shellcheck](https://github.com/Namiz4n/VPNBox/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/Namiz4n/VPNBox/actions/workflows/shellcheck.yml) |
| **Language** | ![Bash](https://img.shields.io/badge/language-Bash-blue.svg) |
| **License** | ![MIT](https://img.shields.io/badge/license-MIT-green.svg) |
| **ShellCheck** | ![strict](https://img.shields.io/badge/shellcheck-strict-orange.svg) |
| **Target** | Debian / Ubuntu |

---

## What is VPNBox?

A curated set of first-party Bash helpers that stand up and manage VPN and proxy services on a fresh Linux VPS — OpenVPN, WireGuard, OpenConnect, MTProto, WARP, PPTP, L2TP/IPsec, and GRE tunnels — without requiring heavy control panels or databases.

Everything lives in this repo. No external toolchains beyond stock `apt`. Each installer validates its inputs, backs up configs before editing, rolls back on failure, and ships a full uninstall path. Run with no arguments for guided wizards; drive everything else via explicit subcommands and `--auto` flags.

**Built with:**
- **Strict ShellCheck** (`set -euo pipefail` across every script).
- **Real-software validators** in CI: `ocserv --test-config`, strongSwan's `starter --nofork`, xl2tpd startup checks, and functional netns ping tests for GRE.
- **Clean-room design**: each tool is written from official man pages and upstream documentation only. We never copy third-party installers verbatim.
- **Pin-and-check**: pinned URLs and SHA-256 verification where it matters (e.g., the OpenVPN installer commit, the `mtg` binary).

---

## Features

- **One-command bootstrap** — drop into a fresh Debian/Ubuntu box and run a single curl pipeline; the menu guides the rest.
- **Eight protocols out of the box** — OpenVPN, WireGuard, OpenConnect, MTProto, Cloudflare WARP, PPTP, L2TP/IPsec, GRE.
- **Idempotent & rollback-safe** — timestamped backups before edits, automatic rollback on failure, idempotent service setup.
- **Full uninstall paths** — every tool exposes a remove/uninstall mode that reverses what it installed.
- **No database, no panel** — pure systemd units, native config formats, standard iptables/nftables/uFW/firewalld rules.
- **Automated CI per tool** — ShellCheck strict + protocol-specific validation (syntax checks, dry-run renders, live daemon smoke tests where possible).
- **Cross-platform inner-address pairing** — for GRE, peer servers auto-derive mirrored `/30` addresses deterministically, no manual coordination needed.
- **Explicit insecurity guards** — risky choices (e.g., enabling PPTP) require an acknowledgment flag; nothing proceeds quietly.
- **Power-user friendly** — subcommands, `--help` usage text, environment overrides (`VPN_INSTALL_REF`, `GRE_CONF_DIR`), and machine-readable output modes like `print-config`.

---

## Supported Protocols

| # | Protocol | Core purpose | CI coverage |
|---|----------|--------------|-------------|
| 1 | **OpenVPN** ([`install_openvpn.sh`](install_openvpn.sh)) | Mature TLS-based VPN; client-rich ecosystem | ShellCheck strict (upstream installer; pin + SHA verified) |
| 2 | **WireGuard** ([`wireguard-install.sh`](wireguard-install.sh)) | Modern, fast, minimal-crypto tunnel | ShellCheck error-only; in-tree UDP-optimized sysctl (no SysV msg queue caps); HTTPS public-IP detection |
| 3 | **OpenConnect** ([`tools/ocserv.sh`](tools/ocserv.sh)) | SSL VPN with browser support (`ocserv`) | ShellCheck strict + `ocserv --test-config` |
| 4 | **MTProto Proxy** ([`tools/mtproto.sh`](tools/mtproto.sh)) | Telegram proxy; anti-censorship | ShellCheck strict; binary pinned, SHA-256 verified |
| 5 | **Cloudflare WARP** ([`tools/warp.sh`](tools/warp.sh)) | Commercial-grade zero-trust tunnel | ShellCheck strict; Cloudflare official repo |
| 6 | **PPTP** ([`tools/pptp.sh`](tools/pptp.sh)) | Legacy MS-CHAPv2 + MPPE (use only if required) | ShellCheck strict + dry-run structural checks; refuses on Ubuntu 24.04+ |
| 7 | **L2TP/IPsec** ([`tools/l2tp.sh`](tools/l2tp.sh)) | Classic road-warrior IPSec tunnel | ShellCheck strict + real strongSwan `starter --nofork` (fails if starter is missing) + real xl2tpd startup |
| 8 | **GRE** ([`tools/gre.sh`](tools/gre.sh)) | Plaintext layer-3 P2P tunnel between trusted nodes | ShellCheck strict + dry-run mirroring + multiple-tunnel collision checks + ufw add/remove via the tool's functions + netns ping over a real GRE link (skipped with a visible warning if the runner kernel lacks `ip_gre`) |

> ⚠️ **GRE traffic is unencrypted.** Use it only inside trusted networks (same datacenter, VPN backbone, etc.). For untrusted underlays, wrap the link in IPsec or switch to WireGuard/OpenVPN.

---

## Quick Start

Prerequisites: a fresh **root** shell on **Debian** or **Ubuntu**.

```bash
sudo bash <(curl -Ls --max-time 60 --retry 3 https://raw.githubusercontent.com/Namiz4n/VPNBox/refs/heads/main/main.sh)
```

Pick a menu item. Each tool can also be run standalone:

```bash
sudo bash tools/ocserv.sh        # guided install or management menu
sudo bash tools/pptp.sh
sudo bash tools/l2tp.sh
sudo bash tools/gre.sh
```

Run a tool with **no arguments** to hit the guided wizard (or the management menu when already installed). Power users can drive anything explicitly via subcommands; `-h` / `--help` prints usage.

Override which ref the bootstrap fetches from:

```bash
VPN_INSTALL_REF=my-topic-branch sudo bash <(curl -Ls --max-time 60 --retry 3 https://raw.githubusercontent.com/Namiz4n/VPNBox/refs/heads/main/main.sh)
```

---

## Usage Guide

### Interactive menu

Invoking `main.sh` presents numbered options 1–8 plus 0 (Quit). After completing a wizard, rerunning the same tool brings up a short management menu (`status`, `uninstall`, …) rather than another full install.

### Guided vs automated

- **Guided** — default when called with no args; prompts for missing values.
- **`--auto`** — non-interactive, uses sane defaults or env vars. Safe for playbooks.
- **Subcommands** — e.g. `bash tools/gre.sh add mytun --remote 1.2.3.4` or `bash tools/gre.sh remove mytun`. Check `--help` per tool for the exact verb list.
- **`print-config`** — dry-render full config/command output to stdout without applying anything (useful for review, scripting, or peer-generation, as with GRE).

### Per-tool highlights

#### OpenVPN (menu 1)

Installs via the pinned [angristan/openvpn-install](https://github.com/angristan/openvpn-install) (`openvpn-install.sh`). Our wrapper verifies the downloaded script's SHA-256 before executing it.

#### WireGuard (menu 2)

Standalone `wireguard-install.sh` in this repo. Uses HTTPS for public-IP detection, embeds its own sysctl tuning (BDPR-aligned socket buffers + BBR + fq when available; intentionally excludes unrelated SysV message-queue knobs), and touches the MIT-licensed copyright header only for comments.

#### OpenConnect (menu 3)

Sets up `ocserv` with `ocpasswd` users and a self-signed cert by default. The CI validator runs `ocserv --test-config` against the generated config to catch unknown directives early.

#### MTProto (menu 4)

Downloads the pinned `mtg` binary from `9seconds/mtg`, verifies its SHA-256, and drops it behind a systemd unit. Pinning means supply-chain integrity is guaranteed at runtime.

#### WARP (menu 5)

Points at Cloudflare's official APT/YUM repository and installs the WARP client. Smoke-tested at install time.

#### PPTP (menu 6)

Uses `pptpd` (MS-CHAPv2 + 128-bit MPPE). Exits early on Ubuntu 24.04+ where the package was dropped, nudging users toward L2TP/IPsec instead. Requires explicit confirmation (`yes` or `--i-understand-pptp-is-insecure`) because PPTP's crypto is weak.

#### L2TP/IPsec (menu 7)

Generates `ipsec.conf` / `ipsec.secrets` (strongSwan, classic stroke format) and `xl2tpd.conf` / `options.xl2tpd` from scratch. CI feeds those exact files to strongSwan's `starter --nofork` and `xl2tpd -D`; any unknown keyword or parse error fails the build, and a missing `starter` binary fails the build too.

The classic `ipsec.conf` is only read by `starter` from the **`strongswan-starter`** package, so the tool installs `strongswan-starter strongswan-charon xl2tpd ppp` explicitly and first checks that each has an install candidate (`apt-cache policy`); if one is missing it stops before changing anything. The `strongswan` metapackage is not enough on newer releases: there it resolves to `charon-systemd` + `strongswan-swanctl` and installs no starter.

**Supported OS for `l2tp.sh`** — verified by the `l2tp-os-matrix` CI job (official Docker image per release: `apt-get update`, `apt-cache policy`, `apt-cache depends strongswan`, explicit install, `l2tp.sh preflight`, real `starter` + `xl2tpd` validation), run [45451529139](https://github.com/Namiz4n/VPNBox/actions/runs/45451529139), 24 Nov 2026 (amd64). Versions are the candidates on that date and will drift with point updates:

| Release | `strongswan-starter` | Component | `strongswan` metapackage pulls in starter? | `l2tp.sh` | Verified |
|---------|----------------------|-----------|---------------------------------------------|-----------|----------|
| Ubuntu 22.04 (jammy) | 5.9.5-2ubuntu2.8 | main | Yes (`strongswan-charon, strongswan-starter`) | Supported | CI pass |
| Ubuntu 24.04 (noble) | 5.9.13-2ubuntu4.24.04.5 | main | Yes (`strongswan-charon, strongswan-starter`) | Supported | CI pass |
| Ubuntu 26.04 (resolute) | 6.0.4-1ubuntu3.2 | **universe** | No (`charon-systemd \| strongswan-charon, strongswan-swanctl \| strongswan-starter`) | Supported with `universe` enabled (default on stock images); `l2tp.sh` installs starter explicitly and refuses with an explanation when `universe` is off | CI pass (incl. universe-off refusal) |
| Debian 12 (bookworm) | 5.9.8-5+deb12u6 | main | Yes (`strongswan-charon, strongswan-starter`) | Supported | CI pass |
| Debian 13 (trixie) | 6.0.1-6+deb13u7 | main | No (`charon-systemd \| strongswan-charon, strongswan-swanctl \| strongswan-starter`) | Supported; starter installed explicitly | CI pass |

Run `sudo bash tools/l2tp.sh preflight` to check a server before installing: it changes nothing and exits non-zero with an explanation if `strongswan-starter`, `strongswan-charon`, `xl2tpd` or `ppp` cannot be installed (including a disabled Ubuntu `universe`).

strongSwan documents the stroke/`starter` interface as legacy. Moving to `swanctl.conf` is a TODO in the script header.

- **Firewall**: expose **UDP 500** and **UDP 4500** only. UDP 1701 is **not** opened publicly — L2TP rides inside the IPsec tunnel.
- **Windows behind NAT**: some builds require `EnableTransportModeDirectAccess` (DWORD = 1) in `HKLM\SYSTEM\CurrentControlSet\Services\PolicyAgent\`. Without it, Phase 1 may fail or the tunnel may drop. See Microsoft's IKE transport-mode docs.
- **iOS / Android**: native clients connect with the printed PSK and username/password out of the box.
- **Multiple clients behind one NAT**: IPsec SAs share a single SPI, so only one client per NAT router can be active simultaneously. For many simultaneous clients through one gateway, use WireGuard or OpenConnect.

#### GRE (menu 8)

A plaintext `iproute2` point-to-point tunnel with systemd persistence. Both ends run this tool independently; the generator prints the peer command you paste into the other server. Inner `/30` addresses are derived deterministically — the lower public IP takes `.1`, the higher takes `.2` — so no manual address planning is required.

```bash
# Server A
sudo bash tools/gre.sh add mytun --remote <B-public-IP>

# Output includes the exact command to run on Server B
bash tools/gre.sh add mytun --local <B-public-IP> --remote <A-public-IP> ...
```

---

## Security & Clean-Room Architecture

### Clean-room implementation

Every tool in `tools/` is written from **official documentation and man pages**, not reverse-engineered from competing installers. When a downstream dependency isn't safe to ship inline (the OpenVPN installer, the `mtg` binary), we download a **pinned version** and verify its **SHA-256** before execution. No unvetted scripts are ever sourced.

### Script hygiene

- `set -euo pipefail` everywhere — failures abort, undefined variables crash loudly.
- Input validated before use; root check enforced at the top of every entry point.
- All edits are backed up (timestamped) before modification; rollback hooks fire on failure.
- Every `rm -rf` targets a known variable prefix and rejects absolute `/` or empty paths.
- Functions whose output is captured with `$(...)` log only to **stderr**, keeping stdout clean for scripted consumption.

### Firewall & protocol warnings

- **PPTP** is insecure by design (weak MPPE key handling). The installer refuses unless you acknowledge the risk.
- **GRE** carries no encryption. Trust the underlay or wrap it in IPsec/WireGuard/OpenVPN.
- **L2TP without IPsec is unsafe**; our tool always wraps it, exposing only UDP 500/4500.

### Running as root

These tools operate as `root` and touch system config, networking, and packages. Snapshot or back up your server before the first run. A fresh VPS image is the safest starting point.

---

## CI

GitHub Actions validates every push / PR touching `.sh` or `.yml`:

| Job | What it checks |
|-----|----------------|
| `shellcheck` | Strict ShellCheck on all our scripts; error-only on `wireguard-install.sh` |
| `config-test` | `ocserv --test-config` against the generated config |
| `pptp-dryrun` | Structural greps on `pptp.sh print-config` output; apt-cache guard for 24.04+ |
| `l2tp-validate` | On the runner: `apt-cache policy`, explicit `strongswan-starter` install, then `.github/scripts/l2tp-validate.sh`: deliberately broken `ipsec.conf` / `xl2tpd.conf` must be rejected (proves the parsers run), then the generated configs go to `starter --nofork` and `xl2tpd -D`; fails on parser errors or a missing starter binary (no fallback) |
| `l2tp-os-matrix` | One job per Docker image (`ubuntu:22.04`, `ubuntu:24.04`, `ubuntu:26.04`, `debian:12`, `debian:13`): `apt-get update`, `apt-cache policy strongswan strongswan-starter xl2tpd ppp`, `apt-cache depends strongswan`, explicit `strongswan-starter xl2tpd ppp` install (fails if impossible), `l2tp.sh preflight`, same validation script. On 26.04 it also disables `universe` and asserts that `l2tp.sh` refuses with an explanation. This job is the source of the README support table |
| `gre-dryrun` | Keyword-based parse of the generated `ip` lines (word-order independent): mirrored inner addresses, swapped outer endpoints (checked against the expected IPs), identical MTU, `mtu` before `type gre`; `gre0`/`gretap0`/`erspan0`/over-long names rejected; default name `vgre0` |
| `gre-functional` | End-to-end netns test: runs the `ip` commands from `print-config` in two namespaces under `set -euo pipefail` (fails if any is rejected) and pings over `vgre0` in both directions. Skipped only if the runner kernel cannot load `ip_gre`; a skip shows up as a `::warning::` and in the job summary, and does not count as a pass |
| `gre-multiple` | Two independent tunnel pairs pick disjoint `/30` subnets (collision avoidance) |
| `gre-ufw` | Adds the rule with the tool's `allow_gre_firewall`, removes it with the tool's `remove_gre_firewall` (the same function `remove` and `uninstall` use), and checks `ufw show added` after each step |

Only `actions/checkout@v4` is used as a third-party action; all other steps are plain `run` commands.

---

## Contributing

### Local pre-flight

Before committing, run the same checks CI enforces:

```bash
shellcheck main.sh install_openvpn.sh tools/*.sh \
             wireguard-install.sh
shellcheck --severity=error wireguard-install.sh
for f in *.sh tools/*.sh; do bash -n "$f"; done
grep -rP '\r' --include='*.sh' --include='*.yml' .   # must produce no hits
```

### Adding a new tool

1. Create `tools/<name>.sh` following the style of existing tools: shebang, `set -euo pipefail`, root check, `usage()`/`--help`, idempotent install, backup-before-edit, rollback on failure, uninstall path, `print-config` if applicable.
2. Add it to the menu in `main.sh`.
3. Add a CI job under `.github/workflows/shellcheck.yml` with the strongest validator you can (prefer real-daemon smoke tests over grep-only).
4. Update the Status table and the Protocols matrix in this README.

### Issues & questions

File an issue on GitHub. Include:
- OS/distro + version.
- Which tool/menu item triggered the problem.
- Relevant output/logs (redact keys and private IPs).
- Steps to reproduce from a fresh VPS when possible.

Pull requests are welcome — keep changes scoped, document the rationale, and ensure all local checks pass.

---

## License

Copyright © 2024 Namiz4n. Licensed under the **[MIT License](LICENSE)**.

Note: `wireguard-install.sh` preserves its original copyright notices (MIT, Nyr / Lin Song) and `install_openvpn.sh` delegates to the MIT-licensed angristan/openvpn-install. Our additions to those files are MIT-licensed as well.

# VPNBox

Bash installers/managers for a Debian/Ubuntu VPS. Entry point: main.sh (menu; downloads tools with run_remote_script). Our own tools live in tools/: ocserv, mtproto, warp, pptp, l2tp, gre. install_openvpn.sh is a thin wrapper around a pinned third-party OpenVPN installer. wireguard-install.sh is a modified copy of an MIT script: never touch its copyright/license header.

## Rules
- Our tools are written ONLY from official docs/man pages (clean-room). Never read, copy or paraphrase third-party installer scripts. Downloading a pinned, SHA-256-verified third-party binary at runtime is allowed (like mtg in mtproto.sh) and must be stated plainly in the README.
- Verify every package name, option and URL before using it (man pages, apt-cache, curl, and the real validators: `ocserv --test-config`, `ipsec starter --nofork`, `xl2tpd -D`, `nginx -t`). Never invent options.
- NEVER run the installers/tools on the dev machine. Static checks only: shellcheck, bash -n, print-config/--dry-run modes. Every `rm -rf` on a variable path must be guarded (non-empty, absolute, not "/", under an expected prefix).
- Style: `#!/bin/bash`, `set -euo pipefail`, root check, idempotent, validate all inputs, back up before editing configs, automatic rollback, full uninstall. Functions whose output is captured with $(...) must log to stderr. LF line endings only.
- UX: a tool run with no arguments starts the guided install (or the management menu if installed); `--auto` for automation; usage only with `--help`.
- CI (.github/workflows/shellcheck.yml): ShellCheck strict plus real config validators. Plain `run` steps; only the pinned actions/checkout is allowed as a third-party action.
- Never commit secrets (API keys, tokens). Do not print them in output either.

## Checks before every commit
shellcheck main.sh install_openvpn.sh tools/*.sh ; shellcheck --severity=error wireguard-install.sh ; bash -n on every script ; no CR characters in tracked files (grep -cP '\r' must be 0).

## Status (verified from the repo on 2026-11-16)
- Rename to VPNBox done. L2TP config valid for strongSwan starter and xl2tpd. GRE pairing (mirrored inner addresses) fixed, `remove` no longer crashes. CI has: ShellCheck, ocserv --test-config, pptp dry-run, l2tp validators, GRE mirrored-address dry-run, GRE netns functional test. README has a Status section.
- Known issues being fixed now: (1) gre.sh never removes the ufw rule for protocol 47 on remove/uninstall (`ufw delete allow in proto gre from <IP> any` works); (2) wireguard-install.sh detects the public IP over plain http:// and downloads a sysctl file with no checksum; (3) leftover `vpn-install-*` markers; (4) EXPECTED_SHA256 empty in install_openvpn.sh.

## Later
- DNS tunnel server tool (pinned, checksum-verified dnstt/VayDNS/MasterDnsVPN binaries; needs a domain with NS delegation and port 53 free).
- ocserv.sh: real certificate with a domain, `camouflage` option.
- Test everything on a throwaway VPS (never the main server).

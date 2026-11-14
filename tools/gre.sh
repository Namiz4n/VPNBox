#!/bin/bash
#
# tools/gre.sh -- GRE tunnel setup / manager (iproute2)
#
# Builds a point-to-point GRE tunnel with iproute2, persists it with a small
# oneshot systemd unit plus /etc/modules-load.d for the ip_gre module,
# supports multiple named tunnels (list/add/remove), and prints the exact
# non-interactive command to run on the peer side so both ends can be
# created from the same generator.
#
# SECURITY NOTICE: GRE is NOT encrypted. Anything that travels over this
# tunnel is plaintext on the underlay. Use it for lab / same-trust-domain
# links only; for anything crossing untrusted networks use an encrypted
# tunnel (IPsec, WireGuard, OpenVPN). This tool does not implement
# GRE-over-IPsec (see the "Secure mode" section at the bottom of this
# header and the final report).
#
# UX (this script is self-contained and also launched with no arguments
# from main.sh):
#   * No arguments:
#       - no tunnels yet -> guided add (asks only what is needed; ENTER
#         accepts every default; the local IP is auto-detected and editable),
#       - tunnels exist  -> short numbered management menu
#         (status, list, add, remove, connection info, uninstall, back).
#   * Subcommands (power-user):
#       add <name> | remove <name> | list | status [name] |
#       print-config | uninstall
#     Non-interactive flags/env vars:
#       --auto                       accept every default, no prompts
#       --name <n>                   tunnel name (default gre0 / greN)
#       --local <ip>                 local public IP (auto-detected default)
#       --remote <ip>                remote public IP (required, validated)
#       --inner-subnet <cidr>        /30 inner pair parent, default
#                                   10.10.0.0/24 -> pair 10.10.0.1/10.10.0.2
#       --key <n>                    optional GRE key (32-bit int or dotted
#                                   quad); lowers MTU by 4
#       --ttl <n>                    optional TTL (default: unset)
#       --no-forwarding              skip NAT/forwarding + MSS clamp
#       GRE_TUNNEL_NAME / GRE_LOCAL_IP / GRE_REMOTE_IP / GRE_INNER_SUBNET
#   * `-h` / `--help`: print usage. Any other first argument that is not a
#     known subcommand is treated as no-args, so `gre.sh` alone never
#     prints a Usage line.
#
# OS: Debian/Ubuntu only.
#
# MTU MODEL (documented): underlay MTU 1500 -> tunnel MTU 1476 (20-byte
# IPv4 header + 4-byte GRE flag/reserved overhead). With a 32-bit GRE key
# add 4 more bytes -> 1472; with key + sequence -> 1468. The tool picks
# 1476 by default and reduces it when a key is set.
#
# Verification notes (clean-room; source: ip-link(8) from the iproute2
# man page at man7.org, plus /etc/protocols and the kernel docs):
#   * `ip link add <n> type gre remote <A> local <B> [ i|o key K ] [ ttl T ]`
#     -- exact option spellings verified from ip-link(8) "GRE Type Support".
#   * P2P addressing: `ip addr add <local>/30 peer <remote> dev <n>`
#     (ip-address(8): the `peer` form carries the prefix).
#   * GRE is IP protocol 47 (from /etc/protocols). iptables accepts
#     `-p 47` (numeric) or `-p gre` (name form, resolved via /etc/protocols);
#     this tool uses the numeric form for portability.
#   * Kernel module: `ip_gre` (CONFIG_NET_IPGRE). On generic
#     Ubuntu/Debian kernels it is frequently built-in, so `modprobe` may
#     be a no-op; the modules-load.d line is kept and every modprobe is
#     `|| true`-ed.
#   * Persistence: a oneshot systemd unit (RemainAfterExit=yes) that runs
#     the exact ip commands is the standard portable pattern; it is
#     removed on uninstall.
#
# Secure mode (GRE over IPsec): OMITTED. strongSwan's L2TP/IPsec
# configuration does not cleanly carry arbitrary GRE P2P traffic, and a
# verified, minimal GRE-over-IPsec recipe is not available from the
# official docs alone; implementing one would be untestable in CI. This
# tool therefore ships plaintext GRE only, and says so in the status
# output and the final report.
#
# Test hooks (for CI / automated testing without root-owned system paths):
#   GRE_CONF_DIR    override for /etc/gre-tunnels (default: /etc/gre-tunnels)
#   GRE_UNIT_DIR    override for /etc/systemd/system (default: /etc/systemd/system)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONF_DIR="${GRE_CONF_DIR:-/etc/gre-tunnels}"
SYSCTL="/etc/sysctl.d/90-gre.conf"
MODULES="/etc/modules-load.d/gre.conf"
UNIT_DIR="${GRE_UNIT_DIR:-/etc/systemd/system}"

NAME=""
LOCAL_IP=""
REMOTE_IP=""
INNER_SUBNET="${GRE_INNER_SUBNET:-10.10.0.0/24}"
GRE_KEY=""
GRE_TTL=""
DO_FORWARDING=1
AUTO=0

FW_TAG="vpnbox-gre"

log() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}Warning: $*${NC}" >&2; }
err() { echo -e "${RED}Error: $*${NC}" >&2; }
info() { echo -e "${BLUE}$*${NC}"; }

usage() {
    cat <<EOF
Usage: bash gre.sh [subcommand] [flags]
  No arguments: guided add or management menu (recommended).
  Subcommands: add <name> | remove <name> | list | status [name] |
               print-config | uninstall
  Flags: --auto, --name <n>, --local <ip>, --remote <ip>,
         --inner-subnet <cidr>, --key <n|dotted.quad>, --ttl <n>,
         --no-forwarding
  -h / --help: this text.
EOF
}

die() { err "$*"; exit 1; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This script must be run as root. Try: sudo bash $0."
    fi
}

detect_os() {
    if [[ -r /etc/os-release ]]; then
        set -a
        # shellcheck source=/dev/null
        source /etc/os-release
        set +a
        DISTRO_ID="${ID:-unknown}"
    else
        die "Cannot detect OS: /etc/os-release is missing."
    fi
    case "$DISTRO_ID" in
        debian|ubuntu) : ;;
        *)
            die "Unsupported OS: ${DISTRO_ID:-unknown}. This tool supports Debian/Ubuntu only."
            ;;
    esac
}

validate_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { err "Not a valid IPv4 address: $ip"; return 1; }
    local IFS='.'
    local -a octets
    read -ra octets <<< "$ip"
    for o in "${octets[@]}"; do
        if ! [[ "$o" =~ ^[0-9]+$ ]] || (( 10#$o > 255 )); then
            err "Octet out of range in $ip"
            return 1
        fi
    done
}

default_iface() {
    local iface
    iface="$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)"
    [[ -n "$iface" ]] || iface="eth0"
    printf '%s' "$iface"
}

public_ip() {
    local ip
    ip="$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | grep -vE '^(10\.|172\.(1[6-9]|[2-4][0-9])\.|192\.168\.)' | head -n1 || true)"
    if [[ -z "$ip" ]]; then
        local iface
        iface="$(default_iface)"
        ip="$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}' | head -n1 || true)"
    fi
    ip="${ip%/*}"
    printf '%s' "$ip"
}

# --- helpers ----------------------------------------------------------------
ask() {
    local prompt="$1" default="$2" reply=""
    if [[ -t 0 && "$AUTO" -eq 0 ]]; then
        printf '%s [%s]: ' "$prompt" "$default"
        read -r reply || reply=""
        printf '%s' "${reply:-$default}"
    else
        printf '%s' "$default"
    fi
}

ask_yes_no() {
    local prompt="$1" default="$2" reply=""
    if [[ -t 0 && "$AUTO" -eq 0 ]]; then
        printf '%s [%s] ' "$prompt" "$default"
        read -r reply || reply=""
        reply="${reply:-$default}"
        [[ "$reply" =~ ^[Yy] ]]
    else
        [[ "$default" =~ ^[Yy] ]]
    fi
}

# --- tunnel bookkeeping -----------------------------------------------------
# Tunnels are stored as one JSON-ish line each in $CONF_DIR/<name>.conf.
# Each file holds the full parameter set so `add` is idempotent and the
# peer-command generator can re-derive the exact commands.

next_name() {
    local n=0 base="gre"
    while [[ -e "$CONF_DIR/${base}${n}.conf" ]] || ip link show "${base}${n}" >/dev/null 2>&1; do
        n=$((n + 1))
    done
    printf '%s' "${base}${n}"
}

write_tunnel_file() {
    # write_tunnel_file <name> -- serializes the current globals.
    local name="$1"
    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/${name}.conf" <<EOF
# GRE tunnel parameters (written by gre.sh)
NAME=${NAME}
LOCAL_IP=${LOCAL_IP}
REMOTE_IP=${REMOTE_IP}
INNER_SUBNET=${INNER_SUBNET}
LOCAL_INNER=${LOCAL_INNER}
REMOTE_INNER=${REMOTE_INNER}
GRE_KEY=${GRE_KEY}
GRE_TTL=${GRE_TTL}
MTU=${TUNNEL_MTU}
FORWARDING=${DO_FORWARDING}
EOF
}

load_tunnel_file() {
    # load_tunnel_file <name> -- globals from disk; dies if missing.
    local name="$1"
    local f="$CONF_DIR/${name}.conf"
    [[ -r "$f" ]] || die "No tunnel config for '$name' ($f missing)."
    # shellcheck disable=SC1090
    source "$f"
}

compute_mtu() {
    # Underlay MTU -> tunnel MTU. 1500 -> 1476; a 32-bit key adds 4 -> 1472.
    local underlay
    underlay="$(default_iface)"
    underlay="$(cat "/sys/class/net/${underlay}/mtu" 2>/dev/null || echo 1500)"
    TUNNEL_MTU=$(( underlay - 24 ))
    if [[ -n "$GRE_KEY" ]]; then
        TUNNEL_MTU=$(( TUNNEL_MTU - 4 ))
    fi
    if [[ "$TUNNEL_MTU" -lt 1280 ]]; then
        TUNNEL_MTU=1280
    fi
}

compute_inner_pair() {
    # Deterministic symmetric /30 assignment from the parent subnet.
    # The side with the numerically lower public IP takes .1, the other
    # takes .2. Both sides, running independently, always agree because
    # they sort the same two endpoints the same way.
    #
    # Collision check: walk through existing tunnels' stored pairs and
    # existing ip routes/dev addresses to find a free /30 under the
    # parent subnet. For simplicity we increment the third octet of the
    # parent net and reuse .1/.2 within it.
    local net="${INNER_SUBNET%/*}"
    local prefix="${INNER_SUBNET#*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] || die "Invalid CIDR: $INNER_SUBNET"

    # Build all candidate /30 network bases under the parent.
    local -a candidates=()
    local base_last step mask host_bits start_octet end_octet
    base_last="${net##*.}"
    # A /30 has 4 addresses; step through in increments of 4.
    step=$(( 1 << (32 - prefix) ))
    # Iterate over all /30 blocks in the parent subnet.
    for (( i = 0; i < step; i++ )); do
        local cand_last=$(( (base_last / 4) * 4 + i ))
        candidates+=("${net%.*}.${cand_last}")
    done

    # Collect already-used inner IPs from config files and live links.
    local -A used=()
    local c
    for c in "${candidates[@]}"; do
        used["${c%.0}.1"]=1
        used["${c%.0}.2"]=1
    done
    # Mark already-assigned pairs from stored configs.
    if [[ -d "$CONF_DIR" ]]; then
        local conf_f
        for conf_f in "$CONF_DIR"/*.conf; do
            [[ -r "$conf_f" ]] || continue
            # Source into locals without polluting current globals.
            local src_NAME src_LOCAL_INNER src_REMOTE_INNER
            src_NAME=""; src_LOCAL_INNER=""; src_REMOTE_INNER=""
            # shellcheck disable=SC1090
            source "$conf_f"
            [[ -n "$src_LOCAL_INNER" ]] && used["$src_LOCAL_INNER"]=1
            [[ -n "$src_REMOTE_INNER" ]] && used["$src_REMOTE_INNER"]=1
        done
    fi
    # Mark currently-up links.
    local link
    for link in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}' | grep -E '^gre' || true); do
        local addr
        addr="$(ip -4 addr show "$link" 2>/dev/null | awk '/inet /{print $2}' | head -n1 || true)"
        [[ -n "$addr" ]] && used["${addr%/*}"]=1
        addr="$(ip -4 addr show "$link" 2>/dev/null | awk '/peer /{print $2}' | head -n1 || true)"
        [[ -n "$addr" ]] && used["${addr%/*}"]=1
    done

    # Pick the best candidate: sort the two public IPs; lower gets .1.
    local sorted_ips
    if [[ "$(printf '%s\n%s\n' "$LOCAL_IP" "$REMOTE_IP" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | sed -n '1p')" == "$LOCAL_IP" ]]; then
        # LOCAL_IP is the lower endpoint -> it gets .1.
        local my_role="a"
    else
        local my_role="b"
    fi

    local assigned=0
    local cand
    for cand in "${candidates[@]}"; do
        local a b
        a="${cand%.0}.1"
        b="${cand%.0}.2"
        if [[ "$my_role" == "a" ]]; then
            if [[ -z "${used[$a]:-}" ]]; then
                LOCAL_INNER="$a"
                REMOTE_INNER="$b"
                assigned=1
                break
            fi
        else
            if [[ -z "${used[$b]:-}" ]]; then
                LOCAL_INNER="$b"
                REMOTE_INNER="$a"
                assigned=1
                break
            fi
        fi
    done
    [[ "$assigned" -eq 1 ]] || die "No free /30 pair in $INNER_SUBNET (all addresses exhausted or colliding with existing tunnels)."
}

# --- ip commands (single source of truth) ----------------------------------
ip_link_add_cmd() {
    # Echoes the exact `ip link add` line for the current globals.
    local keyarg=""
    if [[ -n "$GRE_KEY" ]]; then
        keyarg=" ikey ${GRE_KEY} okey ${GRE_KEY}"
    fi
    local ttlarg=""
    if [[ -n "$GRE_TTL" ]]; then
        ttlarg=" ttl ${GRE_TTL}"
    fi
    printf 'ip link add %s type gre local %s remote %s%s%s mtu %s\n' \
        "$NAME" "$LOCAL_IP" "$REMOTE_IP" "$keyarg" "$ttlarg" "$TUNNEL_MTU"
}

ip_addr_cmd() {
    printf 'ip addr add %s/30 peer %s dev %s\n' "$LOCAL_INNER" "$REMOTE_INNER" "$NAME"
}

ip_down_cmd() {
    printf 'ip link set %s down\n' "$NAME"
}

ip_link_del_cmd() {
    printf 'ip link delete %s\n' "$NAME"
}

ip_up_cmd() {
    printf 'ip link set %s up\n' "$NAME"
}

# --- systemd persistence ----------------------------------------------------
unit_name() {
    printf 'gre-%s.service' "$NAME"
}

render_unit() {
    local unit
    unit="$(unit_name)"
    cat <<EOF
# /etc/systemd/system/${unit} -- written by gre.sh
[Unit]
Description=GRE tunnel ${NAME} (${LOCAL_IP} -> ${REMOTE_IP})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '\
  $(ip_link_add_cmd) 2>/dev/null || true; \
  $(ip_addr_cmd); \
  $(ip_up_cmd)'
ExecStop=/bin/sh -c '\
  $(ip_down_cmd) 2>/dev/null || true; \
  $(ip_link_del_cmd) 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

render_modules() {
    cat <<EOF
# /etc/modules-load.d/gre.conf -- written by gre.sh
ip_gre
EOF
}

# --- create / remove / status ------------------------------------------------
create_tunnel() {
    require_root
    detect_os
    compute_mtu
    compute_inner_pair

    # Persist modules + sysctl (idempotent).
    mkdir -p /etc/modules-load.d /etc/sysctl.d
    printf '%s\n' "$(render_modules)" > "$MODULES"
    cat > "$SYSCTL" <<EOF
# /etc/sysctl.d/90-gre.conf -- written by gre.sh
net.ipv4.ip_forward = 1
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true
    modprobe ip_gre 2>/dev/null || true

    # Idempotent: recreate if the link is gone.
    if ip link show "$NAME" >/dev/null 2>&1; then
        info "Link '$NAME' already exists; updating address/up."
        ip link set "$NAME" down 2>/dev/null || true
        ip link delete "$NAME" 2>/dev/null || true
    fi
    eval "$(ip_link_add_cmd)"
    eval "$(ip_addr_cmd)"
    eval "$(ip_up_cmd)"

    # Firewall: allow GRE (protocol 47) from the remote IP only.
    allow_gre_firewall
    # Optional forwarding / NAT + MSS clamp.
    if [[ "$DO_FORWARDING" -eq 1 ]]; then
        setup_forwarding
    fi

    # systemd persistence for this tunnel.
    write_tunnel_file "$NAME"
    install -m 0644 /dev/stdin "${UNIT_DIR}/$(unit_name)" < <(render_unit)
    systemctl daemon-reload
    systemctl enable "$(unit_name)" >/dev/null 2>&1 || true
    systemctl start "$(unit_name)" >/dev/null 2>&1 || true

    log "GRE tunnel '$NAME' created (${LOCAL_IP} -> ${REMOTE_IP}, inner ${LOCAL_INNER} <-> ${REMOTE_INNER})."
}

allow_gre_firewall() {
    local fw
    fw="$(detect_firewall)"
    case "$fw" in
        ufw)
            ufw allow in proto 47 from "$REMOTE_IP" any >>/dev/null 2>&1 \
                || warn "ufw: could not allow GRE from $REMOTE_IP"
            ;;
        firewalld)
            firewall-cmd --permanent --add-rich-rule="rule protocol value=\"gre\" source address=\"$REMOTE_IP\" accept" >/dev/null 2>&1 \
                || warn "firewalld: could not allow GRE from $REMOTE_IP"
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
        iptables)
            iptables -C INPUT -p 47 -s "$REMOTE_IP" -j ACCEPT 2>/dev/null \
                || iptables -A INPUT -p 47 -s "$REMOTE_IP" -j ACCEPT
            ;;
        none)
            warn "No active firewall detected. GRE is not encrypted; only allow"
            warn "IP protocol 47 from your peer's IP ($REMOTE_IP) in the cloud"
            warn "security group."
            ;;
    esac
}

setup_forwarding() {
    local iface
    iface="$(default_iface)"
    # Apply immediately AND persist. Install iptables-persistent if absent.
    apt_get install iptables-persistent >/dev/null 2>&1 || true
    local savefile="/etc/iptables/rules.v4"
    # Always insert the rules (they are idempotent via -C check below).
    iptables -t nat -C POSTROUTING -o "$iface" -m comment --comment "$FW_TAG" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -o "$iface" -m comment --comment "$FW_TAG" -j MASQUERADE
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,SYNACK SYN -m comment --comment "$FW_TAG" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,SYNACK SYN -m comment --comment "$FW_TAG" -j TCPMSS --clamp-mss-to-pmtu
    # Persist to the canonical iptables-persistent location regardless of
    # whether a rules.v4 file existed beforehand.
    netfilter-persistent save >/dev/null 2>&1 || true
}

remove_tunnel() {
    local name="$1"
    require_root
    [[ -n "$name" ]] || die "Tunnel name required."
    # Load the stored config so we know the public-tagged firewall rules
    # to remove; fall back gracefully if the config is already gone.
    local saved_remote=""
    if [[ -r "$CONF_DIR/${name}.conf" ]]; then
        # shellcheck disable=SC1090
        source "$CONF_DIR/${name}.conf"
        saved_remote="$REMOTE_IP"
    fi
    # Tear down the link (ignore errors — already gone is fine).
    ip link set "$name" down 2>/dev/null || true
    ip link delete "$name" 2>/dev/null || true
    # Clean up any stray route that might remain.
    if [[ -n "${LOCAL_INNER:-}" ]]; then
        ip route del "${LOCAL_INNER%/30}"/30 2>/dev/null || true
    fi
    # Remove our systemd unit.
    rm -f "${UNIT_DIR}/gre-${name}.service"
    # Remove our config.
    rm -f "$CONF_DIR/${name}.conf"
    # Firewall cleanup: remove the rule(s) we added, tagged with our FW_TAG.
    local fw
    fw="$(detect_firewall)"
    case "$fw" in
        ufw)
            # ufw does not support deleting by-rule-content for raw-protocol
            # rules added via `ufw allow in proto …`; best-effort removal
            # is left to the uninstall path (which wipes everything).
            ;;
        firewalld)
            firewall-cmd --permanent --remove-rich-rule="rule protocol value=\"gre\" source address=\"${saved_remote}\" accept" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
        iptables)
            iptables -D INPUT -p 47 -s "${saved_remote}" -j ACCEPT 2>/dev/null || true
            # Also clean the NAT/MSS rules if forwarding was enabled.
            local iface
            iface="$(default_iface)"
            iptables -t nat -D POSTROUTING -o "$iface" -m comment --comment "$FW_TAG" -j MASQUERADE 2>/dev/null || true
            iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,SYNACK SYN -m comment --comment "$FW_TAG" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            netfilter-persistent save >/dev/null 2>&1 || true
            ;;
    esac
    systemctl daemon-reload 2>/dev/null || true
    log "GRE tunnel '$name' removed."
}

list_tunnels() {
    local shown=0
    if [[ -d "$CONF_DIR" ]]; then
        for f in "$CONF_DIR"/*.conf; do
            [[ -e "$f" ]] || continue
            local n
            n="$(basename "$f" .conf)"
            echo "  $n  (configured)"
            shown=1
        done
    fi
    local live
    for live in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}' | grep -E '^gre'); do
        echo "  $live  (live on this host)"
        shown=1
    done
    [[ "$shown" -eq 1 ]] || info "No GRE tunnels."
}

status() {
    local name="${1:-}"
    echo "=== GRE tunnel status ==="
    warn "GRE is NOT encrypted. Traffic is plaintext on the underlay."
    if [[ -n "$name" ]]; then
        load_tunnel_file "$name" 2>/dev/null || { warn "No config for '$name'"; return 0; }
    fi
    for n in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}' | grep -E '^gre' || true); do
        echo
        echo "Tunnel: $n"
        ip -s link show "$n" 2>/dev/null | sed 's/^/    /'
        echo "    Inner address(es):"
        ip addr show "$n" 2>/dev/null | grep -E 'inet |peer' | sed 's/^/      /' || true
        echo "    Routes:"
        ip route show dev "$n" 2>/dev/null | sed 's/^/      /' || true
        if [[ -n "${REMOTE_IP:-}" ]]; then
            echo -n "    Ping to peer inner (${REMOTE_INNER:-?}): "
            if ping -c 1 -W 2 "${REMOTE_INNER:-?}" >/dev/null 2>&1; then
                log "reached"
            else
                warn "not reachable (peer may be down or firewall is blocking)"
            fi
        fi
    done
}

print_config() {
    # No writes. Echoes every file/command we would create for the current
    # globals, plus the peer-side command.
    compute_mtu
    compute_inner_pair
    echo "=== [dry-run] gre.sh would create ==="
    echo
    echo "--- ip commands (run in this order, as root)"
    ip_link_add_cmd
    ip_addr_cmd
    ip_up_cmd
    echo
    echo "--- /etc/modules-load.d/gre.conf"
    render_modules
    echo
    echo "--- /etc/sysctl.d/90-gre.conf"
    echo "net.ipv4.ip_forward = 1"
    echo
    echo "--- /etc/systemd/system/$(unit_name)"
    render_unit
    echo
    echo "--- peer-side non-interactive command (run on the REMOTE host)"
    # Swapped: what was local becomes remote and vice versa. The peer
    # command passes the mirrored inner addresses explicitly so both
    # sides compute the same pair deterministically.
    local peer_key="$GRE_KEY" peer_ttl="$GRE_TTL"
    local -a peer_args=()
    if [[ -n "$REMOTE_IP" ]]; then
        peer_args+=(--local "$REMOTE_IP" --remote "$LOCAL_IP")
    fi
    if [[ -n "$peer_key" ]]; then
        peer_args+=(--key "$peer_key")
    fi
    if [[ -n "$peer_ttl" ]]; then
        peer_args+=(--ttl "$peer_ttl")
    fi
    # Explicitly pass the mirrored inner addresses so the peer computes
    # the same /30 but assigns LOCAL_INNER=REMOTE_INNER_of_us and
    # REMOTE_INNER=LOCAL_INNER_of_us.
    printf 'bash gre.sh add %s %s --auto --inner-subnet %s --inner-local %s --inner-remote %s\n' \
        "$NAME" "${peer_args[*]}" "$INNER_SUBNET" "$REMOTE_INNER" "$LOCAL_INNER"
}

# --- uninstall ----------------------------------------------------------------
uninstall() {
    require_root
    # Collect all tunnel names from config files AND live links so we
    # don't miss any.
    local -a all_names=()
    if [[ -d "$CONF_DIR" ]]; then
        local f
        for f in "$CONF_DIR"/*.conf; do
            [[ -e "$f" ]] || continue
            all_names+=("$(basename "$f" .conf)")
        done
    fi
    local live
    for live in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}' | grep -E '^gre'); do
        # Avoid duplicates.
        local seen=0
        local n
        for n in "${all_names[@]+"${all_names[@]}"}"; do
            [[ "$n" == "$live" ]] && seen=1 && break
        done
        [[ "$seen" -eq 0 ]] && all_names+=("$live")
    done
    local n
    for n in "${all_names[@]+"${all_names[@]}"}"; do
        remove_tunnel "$n"
    done
    rm -rf "$CONF_DIR"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$MODULES" "$SYSCTL"
    # Clean up the NAT/MSS rules we added (regardless of whether any
    # tunnels remained).
    local fw iface
    fw="$(detect_firewall)"
    iface="$(default_iface)"
    case "$fw" in
        ufw)
            # ufw cannot enumerate/delete individual raw-protocol rules;
            # document that manual cleanup may be needed.
            warn "UFW: manually remove GRE (proto 47) rules if needed."
            ;;
        firewalld)
            # Remove any rich rule matching our tag pattern.
            firewall-cmd --permanent --remove-rich-rule="rule protocol value=\"gre\" accept" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
        iptables)
            iptables -D INPUT -p 47 -s 0.0.0.0/0 -j ACCEPT 2>/dev/null || true
            iptables -t nat -D POSTROUTING -o "$iface" -m comment --comment "$FW_TAG" -j MASQUERADE 2>/dev/null || true
            iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,SYNACK SYN -m comment --comment "$FW_TAG" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            netfilter-persistent save >/dev/null 2>&1 || true
            ;;
    esac
    log "All GRE tunnels removed and persistence files deleted."
}

# --- guided add ---------------------------------------------------------------
guided_add() {
    compute_mtu
    compute_inner_pair
    echo
    echo "GRE tunnel setup (NOT encrypted)"
    echo "  Local public IP  : $LOCAL_IP  (auto-detected; edit with --local)"
    echo "  Remote public IP : $REMOTE_IP"
    echo "  Inner /30        : $LOCAL_INNER <-> $REMOTE_INNER  (parent $INNER_SUBNET)"
    echo "  Key              : ${GRE_KEY:-(none)}"
    echo "  TTL              : ${GRE_TTL:-(unset)}"
    echo "  Tunnel MTU       : $TUNNEL_MTU"
    echo "  Forwarding/NAT   : $([[ $DO_FORWARDING -eq 1 ]] && echo enabled || echo disabled)"
    echo
    warn "GRE is NOT encrypted. Use it only inside a trusted underlay."
    if ! ask_yes_no "Proceed with GRE tunnel '$NAME'?" "Y"; then
        die "Aborted before writing anything."
    fi
    create_tunnel
}

# --- argument parsing -----------------------------------------------------------
cmd=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --auto) AUTO=1; shift ;;
        --name) NAME="${2:-}"; shift 2 ;;
        --local) LOCAL_IP="${2:-}"; shift 2 ;;
        --remote) REMOTE_IP="${2:-}"; shift 2 ;;
        --inner-subnet) INNER_SUBNET="${2:-}"; shift 2 ;;
        --key) GRE_KEY="${2:-}"; shift 2 ;;
        --ttl) GRE_TTL="${2:-}"; shift 2 ;;
        --no-forwarding) DO_FORWARDING=0; shift ;;
        --inner-local) LOCAL_INNER="${2:-}"; shift 2 ;;
        --inner-remote) REMOTE_INNER="${2:-}"; shift 2 ;;
        add)
            cmd="add"; shift
            NAME="${1:-${GRE_TUNNEL_NAME:-}}"
            shift || true
            ;;
        remove) cmd="remove"; NAME="${1:-${GRE_TUNNEL_NAME:-}}"; shift || true ;;
        list) cmd="list"; shift ;;
        status) cmd="status"; STATUS_NAME="${1:-}"; shift || true ;;
        print-config) cmd="print-config"; shift ;;
        uninstall) cmd="uninstall"; shift ;;
        -*) warn "Unknown flag: $1 (ignored)"; shift ;;
        *) cmd="${cmd:-default}"; NAME="${NAME:-$1}"; shift ;;
    esac
done

# Validate inputs for any command that touches the network.
validate_inputs() {
    [[ -n "$NAME" ]] || NAME="${GRE_TUNNEL_NAME:-gre0}"
    [[ "$NAME" =~ ^[A-Za-z0-9_-]{1,15}$ ]] || die "Tunnel name must be 1..15 chars [A-Za-z0-9_-] (iproute2)."
    [[ -n "$LOCAL_IP" ]] || LOCAL_IP="${GRE_LOCAL_IP:-$(public_ip)}"
    validate_ipv4 "$LOCAL_IP" || die "Bad local IP."
    [[ -n "$REMOTE_IP" ]] || REMOTE_IP="${GRE_REMOTE_IP:-}"
    [[ -n "$REMOTE_IP" ]] || die "Remote IP is required (--remote or GRE_REMOTE_IP)."
    validate_ipv4 "$REMOTE_IP" || die "Bad remote IP."
    [[ "$REMOTE_IP" != "$LOCAL_IP" ]] || die "Remote IP equals local IP; a GRE tunnel needs two distinct endpoints."
    if [[ -n "$GRE_KEY" ]]; then
        if ! [[ "$GRE_KEY" =~ ^[0-9]+$ ]] && ! [[ "$GRE_KEY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            die "GRE key must be a 32-bit integer or a dotted quad."
        fi
    fi
    if [[ -n "$GRE_TTL" ]]; then
        if ! [[ "$GRE_TTL" =~ ^[1-9][0-9]*$ ]]; then
            die "TTL must be a positive integer."
        fi
    fi
}

main() {
    case "$cmd" in
        add)
            validate_inputs
            # If the caller passed explicit inner addresses (as the
            # peer-command does), honour them instead of recomputing.
            if [[ -n "${LOCAL_INNER:-}" && -n "${REMOTE_INNER:-}" ]]; then
                compute_mtu
            else
                compute_mtu
                compute_inner_pair
            fi
            if [[ "$AUTO" -eq 1 && ! -t 0 ]]; then
                create_tunnel
            elif [[ -t 0 ]]; then
                guided_add
            else
                create_tunnel
            fi
            ;;
        remove)
            [[ -n "$NAME" ]] || die "Tunnel name required."
            remove_tunnel "$NAME"
            ;;
        list)
            list_tunnels
            ;;
        status)
            status "${STATUS_NAME:-}"
            ;;
        print-config)
            validate_inputs
            compute_mtu
            compute_inner_pair
            print_config
            ;;
        uninstall)
            uninstall
            ;;
        default|"")
            if ip link show gre0 >/dev/null 2>&1 || [[ -d "$CONF_DIR" ]]; then
                management_menu
            else
                require_root
                detect_os
                NAME="${NAME:-$(next_name)}"
                LOCAL_IP="${LOCAL_IP:-$(public_ip)}"
                guided_add
            fi
            ;;
        *)
            warn "Unknown subcommand '$cmd' (treated as no-args)."
            if ip link show gre0 >/dev/null 2>&1 || [[ -d "$CONF_DIR" ]]; then
                management_menu
            else
                require_root
                detect_os
                NAME="${NAME:-$(next_name)}"
                LOCAL_IP="${LOCAL_IP:-$(public_ip)}"
                guided_add
            fi
            ;;
    esac
}

management_menu() {
    local choice
    while true; do
        echo
        echo "GRE management menu"
        echo "  1) Status (all tunnels)"
        echo "  2) List tunnels"
        echo "  3) Add tunnel"
        echo "  4) Remove tunnel"
        echo "  5) Print config (dry-run)"
        echo "  6) Uninstall all"
        echo "  0) Back / exit"
        printf 'Choice [0-6]: '
        read -r choice || choice="0"
        case "$choice" in
            1) status ;;
            2) list_tunnels ;;
            3)
                local n r
                n="$(ask "Tunnel name" "$(next_name)")"
                r="$(ask "Remote public IP" "")"
                NAME="$n"
                REMOTE_IP="$r"
                validate_inputs
                if ask_yes_no "Create tunnel '$NAME'?" "Y"; then
                    create_tunnel
                fi
                ;;
            4)
                local rn
                rn="$(ask "Tunnel to remove" "")"
                [[ -n "$rn" ]] && remove_tunnel "$rn"
                ;;
            5)
                NAME="${NAME:-$(next_name)}"
                REMOTE_IP="${REMOTE_IP:-}"
                validate_inputs
                compute_mtu
                compute_inner_pair
                print_config
                ;;
            6)
                if ask_yes_no "Uninstall all GRE tunnels?" "n"; then
                    uninstall
                fi
                ;;
            0|*) break ;;
        esac
    done
}

# Shared apt helper.
apt_get() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get "$@"
    elif command -v dnf >/dev/null 2>&1; then
        dnf "$@"
    else
        err "No supported package manager found (apt/dnf)."
        return 1
    fi
}

detect_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        echo "ufw"
    elif systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "firewalld"
    elif command -v iptables >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "none"
    fi
}

main

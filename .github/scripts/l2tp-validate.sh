#!/usr/bin/env bash
#
# .github/scripts/l2tp-validate.sh -- CI helper (not shipped to users).
#
# Feeds the output of `tools/l2tp.sh print-config` to the REAL strongSwan
# `starter` (ipsec.conf parser) and the REAL `xl2tpd`. Shared by the host
# job (l2tp-validate) and every container of the OS matrix
# (l2tp-os-matrix), so all of them apply exactly the same rules.
#
# Rules:
#   * strongswan-starter, xl2tpd and ppp must already be installed.
#   * No starter binary -> fail (nothing else parses ipsec.conf; no fallback).
#   * Negative controls first: a deliberately broken ipsec.conf and a
#     deliberately broken xl2tpd.conf MUST be rejected. If they are not,
#     the parser is not being exercised in this environment and a "clean"
#     result on the real config would mean nothing -> fail.
#   * Real config: any parser error -> fail. starter runtime errors (no
#     XFRM / netlink in a container, already running) are warnings only.
#
# Run from the repository root. Works as root (containers) or via sudo.
set -euo pipefail

SUDO=()
[[ "$(id -u)" -eq 0 ]] || SUDO=(sudo)
as_root() { "${SUDO[@]}" "$@"; }

IPSEC_PARSE_ERR='unknown keyword|parsing error|syntax error|invalid'
XL2TPD_PARSE_ERR='parse_config:|Unable to load config file'

out="$(mktemp)"
bash tools/l2tp.sh print-config \
    --public-ip 203.0.113.9 \
    --psk 'TestPSK123456789012345' \
    >"$out"
echo "--- generated L2TP configs ---"
cat "$out"

# section FILE: body of the "--- FILE" block of the print-config output.
section() {
    awk -v h="--- $1" '$0 == h { f = 1; next } /^--- / { f = 0 } f { print }' "$out"
}
for f in /etc/ipsec.conf /etc/ipsec.secrets /etc/xl2tpd/xl2tpd.conf /etc/ppp/options.xl2tpd; do
    [[ -n "$(section "$f")" ]] || { echo "::error::print-config produced no '$f' section"; exit 1; }
done

as_root mkdir -p /etc/xl2tpd /etc/ppp /var/run/xl2tpd
section /etc/ipsec.secrets | as_root tee /etc/ipsec.secrets >/dev/null
as_root chmod 640 /etc/ipsec.secrets
section /etc/ppp/options.xl2tpd | as_root tee /etc/ppp/options.xl2tpd >/dev/null

stop_ipsec() {
    # A packaged service may auto-start on install; it would make our
    # foreground starter fail with "already running".
    if command -v systemctl >/dev/null 2>&1; then
        as_root systemctl stop strongswan-starter strongswan xl2tpd 2>/dev/null || true
        as_root systemctl disable strongswan-starter strongswan xl2tpd 2>/dev/null || true
    fi
    if command -v pkill >/dev/null 2>&1; then
        as_root pkill -f '/starter' 2>/dev/null || true
        as_root pkill charon 2>/dev/null || true
        as_root pkill xl2tpd 2>/dev/null || true
    fi
    if command -v ip >/dev/null 2>&1; then
        as_root ip xfrm state flush 2>/dev/null || true
        as_root ip xfrm policy flush 2>/dev/null || true
    fi
    as_root rm -f /var/run/starter.charon.pid /var/run/charon.pid /var/run/starter.pid \
        /var/run/charon.ctl /var/run/xl2tpd/l2tp-control 2>/dev/null || true
}

# --- locate starter ---------------------------------------------------------
STARTER_PATH=""
for cand in /usr/lib/ipsec/starter /usr/libexec/ipsec/starter /usr/sbin/starter \
            /usr/lib/strongswan/starter /usr/libexec/strongswan/starter; do
    if as_root test -x "$cand"; then STARTER_PATH="$cand"; break; fi
done
if [[ -z "$STARTER_PATH" ]]; then
    STARTER_PATH="$(dpkg -L strongswan-starter 2>/dev/null | grep -E '/starter$' | head -n1 || true)"
fi
if [[ -z "$STARTER_PATH" ]] || ! as_root test -x "$STARTER_PATH"; then
    echo "::error::strongSwan starter binary not found (is strongswan-starter installed?); ipsec.conf cannot be validated."
    dpkg -L strongswan-starter 2>&1 | head -40 || true
    exit 1
fi
echo "[l2tp] starter: $STARTER_PATH"

# Raise starter's log level so the parser's progress lines are printed,
# but only if this starter build advertises the option (never invent one).
STARTER_ARGS=(--nofork)
starter_help="$(as_root "$STARTER_PATH" --help 2>&1 || true)"
if grep -q -- '--debug' <<<"$starter_help"; then
    STARTER_ARGS+=(--debug)
fi
echo "[l2tp] starter args: ${STARTER_ARGS[*]}"

STARTER_OUT="" STARTER_RC=0
run_starter() {
    stop_ipsec
    STARTER_RC=0
    STARTER_OUT="$(timeout 10 "${SUDO[@]}" "$STARTER_PATH" "${STARTER_ARGS[@]}" 2>&1)" || STARTER_RC=$?
    stop_ipsec
}

# --- negative control: broken ipsec.conf MUST be rejected ---------------------
{
    section /etc/ipsec.conf
    printf '\nconn vpnbox-ci-broken\n    vpnboxbogusoption=yes\n'
} | as_root tee /etc/ipsec.conf >/dev/null
echo "=== starter on a DELIBERATELY BROKEN ipsec.conf (must report an error) ==="
run_starter
echo "$STARTER_OUT"
echo "[l2tp] starter exit code (broken config): $STARTER_RC"
if ! grep -iqE "$IPSEC_PARSE_ERR" <<<"$STARTER_OUT"; then
    echo "::error::starter did NOT reject an unknown keyword: the ipsec.conf parser is not being exercised here, so a clean run would prove nothing."
    exit 1
fi
echo "[l2tp] negative control OK: starter rejects a broken ipsec.conf."

# --- real ipsec.conf ------------------------------------------------------------
section /etc/ipsec.conf | as_root tee /etc/ipsec.conf >/dev/null
echo "=== starter on the GENERATED ipsec.conf ==="
run_starter
echo "$STARTER_OUT"
echo "[l2tp] starter exit code: $STARTER_RC"
case "$STARTER_RC" in
    124) echo "[l2tp] starter kept running for 10s (config loaded)." ;;
    0)   echo "[l2tp] starter exited cleanly." ;;
    126|127) echo "::error::starter could not be executed (exit $STARTER_RC)"; exit 1 ;;
    *)   echo "::warning::starter exited $STARTER_RC (runtime/environment, e.g. no XFRM in a container; not a config error)" ;;
esac
if grep -iqE "$IPSEC_PARSE_ERR" <<<"$STARTER_OUT"; then
    echo "::error::starter reported parsing errors in the generated ipsec.conf"
    exit 1
fi
echo "[l2tp] starter: generated ipsec.conf parsed with no errors."

# --- negative control: broken xl2tpd.conf MUST be rejected ----------------------
XL2TPD_OUT=""
run_xl2tpd() {
    stop_ipsec
    XL2TPD_OUT="$(timeout 3 "${SUDO[@]}" xl2tpd -D -c /etc/xl2tpd/xl2tpd.conf \
        -C /var/run/xl2tpd/l2tp-control 2>&1 || true)"
    stop_ipsec
}
{
    section /etc/xl2tpd/xl2tpd.conf
    printf '\n[lns vpnboxcibroken]\nvpnbox bogus field = yes\n'
} | as_root tee /etc/xl2tpd/xl2tpd.conf >/dev/null
echo "=== xl2tpd on a DELIBERATELY BROKEN xl2tpd.conf (must report an error) ==="
run_xl2tpd
echo "${XL2TPD_OUT:-(no output)}"
if ! grep -iqE "$XL2TPD_PARSE_ERR" <<<"$XL2TPD_OUT"; then
    echo "::error::xl2tpd did NOT reject an unknown field: its config parser is not being exercised here."
    exit 1
fi
echo "[l2tp] negative control OK: xl2tpd rejects a broken xl2tpd.conf."

# --- real xl2tpd.conf -------------------------------------------------------------
section /etc/xl2tpd/xl2tpd.conf | as_root tee /etc/xl2tpd/xl2tpd.conf >/dev/null
echo "=== xl2tpd on the GENERATED xl2tpd.conf ==="
run_xl2tpd
echo "${XL2TPD_OUT:-(no output)}"
if grep -iqE "$XL2TPD_PARSE_ERR" <<<"$XL2TPD_OUT"; then
    echo "::error::xl2tpd rejected the generated config"
    exit 1
fi
echo "[l2tp] xl2tpd: generated xl2tpd.conf loaded with no parse errors."

rm -f "$out"
echo "L2TP/IPsec config validated by real strongSwan starter + xl2tpd (negative controls passed)."

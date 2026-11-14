import re

with open('.github/workflows/shellcheck.yml', 'r') as f:
    content = f.read()

# Fix 1: Add sudo to chmod
content = content.replace(
    '          chmod 640 /etc/ipsec.secrets\n',
    '          sudo chmod 640 /etc/ipsec.secrets\n'
)

# Fix 2: GRE multiple tunnels - add shared CONF_DIR and synthetic gre0 config
old_gre = """      - name: Two independent pairs must pick disjoint /30s
        run: |
          set -uo pipefail
          D1="$(mktemp -d)"
          D2="$(mktemp -d)"
          bash tools/gre.sh print-config \\
            --name gre0 --local 203.0.113.1 --remote 203.0.113.2 \\
            --inner-subnet 10.10.0.0/24 > "$D1/a.txt"
          # Side B via print-config (not eval) to avoid root requirement
          bash tools/gre.sh print-config \\
            --name gre0 --local 203.0.113.2 --remote 203.0.113.1 \\
            --inner-subnet 10.10.0.0/24 > "$D1/b.txt"
          bash tools/gre.sh print-config \\
            --name gre1 --local 203.0.114.1 --remote 203.0.114.2 \\
            --inner-subnet 10.10.0.0/24 > "$D2/a.txt"
          bash tools/gre.sh print-config \\
            --name gre1 --local 203.0.114.2 --remote 203.0.114.1 \\
            --inner-subnet 10.10.0.0/24 > "$D2/b.txt"
"""

new_gre = """      - name: Two independent pairs must pick disjoint /30s
        run: |
          set -uo pipefail
          D1="$(mktemp -d)"
          D2="$(mktemp -d)"
          # Use a shared temp CONF_DIR so collision detection works across invocations.
          TEMP_CONF="$(mktemp -d)"
          export GRE_CONF_DIR="$TEMP_CONF"
          bash tools/gre.sh print-config \\
            --name gre0 --local 203.0.113.1 --remote 203.0.113.2 \\
            --inner-subnet 10.10.0.0/24 > "$D1/a.txt"
          # Side B via print-config (not eval) to avoid root requirement
          bash tools/gre.sh print-config \\
            --name gre0 --local 203.0.113.2 --remote 203.0.113.1 \\
            --inner-subnet 10.10.0.0/24 > "$D1/b.txt"
          # Simulate gre0 being installed: write its config so gre1 sees it.
          cat > "$TEMP_CONF/gre0.conf" <<'CONF'
NAME=gre0
LOCAL_IP=203.0.113.1
REMOTE_IP=203.0.113.2
INNER_SUBNET=10.10.0.0/24
LOCAL_INNER=10.10.0.1
REMOTE_INNER=10.10.0.2
GRE_KEY=
GRE_TTL=
MTU=1476
FORWARDING=1
CONF
          bash tools/gre.sh print-config \\
            --name gre1 --local 203.0.114.1 --remote 203.0.114.2 \\
            --inner-subnet 10.10.0.0/24 > "$D2/a.txt"
          bash tools/gre.sh print-config \\
            --name gre1 --local 203.0.114.2 --remote 203.0.114.1 \\
            --inner-subnet 10.10.0.0/24 > "$D2/b.txt"
"""

if old_gre in content:
    content = content.replace(old_gre, new_gre)
    print('GRE multiple fix applied')
else:
    print('GRE old string NOT found')
    # Show what's around that area
    idx = content.find('Two independent pairs must pick disjoint')
    if idx >= 0:
        print(repr(content[idx:idx+500]))

with open('.github/workflows/shellcheck.yml', 'w') as f:
    f.write(content)

print('Done')

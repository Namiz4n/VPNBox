import re

with open('.github/workflows/shellcheck.yml', 'r') as f:
    content = f.read()

# Fix 1: Add sudo to starter command
old_starter = '''starter_out="$(timeout 10 /usr/lib/ipsec/starter --nofork 2>&1)" || rc=$?'''
new_starter = '''starter_out="$(timeout 10 sudo /usr/lib/ipsec/starter --nofork 2>&1)" || rc=$?'''
if old_starter in content:
    content = content.replace(old_starter, new_starter)
    print('Starter sudo fix applied')
else:
    print('Starter fix NOT found')

# Fix 2: Replace heredoc with printf for GRE config
old_heredoc = """          # Simulate gre0 being installed: write its config so gre1 sees it.
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
"""

new_printf = """          # Simulate gre0 being installed: write its config so gre1 sees it.
          printf '%s\\n' \\
            'NAME=gre0' \\
            'LOCAL_IP=203.0.113.1' \\
            'REMOTE_IP=203.0.113.2' \\
            'INNER_SUBNET=10.10.0.0/24' \\
            'LOCAL_INNER=10.10.0.1' \\
            'REMOTE_INNER=10.10.0.2' \\
            'GRE_KEY=' \\
            'GRE_TTL=' \\
            'MTU=1476' \\
            'FORWARDING=1' \\
            > "$TEMP_CONF/gre0.conf"
"""

if old_heredoc in content:
    content = content.replace(old_heredoc, new_printf)
    print('Heredoc->printf fix applied')
else:
    print('Heredoc fix NOT found')
    idx = content.find('Simulate gre0')
    if idx >= 0:
        print(repr(content[idx:idx+500]))
    else:
        print('Section not found at all')

with open('.github/workflows/shellcheck.yml', 'w') as f:
    f.write(content)

print('Done')

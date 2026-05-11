#!/bin/sh
set -eu

cat <<'EOF'
Placeholder for the manual IGMP smoke test workflow.

Target checks:
1. multicast floods when snooping is disabled,
2. multicast floods on MDB miss,
3. one interested port receives multicast after join,
4. one uninterested port receives zero packets,
5. fallback flooding returns after listener teardown or expiry.

Expected tools:
- jail(8) or vnet-enabled test environment
- ifconfig(8)
- tcpdump(1)
- mcjoin(1)
EOF

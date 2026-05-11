#!/bin/sh
set -eu

cat <<'EOF'
Placeholder for the baseline VNET topology setup.

Planned topology:
- sender jail
- interested receiver jail
- uninterested receiver jail
- optional querier jail
- one if_bridge(4) instance
- epair(4) links between bridge and jails

This script should eventually:
1. create epair interfaces,
2. create the jails or VNET contexts,
3. attach member interfaces to the bridge,
4. configure IPv4 addressing and optional VLAN tagging,
5. print cleanup instructions or provide a teardown mode.
EOF

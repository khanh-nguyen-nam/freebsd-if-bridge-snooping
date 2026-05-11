#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 /path/to/freebsd-src" >&2
    exit 1
fi

src_root=$1

cat <<EOF
Expected upstream touch points for this project:

- $src_root/sys/net/if_bridge.c
- $src_root/sys/net/if_bridge.h
- $src_root/share/man/man4/if_bridge.4
- $src_root/tests/sys/net/if_bridge/

Next steps:
1. Create a dedicated development branch in the FreeBSD source tree.
2. Record the exact commit or branch under test in docs/progress/.
3. Build the VNET topology scripts in this repository before starting forwarding-path changes.
EOF

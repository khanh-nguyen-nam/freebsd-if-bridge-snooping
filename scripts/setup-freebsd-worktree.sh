#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $0 /path/to/freebsd-src [main|stable/14|stable/13|...]" >&2
    exit 1
fi

src_root=$1
branch=${2:-main}

cat <<EOF
FreeBSD source checkout plan
============================

Recommended branch: $branch

Official clone command:
    git clone -o freebsd https://git.FreeBSD.org/src.git $src_root

Initial checkout:
    cd $src_root
    git checkout $branch
    git switch -c khanh/if-bridge-snooping

Suggested local workflow:
1. Keep this proposal repo separate from the FreeBSD src tree.
2. Record the exact FreeBSD branch and commit under test in dev-notes/progress.md.
3. Develop in the external src tree and export patch series back into this repo's patches/ directory.
4. Build VNET topology helpers in this repo before touching the forwarding path.

Primary files to read first:
- $src_root/sys/net/if_bridge.c
- $src_root/sys/net/if_bridge.h
- $src_root/share/man/man4/if_bridge.4

Second-pass files for multicast and parser behavior:
- $src_root/sys/net/if.c
- $src_root/sys/net/if_var.h
- $src_root/sys/net/if_types.h
- $src_root/sys/net/if_vlan_var.h
- $src_root/sys/net/ethernet.h
- $src_root/sys/netinet/ip.h
- $src_root/sys/netinet/igmp.h
- $src_root/sys/netinet/in.h
- $src_root/sys/netinet6/ip6.h
- $src_root/sys/netinet6/icmp6.h
- $src_root/sys/netinet6/mld6.h

Files and directories to search while reading:
- $src_root/tests/sys/net/
- $src_root/sys/modules/if_bridge/
- $src_root/sys/netinet/
- $src_root/sys/netinet6/
- $src_root/share/man/man9/

Searches worth running inside the src tree:
    rg -n "bridge_input|bridge_forward|bridge_broadcast|mld|igmp|NET_EPOCH|callout" sys/net sys/netinet sys/netinet6
    rg -n "if_bridge" tests/sys/net share/man/man4 sys/modules
EOF

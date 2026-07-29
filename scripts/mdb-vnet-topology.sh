#!/bin/sh
#
# Create or destroy a small VNET topology for if_bridge(4) MDB work.
#
# Topology:
#
#   sender jail       listener jail       idle jail
#       |                  |                 |
#    epair(s)b          epair(l)b         epair(i)b
#    epair(s)a          epair(l)a         epair(i)a
#       +------------------+-----------------+
#                         bridge

set -eu

prefix=${MDB_VNET_PREFIX:-mdbtest}
state_file=${MDB_VNET_STATE:-/tmp/${prefix}.state}

sender_jail=${prefix}_sender
listener_jail=${prefix}_listener
idle_jail=${prefix}_idle

usage()
{
	echo "usage: $0 create|check|destroy" >&2
	exit 2
}

require_root()
{
	if [ "$(id -u)" -ne 0 ]; then
		echo "must run as root" >&2
		exit 1
	fi
}

load_modules()
{
	kldload -n if_epair >/dev/null 2>&1 || true
	kldload -n if_bridge >/dev/null 2>&1 || true
}

jail_exists()
{
	jls -j "$1" jid >/dev/null 2>&1
}

destroy_jail()
{
	jail_name=$1
	ifname=$2

	if jail_exists "${jail_name}"; then
		jexec "${jail_name}" ifconfig "${ifname}" destroy \
		    >/dev/null 2>&1 || true
		jail -r "${jail_name}" >/dev/null 2>&1 || true
	fi
}

destroy_topology()
{
	if [ -f "${state_file}" ]; then
		. "${state_file}"

		destroy_jail "${sender_jail}" "${sender_epair}b"
		destroy_jail "${listener_jail}" "${listener_epair}b"
		destroy_jail "${idle_jail}" "${idle_epair}b"

		ifconfig "${bridge}" destroy >/dev/null 2>&1 || true
		ifconfig "${sender_epair}a" destroy >/dev/null 2>&1 || true
		ifconfig "${listener_epair}a" destroy >/dev/null 2>&1 || true
		ifconfig "${idle_epair}a" destroy >/dev/null 2>&1 || true

		rm -f "${state_file}"
	fi
}

create_topology()
{
	destroy_topology
	load_modules

	bridge=$(ifconfig bridge create)
	sender_if=$(ifconfig epair create)
	listener_if=$(ifconfig epair create)
	idle_if=$(ifconfig epair create)

	sender_epair=${sender_if%a}
	listener_epair=${listener_if%a}
	idle_epair=${idle_if%a}

	jail -c name="${sender_jail}" persist vnet \
	    vnet.interface="${sender_epair}b"
	jail -c name="${listener_jail}" persist vnet \
	    vnet.interface="${listener_epair}b"
	jail -c name="${idle_jail}" persist vnet \
	    vnet.interface="${idle_epair}b"

	jexec "${sender_jail}" ifconfig "${sender_epair}b" 192.0.2.1/24 up
	jexec "${listener_jail}" ifconfig "${listener_epair}b" 192.0.2.2/24 up
	jexec "${idle_jail}" ifconfig "${idle_epair}b" 192.0.2.3/24 up

	ifconfig "${bridge}" up
	ifconfig "${sender_epair}a" up
	ifconfig "${listener_epair}a" up
	ifconfig "${idle_epair}a" up
	ifconfig "${bridge}" addm "${sender_epair}a"
	ifconfig "${bridge}" addm "${listener_epair}a"
	ifconfig "${bridge}" addm "${idle_epair}a"

	cat > "${state_file}" <<EOF
bridge='${bridge}'
sender_epair='${sender_epair}'
listener_epair='${listener_epair}'
idle_epair='${idle_epair}'
sender_jail='${sender_jail}'
listener_jail='${listener_jail}'
idle_jail='${idle_jail}'
EOF

	echo "created ${bridge} with ${sender_jail}, ${listener_jail}, ${idle_jail}"
}

check_topology()
{
	if [ ! -f "${state_file}" ]; then
		echo "no state file: ${state_file}" >&2
		exit 1
	fi

	. "${state_file}"

	ifconfig "${bridge}" | grep 'member:'
	jexec "${sender_jail}" ping -c 1 -t 1 192.0.2.2
	jexec "${sender_jail}" ping -c 1 -t 1 192.0.2.3
}

require_root

case "${1:-}" in
create)
	create_topology
	;;
check)
	check_topology
	;;
destroy)
	destroy_topology
	;;
*)
	usage
	;;
esac

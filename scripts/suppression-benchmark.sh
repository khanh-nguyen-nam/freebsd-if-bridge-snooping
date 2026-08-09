#!/bin/sh
#
# suppression-benchmark.sh — quantifies IGMP-snooping suppression efficiency
# using mcjoin (https://github.com/troglobit/mcjoin) as the traffic
# generator, per Bruce Simpson's guidance during proposal review:
#
#   "Using iperf is probably overkill unless there's a specific need for
#    performance testing. In this case, it's more important that the
#    suppression of traffic is what is exercised. Correctness and
#    conformance are more important... Something like ports/net/mcjoin
#    would perhaps be easier."
#
# This is deliberately NOT a throughput/latency benchmark. It measures one
# thing: how many multicast deliveries to *uninterested* ports the bridge
# suppresses, compared to the pre-snooping flood-everywhere baseline. That
# is the actual value proposition from the proposal's problem statement --
# "every uninterested guest still pays the cost of receiving, filtering,
# and discarding traffic it never joined" -- quantified rather than just
# asserted.
#
# Measurement approach:
#   - the SENDER and the real LISTENER both use mcjoin itself (traffic
#     generation and interested-receiver accounting, per Bruce's tool);
#   - IDLE ports are measured with tcpdump packet counts at the link
#     layer, not via mcjoin's own join/receive path -- this isolates what
#     the *bridge* delivers to the wire from any additional filtering an
#     idle port's own IP stack might apply, which would conflate two
#     different layers of suppression.
#
# Requires: mcjoin built and present at /tmp/mcjoin-src/mcjoin on this host
# (see docs/suppression-benchmark-result.md for how it was built here --
# this VM's ports tree doesn't carry net/mcjoin and pkg has no network
# access, so it's compiled by hand from upstream source, config.h
# hand-written since only 4 trivial PACKAGE_* string defines are needed).
#
# Usage: sh /tmp/suppression-benchmark.sh [idle-port-count] [packet-count]

set -u

MCJOIN=/tmp/mcjoin-src/mcjoin
NIDLE=${1:-4}
NPKT=${2:-500}
GROUP=239.77.77.1
PORT=12345
PAYLOAD=500          # bytes, roughly a typical small telemetry/control payload
FREQ_MS=5             # send interval -> ~2.5s run at NPKT=500
B=/tmp/suppbench
CAPT=6                # tcpdump timeout, > expected run time

log()  { echo "$@"; }
hdr()  { echo; echo "=== $* ==="; }

fail_hard() {
	echo "FATAL: $*" >&2
	exit 1
}

prereqs()
{
	test -x "$MCJOIN" || fail_hard "mcjoin not found at $MCJOIN"
	kldstat -q -m if_bridge || kldload if_bridge
	kldstat -q -m if_epair  || kldload if_epair
	mkdir -p "$B"
}

# stale_cleanup — remove any jails/bridge/epairs left behind by a prior
# run that was interrupted (e.g. Ctrl+C) before its own topo_destroy ran.
# Without this, a leftover topology from a killed run silently corrupts
# the next run's topo_create (this happened in practice: an interrupted
# run left bridge0 + 6 epairs behind, and the next run's fresh
# topo_create collided with them, producing an all-zeros result that
# looked like a measurement failure but was actually stale state).
stale_cleanup()
{
	i=0
	while [ ${i} -lt 32 ]; do
		jail -r "sbidle${i}" >/dev/null 2>&1
		i=$((i+1))
	done
	jail -r sbsend   >/dev/null 2>&1
	jail -r sblisten >/dev/null 2>&1
	for br in $(ifconfig -l | tr ' ' '\n' | grep '^bridge'); do
		ifconfig "${br}" destroy >/dev/null 2>&1
	done
	for ep in $(ifconfig -l | tr ' ' '\n' | grep '^epair.*a$'); do
		ifconfig "${ep}" destroy >/dev/null 2>&1
	done
}

# topo_create <n_idle> — bridge + sender + listener + n_idle idle jails.
# Sets TOPO_BRIDGE, TOPO_SENDER_EP, TOPO_LISTENER_EP, TOPO_IDLE_EP_<i>.
topo_create()
{
	n=$1
	TOPO_N_IDLE=${n}
	TOPO_BRIDGE=$(ifconfig bridge create)
	ifconfig ${TOPO_BRIDGE} up

	e=$(ifconfig epair create); ifconfig ${e} -txcsum -txcsum6
	TOPO_SENDER_EP=${e%a}
	jail -c name=sbsend persist vnet vnet.interface=${TOPO_SENDER_EP}b \
	    >/dev/null 2>&1
	jexec sbsend ifconfig ${TOPO_SENDER_EP}b 192.0.2.1/24 up
	jexec sbsend route add -net 224.0.0.0/4 -interface ${TOPO_SENDER_EP}b \
	    >/dev/null 2>&1
	ifconfig ${TOPO_SENDER_EP}a up
	ifconfig ${TOPO_BRIDGE} addm ${TOPO_SENDER_EP}a

	e=$(ifconfig epair create); ifconfig ${e} -txcsum -txcsum6
	TOPO_LISTENER_EP=${e%a}
	jail -c name=sblisten persist vnet vnet.interface=${TOPO_LISTENER_EP}b \
	    >/dev/null 2>&1
	jexec sblisten ifconfig ${TOPO_LISTENER_EP}b 192.0.2.2/24 up
	ifconfig ${TOPO_LISTENER_EP}a up
	ifconfig ${TOPO_BRIDGE} addm ${TOPO_LISTENER_EP}a

	i=0
	while [ ${i} -lt ${n} ]; do
		e=$(ifconfig epair create); ifconfig ${e} -txcsum -txcsum6
		ep=${e%a}
		jl="sbidle${i}"
		eval TOPO_IDLE_EP_${i}=${ep}
		jail -c name=${jl} persist vnet vnet.interface=${ep}b \
		    >/dev/null 2>&1
		jexec ${jl} ifconfig ${ep}b 192.0.2.$((10+i))/24 up
		ifconfig ${ep}a up
		ifconfig ${TOPO_BRIDGE} addm ${ep}a
		i=$((i+1))
	done
	sleep 1
}

topo_destroy()
{
	jail -r sbsend   >/dev/null 2>&1
	jail -r sblisten >/dev/null 2>&1
	ifconfig ${TOPO_SENDER_EP}a   destroy >/dev/null 2>&1
	ifconfig ${TOPO_LISTENER_EP}a destroy >/dev/null 2>&1
	i=0
	while [ ${i} -lt ${TOPO_N_IDLE:-0} ]; do
		eval ep=\$TOPO_IDLE_EP_${i}
		jail -r "sbidle${i}" >/dev/null 2>&1
		ifconfig ${ep}a destroy >/dev/null 2>&1
		i=$((i+1))
	done
	ifconfig ${TOPO_BRIDGE} destroy >/dev/null 2>&1
}

# run_once <snoop 0|1> -> sets RESULT_LISTENER, RESULT_IDLE_TOTAL,
# RESULT_IDLE_MAX (idle-port counts should be 0 unless snoop=0).
run_once()
{
	snoop=$1
	sysctl -q net.link.bridge.igmp_snooping=${snoop}

	# Listener joins and counts via mcjoin itself.
	jexec sblisten "$MCJOIN" -j -o -i ${TOPO_LISTENER_EP}b \
	    -c ${NPKT} -p ${PORT} -W ${CAPT} ${GROUP} \
	    > "${B}/listener.out" 2>&1 &
	lpid=$!

	# Idle ports: raw link-layer packet counts, independent of mcjoin's
	# own socket-level group membership (see header comment).
	# Single background level only -- jexec here must block on tcpdump
	# itself so that waiting on its PID actually waits for the capture
	# to finish, not just for jexec to spawn a detached grandchild.
	i=0
	idle_pids=""
	while [ ${i} -lt ${NIDLE} ]; do
		eval ep=\$TOPO_IDLE_EP_${i}
		jexec "sbidle${i}" sh -c \
		    "timeout ${CAPT} tcpdump -n --immediate-mode -i ${ep}b \
		    -c ${NPKT} \
		    'udp and dst host ${GROUP} and dst port ${PORT}' \
		    > ${B}/idle${i}.out 2>&1" &
		idle_pids="${idle_pids} $!"
		i=$((i+1))
	done
	sleep 1

	jexec sbsend "$MCJOIN" -s -o -i ${TOPO_SENDER_EP}b -b ${PAYLOAD} \
	    -c ${NPKT} -f ${FREQ_MS} -p ${PORT} -W ${CAPT} ${GROUP} \
	    > "${B}/sender.out" 2>&1

	wait ${lpid} 2>/dev/null
	for p in ${idle_pids}; do wait "${p}" 2>/dev/null; done
	sleep 1

	RESULT_SENT=$(grep -oE 'packets[[:space:]]+[0-9]+' "${B}/sender.out" \
	    | tail -1 | grep -oE '[0-9]+')
	RESULT_LISTENER=$(grep -oE 'packets[[:space:]]+[0-9]+' \
	    "${B}/listener.out" | tail -1 | grep -oE '[0-9]+')
	: "${RESULT_SENT:=0}"
	: "${RESULT_LISTENER:=0}"

	RESULT_IDLE_TOTAL=0
	RESULT_IDLE_MAX=0
	i=0
	while [ ${i} -lt ${NIDLE} ]; do
		# tcpdump -c N stops at N packets; count actual capture lines
		# (each printed packet is one line in default -n output,
		# excluding the summary lines it prints to the same stream).
		c=$(grep -cE '^[0-9]+:[0-9]+:[0-9]+\.[0-9]+ ' \
		    "${B}/idle${i}.out" 2>/dev/null)
		: "${c:=0}"
		RESULT_IDLE_TOTAL=$((RESULT_IDLE_TOTAL + c))
		[ "${c}" -gt "${RESULT_IDLE_MAX}" ] && RESULT_IDLE_MAX=${c}
		eval RESULT_IDLE_${i}=${c}
		i=$((i+1))
	done
}

main()
{
	prereqs
	stale_cleanup
	orig_snoop=$(sysctl -n net.link.bridge.igmp_snooping)
	topo_create "${NIDLE}"

	hdr "Config: ${NIDLE} idle ports, ${NPKT} packets/run, ${PAYLOAD}B payload, ${FREQ_MS}ms interval"

	hdr "Run 1/2: snooping OFF (baseline flood)"
	run_once 0
	SENT_OFF=${RESULT_SENT}
	LISTENER_OFF=${RESULT_LISTENER}
	IDLE_TOTAL_OFF=${RESULT_IDLE_TOTAL}
	IDLE_MAX_OFF=${RESULT_IDLE_MAX}
	log "  sent=${SENT_OFF} listener_received=${LISTENER_OFF} idle_total=${IDLE_TOTAL_OFF} (across ${NIDLE} ports) idle_max=${IDLE_MAX_OFF}"

	hdr "Run 2/2: snooping ON (pruned)"
	run_once 1
	SENT_ON=${RESULT_SENT}
	LISTENER_ON=${RESULT_LISTENER}
	IDLE_TOTAL_ON=${RESULT_IDLE_TOTAL}
	IDLE_MAX_ON=${RESULT_IDLE_MAX}
	log "  sent=${SENT_ON} listener_received=${LISTENER_ON} idle_total=${IDLE_TOTAL_ON} (across ${NIDLE} ports) idle_max=${IDLE_MAX_ON}"

	topo_destroy
	sysctl -q net.link.bridge.igmp_snooping=${orig_snoop}

	hdr "Results"
	log "Listener delivery:  OFF ${LISTENER_OFF}/${SENT_OFF}   ON ${LISTENER_ON}/${SENT_ON}  (both should be ~complete: pruning must never cost the real listener packets)"
	log "Idle-port delivery: OFF ${IDLE_TOTAL_OFF} total across ${NIDLE} ports (max ${IDLE_MAX_OFF}/port)   ON ${IDLE_TOTAL_ON} total (max ${IDLE_MAX_ON}/port)"

	if [ "${IDLE_TOTAL_OFF}" -gt 0 ]; then
		suppressed=$(( (IDLE_TOTAL_OFF - IDLE_TOTAL_ON) * 100 / IDLE_TOTAL_OFF ))
	else
		suppressed="n/a (baseline captured 0 -- harness problem, not a real result)"
	fi
	log "Suppression ratio: ${suppressed}% of would-be-flooded idle deliveries avoided"
	log "Unnecessary deliveries avoided this run: $((IDLE_TOTAL_OFF - IDLE_TOTAL_ON)) packets across ${NIDLE} idle ports"
	log "(scales linearly with idle-port count: each additional uninterested jail/VM that would have paid the flood cost pays ~0 instead)"

	if [ "${IDLE_TOTAL_OFF}" -eq 0 ]; then
		echo "FAIL: baseline (snooping=0) captured zero idle packets -- harness is broken, not the kernel; do not trust the ON result above" >&2
		exit 1
	fi
	if [ "${LISTENER_OFF}" -eq 0 ] || [ "${LISTENER_ON}" -eq 0 ]; then
		echo "FAIL: the real listener received zero packets in some run -- that is the one failure mode that must never happen" >&2
		exit 1
	fi
}

main "$@"

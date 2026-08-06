#!/bin/sh
#
# snooping-edge-cases.sh — edge-case suite for if_bridge IGMP snooping
# patches 0001-0007.  Run as root on the test VM after the full series is
# built and installed.
#
#   scp scripts/snooping-edge-cases.sh nkhanh@172.16.167.140:/tmp/
#   (as root)  sh /tmp/snooping-edge-cases.sh
#
# Covers behaviors the ATF suite does not: the proposal's core correctness
# assertions 1-6, VLAN scoping of learned state, teardown/lifetime safety,
# and parser robustness.  Each test builds and destroys its own topology.
#
# Exits non-zero if any test FAILs.

set -u

PASS=0
FAIL=0
SKIP=0
FAILED_TESTS=""

B=/tmp/snoop_edge          # scratch dir (absolute: jexec chdirs to jail root)
CAPT=4                     # tcpdump capture window, seconds

log()  { echo "$@"; }
hdr()  { echo; echo "=== $* ==="; }
pass() { PASS=$((PASS+1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL+1)); FAILED_TESTS="${FAILED_TESTS}
  - $*"; echo "FAIL: $*"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $*"; }

#----------------------------------------------------------------------
# Helpers
#----------------------------------------------------------------------

prereqs()
{
	kldstat -q -m if_bridge || kldload if_bridge
	kldstat -q -m if_epair  || kldload if_epair
	mkdir -p ${B}
}

# build_helpers: compile the C senders/joiners once.
build_helpers()
{
	cat > ${B}/mcjoin.c << 'CSRC'
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv)
{
    struct ip_mreq mreq;
    int s, on = 1;
    if (argc != 4) return 1;
    s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s < 0) return 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    memset(&mreq, 0, sizeof(mreq));
    mreq.imr_multiaddr.s_addr = inet_addr(argv[1]);
    mreq.imr_interface.s_addr = inet_addr(argv[2]);
    if (setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP,
        &mreq, sizeof(mreq)) < 0)
        return 1;
    sleep(atoi(argv[3]));
    return 0;
}
CSRC
	cc -o ${B}/mcjoin ${B}/mcjoin.c 2>${B}/cc.err || return 1

	# igmpsend <ifaddr> <group> <type> <ttl> <mangle>
	#   type:   0x11 query, 0x16 v2 report, 0x17 leave, 0x22 v3 report
	#   mangle: none|cksum|trunc
	# For 0x22, a single group record is emitted; <group> is the record
	# group and the record type is taken from $6 (default 4 = TO_EX) with
	# $7 source addresses appended (default 0).
	cat > ${B}/igmpsend.c << 'CSRC'
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/igmp.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>

static unsigned short
cksum(const unsigned char *b, int len)
{
    unsigned long sum = 0;
    int i;
    for (i = 0; i + 1 < len; i += 2) sum += (b[i] << 8) | b[i + 1];
    if (len & 1) sum += b[len - 1] << 8;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (unsigned short)(~sum);
}

int
main(int argc, char **argv)
{
    struct sockaddr_in dst;
    struct in_addr mif;
    unsigned char buf[128];
    unsigned short sum;
    unsigned char ttl;
    const char *mangle;
    int s, len, type, rectype, nsrc, i;

    if (argc < 6) {
        fprintf(stderr, "usage: %s ifaddr group type ttl mangle "
            "[rectype nsrc]\n", argv[0]);
        return 2;
    }
    type = (int)strtol(argv[3], NULL, 0);
    ttl = (unsigned char)atoi(argv[4]);
    mangle = argv[5];
    rectype = argc > 6 ? (int)strtol(argv[6], NULL, 0) : 4;
    nsrc = argc > 7 ? atoi(argv[7]) : 0;

    s = socket(AF_INET, SOCK_RAW, IPPROTO_IGMP);
    if (s < 0) { perror("socket"); return 1; }
    mif.s_addr = inet_addr(argv[1]);
    if (setsockopt(s, IPPROTO_IP, IP_MULTICAST_IF, &mif, sizeof(mif)) < 0) {
        perror("IP_MULTICAST_IF"); return 1;
    }
    if (setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl)) < 0) {
        perror("IP_MULTICAST_TTL"); return 1;
    }

    memset(buf, 0, sizeof(buf));
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;

    if (type == 0x22) {
        /* IGMPv3 membership report, one group record. */
        buf[0] = 0x22;
        buf[6] = 0; buf[7] = 1;              /* numgrps = 1 */
        buf[8] = (unsigned char)rectype;      /* record type */
        buf[9] = 0;                           /* aux data len */
        buf[10] = (unsigned char)(nsrc >> 8);
        buf[11] = (unsigned char)(nsrc & 0xff);
        memcpy(&buf[12], &(struct in_addr){ inet_addr(argv[2]) }, 4);
        for (i = 0; i < nsrc; i++) {
            struct in_addr src;
            src.s_addr = htonl(ntohl(inet_addr("192.0.2.100")) + i);
            memcpy(&buf[16 + i * 4], &src, 4);
        }
        len = 16 + nsrc * 4;
        dst.sin_addr.s_addr = inet_addr("224.0.0.22");
    } else {
        buf[0] = (unsigned char)type;
        buf[1] = 100;                         /* max resp / unused */
        if (type != 0x11) {
            struct in_addr g;
            g.s_addr = inet_addr(argv[2]);
            memcpy(&buf[4], &g, 4);
            dst.sin_addr.s_addr = g.s_addr;
        } else {
            dst.sin_addr.s_addr = inet_addr("224.0.0.1");
        }
        len = 8;
    }

    if (strcmp(mangle, "v3trunc") == 0 && type == 0x22) {
        /*
         * Overclaim the source count: the record header now advertises
         * more sources than the packet carries.  The checksum below is
         * computed over the bytes actually sent, so it is valid and the
         * packet reaches the record-walk length validation, which must
         * reject it.
         */
        buf[10] = 0; buf[11] = (unsigned char)(nsrc + 8);
    }

    sum = cksum(buf, len);
    buf[2] = sum >> 8; buf[3] = sum & 0xff;

    if (strcmp(mangle, "cksum") == 0)
        buf[2] ^= 0xff;                       /* corrupt the checksum */
    if (strcmp(mangle, "trunc") == 0)
        len = 4;                              /* shorter than IGMP_MINLEN */

    for (i = 0; i < 3; i++) {
        if (sendto(s, buf, len, 0, (struct sockaddr *)&dst,
            sizeof(dst)) < 0) {
            perror("sendto");
            return 1;
        }
        usleep(200000);
    }
    return 0;
}
CSRC
	cc -o ${B}/igmpsend ${B}/igmpsend.c 2>>${B}/cc.err || return 1

	# massjoin <base-group> <count> <ifaddr> <secs> — join <count>
	# consecutive groups starting at <base-group> on one socket and hold.
	cat > ${B}/massjoin.c << 'CSRC'
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv)
{
    struct ip_mreq mreq;
    struct in_addr base;
    int s, i, n, ok = 0;
    if (argc != 5) return 2;
    base.s_addr = inet_addr(argv[1]);
    n = atoi(argv[2]);
    s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s < 0) return 1;
    for (i = 0; i < n; i++) {
        memset(&mreq, 0, sizeof(mreq));
        mreq.imr_multiaddr.s_addr = htonl(ntohl(base.s_addr) + i);
        mreq.imr_interface.s_addr = inet_addr(argv[3]);
        if (setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP,
            &mreq, sizeof(mreq)) == 0)
            ok++;
    }
    fprintf(stderr, "joined %d/%d\n", ok, n);
    sleep(atoi(argv[4]));
    return ok == n ? 0 : 1;
}
CSRC
	cc -o ${B}/massjoin ${B}/massjoin.c 2>>${B}/cc.err || return 1
	return 0
}

# topo_create <nports> — bridge + N jails named e0..e(N-1) / jail sn0..
# Sets: TOPO_BRIDGE, TOPO_EP_<i>, TOPO_JAIL_<i>; addresses 192.0.2.<i+1>.
topo_create()
{
	n=$1
	TOPO_N=${n}
	TOPO_BRIDGE=$(ifconfig bridge create)
	ifconfig ${TOPO_BRIDGE} up
	i=0
	while [ ${i} -lt ${n} ]; do
		e=$(ifconfig epair create)
		ifconfig ${e} -txcsum -txcsum6
		ep=${e%a}
		jl="sn${i}"
		eval TOPO_EP_${i}=${ep}
		eval TOPO_JAIL_${i}=${jl}
		jail -c name=${jl} persist vnet vnet.interface=${ep}b \
		    >/dev/null 2>&1
		jexec ${jl} ifconfig ${ep}b 192.0.2.$((i+1))/24 up
		# Every jail may originate multicast: IP_MULTICAST_IF does not
		# bypass the route lookup in ip_output().
		jexec ${jl} route add -net 224.0.0.0/4 -interface ${ep}b \
		    >/dev/null 2>&1
		ifconfig ${ep}a up
		ifconfig ${TOPO_BRIDGE} addm ${ep}a
		i=$((i+1))
	done
	sleep 1
}

topo_destroy()
{
	i=0
	while [ ${i} -lt ${TOPO_N:-0} ]; do
		eval jl=\$TOPO_JAIL_${i}
		eval ep=\$TOPO_EP_${i}
		jail -r ${jl} >/dev/null 2>&1
		ifconfig ${ep}a destroy >/dev/null 2>&1
		i=$((i+1))
	done
	ifconfig ${TOPO_BRIDGE} destroy >/dev/null 2>&1
	TOPO_N=0
}

# watch_start <jail> <ifc> <filter> <capfile> — background tcpdump.
# Sets WATCH_PID.  MUST NOT be called via command substitution: that runs
# the function in a subshell, so the job would not be a child of the caller
# and wait(1) would fail immediately rather than block.
watch_start()
{
	rm -f "$4"
	jexec "$1" sh -c "timeout ${CAPT} tcpdump --immediate-mode -n \
	    -i $2 -c 1 '$3' > $4 2>&1" &
	WATCH_PID=$!
}

# watch_result — sets WATCH_GOT to yes (frame captured) or no (timed out).
watch_result()
{
	if wait ${WATCH_PID}; then WATCH_GOT=yes; else WATCH_GOT=no; fi
}

snoop_on()  { sysctl -q net.link.bridge.igmp_snooping=1; }
snoop_off() { sysctl -q net.link.bridge.igmp_snooping=0; }
entries()   { sysctl -n net.link.bridge.mdb_entries; }
routers()   { sysctl -n net.link.bridge.mdb_routers; }
rejects()   { sysctl -n net.link.bridge.mdb_parse_reject; }

#----------------------------------------------------------------------
# T0 — harness self-test.  With snooping fully disabled and no MDB state
# whatsoever, a multicast ping MUST be observed on an uninterested port.
# If this fails the capture plumbing is broken and every "expected to be
# flooded" result below is meaningless, so abort rather than report a wall
# of false failures.
#----------------------------------------------------------------------
t0_harness_selftest()
{
	hdr "T0  harness self-test (capture path must observe a flood)"
	topo_create 3
	snoop_off
	watch_start ${TOPO_JAIL_2} "$(eval echo \$TOPO_EP_2)b" \
	    'icmp and dst host 239.0.0.1' ${B}/t0.cap
	sleep 1
	jexec ${TOPO_JAIL_0} ping -c 3 -t 1 239.0.0.1 >/dev/null 2>&1
	watch_result; got=${WATCH_GOT}
	topo_destroy

	if [ "${got}" = yes ]; then
		pass "T0 capture path works (flood observed with snooping off)"
		return 0
	fi
	fail "T0 harness self-test failed — capture path is broken, not the kernel"
	echo
	echo "ABORTING: cannot trust any flood-expectation result."
	echo "Capture output was:"; cat ${B}/t0.cap 2>/dev/null
	return 1
}

#----------------------------------------------------------------------
# T1 — link-local 224.0.0.0/24 must never be pruned (RFC 4541 2.1.1)
#----------------------------------------------------------------------
t1_link_local_exempt()
{
	hdr "T1  link-local group (224.0.0.251) must not be pruned"
	topo_create 3      # 0 sender, 1 listener, 2 idle
	snoop_on

	before=$(entries)
	jexec ${TOPO_JAIL_1} ${B}/mcjoin 224.0.0.251 192.0.2.2 25 &
	jpid=$!
	sleep 2
	after=$(entries)

	log "    mdb_entries before=${before} after=${after}"
	if [ "${after}" -gt "${before}" ]; then
		fail "T1a bridge created MDB state for link-local 224.0.0.251 (RFC 4541 says never snoop 224.0.0.0/24)"
	else
		pass "T1a no MDB state created for a link-local group"
	fi

	watch_start ${TOPO_JAIL_2} "$(eval echo \$TOPO_EP_2)b" \
	    'icmp and dst host 224.0.0.251' ${B}/t1.cap
	sleep 1
	jexec ${TOPO_JAIL_0} ping -c 3 -t 1 224.0.0.251 >/dev/null 2>&1
	watch_result; got=${WATCH_GOT}
	kill ${jpid} 2>/dev/null

	if [ "${got}" = yes ]; then
		pass "T1b link-local traffic still flooded to the uninterested port"
	else
		fail "T1b link-local 224.0.0.251 was PRUNED from an uninterested port (breaks mDNS/OSPF-class traffic; violates RFC 4541 and the proposal's assertion 5)"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
# T2 — state learned on one VLAN must not affect another VLAN
#----------------------------------------------------------------------
t2_vlan_scoping()
{
	hdr "T2  membership on VLAN 10 must not prune VLAN 20"
	topo_create 3
	snoop_on

	e1=$(eval echo \$TOPO_EP_1); e2=$(eval echo \$TOPO_EP_2)
	e0=$(eval echo \$TOPO_EP_0)

	# listener: vlan10.  sender+idle: vlan20.
	jexec ${TOPO_JAIL_1} ifconfig vlan10 create vlandev ${e1}b vlan 10 \
	    192.0.2.130/24 up >/dev/null 2>&1 || {
		skip "T2 could not create vlan interface"; topo_destroy; return; }
	jexec ${TOPO_JAIL_0} ifconfig vlan20 create vlandev ${e0}b vlan 20 \
	    192.0.2.140/24 up >/dev/null 2>&1
	jexec ${TOPO_JAIL_2} ifconfig vlan20 create vlandev ${e2}b vlan 20 \
	    192.0.2.141/24 up >/dev/null 2>&1
	# topo_create already pointed 224.0.0.0/4 at the untagged epair in
	# every jail.  A second "route add" for the same prefix silently fails
	# ("route already in table"), which would send the multicast out
	# untagged and make the VLAN-20 watcher see nothing no matter what the
	# bridge did.  Repoint the route at the tagged interface instead.
	jexec ${TOPO_JAIL_0} route delete -net 224.0.0.0/4 >/dev/null 2>&1
	jexec ${TOPO_JAIL_0} route add -net 224.0.0.0/4 -interface vlan20 \
	    >/dev/null 2>&1
	jexec ${TOPO_JAIL_1} route delete -net 224.0.0.0/4 >/dev/null 2>&1
	jexec ${TOPO_JAIL_1} route add -net 224.0.0.0/4 -interface vlan10 \
	    >/dev/null 2>&1
	sleep 1

	# Positive control: with snooping off there is no MDB involvement at
	# all, so the VLAN-20 idle port must see a VLAN-20 multicast ping.  If
	# it does not, the VLAN plumbing itself is broken and any pruning
	# claim below would be unfounded -- skip instead of blaming the kernel.
	snoop_off
	watch_start ${TOPO_JAIL_2} vlan20 \
	    'icmp and dst host 239.9.9.9' ${B}/t2ctl.cap
	sleep 1
	jexec ${TOPO_JAIL_0} ping -c 3 -t 1 239.9.9.9 >/dev/null 2>&1
	watch_result
	if [ "${WATCH_GOT}" != yes ]; then
		skip "T2 VLAN-20 control path did not carry multicast; VLAN topology unusable on this host"
		snoop_on; topo_destroy; return
	fi
	log "    control: VLAN-20 flood observed with snooping off"
	snoop_on

	jexec ${TOPO_JAIL_1} ${B}/mcjoin 239.9.9.9 192.0.2.130 25 &
	jpid=$!
	sleep 2
	log "    mdb_entries after VLAN-10 join: $(entries)"

	# Sender transmits on VLAN 20; the VLAN-20 idle port has no learned
	# state for (20, 239.9.9.9) and must therefore still be flooded.
	watch_start ${TOPO_JAIL_2} vlan20 \
	    'icmp and dst host 239.9.9.9' ${B}/t2.cap
	sleep 1
	jexec ${TOPO_JAIL_0} ping -c 3 -t 1 239.9.9.9 >/dev/null 2>&1
	watch_result; got=${WATCH_GOT}
	kill ${jpid} 2>/dev/null

	if [ "${got}" = yes ]; then
		pass "T2 VLAN-20 traffic unaffected by VLAN-10 membership"
	else
		fail "T2 VLAN-20 port was pruned using VLAN-10 listener state (MDB VLAN key not honored)"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
# T3 — snooping disabled floods even with live state (assertion 1)
#----------------------------------------------------------------------
t3_disable_restores_flood()
{
	hdr "T3  toggling snooping off restores flooding with state present"
	topo_create 3
	snoop_on
	jexec ${TOPO_JAIL_1} ${B}/mcjoin 239.1.1.1 192.0.2.2 25 &
	jpid=$!
	sleep 2
	log "    mdb_entries with listener joined: $(entries)"

	snoop_off
	watch_start ${TOPO_JAIL_2} "$(eval echo \$TOPO_EP_2)b" \
	    'icmp and dst host 239.1.1.1' ${B}/t3.cap
	sleep 1
	jexec ${TOPO_JAIL_0} ping -c 3 -t 1 239.1.1.1 >/dev/null 2>&1
	watch_result; got=${WATCH_GOT}
	kill ${jpid} 2>/dev/null
	snoop_on

	if [ "${got}" = yes ]; then
		pass "T3 snooping=0 floods despite live MDB state"
	else
		fail "T3 snooping=0 still pruned — the runtime knob does not fully disable the forwarding path"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
# T4 — unknown group floods while a different group is learned (assert 2)
#----------------------------------------------------------------------
t4_unknown_group_floods()
{
	hdr "T4  a learned group must not prune a different, unlearned group"
	topo_create 3
	snoop_on
	jexec ${TOPO_JAIL_1} ${B}/mcjoin 239.1.1.1 192.0.2.2 25 &
	jpid=$!
	sleep 2

	watch_start ${TOPO_JAIL_2} "$(eval echo \$TOPO_EP_2)b" \
	    'icmp and dst host 239.5.5.5' ${B}/t4.cap
	sleep 1
	jexec ${TOPO_JAIL_0} ping -c 3 -t 1 239.5.5.5 >/dev/null 2>&1
	watch_result; got=${WATCH_GOT}
	kill ${jpid} 2>/dev/null

	if [ "${got}" = yes ]; then
		pass "T4 unlearned group still flooded"
	else
		fail "T4 unlearned group 239.5.5.5 was pruned"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
# T5 — member detach with live MDB state (lifetime safety)
#----------------------------------------------------------------------
t5_member_detach()
{
	hdr "T5  detaching a member that holds MDB state"
	topo_create 3
	snoop_on
	jexec ${TOPO_JAIL_1} ${B}/mcjoin 239.1.1.1 192.0.2.2 25 &
	jpid=$!
	sleep 2
	held=$(entries)
	log "    mdb_entries with listener joined: ${held}"

	ifconfig ${TOPO_BRIDGE} deletem "$(eval echo \$TOPO_EP_1)a"
	sleep 1
	post=$(entries)
	log "    mdb_entries after member detach: ${post}"
	kill ${jpid} 2>/dev/null

	if [ "${post}" -le "${held}" ]; then
		pass "T5a member detach flushed its MDB state (no growth)"
	else
		fail "T5a MDB state grew after detaching a member"
	fi

	# Traffic must now flood again rather than blackhole.
	watch_start ${TOPO_JAIL_2} "$(eval echo \$TOPO_EP_2)b" \
	    'icmp and dst host 239.1.1.1' ${B}/t5.cap
	sleep 1
	jexec ${TOPO_JAIL_0} ping -c 3 -t 1 239.1.1.1 >/dev/null 2>&1
	watch_result; got=${WATCH_GOT}
	if [ "${got}" = yes ]; then
		pass "T5b traffic floods again after the listener port left"
	else
		fail "T5b traffic blackholed after the only listener port was detached"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
# T6 — repeated join/leave cycles must not leak MDB state (assertion 6)
#----------------------------------------------------------------------
t6_churn_no_leak()
{
	hdr "T6  20x join/leave churn must not leak entries"
	topo_create 2
	snoop_on
	base=$(entries)
	i=0
	while [ ${i} -lt 20 ]; do
		jexec ${TOPO_JAIL_1} ${B}/mcjoin 239.2.2.2 192.0.2.2 1 \
		    >/dev/null 2>&1
		i=$((i+1))
	done
	sleep 2
	after=$(entries)
	log "    mdb_entries base=${base} after 20 cycles=${after}"
	# One group was used, so at most one new entry may exist.
	if [ "${after}" -le "$((base+1))" ]; then
		pass "T6 no entry leak across 20 join/leave cycles (${base} -> ${after})"
	else
		fail "T6 MDB entries leaked across churn (${base} -> ${after})"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
# T7 — malformed IGMP is rejected and creates no state
#----------------------------------------------------------------------
t7_malformed_rejected()
{
	hdr "T7  malformed IGMP: rejected, no state created"
	topo_create 2
	snoop_on
	e1=$(eval echo \$TOPO_EP_1)

	for mangle in cksum trunc; do
		r0=$(rejects); e0c=$(entries)
		jexec ${TOPO_JAIL_1} ${B}/igmpsend 192.0.2.2 239.3.3.3 0x16 \
		    1 ${mangle} >/dev/null 2>&1
		sleep 1
		r1=$(rejects); e1c=$(entries)
		log "    ${mangle}: parse_reject ${r0}->${r1}, entries ${e0c}->${e1c}"
		if [ "${e1c}" -le "${e0c}" ]; then
			pass "T7 ${mangle} IGMP created no MDB state"
		else
			fail "T7 ${mangle} IGMP created MDB state"
		fi
	done

	# TTL != 1 must also be refused (RFC 2236 requires TTL 1).
	e0c=$(entries)
	jexec ${TOPO_JAIL_1} ${B}/igmpsend 192.0.2.2 239.4.4.4 0x16 5 none \
	    >/dev/null 2>&1
	sleep 1
	e1c=$(entries)
	log "    ttl=5: entries ${e0c}->${e1c}"
	if [ "${e1c}" -le "${e0c}" ]; then
		pass "T7 report with TTL!=1 created no MDB state"
	else
		fail "T7 report with TTL!=1 was accepted"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
# T8 — IGMPv3 revocation-only records must not create state (patch 7)
#----------------------------------------------------------------------
t8_igmpv3_negative_records()
{
	hdr "T8  IGMPv3 revocation-only records create no state"
	topo_create 2
	snoop_on

	# BLOCK_OLD_SOURCES (6) with sources, and TO_IN (3) with none.
	for spec in "6 2 BLOCK_OLD_SOURCES" "3 0 TO_IN-empty(leave)"; do
		set -- ${spec}
		rt=$1; ns=$2; name=$3
		e0c=$(entries)
		jexec ${TOPO_JAIL_1} ${B}/igmpsend 192.0.2.2 239.6.6.6 0x22 \
		    1 none ${rt} ${ns} >/dev/null 2>&1
		sleep 1
		e1c=$(entries)
		log "    ${name}: entries ${e0c}->${e1c}"
		if [ "${e1c}" -le "${e0c}" ]; then
			pass "T8 ${name} created no MDB state"
		else
			fail "T8 ${name} wrongly created MDB state"
		fi
	done

	# Positive control: ALLOW_NEW_SOURCES (5) with sources must create it.
	e0c=$(entries)
	jexec ${TOPO_JAIL_1} ${B}/igmpsend 192.0.2.2 239.7.7.7 0x22 1 none \
	    5 2 >/dev/null 2>&1
	sleep 1
	e1c=$(entries)
	log "    ALLOW_NEW_SOURCES(2 srcs): entries ${e0c}->${e1c}"
	if [ "${e1c}" -gt "${e0c}" ]; then
		pass "T8 ALLOW_NEW_SOURCES with sources created (*,G) state"
	else
		fail "T8 ALLOW_NEW_SOURCES with sources did NOT create state (patch 7 regression)"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
# T9 — router-port state is flushed when the router port detaches
#----------------------------------------------------------------------
t9_router_flush_on_detach()
{
	hdr "T9  router-port state flushed on member detach"
	topo_create 2
	snoop_on
	sysctl -q net.link.bridge.mdb_routers=0
	jexec ${TOPO_JAIL_1} ${B}/igmpsend 192.0.2.2 0.0.0.0 0x11 1 none \
	    >/dev/null 2>&1
	sleep 1
	learned=$(routers)
	log "    mdb_routers after queries: ${learned}"
	if [ "${learned}" -ge 1 ]; then
		pass "T9a router port learned from queries"
	else
		fail "T9a router port not learned from queries"
	fi

	ifconfig ${TOPO_BRIDGE} deletem "$(eval echo \$TOPO_EP_1)a"
	sleep 1
	post=$(routers)
	log "    mdb_routers after detach: ${post}"
	if [ "${post}" -lt "${learned}" ] || [ "${post}" -eq 0 ]; then
		pass "T9b router state released on detach (${learned} -> ${post})"
	else
		fail "T9b router state survived member detach (${learned} -> ${post})"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
# T10 — counters are writable-to-zero (patch 5 contract)
#----------------------------------------------------------------------
t10_counter_reset()
{
	hdr "T10 counters reset on write"
	ok=1
	for c in mdb_prune_hits mdb_flood_fallback mdb_parse_reject \
	    mdb_expired mdb_routers mdb_entries; do
		if ! sysctl -q net.link.bridge.${c}=0 2>/dev/null; then
			fail "T10 net.link.bridge.${c} is not writable"
			ok=0
		fi
	done
	[ ${ok} -eq 1 ] && pass "T10 all six counters accept a reset write"
}

#----------------------------------------------------------------------
# T11 — bridge destroy with live MDB state must not panic
#----------------------------------------------------------------------
t11_destroy_with_state()
{
	hdr "T11 bridge destroy while holding MDB state"
	topo_create 2
	snoop_on
	jexec ${TOPO_JAIL_1} ${B}/mcjoin 239.8.8.8 192.0.2.2 25 &
	jpid=$!
	sleep 2
	log "    mdb_entries before destroy: $(entries)"
	topo_destroy          # destroys the bridge with state still held
	kill ${jpid} 2>/dev/null
	sleep 1
	if sysctl -n net.link.bridge.mdb_entries >/dev/null 2>&1; then
		pass "T11 bridge destroyed with live state; system still healthy"
	else
		fail "T11 bridge subsystem unresponsive after destroy"
	fi
}

#----------------------------------------------------------------------
# T12 — IGMPv2 leave (0x17) must not remove state eagerly
#----------------------------------------------------------------------
t12_v2_leave_not_eager()
{
	hdr "T12 IGMPv2 leave does not remove state eagerly"
	topo_create 2
	snoop_on
	jexec ${TOPO_JAIL_1} ${B}/mcjoin 239.12.12.12 192.0.2.2 25 &
	jpid=$!
	sleep 2
	before=$(entries)
	jexec ${TOPO_JAIL_1} ${B}/igmpsend 192.0.2.2 239.12.12.12 0x17 1 none \
	    >/dev/null 2>&1
	sleep 1
	after=$(entries)
	kill ${jpid} 2>/dev/null
	log "    entries before leave=${before} after leave=${after}"
	if [ "${before}" -ge 1 ] && [ "${after}" -eq "${before}" ]; then
		pass "T12 v2 leave left state to aging (${before} -> ${after})"
	else
		fail "T12 v2 leave changed state eagerly (${before} -> ${after})"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
# T13 — malformed IGMPv3: record claims more sources than present
#----------------------------------------------------------------------
t13_malformed_v3()
{
	hdr "T13 malformed IGMPv3 record (overclaimed nsrc) is rejected"
	topo_create 2
	snoop_on
	r0=$(rejects); e0c=$(entries)
	jexec ${TOPO_JAIL_1} ${B}/igmpsend 192.0.2.2 239.13.13.13 0x22 1 \
	    v3trunc 4 1 >/dev/null 2>&1
	sleep 1
	r1=$(rejects); e1c=$(entries)
	log "    parse_reject ${r0}->${r1}, entries ${e0c}->${e1c}"
	if [ "${e1c}" -le "${e0c}" ] && [ "${r1}" -gt "${r0}" ]; then
		pass "T13 overclaimed-nsrc v3 report rejected, no state"
	elif [ "${e1c}" -le "${e0c}" ]; then
		fail "T13 no state created but mdb_parse_reject did not increment (${r0}->${r1})"
	else
		fail "T13 malformed v3 report created MDB state"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
# T14 — a port that is both listener and router gets exactly one copy
#----------------------------------------------------------------------
t14_dual_role_no_dup()
{
	hdr "T14 listener+router port receives exactly one copy (dedup)"
	topo_create 2
	snoop_on
	e1=$(eval echo \$TOPO_EP_1)

	# Jail 1 is a listener (join) and a router (sends queries).
	jexec ${TOPO_JAIL_1} ${B}/mcjoin 239.14.14.14 192.0.2.2 25 &
	jpid=$!
	sleep 2
	jexec ${TOPO_JAIL_1} ${B}/igmpsend 192.0.2.2 0.0.0.0 0x11 1 none \
	    >/dev/null 2>&1
	sleep 1
	log "    entries=$(entries) routers=$(routers) (same port holds both roles)"

	# One echo request in; count how many copies the dual-role port sees.
	rm -f ${B}/t14.cap
	jexec ${TOPO_JAIL_1} sh -c "timeout 3 tcpdump --immediate-mode -n \
	    -i ${e1}b -c 4 'icmp and dst host 239.14.14.14' \
	    > ${B}/t14.cap 2>&1" &
	tpid=$!
	sleep 1
	jexec ${TOPO_JAIL_0} ping -c 1 -t 1 239.14.14.14 >/dev/null 2>&1
	wait ${tpid} 2>/dev/null
	kill ${jpid} 2>/dev/null

	copies=$(grep -c 'echo request' ${B}/t14.cap 2>/dev/null || echo 0)
	log "    copies observed: ${copies}"
	if [ "${copies}" -eq 1 ]; then
		pass "T14 exactly one copy delivered to the dual-role port"
	elif [ "${copies}" -eq 0 ]; then
		fail "T14 dual-role port received nothing (blackhole)"
	else
		fail "T14 dual-role port received ${copies} copies (listener/router dedup broken)"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
# T15 — two listeners both receive; idle port still pruned
#----------------------------------------------------------------------
t15_two_listeners()
{
	hdr "T15 two listeners both receive; idle port pruned"
	topo_create 4      # 0 sender, 1+2 listeners, 3 idle
	snoop_on
	jexec ${TOPO_JAIL_1} ${B}/mcjoin 239.15.15.15 192.0.2.2 25 &
	j1=$!
	jexec ${TOPO_JAIL_2} ${B}/mcjoin 239.15.15.15 192.0.2.3 25 &
	j2=$!
	sleep 2
	log "    entries=$(entries) members expected on 2 ports"

	e1=$(eval echo \$TOPO_EP_1); e2=$(eval echo \$TOPO_EP_2)
	e3=$(eval echo \$TOPO_EP_3)
	rm -f ${B}/t15_l1.cap ${B}/t15_l2.cap ${B}/t15_i.cap
	jexec ${TOPO_JAIL_1} sh -c "timeout ${CAPT} tcpdump --immediate-mode \
	    -n -i ${e1}b -c 1 'icmp and dst host 239.15.15.15' \
	    > ${B}/t15_l1.cap 2>&1" &
	p1=$!
	jexec ${TOPO_JAIL_2} sh -c "timeout ${CAPT} tcpdump --immediate-mode \
	    -n -i ${e2}b -c 1 'icmp and dst host 239.15.15.15' \
	    > ${B}/t15_l2.cap 2>&1" &
	p2=$!
	jexec ${TOPO_JAIL_3} sh -c "timeout ${CAPT} tcpdump --immediate-mode \
	    -n -i ${e3}b -c 1 'icmp and dst host 239.15.15.15' \
	    > ${B}/t15_i.cap 2>&1" &
	p3=$!
	sleep 1
	jexec ${TOPO_JAIL_0} ping -c 3 -t 1 239.15.15.15 >/dev/null 2>&1
	wait ${p1}; s1=$?
	wait ${p2}; s2=$?
	wait ${p3}; s3=$?
	kill ${j1} ${j2} 2>/dev/null

	[ ${s1} -eq 0 ] && pass "T15 listener 1 received" \
	    || fail "T15 listener 1 did not receive (multi-member replication broken)"
	[ ${s2} -eq 0 ] && pass "T15 listener 2 received" \
	    || fail "T15 listener 2 did not receive (multi-member replication broken)"
	[ ${s3} -ne 0 ] && pass "T15 idle port pruned" \
	    || fail "T15 idle port received despite two-listener prune set"
	topo_destroy
}

#----------------------------------------------------------------------
# T16 — mass join: growth behavior and (absence of) an entry cap
#----------------------------------------------------------------------
t16_mass_join()
{
	hdr "T16 mass join: 300 groups from one port"
	topo_create 2
	snoop_on
	jexec ${TOPO_JAIL_1} ${B}/massjoin 239.100.0.1 300 192.0.2.2 20 \
	    2>${B}/t16.joins &
	jpid=$!
	sleep 8
	got=$(entries)
	log "    $(cat ${B}/t16.joins 2>/dev/null); mdb_entries=${got}"
	kill ${jpid} 2>/dev/null
	if [ "${got}" -ge 290 ]; then
		pass "T16 all 300 groups learned (${got} entries); NOTE: no upper bound on MDB size exists (cf. sc_brtmax=2000 for the unicast table) -- flag for upstream review"
	elif [ "${got}" -ge 1 ]; then
		fail "T16 only ${got}/300 groups learned (unexpected plateau: undocumented cap or report loss)"
	else
		fail "T16 no groups learned at all"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
# T17 (SLOW, ~5-10 min; set RUN_SLOW=1) — aging: expiry restores flooding
#----------------------------------------------------------------------
t17_aging_expiry()
{
	hdr "T17 aging: listener and router state expires, flooding restored"
	if [ "${RUN_SLOW:-0}" != "1" ]; then
		skip "T17 slow test skipped (set RUN_SLOW=1; needs up to MAXAGE 260s + prune period 300s)"
		return
	fi
	topo_create 3
	snoop_on
	sysctl -q net.link.bridge.mdb_expired=0

	# Short-lived joiner: reports once, exits after 5s, never refreshes.
	jexec ${TOPO_JAIL_1} ${B}/mcjoin 239.17.17.17 192.0.2.2 5
	jexec ${TOPO_JAIL_1} ${B}/igmpsend 192.0.2.2 0.0.0.0 0x11 1 none \
	    >/dev/null 2>&1
	sleep 1
	log "    t=0: entries=$(entries) routers=$(routers)"
	if [ "$(entries)" -lt 1 ] || [ "$(routers)" -lt 1 ]; then
		fail "T17 setup failed to create listener+router state"
		topo_destroy; return
	fi

	# Poll until both expire.  Lifetimes are 260s/255s but the prune
	# callout fires only every 300s, so worst case is ~560s.
	waited=0
	while [ ${waited} -lt 640 ]; do
		sleep 20; waited=$((waited+20))
		printf '    ...waited %ss (entries=%s routers=%s)\n' \
		    "${waited}" "$(entries)" "$(routers)"
		if [ "$(entries)" -eq 0 ] && [ "$(routers)" -eq 0 ]; then
			break
		fi
	done
	log "    expired after <= ${waited}s: entries=$(entries) routers=$(routers) mdb_expired=$(sysctl -n net.link.bridge.mdb_expired)"

	if [ "$(entries)" -eq 0 ] && [ "$(routers)" -eq 0 ]; then
		pass "T17a listener and router state expired (within ${waited}s)"
	else
		fail "T17a state did not expire within 640s (aging callout broken?)"
		topo_destroy; return
	fi
	if [ "$(sysctl -n net.link.bridge.mdb_expired)" -ge 1 ]; then
		pass "T17b mdb_expired counter incremented (first time this counter has ever been observed non-zero)"
	else
		fail "T17b state vanished but mdb_expired stayed 0 (removed via some other path?)"
	fi

	# Expiry must restore flooding, not blackhole.
	watch_start ${TOPO_JAIL_2} "$(eval echo \$TOPO_EP_2)b" \
	    'icmp and dst host 239.17.17.17' ${B}/t17.cap
	sleep 1
	jexec ${TOPO_JAIL_0} ping -c 3 -t 1 239.17.17.17 >/dev/null 2>&1
	watch_result
	if [ "${WATCH_GOT}" = yes ]; then
		pass "T17c traffic floods again after expiry (assertion 4)"
	else
		fail "T17c traffic blackholed after expiry"
	fi
	topo_destroy
}

#----------------------------------------------------------------------
main()
{
	prereqs
	log "Building helpers..."
	if ! build_helpers; then
		echo "FATAL: helper compilation failed:"; cat ${B}/cc.err; exit 2
	fi

	orig_snoop=$(sysctl -n net.link.bridge.igmp_snooping)

	if ! t0_harness_selftest; then
		sysctl -q net.link.bridge.igmp_snooping=${orig_snoop}
		exit 3
	fi

	t1_link_local_exempt
	t2_vlan_scoping
	t3_disable_restores_flood
	t4_unknown_group_floods
	t5_member_detach
	t6_churn_no_leak
	t7_malformed_rejected
	t8_igmpv3_negative_records
	t9_router_flush_on_detach
	t10_counter_reset
	t11_destroy_with_state
	t12_v2_leave_not_eager
	t13_malformed_v3
	t14_dual_role_no_dup
	t15_two_listeners
	t16_mass_join
	t17_aging_expiry

	sysctl -q net.link.bridge.igmp_snooping=${orig_snoop}

	hdr "Summary"
	echo "passed:  ${PASS}"
	echo "failed:  ${FAIL}"
	echo "skipped: ${SKIP}"
	if [ ${FAIL} -gt 0 ]; then
		echo "failing checks:${FAILED_TESTS}"
	fi
	echo
	echo "Check for kernel complaints with:"
	echo "  dmesg | grep -iE '\\b(panic|fault|trap|use-after|KASSERT)\\b'"
	[ ${FAIL} -eq 0 ]
}

main "$@"

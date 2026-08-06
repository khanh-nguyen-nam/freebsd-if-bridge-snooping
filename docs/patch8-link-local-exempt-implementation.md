# Patch 8 Implementation — Link-Local 224.0.0.0/24 Exemption

Patch: `patches/0008-if-bridge-link-local-exempt.patch`
Created: 2026-08-06. Applies after `0007`. Discovered via the edge-case
audit in `scripts/snooping-edge-cases.sh` (see
`docs/edge-case-test-suite.md`), not by inspection or an ATF failure.

## The bug

Nothing in the snooping path excluded the link-local `224.0.0.0/24` block.
`bridge_mdb_igmp_group_valid()` ([if_bridge.c:1320](../../../freebsd-src/sys/net/if_bridge.c)
in the pre-patch tree) was:

```c
return (IN_MULTICAST(ntohl(group.s_addr)));
```

`IN_MULTICAST` is true for all of `224.0.0.0`–`239.255.255.255`. That is the
right test for "is this address multicast at all," but RFC 4541 §2.1.1
carves `224.0.0.0/24` out as the administratively-scoped local-network
control block — mDNS (`224.0.0.251`), OSPF (`224.0.0.5`/`.6`), VRRP, RIP2,
etc. — traffic that every host on the segment must see unconditionally,
never subject to join/leave-style pruning. Both the IGMPv2/v1 report path
and the IGMPv3 record path in `bridge_mdb_learn_igmp()` /
`bridge_mdb_igmp_v3_report()` would learn `(*,G)` state for a group in this
block exactly as they would for any ordinary group, and `bridge_mdb_forward()`
would then prune to that state.

### Why it is reachable, not just theoretical

FreeBSD ships `net.inet.igmp.sendlocal=1` by default
(`sys/netinet/igmp.c:246`). `igmp_isgroupreported()` only unconditionally
suppresses the report for `224.0.0.1` (all-hosts); every other
`224.0.0.0/24` group, including `224.0.0.251`, gets a real IGMP report
whenever an application joins it and `sendlocal` is on — which is the
FreeBSD default. An ordinary mDNS-capable host joining that group on stock
FreeBSD triggers exactly the report the bridge mis-learned from.

### Why it blackholes listeners rather than just over-pruning

IGMPv2 report suppression means that if host B is about to report a group
it already sees host A reporting on the shared segment, B cancels its own
report. Before any MDB state exists the segment is still flooded, so B does
see A's report and does suppress its own. The bridge then learns only A's
port. Once that state exists, `bridge_mdb_forward()` switches from
"unknown group → flood" to "known group → prune to the recorded
listener(s)," and B — who never sent a report — is not in that set. B goes
from receiving via flood to receiving nothing, with no signal on the wire
that anything changed from B's point of view.

### Why earlier patches didn't already exclude it

Patches 2–4 built the general ASM join/learn/forward mechanism, which is
correct for its intended case: an application joins a real group, the
kernel reports it, the bridge learns and prunes to listeners. Patch 1's
`group_fwd_mask` is unrelated — it exempts a *link-layer* reserved MAC range
(`01-80-C2-00-00-0x`, STP/LLDP), not IP multicast. The "exempt link-local
control traffic" sentence patch 5 added to `bridge.4` described intent, not
implemented behavior; nothing before patch 8 special-cased this address
range in the learn or forward path.

## The fix

Two independent guards, so a stale kernel/patch state on one side can't
undermine the other:

1. **Learn side** — a new predicate:

   ```c
   static bool
   bridge_mdb_igmp_group_snoopable(struct in_addr group)
   {
       return (!IN_LOCAL_GROUP(ntohl(group.s_addr)));
   }
   ```

   Called at both the IGMPv2/v1 report site and the IGMPv3 per-record site
   (after the existing `bridge_mdb_igmp_group_valid()` check). A report
   naming a `224.0.0.0/24` group returns `0` (accepted, no state change) —
   not `EINVAL` — because the report is well-formed and simply not
   actionable; treating it as a parse failure would pollute
   `mdb_parse_reject` with legitimate traffic.

2. **Forward side** — in `bridge_mdb_forward()`, before the MDB lookup:

   ```c
   if (IN_LOCAL_GROUP(ntohl(ip.ip_dst.s_addr)))
       return (false);
   ```

   `IN_LOCAL_GROUP` is the existing FreeBSD macro (`sys/netinet/in.h`) for
   exactly this range; `IN_ANY_LOCAL` is the same macro `igmp.c` itself uses
   for equivalent decisions, so this reuses stock kernel definitions rather
   than inventing a new range check. This guard means that even if listener
   state for a `224.0.0.0/24` group already existed — e.g. recorded by a
   pre-patch-8 kernel before an upgrade — the forwarding path floods it
   regardless of what the MDB says.

## Files touched

- `sys/net/if_bridge.c` — three hunks: the new predicate, the IGMPv2/v1
  call site, the IGMPv3 call site, and the forwarding-side guard.
- `share/man/man4/bridge.4` — a paragraph in IGMP SNOOPING documenting the
  exemption and naming the concrete protocols it protects (mDNS, OSPF).
- `tests/sys/net/if_bridge_test.sh` — new `mdb_link_local_exempt` ATF test:
  join `224.0.0.251`, assert `mdb_entries` stays `0`, assert an
  uninterested port still receives the traffic.

## Deliberately out of scope

- IPv6 link-local/multicast-scope exemptions (`ff02::/16` etc.) — deferred
  to the IPv6/MLD phase, if pursued.
- A configurable allow-list — RFC 4541 treats this as unconditional, not a
  policy knob; matches the proposal's "exempt link-local control traffic"
  language, which was never conditional.

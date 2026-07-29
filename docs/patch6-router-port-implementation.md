# Patch 0006 — Implementation Summary

`0006-if-bridge-router-port-learning.patch` teaches `if_bridge(4)` to learn
multicast-router ports from IGMP membership queries and to include those ports
in the pruned forwarding set, so that snooping does not blackhole multicast
that a router needs to relay.

It closes the gap the proposal's forwarding invariant #6 left open — "forward
only to ports with positive listener state, *plus router ports later, if that
logic is added safely*" — and delivers the stretch item "conservative
router-port learning from IGMP/MLD queries" for the IPv4 path.

Apply after `0005`.

---

## Problem it solves

Before this patch, a learned group (an MDB hit) is forwarded to its listener
ports only. If a multicast router sits behind a bridge port but has no local
IGMP *listener* on that port (routers send queries, they do not join groups as
receivers), the router's port is pruned out. Any multicast the router needs to
forward upstream/downstream is silently dropped once snooping learns a
listener elsewhere. Standard IGMP-snooping switches avoid this by treating any
port on which IGMP queries are seen as a *multicast-router port* that receives
all snooped multicast.

Note the pre-patch behavior was only wrong on an MDB *hit*: with no listener
state at all the frame floods (reaching the router anyway). So router handling
only has to be added to the positive-listener forwarding path.

---

## What it adds

### 1. Router-port state

```c
struct bridge_mdb_router {
	CK_LIST_ENTRY(bridge_mdb_router) bmr_next;
	struct bridge_iflist	*bmr_bif;
	ether_vlanid_t		bmr_vlan;
	unsigned long		bmr_expire;
	struct epoch_context	bmr_epoch_ctx;
};
```

- A per-bridge `CK_LIST` `sc_mdbrouters` plus a `sc_mdbroutercnt` gauge, added
  to `struct bridge_softc` beside the existing MDB fields.
- Keyed by `(VLAN, port)` so router reachability is VLAN-scoped, matching the
  MDB's `(VID,G)` keying and preserving VLAN isolation.
- Aged exactly like listener membership: `bmr_expire` is refreshed by each
  query and reaped by the existing `bridge_mdb_prune()` aging callout.
- Reclaimed with the same epoch-deferred pattern as MDB members
  (`NET_EPOCH_CALL` on a `bmr_epoch_ctx`), so the lock-free forwarding reader
  can never dereference freed memory.

### 2. Learning from IGMP queries

`bridge_mdb_learn_igmp()` gains one switch case:

```c
case IGMP_HOST_MEMBERSHIP_QUERY:
	return (bridge_mdb_add_router(sc, vlan, bif,
	    BRIDGE_MDB_ROUTER_MAXAGE));
```

The query reuses all of the existing IGMP validation (IPv4, header
contiguity, length, IGMP checksum, `ttl == 1`, unfragmented) that already
guards the report/leave cases before the switch — a malformed query is
rejected and counted as `mdb_parse_reject`, same as any other bad control
frame. A query is *not* a group join, so no listener (`bmd`) state is created.
`BRIDGE_MDB_ROUTER_MAXAGE` (255 s) is the standard "other querier present"
interval and is conservative: the port stops being a router port only after
queries stop arriving for that long.

`bridge_mdb_add_router()` mirrors `bridge_mdb_add_member()` exactly — allocate
outside the lock with `M_NOWAIT`, insert-or-refresh under `BRIDGE_RT_LOCK`,
free the loser on the refresh path.

### 3. Forwarding to router ports

`bridge_mdb_forward()`'s delivery set becomes the union of:

1. the group's learned listener ports (as before), and
2. every router port whose VLAN matches the frame, excluding ports that are
   already listeners for this group (dedup via `bridge_mdb_member_lookup`).

The two-pass structure (find the last eligible destination, then replicate
giving it the original mbuf) is preserved, but generalized so `last` is a
`struct bridge_iflist *` rather than a listener-specific pointer, letting one
"last" straddle both lists. Two helpers factor out the shared logic and keep
the change behavior-preserving for the no-router case:

- `bridge_mdb_dest_ok()` — the eligibility test (not source, not
  `IFBIF_PRIVATE`-blocked, not STP-discarding, running) that both passes and
  both lists now share.
- `bridge_mdb_forward_one()` — the per-destination `m_dup`/pfil/`m_copyup`/
  enqueue sequence, lifted verbatim out of the old inline loop.

With no router ports learned, both router loops are empty and delivery is
byte-for-byte the previous behavior — the existing `mdb_selective_forward` and
`mdb_counters` tests exercise this unchanged path.

### 4. Observability

A sixth counter, consistent with patch 5's set:

```
net.link.bridge.mdb_routers   (RW, per-VNET) — current # of learned router ports
```

Registered `CTLFLAG_RW` (writable-to-zero reset, like the others),
incremented in `bridge_mdb_add_router` on a new entry, decremented in
`bridge_mdb_remove_router`, allocated/freed alongside the patch-5 counters in
`vnet_bridge_init`/`vnet_bridge_uninit`.

### 5. Lifetime / teardown

- `bridge_mdb_flush_member()` now also flushes router entries for a departing
  member port (`bridge_mdb_flush_router`), so detaching a member cannot leave
  a dangling router entry pointing at a freed `bif`.
- `bridge_mdb_fini()` drains `sc_mdbrouters` and its `KASSERT` now also
  requires `sc_mdbroutercnt == 0`.

### 6. Man page

`bridge.4`'s IGMP SNOOPING section documents router-port learning and the new
`mdb_routers` counter.

---

## Safety invariants preserved

- **Epoch-safety.** Router entries use the same synchronous-unlink /
  epoch-deferred-free pattern as MDB members. Readers
  (`bridge_mdb_forward`, `bridge_mdb_router_lookup`) run under `NET_EPOCH`;
  writers hold `BRIDGE_RT_LOCK`. `bridge_mdb_router_lookup` asserts
  `BRIDGE_RT_LOCK_OR_NET_EPOCH`.
- **No new blackhole.** Router forwarding is additive: it can only *add*
  destinations to a frame that was already going to be pruned, never remove
  one. The unknown-group flood fallback is untouched.
- **Default-off.** All of this runs only when `net.link.bridge.igmp_snooping`
  is 1; the learn and forward call sites remain gated in `bridge_forward`.
- **VLAN isolation.** Router ports are matched by VLAN before being added to a
  frame's delivery set.

---

## Files touched

| File | Change |
|------|--------|
| `sys/net/if_bridge.c` | `struct bridge_mdb_router`; softc list + gauge; `BRIDGE_MDB_ROUTER_MAXAGE`; router lookup/add/remove/destroy/flush; query case in `bridge_mdb_learn_igmp`; `bridge_mdb_dest_ok`/`bridge_mdb_forward_one` helpers + router-aware delivery in `bridge_mdb_forward`; router aging in `bridge_mdb_prune`; flush on member detach; `mdb_routers` counter; init/fini/uninit wiring |
| `share/man/man4/bridge.4` | router-port learning paragraph + `mdb_routers` counter in the IGMP SNOOPING section |
| `tests/sys/net/if_bridge_test.sh` | 4-jail router topology helper; IGMP-query sender helper; new `mdb_router_forward` ATF test + registration |

Deferred to later work (unchanged from the proposal): IGMPv3 source-filter
(SSM) fidelity beyond the ASM subset, and MLD/IPv6 router and listener
learning.

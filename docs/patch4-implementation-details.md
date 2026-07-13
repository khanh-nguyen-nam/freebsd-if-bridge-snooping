# Patch 0004 — Implementation Details

`0004-if-bridge-mdb-forward.patch` adds MDB-aware IPv4 multicast forwarding to
`if_bridge(4)`.  It touches four things: a locking assertion relaxation, the
epoch-deferred reclamation that makes that relaxation safe, the new
`bridge_mdb_forward()` function, and its call site inside `bridge_forward()`.
Each is described in full below.

---

## Bug fix: epoch-deferred reclamation (use-after-free)

### Root cause

The initial version of `bridge_mdb_forward()` relaxed the `bridge_mdb_lookup()`
assertion from `BRIDGE_RT_LOCK_ASSERT` to `BRIDGE_RT_LOCK_OR_NET_EPOCH_ASSERT`
so the fast path could call it without the mutex.  However the MDB destroy paths
(`bridge_mdb_destroy_entry`, `bridge_mdb_remove_member`) still called `free()`
immediately after `CK_LIST_REMOVE`, under `BRIDGE_RT_LOCK` only.

`BRIDGE_RT_LOCK` is a plain mutex.  An epoch reader never takes it, so there is
no mutual exclusion between:
- the aging callout `bridge_mdb_timer()` → `bridge_mdb_prune()` freeing a
  `bmd`/`bmm`, and
- `bridge_mdb_forward()` dereferencing that same pointer while still inside the
  net epoch.

Result: **use-after-free / kernel panic under load + aging**.

### Fix

Mirror the pattern `bridge_rtnode_destroy()` already uses for the unicast table:
keep `CK_LIST_REMOVE` and counter updates synchronous under `BRIDGE_RT_LOCK`,
but defer `free()` to the end of the current net epoch via `NET_EPOCH_CALL`.

Two `struct epoch_context` fields added to the MDB structs:

```c
struct bridge_mdb_member { ...; struct epoch_context bmm_epoch_ctx; };
struct bridge_mdb_entry  { ...; struct epoch_context bmd_epoch_ctx; };
```

Two deferred-free callbacks:

```c
static void bridge_mdb_destroy_member_cb(struct epoch_context *ctx) {
    free(__containerof(ctx, struct bridge_mdb_member, bmm_epoch_ctx), M_DEVBUF);
}
static void bridge_mdb_destroy_entry_cb(struct epoch_context *ctx) {
    free(__containerof(ctx, struct bridge_mdb_entry, bmd_epoch_ctx), M_DEVBUF);
}
```

Both destroy paths now end with `NET_EPOCH_CALL` instead of `free()`:

```c
CK_LIST_REMOVE(bmm, bmm_next);   /* unlinked synchronously — invisible to new lookups */
sc->sc_mdbmembercnt--;
NET_EPOCH_CALL(bridge_mdb_destroy_member_cb, &bmm->bmm_epoch_ctx);  /* freed after epoch */
```

The `new_bmd`/`new_bmm` cleanup in `bridge_mdb_add_member()` keeps immediate
`free()` — those allocations are never published to a list, so no epoch reader
can reach them.

---

## 1. Locking assertion relaxation in `bridge_mdb_lookup()`

**Location:** [if_bridge.c:979–991](sys/net/if_bridge.c#L979-L991)

```c
static struct bridge_mdb_entry *
bridge_mdb_lookup(struct bridge_softc *sc, const struct bridge_mdb_key *key)
{
    struct bridge_mdb_entry *bmd;

    BRIDGE_RT_LOCK_OR_NET_EPOCH_ASSERT(sc);   // ← changed from BRIDGE_RT_LOCK_ASSERT

    CK_LIST_FOREACH(bmd, &sc->sc_mdb, bmd_next) {
        if (bridge_mdb_key_equal(&bmd->bmd_key, key))
            return (bmd);
    }
    return (NULL);
}
```

### What the assertion means

`BRIDGE_RT_LOCK_OR_NET_EPOCH_ASSERT` is defined at [if_bridge.c:256–257](sys/net/if_bridge.c#L256-L257):

```c
#define BRIDGE_RT_LOCK_OR_NET_EPOCH_ASSERT(_sc)	\
    MPASS(in_epoch(net_epoch_preempt) || mtx_owned(&(_sc)->sc_rt_mtx))
```

It passes if **either** the caller holds the `sc_rt_mtx` mutex **or** the
caller is currently inside a `NET_EPOCH` section.  The previous assertion
(`BRIDGE_RT_LOCK_ASSERT`) required the mutex unconditionally.

### Why the change is safe

The MDB uses `CK_LIST` (Concurrent Key list), which is part of FreeBSD's
lock-free read side.  Readers may traverse a `CK_LIST` without a lock as long
as they are within an epoch section **and** removed nodes are not freed until
all concurrent readers have left their epoch.  `CK_LIST` makes the pointer
updates safe for concurrent traversal, but reclaiming node memory at the right
time is the writer's responsibility — see section 1a, which this patch adds
alongside the relaxed assertion.  Relaxing the assertion without deferring the
free would be a use-after-free.

Writers (`bridge_mdb_add_member`, `bridge_mdb_flush_member`,
`bridge_mdb_prune`, etc.) always take `BRIDGE_RT_LOCK` before modifying the
list.  This is the same pattern used by `bridge_rtnode_lookup` /
`bridge_rtnode_destroy` for the unicast forwarding table.

---

## 1a. Epoch-deferred reclamation of MDB nodes

**Location:** [if_bridge.c:1008–1068](sys/net/if_bridge.c#L1008-L1068)

`bridge_mdb_forward()` walks `sc_mdb` and an entry's `bmd_members` list under
**NET_EPOCH only** — it does not hold `BRIDGE_RT_LOCK`.  Since that lock is a
plain mutex, it gives no mutual exclusion against an epoch reader.  The aging
callout `bridge_mdb_timer()` → `bridge_mdb_prune()` (and member detach via
`bridge_mdb_flush_member()`) can therefore `free()` a `bmd`/`bmm` while a
forwarder is still dereferencing it — a use-after-free.

Originally the MDB was only read with `BRIDGE_RT_LOCK` held, so the destroy
paths freed nodes immediately.  This patch adds the first epoch-only reader, so
it also makes reclamation epoch-safe, mirroring `bridge_rtnode_destroy()`:
embed a `struct epoch_context` in each node and defer the `free()` via
`NET_EPOCH_CALL`.

```c
struct bridge_mdb_member { ...; struct epoch_context bmm_epoch_ctx; };
struct bridge_mdb_entry  { ...; struct epoch_context bmd_epoch_ctx; };

/* bridge_mdb_destroy_entry() / bridge_mdb_remove_member(): */
CK_LIST_REMOVE(bmm, bmm_next);          /* unlink synchronously, under lock */
sc->sc_mdbmembercnt--;
NET_EPOCH_CALL(bridge_mdb_destroy_member_cb, &bmm->bmm_epoch_ctx); /* free later */
...
CK_LIST_REMOVE(bmd, bmd_next);
sc->sc_mdbcnt--;
NET_EPOCH_CALL(bridge_mdb_destroy_entry_cb, &bmd->bmd_epoch_ctx);
```

The node is unlinked synchronously (invisible to new lookups) but freed only
once every reader that might hold a pointer has left the epoch — the guarantee
section 1's relaxed assertion depends on.

The `new_bmd` / `new_bmm` cleanup in `bridge_mdb_add_member()` keeps immediate
`free()`: those are speculative allocations freed only when never linked into a
list, so no epoch reader can reach them.

### Why the change is necessary

`bridge_mdb_forward()` is called from the fast path in `bridge_forward()`.
`bridge_forward()` runs entirely under `NET_EPOCH_ASSERT()` (see
[if_bridge.c:3089](sys/net/if_bridge.c#L3089)) and does **not** hold
`sc_rt_mtx`.  Without the relaxed assertion, calling `bridge_mdb_lookup()`
from the forwarding path would panic every time the assertion fired.

---

## 2. `bridge_mdb_forward()` — complete walk-through

**Location:** [if_bridge.c:1280–1436](sys/net/if_bridge.c#L1280-L1436)

### Signature and contract

```c
static bool
bridge_mdb_forward(struct bridge_softc *sc, struct bridge_iflist *sbif,
    struct mbuf *m)
```

| Parameter | Meaning |
|---|---|
| `sc` | Bridge softc (the bridge the packet arrived on) |
| `sbif` | Source `bridge_iflist` — the member port the packet came in on |
| `m` | The mbuf chain to forward; **ownership is transferred on `true` return** |

**Return value:**
- `true` — the MDB handled the packet; caller must not call `bridge_broadcast`.
  The mbuf has been consumed (either enqueued or freed).
- `false` — the group is not in the MDB; caller should fall through to
  `bridge_broadcast` as normal.

### Phase 1 — Early classification (return `false` without touching `m`)

```c
NET_EPOCH_ASSERT();

if (m->m_pkthdr.len < ETHER_HDR_LEN)
    return (false);

eh = mtod(m, struct ether_header *);

/* IPv4 multicast Ethernet addresses are 01:00:5e:xx:xx:xx. */
if (eh->ether_dhost[0] != 0x01 || eh->ether_dhost[1] != 0x00 ||
    eh->ether_dhost[2] != 0x5e)
    return (false);
```

The assertion confirms the function is only ever reached on the forwarding fast
path.  The MAC prefix check short-circuits everything else: if the destination
is not in the IANA IPv4 multicast Ethernet block (`01:00:5e:00:00:00` –
`01:00:5e:7f:ff:ff`), this function has nothing to do.  Returning `false` here
costs one pointer dereference and three byte comparisons for the common case of
non-multicast traffic that somehow reached this branch.

### Phase 2 — VLAN tag extraction and EtherType parsing

```c
vlan = VLANTAGOF(m);
ether_type = ntohs(eh->ether_type);
ipoff = ETHER_HDR_LEN;

if (ether_type == ETHERTYPE_VLAN || ether_type == ETHERTYPE_QINQ) {
    if (m->m_pkthdr.len < (int)sizeof(evh))
        return (false);
    m_copydata(m, 0, sizeof(evh), (caddr_t)&evh);
    if ((m->m_flags & M_VLANTAG) == 0)
        vlan = EVL_VLANOFTAG(ntohs(evh.evl_tag));
    ether_type = ntohs(evh.evl_proto);
    ipoff = sizeof(evh);
}

if (ether_type != ETHERTYPE_IP)
    return (false);
```

`VLANTAGOF(m)` reads the VLAN ID from the mbuf's hardware-stripped tag
(`M_VLANTAG` / `m_pkthdr.ether_vtag`).  When a VLAN or QinQ tag is still
inline in the packet (not stripped), the code reads the full `ether_vlan_header`
and extracts the tag from the wire bytes — but only if `M_VLANTAG` is not
already set (to avoid double-reading).  The IP payload offset (`ipoff`) is
advanced past the tag.  Non-IP frames are rejected so the function does not
attempt to parse arbitrary payloads.

### Phase 3 — IP header copy and multicast address check

```c
if (m->m_pkthdr.len < ipoff + (int)sizeof(ip))
    return (false);
m_copydata(m, ipoff, sizeof(ip), (caddr_t)&ip);

if (!IN_MULTICAST(ntohl(ip.ip_dst.s_addr)))
    return (false);

if (bridge_mdb_key_init(&key, AF_INET, &ip.ip_dst, vlan) != 0)
    return (false);
```

`m_copydata` copies exactly `sizeof(struct ip)` (20 bytes) out of the mbuf
chain at offset `ipoff`.  This is safe regardless of how the chain is
fragmented across mbufs.  The copy is into a stack-local `struct ip`, so no
mbuf pullup is needed.

`IN_MULTICAST` checks that bits 28–31 of the address are `1110` (the `224/4`
block).  This rejects the broadcast address (`255.255.255.255`) and all
unicast addresses that might have slipped through.

`bridge_mdb_key_init` populates the lookup key with `AF_INET`, the VLAN ID,
and the destination address.  It can only fail if the family is unsupported
(not possible here since we pass `AF_INET` directly), so the error path is
present only for completeness.

### Phase 4 — MDB lookup

```c
bmd = bridge_mdb_lookup(sc, &key);
if (bmd == NULL)
    return (false);
```

`bridge_mdb_lookup` does a linear scan of `sc_mdb` comparing each entry's key
with `bridge_mdb_key_equal`.  A `NULL` return means no IGMP Membership Report
has been seen for this group, so the bridge does not know where listeners are —
the caller should flood normally.

At this point the function has committed to handling the packet.  All
subsequent returns are `true`.

### Phase 5 — Bridge-level output pfil

```c
if (PFIL_HOOKED_OUT_46) {
    if (bridge_pfil(&m, sc->sc_ifp, NULL, PFIL_OUT) != 0)
        return (true);
    if (m == NULL)
        return (true);
}
```

`PFIL_HOOKED_OUT_46` is a compile-time or runtime check on whether any output
packet filters are registered on either the IPv4 or IPv6 pfil heads.  When no
filters are active, this entire block compiles away.

When filters are present, `bridge_pfil` runs the packet through the bridge
interface's (`sc->sc_ifp`) output hooks.  The second argument is `NULL` for the
per-interface destination because this is the bridge-level (pre-replication)
pass — the per-interface pass happens later, inside the member loop.

- If `bridge_pfil` returns non-zero, the packet has been freed internally;
  return `true` to prevent double-free.
- If it returns zero but `m` is `NULL`, the filter consumed the packet without
  returning an error (valid pfil behaviour); return `true` for the same reason.

This mirrors the `runfilt=1` path in `bridge_broadcast()`, which passes
`PFIL_OUT` for the bridge interface before iterating over members.

### Phase 6 — Source interface snapshot

```c
src_if = m->m_pkthdr.rcvif;
```

Captured after the pfil call because `bridge_pfil` may replace `m` with a
different mbuf if it needs to linearise the chain for a filter.  Reading
`rcvif` after the filter ensures we use the correct interface pointer from the
current mbuf.

### Phase 7 — First pass: find `last` eligible member

```c
last = NULL;
CK_LIST_FOREACH(bmm, &bmd->bmd_members, bmm_next) {
    struct bridge_iflist *dbif = bmm->bmm_bif;

    if (dbif->bif_ifp == src_if)                              // (a)
        continue;
    if (sbif != NULL &&
        (sbif->bif_flags & dbif->bif_flags & IFBIF_PRIVATE)) // (b)
        continue;
    if ((dbif->bif_flags & IFBIF_STP) &&
        dbif->bif_stp.bp_state == BSTP_IFSTATE_DISCARDING)   // (c)
        continue;
    if ((dbif->bif_ifp->if_drv_flags & IFF_DRV_RUNNING) == 0) // (d)
        continue;
    last = bmm;
}
```

The four eligibility checks:

**(a) Skip the source port** — the packet came in on this interface; sending it
back would create a loop.

**(b) Private segment isolation** — when both the source port and the candidate
destination port both have `IFBIF_PRIVATE` set, traffic between them is blocked
(a private port cannot communicate with other private ports on the same bridge,
by policy).  The `sbif != NULL` guard handles the case where the function is
called without a source `bridge_iflist` (e.g., from a span context), though in
practice `bridge_forward` always provides a valid `sbif`.

**(c) STP discarding state** — a port in the Spanning Tree Protocol discarding
state must not forward frames.  Only ports that have `IFBIF_STP` enabled are
checked (ports without STP are always eligible from STP's point of view).

**(d) Interface not running** — the underlying network interface driver is not
in `IFF_DRV_RUNNING` state; it cannot accept packets.

The purpose of this pass is to record the **last** eligible member.  That
pointer is used in the second pass to avoid one unnecessary `m_dup`: the last
eligible port gets the original mbuf directly instead of a copy.

Why this is a separate pass: when walking the list in a single straightforward
loop, the current member cannot know whether a later eligible member exists.  If
the function handed the original mbuf to the first eligible member, it would no
longer have an original packet to copy for later members.  It could merge the
two phases with a more subtle "pending member" algorithm, where each eligible
member is delayed until another eligible member is found, but that makes mbuf
ownership and pfil error handling harder to audit.  The two-pass version keeps
the ownership rule simple: every eligible member before `last` gets a duplicate,
and `last` gets the original.

```c
if (last == NULL) {
    m_freem(m);
    return (true);
}
```

If the group is in the MDB but every member port is ineligible (e.g., all have
gone down, or all are the source interface), there is nowhere to send the
packet.  It is dropped rather than flooded — the MDB entry proves that a
listener joined, so flooding to unknown ports is not appropriate.  The mbuf is
freed and `true` is returned to prevent the caller from broadcasting.

### Phase 8 — Second pass: replicate and enqueue

```c
used = false;
CK_LIST_FOREACH(bmm, &bmd->bmd_members, bmm_next) {
    struct bridge_iflist *dbif = bmm->bmm_bif;
    dst_if = dbif->bif_ifp;

    /* same four eligibility checks as above */

    if (bmm == last) {
        mc = m;        // hand original to last port
        used = true;
    } else {
        mc = m_dup(m, M_NOWAIT);
        if (mc == NULL) {
            if_inc_counter(sc->sc_ifp, IFCOUNTER_OERRORS, 1);
            continue;
        }
    }
    ...
    bridge_enqueue(sc, dst_if, mc);
}
if (!used)
    m_freem(m);
```

**`m_dup` vs. `m_copym`** — `m_dup` produces a fully independent copy of the
mbuf chain, including packet headers and data.  It is used instead of `m_copym`
because per-interface pfil hooks (below) may modify the packet in place;
having a separate copy per port prevents modifications from bleeding across.
`M_NOWAIT` means the allocation will not sleep — appropriate because this runs
in the network fast path under NET_EPOCH.  Allocation failures skip the port
and increment the bridge's output error counter rather than dropping all
remaining copies.

**`used` flag** — tracks whether the original `m` has been handed off.  After
the loop, if `used` is still `false` (can only happen if `last` was skipped in
the second pass due to some transient state change between the two passes, e.g.,
the interface went down between the first and second walk), the original mbuf
is freed to prevent a leak.

### Phase 9 — Per-interface output pfil (inside the member loop)

```c
if (PFIL_HOOKED_OUT_46) {
    if (!used) {
        i = min(mc->m_pkthdr.len, max_protohdr);
        mc = m_copyup(mc, i, ETHER_ALIGN);
        if (mc == NULL) {
            if_inc_counter(sc->sc_ifp, IFCOUNTER_OERRORS, 1);
            continue;
        }
    }
    if (bridge_pfil(&mc, NULL, dst_if, PFIL_OUT) != 0)
        continue;
    if (mc == NULL)
        continue;
}
```

This block runs per port, with `dst_if` as the destination interface.
It intentionally lives inside the member loop, after `mc` has been chosen for
that specific port and before `bridge_enqueue()`.  A pfil hook may make a
different decision for each outgoing interface, so running this once at the
bridge level would not be equivalent.  For example, a firewall rule could allow
the multicast packet out one member port but block it on another.

**`m_copyup` for duplicated mbufs** — `m_dup` creates a chain where the data
may be split across multiple mbufs.  Many pfil hooks (packet filters, IPsec,
etc.) require the IP header (and often the transport header) to reside in the
first mbuf's data region — `max_protohdr` bytes covers Ethernet + IP + TCP
headers.  `m_copyup` ensures that many bytes are pulled up into the first
mbuf, with `ETHER_ALIGN` (2-byte) alignment to satisfy alignment requirements
of the IP stack.  This is skipped for the original mbuf (`if (!used)` means
this port received a copy, not the original) because the original mbuf was
already in its native layout from the receive path.

**Why `!used` instead of `bmm != last`** — by the time we reach this point,
`used` has been set to `true` only for the last port's iteration (where
`mc = m`).  For all other ports, `mc` is a freshly duplicated chain
(`used` is still `false`), so the copyup is needed.

**Ownership after pfil** — `bridge_pfil(&mc, NULL, dst_if, PFIL_OUT)` is allowed
to consume, replace, modify, or drop the mbuf:

- If it returns non-zero, the packet was rejected or consumed; this output port
  is skipped.
- If it returns zero but sets `mc == NULL`, the packet was consumed without an
  error; this output port is also skipped.
- If it returns zero and `mc != NULL`, `mc` is still valid and is handed to
  `bridge_enqueue(sc, dst_if, mc)`.

Those cases are local to the current replicated packet.  A drop on one member
port does not prevent the loop from trying the remaining eligible member ports.
This is why each non-last port gets its own `m_dup`: pfil may mutate the packet
in place, and those mutations must not leak into the copy sent to another port.

---

## 3. Call site in `bridge_forward()`

**Location:** [if_bridge.c:3187–3194](sys/net/if_bridge.c#L3187-L3194)

```c
if (dst_if == NULL) {
#ifdef INET
    if (bridge_mdb_forward(sc, sbif, m))
        return;
#endif
    bridge_broadcast(sc, src_if, m, 1);
    return;
}
```

### Where this sits in the forwarding pipeline

```
bridge_forward()
  │
  ├─ STP check on source port
  ├─ bridge_rtupdate()  (learn source MAC)
  ├─ STP learning-state drop
  ├─ netmap hook
  │
  ├─ unicast branch: bridge_rtlookup() → dst_if
  └─ multicast/broadcast branch: dst_if = NULL
       ├─ group_fwd_mask check (drop link-local if masked)
       ├─ IFCOUNTER_IMCASTS++
       ├─ bridge_mdb_input()  ← IGMP learning (patch 0003)
       │
       ├─ BPF tap (for unicast or dst_if != NULL case)
       ├─ pfil INPUT (PFIL_IN on bridge interface + source port)
       │
       ├─ if (dst_if == NULL):
       │     bridge_mdb_forward()  ← THIS PATCH
       │         true  → return (packet handled)
       │         false → fall through
       │     bridge_broadcast()    ← flood fallback
       └─ else: unicast enqueue path
```

### Why `bridge_mdb_input` is called before pfil but `bridge_mdb_forward` after

`bridge_mdb_input()` is a passive observer: it reads the IGMP payload to
update the MDB but does not modify `m` and does not make a forwarding decision.
Placing it before pfil ensures that IGMP Membership Reports are learned even
when a firewall rule drops the data packet.  If learning were gated on pfil
passing, a host could be blocked from sending data but its joins would also go
unlearned, causing unnecessary flooding for other hosts.

`bridge_mdb_forward()` must run after pfil INPUT because it is the forwarding
action.  The same packet filter that makes the input decision should have
already run by the time the bridge decides where to send the packet.

### `#ifdef INET` guard

The guard prevents the function from being referenced in `INET`-less kernels,
which would produce a linker error.  In those configurations, the code
compiles as if `bridge_mdb_forward` does not exist and `bridge_broadcast` is
always called.

### The `return` path

When `bridge_mdb_forward` returns `true`, `bridge_forward` returns
immediately.  There is no `goto drop` and no second call to `m_freem`, because
`bridge_mdb_forward`'s contract guarantees it has consumed `m`.

---

## 4. Interaction diagram

```
Incoming multicast frame (e.g. 239.1.1.1)
│
bridge_forward()
│
├─ bridge_mdb_input()          <── IGMP learning side effect; no forwarding
│   └─ (updates sc_mdb if frame is an IGMP report)
│
├─ pfil INPUT on bridge interface
│
└─ bridge_mdb_forward()
    │
    ├─ Phase 1: MAC prefix check (01:00:5e?) → false if not IPv4 mcast
    ├─ Phase 2: strip VLAN tag, determine EtherType
    ├─ Phase 3: copy IP header, check IN_MULTICAST(ip_dst)
    ├─ Phase 4: bridge_mdb_lookup() → NULL? → false (→ bridge_broadcast)
    ├─ Phase 5: pfil PFIL_OUT on bridge interface
    ├─ Phase 6: read src_if from m->m_pkthdr.rcvif
    ├─ Phase 7: first pass over bmd_members → find last eligible port
    │            NULL? → m_freem(m), true
    └─ Phase 8: second pass over bmd_members
                 for each eligible port:
                   dup m (or use original for last port)
                   m_copyup if dup + pfil hooks active
                   pfil PFIL_OUT per dst_if
                   bridge_enqueue()
                 if !used: m_freem(m)
                → return true
```

---

## 5. Edge cases and invariants

| Scenario | Outcome |
|---|---|
| Non-IPv4 frame with multicast MAC (e.g. IPv6 or ARP to `01:00:5e`) | Phase 3 rejects it (`ether_type != ETHERTYPE_IP`); returns `false`; caller floods |
| IPv4 multicast with no MDB entry (group never joined) | Phase 4 returns `false`; caller calls `bridge_broadcast` |
| Group in MDB but all member ports are down | Phase 7 finds `last == NULL`; packet dropped, `true` returned |
| Group in MDB, only source port is a member | Same as above — source is skipped, `last` stays `NULL` |
| Two eligible ports | Port 1 gets `m_dup`; port 2 (last) gets original `m` |
| One eligible port | First pass: `last` = that port. Second pass: `mc = m`, `used = true` immediately; no dup |
| pfil drops packet at bridge level | Returns `true` after phase 5 without entering member loop |
| pfil drops packet at per-interface level | That port's `mc` is discarded; other ports still receive their copies |
| `m_dup` fails for intermediate port | Error counter incremented; that port skipped; others unaffected |
| `m_copyup` fails | Error counter incremented; `continue` skips that port (mc is NULL after `m_copyup` failure) |

# FreeBSD `if_bridge(4)` IGMP/MLD Snooping — Patch Series Change Log

This document describes every source-level change introduced by the four-patch
series that adds IGMP snooping to the FreeBSD `if_bridge(4)` driver.  Changes
are presented patch-by-patch, file-by-file, with the exact lines affected and
the rationale behind each decision.

---

## Patch 0001 — `group_fwd_mask` ioctl and ifconfig support

**File:** `sys/net/if_bridgevar.h`

- Added two new ioctl numbers:
  - `BRDGGFWDMASK` (31) — get the current link-local group forwarding mask.
  - `BRDGSFWDMASK` (32) — set the link-local group forwarding mask.
- Added the macro alias `ifbrp_group_fwd_mask` mapping to the existing
  `ifbrpu_int16` union member of `struct ifbrparam`, so the mask travels
  through the existing parameter ioctl structure without a new ABI type.

**File:** `sys/net/if_bridge.c`

- **`struct bridge_softc`** — added `uint16_t sc_group_fwd_mask` field.
  Initialised to `0` (all 16 reserved link-local destinations filtered) in
  `bridge_clone_create`.

- **`bridge_rsvd_link_local_enabled()`** (new static helper) — given the
  softc and a destination MAC address, returns `true` if the address falls in
  `01:80:c2:00:00:[00-0f]` and the corresponding bit (bit `dst[5]`) is set in
  `sc_group_fwd_mask`.  Bit `n` controls address `01:80:c2:00:00:0n`.

- **`bridge_forward()`** — replaced the unconditional `goto drop` for
  reserved link-local destinations with a conditional: the drop only happens
  when `bridge_rsvd_link_local_enabled()` returns `false`.

- **`bridge_control_table[]`** — added two entries wiring `BRDGGFWDMASK` and
  `BRDGSFWDMASK` to the two new ioctl handlers.

- **`bridge_ioctl_gfwdmask()`** (new) — copies `sc->sc_group_fwd_mask` into
  the caller-supplied `ifbrparam`.

- **`bridge_ioctl_sfwdmask()`** (new) — stores the caller-supplied 16-bit
  value into `sc->sc_group_fwd_mask`.

**File:** `sbin/ifconfig/ifbridge.c`

- **`setbridge_group_fwd_mask()`** (new) — parses a hex or decimal argument,
  validates it fits in 16 bits, and calls `BRDGSFWDMASK`.
- **`bridge_status()`** — added a `printf` line that prints
  `group_fwd_mask 0x%04x` alongside the existing cache and lifetime output.
- **`bridge_cmds[]`** — registered the new `"group_fwd_mask"` keyword mapped
  to `setbridge_group_fwd_mask`.

**File:** `lib/libifconfig/libifconfig.h`

- Added `uint16_t group_fwd_mask` to `struct ifconfig_bridge_status` so
  callers of `libifconfig` can read the mask programmatically.

**File:** `lib/libifconfig/libifconfig_bridge.c`

- In `ifconfig_bridge_get_bridge_status()`, added a `BRDGGFWDMASK` ioctl call
  and stores the result into `bridge->inner.group_fwd_mask`.

**File:** `share/man/man4/bridge.4`

- Added a paragraph explaining the reserved link-local range, how
  `group_fwd_mask` controls it per-bit, and gave the example mask `0x4000`
  (enables forwarding of `01:80:c2:00:00:0e`, i.e., LLDP).

**File:** `tests/sys/net/if_bridge_test.sh`

- Added ATF test case `group_fwd_mask`:
  - Verifies the initial value is `0x0000`.
  - Sets and reads back `0x4000` and `0x0008`.
  - Verifies that `0x10000` (17-bit value) is rejected with exit status 1.

---

## Patch 0002 — Multicast Database (MDB) foundation

**File:** `sys/net/if_bridge.c`

### New constants

- `BRIDGE_MDB_PRUNE_PERIOD` — 5 minutes between aging walks of the MDB
  (matches the existing unicast routing-table prune period).

### New in-kernel data structures (defined inside `if_bridge.c`)

```
struct bridge_mdb_key   — (family, vlan, address) tuple that uniquely
                          identifies a multicast group on a VLAN.

struct bridge_mdb_member — one CK_LIST node per (group, port) pair.
                           Holds a back-pointer to the bridge_iflist and
                           an expiry timestamp (time_uptime-relative).

struct bridge_mdb_entry  — one CK_LIST node per (group, vlan) pair.
                           Contains the key and the head of its member list.
```

All three structures use `CK_LIST` so readers can traverse them safely under
`NET_EPOCH` without holding the write mutex.

### New fields on `struct bridge_softc`

- `sc_mdb` — `CK_LIST_HEAD` of all MDB entries.
- `sc_mdbcnt` — count of tracked multicast groups.
- `sc_mdbmembercnt` — count of (group, port) membership records.
- `sc_mdbcallout` — `struct callout` for the MDB aging timer.

### New static functions

| Function | Purpose |
|---|---|
| `bridge_mdb_init()` | Initialises the three counters and the list head. Called from `bridge_clone_create()`. |
| `bridge_mdb_key_init()` | Fills a `bridge_mdb_key` from a family, address pointer, and VLAN tag. Returns `EAFNOSUPPORT` for unknown families. |
| `bridge_mdb_key_equal()` | Byte-level comparison of two keys (family, VLAN, and address). |
| `bridge_mdb_lookup()` | Linear scan of `sc_mdb` for a matching key. Asserts `BRIDGE_RT_LOCK` (relaxed in patch 4). |
| `bridge_mdb_member_lookup()` | Linear scan of an entry's member list for a given `bridge_iflist *`. |
| `bridge_mdb_destroy_entry()` | Frees all members of one entry, then frees the entry itself. Decrements both counters. |
| `bridge_mdb_remove_member()` | Removes one member; if the entry is now empty, destroys it too. Returns `true` when the entry was destroyed. |
| `bridge_mdb_add_member()` | Full upsert: pre-allocates entry and member structs before taking the lock, then inserts only what is needed, updating or refreshing expiry. Frees pre-allocated memory that was not consumed. |
| `bridge_mdb_flush_member()` | Removes all MDB records for a given `bridge_iflist`. Called when a member interface is deleted from the bridge. |
| `bridge_mdb_prune()` | Removes all records whose `bmm_expire` has passed. Called from the aging timer. |
| `bridge_mdb_fini()` | Destroys all MDB entries. Called with `BRIDGE_RT_LOCK` held during bridge destruction; asserts both counters are zero afterward. |
| `bridge_mdb_timer()` | Callout handler: runs `bridge_mdb_prune()` and re-arms itself if the interface is still running. |

### Lifecycle wiring

- `bridge_clone_create()` — calls `bridge_mdb_init()` and
  `callout_init_mtx(&sc->sc_mdbcallout, &sc->sc_rt_mtx, 0)`.
- `bridge_init()` — calls `callout_reset` to start the MDB aging timer.
- `bridge_stop()` — calls `callout_stop` for the MDB timer.
- `bridge_clone_destroy()` — drains the callout, then calls
  `bridge_mdb_fini()` under `BRIDGE_RT_LOCK`.
- `bridge_delete_member()` — calls `bridge_mdb_flush_member()` before
  `bridge_rtdelete()` when a port is removed.

### Locking comment update

The locking comment at the top of `if_bridge.c` was updated to note that
`BRIDGE_RT_LOCK` protects MDB state in addition to `bridge_rtnodes`.

**File:** `sys/net/if_bridgevar.h`

- Minor whitespace fix: aligned the `BRDGGFWDMASK`/`BRDGSFWDMASK` macro
  definitions and collapsed the two-line `ifbrp_group_fwd_mask` comment to
  one line (no functional change).

**File:** `tests/sys/net/if_bridge_test.sh`

- Added shared helper `bridge_mdb_vnet_topology_create()` that sets up:
  - Three epairs (sender, listener, idle).
  - Three VNET jails (`mdbs`, `mdbl`, `mdbi`) each with a `.1/24` address
    on the `192.0.2.0/24` subnet.
  - One bridge with all three epair host-side interfaces as members.

- Added ATF test case `mdb_vnet_topology`:
  - Calls the topology helper.
  - Asserts the bridge reports exactly 3 member interfaces.
  - Verifies basic unicast reachability with `ping` between jails.

---

## Patch 0003 — IPv4 IGMP listener learning

**File:** `sys/net/if_bridge.c`

### New constant

- `BRIDGE_MDB_IGMP_MAXAGE` — 260 seconds (2 × 125 + 10).  This is the
  conservative worst-case listener lifetime from RFC 3376 §8.3 based on the
  default IGMP query interval (125 s) and two query periods.  Used until
  querier tracking is implemented.

### New `#include`

- `<netinet/igmp.h>` added inside `#ifdef INET` so IGMP type constants and
  struct definitions are available.

### New static functions (all inside `#ifdef INET`)

| Function | Purpose |
|---|---|
| `bridge_mdb_igmp_group_valid()` | Returns `true` if the address is a valid multicast group (`IN_MULTICAST`). Rejects `0.0.0.0` and addresses outside `224/4`. |
| `bridge_mdb_input()` | Entry point called from `bridge_forward()`. Strips the Ethernet header (and optional 802.1Q tag), confirms `ETHERTYPE_IP`, then dispatches to `bridge_mdb_learn_igmp()`. |
| `bridge_mdb_learn_igmp()` | Parses the IPv4 header (version check, options length, fragment check, IP checksum, TTL == 1 check, IGMP checksum). Dispatches on `igmp_type`: IGMPv1/v2 Reports call `bridge_mdb_add_member()` directly; Leave is a no-op (the aging timer expires the record naturally); IGMPv3 Reports delegate to `bridge_mdb_igmp_v3_report()`. |
| `bridge_mdb_igmp_v3_report()` | Parses the IGMPv3 Membership Report.  Two-pass design: first pass validates all group record lengths (bounds-checks `nsrc` and `auxlen` against the remaining buffer), second pass processes only `MODE_IS_EXCLUDE` and `CHANGE_TO_EXCLUDE_MODE` records with `nsrc == 0` (which correspond to "join this group"). Source-specific joins (`INCLUDE` mode with sources) are intentionally ignored in this patch — full IGMPv3 source-filter fidelity is deferred. |

### Call site in `bridge_forward()`

In the multicast else-branch (after the bridge determines no unicast
destination is known and sets `dst_if = NULL`), a call to
`bridge_mdb_input(sc, sbif, m)` is added immediately after the
`IFCOUNTER_IMCASTS` counter increment, before the forwarding decision.
This placement ensures:

1. IGMP learning happens even if pfil later drops the data packet.
2. The packet is still available for the fallback-to-flood path below.

**File:** `tests/sys/net/if_bridge_test.sh`

- Added ATF test case `mdb_unknown_multicast_flood`:
  - Uses the `bridge_mdb_vnet_topology_create()` topology.
  - Arms `tcpdump` on the idle jail watching for ICMP to `239.1.1.1`.
  - Sends a ping from the sender jail.
  - Asserts the packet *does* arrive on the idle port (flood fallback is intact
    because no IGMP join was issued, so the group is unknown to the MDB).

---

## Patch 0004 — MDB-aware IPv4 multicast forwarding

**File:** `sys/net/if_bridge.c`

### Locking assertion relaxed in `bridge_mdb_lookup()`

Changed:
```c
BRIDGE_RT_LOCK_ASSERT(sc);
```
to:
```c
BRIDGE_RT_LOCK_OR_NET_EPOCH_ASSERT(sc);
```

The forwarding path (`bridge_forward`) runs under `NET_EPOCH` without holding
`BRIDGE_RT_LOCK`.  `CK_LIST_FOREACH` is safe for readers under epoch (the same
pattern already used by `bridge_rtnode_lookup`).  Writers still take the mutex
before any modification, so there is no data race.

### New function `bridge_mdb_forward()`

A new `static bool` function inside `#ifdef INET`.

**Signature:**
```c
static bool bridge_mdb_forward(struct bridge_softc *sc,
    struct bridge_iflist *sbif, struct mbuf *m);
```

**Return value:** `true` if the MDB handled the packet (caller must not
broadcast); `false` if the group is unknown (caller should fall back to
flooding).  On a `true` return, ownership of `m` is transferred to this
function.

**Packet classification (early-exit path):**

1. Asserts `NET_EPOCH_ASSERT()` — the function may only be called on the
   forwarding fast-path.
2. Checks minimum Ethernet header length.
3. Checks that the destination MAC is `01:00:5e:xx:xx:xx` (IPv4 multicast
   Ethernet prefix).  Non-matching frames return `false` immediately.
4. Strips an optional 802.1Q or QinQ header; records the VLAN tag.
5. Returns `false` for any non-IP ether type.
6. Copies the IP header; confirms `IN_MULTICAST(ip_dst)`.
7. Calls `bridge_mdb_key_init()`; returns `false` on error.
8. Calls `bridge_mdb_lookup()` under epoch; returns `false` if the group is
   not in the MDB (triggers the flood fallback).

**Bridge-level output filter:**

If `PFIL_HOOKED_OUT_46`, runs `bridge_pfil(&m, sc->sc_ifp, NULL, PFIL_OUT)`
once before replication.  This mirrors the `runfilt=1` code path in
`bridge_broadcast()`.  If pfil drops the packet, returns `true` (packet is
consumed; no flood).

**Two-pass member enumeration:**

- **Pass 1** (find `last`): walks `bmd_members`, skipping:
  - The source interface (`dbif->bif_ifp == src_if`).
  - Private-port pairs (`sbif` and `dbif` both have `IFBIF_PRIVATE` set).
  - STP-discarding ports.
  - Interfaces not `IFF_DRV_RUNNING`.
  Records the last eligible `bridge_mdb_member *` as `last`.

- If `last == NULL` (group is known but no eligible destination exists),
  calls `m_freem(m)` and returns `true` to suppress unnecessary replication.

- **Pass 2** (replicate): same eligibility checks.  For the last eligible
  port, the original `m` is used directly (`used = true`).  For all earlier
  ports, `m_dup(m, M_NOWAIT)` creates a copy; allocation failure increments
  `IFCOUNTER_OERRORS` and skips that port.

  Inside the loop, if `PFIL_HOOKED_OUT_46`, runs per-interface
  `bridge_pfil(&mc, NULL, dst_if, PFIL_OUT)`.  For duplicated mbufs, calls
  `m_copyup(mc, min(mc->m_pkthdr.len, max_protohdr), ETHER_ALIGN)` first to
  ensure the IP header is in a contiguous region (mirrors `bridge_broadcast`).

  Each eligible copy is handed to `bridge_enqueue(sc, dst_if, mc)`.

- After the loop, if `used` is still `false` (no port consumed `m`), calls
  `m_freem(m)`.

### Call site in `bridge_forward()`

At the `if (dst_if == NULL)` branch — after pfil INPUT and the BPF tap, at
the point where the bridge would otherwise call `bridge_broadcast()`:

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

If `bridge_mdb_forward` returns `true`, the function returns immediately
without broadcasting.  If it returns `false` (group unknown), the existing
`bridge_broadcast` call handles the packet normally.

The `bridge_mdb_input()` call (learning) remains in the earlier `else`
multicast branch, before pfil INPUT, so IGMP packets are learned even if a
firewall rule later drops the data stream.

**File:** `tests/sys/net/if_bridge_test.sh`

- Added ATF test case `mdb_selective_forward`:
  - Uses the `bridge_mdb_vnet_topology_create()` topology.
  - Compiles a small C helper (`/tmp/mcast_join_bridge_test`) that calls
    `IP_ADD_MEMBERSHIP` on `239.1.1.1` bound to the listener jail's address,
    causing the kernel to emit an IGMPv2/v3 Membership Report.
  - Runs the helper in the `mdbl` (listener) jail for 30 seconds in the
    background.
  - Sleeps 2 seconds to allow the IGMP report to traverse the bridge and be
    learned by `bridge_mdb_input()`.
  - Arms `tcpdump` on the `mdbi` (idle) jail watching for ICMP to
    `239.1.1.1`, with a 4-second timeout and a capture count of 1.
  - Sends a ping from `mdbs` (sender) to `239.1.1.1`.
  - Asserts that `tcpdump` exits with **non-zero** status (packet was NOT
    captured on the idle port) — i.e., MDB pruning is working.
  - Cleans up the joiner process and the compiled helper binary.

---

## Summary of files changed across the series

| File | Patches | Nature of changes |
|---|---|---|
| `sys/net/if_bridge.c` | 0001–0004 | All kernel logic: ioctl handlers, MDB data structures and lifecycle, IGMP parser, MDB-aware forwarder, `bridge_forward` call sites |
| `sys/net/if_bridgevar.h` | 0001–0002 | New ioctl numbers, `ifbrparam` alias |
| `sbin/ifconfig/ifbridge.c` | 0001 | CLI keyword, status display |
| `lib/libifconfig/libifconfig.h` | 0001 | Public struct field |
| `lib/libifconfig/libifconfig_bridge.c` | 0001 | Ioctl call during status fetch |
| `share/man/man4/bridge.4` | 0001 | Man page documentation |
| `tests/sys/net/if_bridge_test.sh` | 0001–0004 | Four ATF test cases + shared topology helper |

## Deferred work

- **User-visible MDB dump** — no ioctl to read the current MDB state from
  userspace yet; needed for `ifconfig bridge0 mdb` display.
- **IGMPv3 source-filter fidelity** — `INCLUDE` mode records with a non-empty
  source list are currently ignored; full SSM (Source-Specific Multicast)
  pruning is deferred.
- **MLD / IPv6** — `bridge_mdb_input` only handles `ETHERTYPE_IP`; MLD
  listener discovery for IPv6 multicast is not yet implemented.
- **IGMP querier tracking** — the listener lifetime is a fixed conservative
  constant (`BRIDGE_MDB_IGMP_MAXAGE = 260 s`) rather than being derived from
  the active querier's query interval.

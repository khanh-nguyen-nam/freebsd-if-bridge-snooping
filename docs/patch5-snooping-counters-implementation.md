# Patch 0005 — Implementation Summary

`0005-if-bridge-snooping-counters.patch` adds the runtime control surface and
observability layer called for in Deliverable 4 of the proposal
("Hardening, Tests, And Documentation" → *Control Surface And Observability*).

It is the first patch that changes the **default** bridge behavior: snooping is
now opt-in. Everything patches 0002–0004 built remains, but it only takes
effect once `net.link.bridge.igmp_snooping` is set to 1.

Apply after `0004`.

---

## What it adds

### 1. Runtime enable knob (default off)

```
net.link.bridge.igmp_snooping   (RWTUN, per-VNET, default 0)
```

- `VNET_DEFINE_STATIC(int, igmp_snooping) = 0;`
- Gates **both** halves of the snooping path in `bridge_forward()`:
  - learning: `if (V_igmp_snooping) bridge_mdb_input(sc, sbif, m);`
  - forwarding: `if (V_igmp_snooping && bridge_mdb_forward(sc, sbif, m)) return;`
- When off, the bridge never learns listener state and floods all multicast
  exactly as it did before the MDB existed — the proposal's required safe
  default. This satisfies the non-goal "requiring snooping to be enabled for
  correctness of ordinary bridge forwarding."

### 2. Five read-only observability counters

All use `counter(9)` (`counter_u64_t`) so the fast path increments them
per-CPU without a lock, and all are per-VNET `CTLFLAG_RD` sysctls. Writing any
value to a counter zeroes it.

| sysctl | Kind | Meaning | Increment site |
|--------|------|---------|----------------|
| `net.link.bridge.mdb_entries` | gauge | current # of MDB group entries | `bridge_mdb_add_member` (+1 on new entry); `bridge_mdb_destroy_entry` / `bridge_mdb_remove_member` (−1 on entry removal) |
| `net.link.bridge.mdb_prune_hits` | event | IPv4 mcast frames pruned to listeners | `bridge_mdb_forward` after a successful MDB lookup |
| `net.link.bridge.mdb_flood_fallback` | event | IPv4 mcast frames flooded (no listener state) | `bridge_mdb_forward` on the `bmd == NULL` miss |
| `net.link.bridge.mdb_parse_reject` | event | malformed/unsupported IGMP control | `bridge_mdb_input` when `bridge_mdb_learn_igmp` returns `EINVAL` |
| `net.link.bridge.mdb_expired` | event | listener entries aged out | `bridge_mdb_prune` per expired member |

The gauge and event counters together answer the three questions the proposal
wants reviewers to be able to answer without packet captures:

1. *What state did the bridge learn?* → `mdb_entries`
2. *When did it prune?* → `mdb_prune_hits`
3. *When did it fall back to flooding?* → `mdb_flood_fallback` (+ `mdb_parse_reject`, `mdb_expired` for the why)

### 3. Lifetime management

Counters are allocated in `vnet_bridge_init()` (`counter_u64_alloc(M_WAITOK)`)
and freed in `vnet_bridge_uninit()` (`counter_u64_free`). This mirrors the
existing per-VNET pattern in `sys/netinet/ip_id.c`. A fresh VNET therefore
starts every counter at zero, which is what makes the new ATF test
deterministic.

### 4. Man page

`bridge.4` gains an `IGMP SNOOPING` section documenting the enable knob and all
five counters, including the "write zeroes the counter" and per-VNET semantics.

---

## Key implementation decisions

**Why `counter(9)` and not a plain `int`.** `bridge_mdb_forward()` runs in the
forwarding fast path under `NET_EPOCH` on multiple CPUs concurrently, with no
`BRIDGE_RT_LOCK` held. A plain `int++` would race. `counter_u64_add()` is the
idiomatic lock-free per-CPU primitive for exactly this.

**Why the gauge decrement lives at the two entry-removal sites.** All MDB group
entries are created at one site (`sc_mdbcnt++`) and destroyed at two
(`bridge_mdb_destroy_entry`, `bridge_mdb_remove_member`). Placing the
`counter_u64_add(V_mdb_entries, ±1)` calls right beside the existing
`sc_mdbcnt` updates keeps the gauge exactly in step with `sc_mdbcnt`, and both
run under `BRIDGE_RT_LOCK`.

**Why `SYSCTL_COUNTER_U64` + `CTLFLAG_VNET` works.** The sysctl framework
resolves the per-VNET offset (`kern_sysctl.c`: `arg1 = vnet_data_base + arg1`)
before `sysctl_handle_counter_u64` dereferences it, so the read fetches the
current VNET's counter. Confirmed against the tree, not assumed.

**Why the parse-reject counter only counts `EINVAL`.** `bridge_mdb_learn_igmp`
returns `EINVAL` for malformed/truncated/unsupported control traffic, `0` for
"parsed fine / not interesting," and `ENOMEM` for allocation failure. Only
`EINVAL` means "the parser rejected this packet," so only that is counted.

**Prune-hit is counted at commit, not per delivered port.** One frame that the
MDB handles = one prune hit, regardless of how many listener ports it fans out
to. This keeps the counter a frame count comparable to `mdb_flood_fallback`.

---

## Behavior change callout (important for testing)

Because snooping is now **default-off**, the patch also updates the existing
ATF tests so they still exercise the real paths:

- `mdb_selective_forward` — now runs `sysctl net.link.bridge.igmp_snooping=1`
  before joining. Without this it would (correctly) fail, since with snooping
  off the idle port *would* receive the flood.
- `mdb_unknown_multicast_flood` — now enables snooping too, so it tests the
  genuine "snooping on, no entry → flood fallback" path rather than the
  trivially-flooding disabled path.
- New `mdb_counters` test — enables snooping, joins a group, sends traffic to
  the joined group and to an unjoined group, and asserts `mdb_entries`,
  `mdb_prune_hits`, and `mdb_flood_fallback` all advance.

The join-helper C program that was inlined in `mdb_selective_forward` is
factored into a shared `bridge_mdb_compile_join_helper` shell function reused
by the new test.

---

## Files touched

| File | Change |
|------|--------|
| `sys/net/if_bridge.c` | `#include <sys/counter.h>`; enable knob + 5 counter sysctls; alloc/free in VNET init/uninit; increments at 6 sites; 2 call-site gates |
| `share/man/man4/bridge.4` | new `IGMP SNOOPING` section |
| `tests/sys/net/if_bridge_test.sh` | shared join helper; enable-knob in 2 existing tests; new `mdb_counters` test + registration |

Deferred to later patches (unchanged from the proposal): IGMPv3 source-filter
fidelity, router-port learning, MLD/IPv6.

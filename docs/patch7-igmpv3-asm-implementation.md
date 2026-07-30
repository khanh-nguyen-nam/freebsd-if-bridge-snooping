# Patch 7 Implementation — Conservative IGMPv3 ASM Refinement

Patch: `patches/0007-if-bridge-igmpv3-asm-refinement.patch`
Created: 2026-07-29. Applies after `0006`.

## What it does

Widens `bridge_mdb_igmp_v3_report()`'s per-record handling from "EXCLUDE
records with an empty source list only" to the full conservative ASM
reduction the proposal describes as stretch work ("Conservative IGMPv3
ASM-equivalent bookkeeping beyond the MVP subset"):

| IGMPv3 record | Old behavior | New behavior |
|---|---|---|
| `IS_EX` / `TO_EX`, no sources | create/refresh `(*,G)` | unchanged |
| `IS_EX` / `TO_EX`, with sources | ignored (flood) | create/refresh `(*,G)` |
| `IS_IN` / `TO_IN` / `ALLOW`, with sources | ignored (flood) | create/refresh `(*,G)` |
| `TO_IN` with no sources (IGMPv3 leave) | ignored | ignored (aging expires state, like the v2 leave) |
| `IS_IN` / `ALLOW` with no sources | ignored | ignored (no interest expressed) |
| `BLOCK_OLD_SOURCES` | ignored | ignored (only revokes; never removes state eagerly) |

## Why the reduction is safe

The forwarding invariant is unchanged: prune only on positive listener
state; when in doubt, flood.

- EXCLUDE mode means "receive every source except those listed" — that is
  `(*,G)` interest regardless of the source count, so accepting non-empty
  EXCLUDE records only widens learning, never delivery correctness.
- INCLUDE-family records with a non-empty list ask for *at least* those
  sources. Reducing to `(*,G)` delivers a superset of the request to that
  port — over-delivery, the same behavior the port would see from plain
  flooding, never under-delivery. No SSM filtering is claimed: source lists
  are parsed and bounds-checked but not used to narrow delivery.
- Revocation-only records (`TO_IN({})`, `BLOCK`) create no state and remove
  none; existing state expires through the same aging as an IGMPv2 leave,
  which protects shared-segment listeners from eager pruning.

## Files touched

- `sys/net/if_bridge.c` — one hunk: the record-type `switch` in
  `bridge_mdb_igmp_v3_report()`. No new structures, sysctls, counters, or
  locking changes; the record walk's two-pass validation (lengths, source
  counts, aux data) is untouched.
- `share/man/man4/bridge.4` — a paragraph in IGMP SNOOPING documenting
  which records create state and that source lists do not narrow delivery.
- `tests/sys/net/if_bridge_test.sh` — new `mcast_source_join` helper
  (`IP_ADD_SOURCE_MEMBERSHIP`) and new `mdb_igmpv3_source_join` ATF test:
  a source-specific join (which an IGMPv3 stack reports with INCLUDE-family
  records — precisely the class the old code ignored) must create MDB
  state, the listener port must receive the group, and the idle port must
  stay pruned. The listener jail pins `net.inet.igmp.default_version=3` so
  the record class exercised is deterministic.

## Deliberately out of scope

- True SSM fidelity (per-source forwarding state) — would change the MDB
  key/member model and is explicitly deferred by the proposal.
- MLD/IPv6 — separate protocol plane; planned as patch 8.
- Eager leave processing — the proposal prefers timer-based aging over
  aggressive pruning in shared-port scenarios.

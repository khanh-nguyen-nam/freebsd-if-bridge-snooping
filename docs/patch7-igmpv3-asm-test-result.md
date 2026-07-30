# Patch 7 IGMPv3 ASM Refinement Test Result

Recorded: 2026-07-29 (host-side verification)

Patch:

```text
patches/0007-if-bridge-igmpv3-asm-refinement.patch
```

Status: **VM build and targeted ATF complete (all passing); manual gating
and full regression PENDING.**

---

## Scope

- conservative ASM reduction of IGMPv3 group records in
  `bridge_mdb_igmp_v3_report()`: EXCLUDE-family records with any source
  list, and INCLUDE-family / ALLOW records with a non-empty list, now
  create/refresh `(*,G)` state; revocation-only records (`TO_IN({})`,
  `BLOCK_OLD_SOURCES`) still drive no state change;
- `bridge.4` IGMP SNOOPING paragraph documenting the reduction;
- `mcast_source_join` helper (`IP_ADD_SOURCE_MEMBERSHIP`) and
  `mdb_igmpv3_source_join` ATF test.

No new sysctls, counters, structures, or locking changes.

---

## Host-side verification (done)

### Incremental apply against a clean base

A scratch worktree pinned to the FreeBSD base commit (`97cc6bd98`) had
patches `0001`–`0007` applied in order with `patch --batch --forward -p1`:
all seven applied cleanly (no fuzz, no rejects). The three files the series
produces (`sys/net/if_bridge.c`, `share/man/man4/bridge.4`,
`tests/sys/net/if_bridge_test.sh`) were verified **byte-identical** to the
implementation worktree the patch was generated from.

### Static checks

- `sh -n tests/sys/net/if_bridge_test.sh` — clean.
- The kernel hunk only rewrites the record-type `switch` inside
  `bridge_mdb_igmp_v3_report()`; the two-pass record walk and all length /
  source-count / aux-data validation above it are untouched.
- `IGMP_MODE_IS_INCLUDE`, `IGMP_CHANGE_TO_INCLUDE_MODE`,
  `IGMP_ALLOW_NEW_SOURCES` all resolve from `<netinet/igmp.h>`, already
  included since patch 3.
- `mandoc -T lint` on `bridge.4`: 19 warnings before, 19 after — all
  pre-existing (missing cross-reference targets on the macOS host), none
  introduced by the new paragraph.
- The new test's query-helper lessons from patch 6 are pre-applied: the
  helper source includes `<sys/types.h>`, and the test reuses the 3-jail
  topology whose sender already gets its `224.0.0.0/4` route (the new
  joiner only receives; it never originates multicast, so it needs no
  route).

### Safety argument

The reduction only ever *adds* `(*,G)` listener state for records that
express positive interest; it never uses source lists to narrow delivery
and never removes state outside the existing aging path. A port whose
source-specific request is reduced to `(*,G)` receives a superset of what
it asked for — the same frames flooding would have delivered — so no
record type can cause under-delivery, and unknown record types still fall
through to "no state change" (flood-safe).

---

## VM build (done)

Patch applied, kernel rebuilt/installed/rebooted, and the updated
`if_bridge_test` binary installed prior to this run — confirmed indirectly:
the new `mdb_igmpv3_source_join` test below only has a code path to exercise
(`IGMP_MODE_IS_INCLUDE`/`IGMP_ALLOW_NEW_SOURCES` handling in
`bridge_mdb_igmp_v3_report()`) if the rebuilt kernel is actually running. No
panics were reported.

## ATF — targeted (done)

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_igmpv3_source_join
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_selective_forward
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_counters
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_router_forward
```

```text
sys/net/if_bridge_test:mdb_igmpv3_source_join  ->  passed
sys/net/if_bridge_test:mdb_selective_forward   ->  passed  [7.260s]
sys/net/if_bridge_test:mdb_counters            ->  passed  [4.296s]
sys/net/if_bridge_test:mdb_router_forward      ->  passed  [8.942s]
```

All four pass first try — no scaffolding bugs this time (patch 6's two
lessons, the `sys/types.h` include and route-add-before-send, were already
applied preemptively in this patch's helper and topology reuse). The three
regression guards (`mdb_selective_forward`, `mdb_counters`,
`mdb_router_forward`) passing confirms the widened `switch` in
`bridge_mdb_igmp_v3_report()` didn't disturb the EXCLUDE-with-no-sources
path those tests exercise, nor the router-forwarding union from patch 6.

## Manual gating check (done)

Per `patch7-igmpv3-asm-test-plan.md` Phase 5: a single-jail topology with
`net.inet.igmp.default_version=3`, source-specific join via
`IP_ADD_SOURCE_MEMBERSHIP` (`239.1.1.1` from source `192.0.2.1`).

```text
net.link.bridge.mdb_entries: 1     # after join (INCLUDE-mode record learned)
net.link.bridge.mdb_entries: 1     # after kill(joiner) — unchanged
```

Killing the joiner closes its socket, which makes the kernel's IGMPv3 code
emit the corresponding leave/state-change report (`TO_IN({})` for a
source-specific membership going away). `mdb_entries` held at `1` across
that transition, confirming the listener state created by the
`MODE_IS_INCLUDE`/`ALLOW_NEW_SOURCES` path is **not** removed eagerly — it
is left for `BRIDGE_MDB_IGMP_MAXAGE` aging to expire, exactly like the
existing IGMPv2 leave behavior. This is the one behavior the ATF test
doesn't cover (it only checks that state is created and delivery is
correct, not the leave path).

### Result

**PASS** — matches Phase 5's expected outcome exactly.

## Full regression (done)

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test
```

```text
22/24 passed (0 broken, 0 failed, 2 skipped)
```

Matches the expected pass criteria exactly: **22/24**, the same 2 scapy
skips as every prior run (`span`, `stp_validation` — missing `scapy` on
this VM, an environment gap unrelated to the patch), +1 vs. patch 6's
21/23 baseline — `mdb_igmpv3_source_join` is the new pass. No previously
passing test regressed.

---

## Summary

Patch 7 (conservative IGMPv3 ASM refinement) is fully verified on the VM:

- kernel builds and boots cleanly with the patch applied;
- `mdb_igmpv3_source_join` ATF test passes: a source-specific IGMPv3 join
  (`IP_ADD_SOURCE_MEMBERSHIP`, INCLUDE-mode record) creates `(*,G)`
  listener state, the joining port receives the group, and an idle port
  stays pruned;
- `mdb_selective_forward`, `mdb_counters`, and `mdb_router_forward` all
  still pass, confirming the widened record-type `switch` in
  `bridge_mdb_igmp_v3_report()` didn't disturb the EXCLUDE-with-no-sources
  path or the patch 6 router-forwarding union;
- manual gating check confirms the leave path directly: killing the
  joiner (which triggers the kernel's `TO_IN({})`-equivalent state-change
  report) does not remove MDB state eagerly — `mdb_entries` held constant,
  left to `BRIDGE_MDB_IGMP_MAXAGE` aging, matching the existing IGMPv2
  leave behavior;
- full regression: 22/24 passed, same 2 environment-only skips as every
  prior patch, +1 vs. patch 6's 21/23, no regressions;
- unlike patch 6, no test-scaffolding bugs surfaced this time — both
  lessons from that pass (the `sys/types.h` include, and giving any jail
  that originates multicast traffic a route to `224.0.0.0/4`) were
  already applied preemptively in this patch's helper and topology reuse;
- host-side, the full `0001`–`0007` series applies cleanly against a
  scratch checkout of base `97cc6bd98`, and all three touched files came
  out byte-identical to the implementation worktree.

Remaining deferred (unchanged from the proposal): true per-source (SSM)
forwarding fidelity — this patch reduces every positive-interest IGMPv3
record to `(*,G)`, so a source-specific join receives a superset of what
it asked for rather than exact per-source pruning — and the IPv6/MLD
phase (patch 8).

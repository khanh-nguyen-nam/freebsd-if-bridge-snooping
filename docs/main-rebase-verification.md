# Rebase Onto `main` and Verification

Recorded: 2026-08-08

## Why

The GSoC proposal this series grew out of was not accepted. One of the
mentors (Bruce Simpson, `bms@` — the original author of much of the
`if_bridge`/multicast subsystem this series touches) offered to review
patches outside the program on a best-effort basis, with the concrete
venue clarified as `reviews.freebsd.org` (Phabricator). FreeBSD convention
is that new feature work targets `main` first and gets MFC'd to stable
branches later by a committer — the series had been developed entirely
against a `stable/14` base pinned since May, so it needed rebasing before
submission.

## Rebase process

`main` was cloned fresh at its then-current tip, `86199f1a74ab` (2026-08-07).
Rather than reapplying the raw `.patch` files with `patch(1)` — which
proved too brittle for ~3 months of drift — each of the 8 patches was
first applied cleanly against the *original* pinned base
(`97cc6bd98fc4b3fe1ec9ee3ba9d5c091d1f0dcb3`, where they were built and
already fully VM-verified) and committed as a real git commit. The
resulting 8-commit branch was then rebased with `git rebase --onto
main-tip 97cc6bd98 <branch>`, letting git's 3-way merge resolve drift by
content rather than by brittle context-line matching.

Patches 3, 4, 6, 7, 8 rebased with **zero conflicts**. Patches 1, 2, and 5
needed manual resolution — full detail below. After resolution, the
independent fresh-clone check (`patch --batch --forward -p1` against a
*separate*, newly-cloned copy of `main`, not the working tree the
resolution happened in) applied all 8 cleanly, confirming the result
wasn't an artifact of one specific working tree's state.

## Conflicts and how they were resolved

### 1. Bridge ioctl command number collision (patch 1)

Upstream landed a per-VLAN-filtering feature (`BRDGSIFPVID` through
`BRDGSIFVLANPROTO`, values 31–38) in `sys/net/if_bridgevar.h` sometime
after May. Patch 1's `BRDGGFWDMASK`/`BRDGSFWDMASK` had claimed 31/32 under
the old numbering — a direct collision, not just a textual conflict.
`bridge_control_table[]` in `if_bridge.c` is **positionally indexed** by
this command number (confirmed directly: `BRDGADD=0` maps to the table's
first entry), so this had to be resolved as a real renumbering, not a
merge of two diffs: `BRDGGFWDMASK`/`BRDGSFWDMASK` moved to 39/40, and the
corresponding two `bridge_control_table[]` entries were moved to the end
of the table to match.

### 2. `libifconfig_bridge.c` error-handling convention (patch 1)

Upstream had refactored `ifconfig_bridge_get_bridge_status()`'s error
paths from inline `free(bridge); return (-1);` to a `goto err:` cleanup
label, with `bridge`/`buf` pre-initialized to `NULL` so the label's
unconditional `free()` calls are safe. Patch 1's new `BRDGGFWDMASK`
ioctlwrap call used the old inline-return style; it was rewritten to
`goto err;` to match the now-current convention rather than leave a
stylistically inconsistent outlier a reviewer would flag.

### 3. Coincidental-match function boundaries (patch 1, `if_bridge.c`)

Two of patch 1's new functions (`bridge_ioctl_gflags` from upstream,
`bridge_ioctl_gfwdmask` from this series) both happen to end with the
identical two lines `return (0);\n}\n`. Git's diff matched that trailing
text as shared context between the two sides, which meant a naive
"take both halves" merge would have run `bridge_ioctl_gflags`'s body
straight into `bridge_ioctl_gfwdmask`'s signature with no closing brace
between them. Resolved by manually reconstructing the missing
`return (0);\n}\n\nstatic int\n` boundary so both functions end up
complete and independent, exactly as they'd have appeared had the two
patches never touched adjacent lines.

### 4. Stale whitespace-only hunk (patch 2, `if_bridgevar.h`)

Patch 2's original diff carried an incidental tab-realignment on the
`BRDGGFWDMASK`/`BRDGSFWDMASK` `#define` lines — no functional change,
just whitespace, and referring to lines that had already moved (see #1).
Dropped; the current (already-renumbered) content was kept as-is.

### 5. Redundant `#include` block (patch 5, `if_bridge.c`)

Patch 5 originally added a block of ten `#include`s. Upstream had since
reorganized/alphabetized the file's include block and already carries
nine of the ten. The only genuinely new one was `<sys/counter.h>`
(needed for the `counter_u64_t` machinery patch 5 introduces) — inserted
in its alphabetical position; the other nine were dropped as redundant.

## Patch files

`patches/000N-*.patch` were regenerated from the rebased git commits
(`git format-patch`, one per commit) and replace the previous
`stable/14`-based versions. All 8 re-verified to apply cleanly via
`patch --batch --forward -p1` on a fresh, independent clone of `main`.

## VM verification against `main`

The VM's `freebsd-src` had only ever been set up against `stable/14`
(plain source tree, no git, DNS broken so it can't fetch directly). The
rebased tree was streamed over as a compressed tar via SSH (`rsync` isn't
installed on the VM) into a new location
(`/home/nkhanh/src/freebsd-src-main`), verified intact (113,784 files,
`sh -n` clean, spot-checked patch content), and `/usr/src/freebsd-src`
repointed to it — the original `stable/14` tree was left untouched as a
fallback, not overwritten.

- **Build/boot**: `buildkernel`/`installkernel` succeeded, reboot clean,
  `dmesg` empty for panic/fault/trap throughout.
- **Our own tests**: every one of this series's ATF tests
  (`group_fwd_mask`, `mdb_vnet_topology`, `mdb_unknown_multicast_flood`,
  `mdb_selective_forward`, `mdb_counters`, `mdb_router_forward`,
  `mdb_igmpv3_source_join`, `mdb_link_local_exempt`) passed individually
  within the full regression run.
- **Edge-case suite**: `scripts/snooping-edge-cases.sh`, all 29 checks
  (`RUN_SLOW=1`, including the slow aging/expiry test), zero failures,
  `dmesg` clean.

### 11 unrelated ATF failures — diagnosed, not caused by this series

The full regression against `main` has 36 tests (up from 25 on
`stable/14`) — `main` added `bridge_svi_in_bridge` and ten `vlan_*` tests
for upstream's own new VLAN-filtering feature. All 11 failed. Root cause,
confirmed rather than assumed:

- `/sbin/ifconfig` on the VM was last rebuilt 2026-07-16 (during this
  project's own patch 5 work) — `strings /sbin/ifconfig` shows this
  series's own `group_fwd_mask` keyword present, but `vlanfilter`,
  `untagged`, and `pvid` (upstream's new keywords) are completely absent.
  The installed binary predates the feature it's being asked to drive.
- Attempting a targeted rebuild of just `lib/libifconfig` and
  `sbin/ifconfig` surfaced a chain of unrelated stale system headers in
  `/usr/include` — `net/if_bridgevar.h` (June 3), `netinet/ip_carp.h`
  (March 6), then `netinet/ip_carp_nl.h` (CARP-over-netlink attributes),
  then an undeclared `IFCAP2_IPSEC_OFFLOAD_NAME` pointing to at least a
  fourth. None of these are bridge- or multicast-related; they're
  general drift from `/usr/include` never having been resynced since
  this VM's userland was last built, months of unrelated upstream
  history ago.
- Chasing a fully clean rebuild would mean transitively fixing however
  many headers `main` has touched tree-wide since — in effect, a full
  `buildworld`, which was deliberately avoided (an earlier attempt to go
  straight to `installworld` without `buildworld` failed outright, and
  the `mergemaster -Fp` /etc-reconciliation step it implies would have
  **deleted the VM's `nkhanh` account, removed it from `wheel`, and
  blanked root's password** had any diff been "installed" instead of
  left for later — caught and avoided before anything was applied).

None of the 11 failing tests exercise any code this series touches
(`bridge_svi_in_bridge` doesn't even use a bridge-specific ioctl —
its failure is `SIOCIFCREATE2: Protocol not supported`, unrelated to
VLAN filtering entirely). Kernel-level evidence — the actual code these
patches change — is complete and clean: real `main`-based kernel, built,
booted, and exercised by 8 dedicated ATF tests plus a 29-check
adversarial suite, all passing, zero panics.

## Conclusion

The series is verified against current `main`: applies cleanly, builds,
boots, and passes every test that exercises code it touches. The 11
unrelated failures are a pre-existing userland/toolchain gap on this
specific VM, orthogonal to this series, and not something the series is
responsible for fixing. Ready for the Phabricator submission prep.

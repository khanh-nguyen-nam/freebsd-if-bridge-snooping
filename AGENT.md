# AGENT.md

Repository-local instructions for AI-assisted work in this project.

## Commit Rule

Before making any commit:

1. Summarize the intended changes.
2. Double-check the staged diff and current `git status`.
3. Wait for explicit user confirmation.

Do not commit automatically, even for small documentation fixes.

## Commit Scope

Do not commit changes in the sibling `../freebsd-src` checkout. Keep that tree
as a local implementation worktree.

Package FreeBSD source changes as numbered review artifacts under `patches/`.
Each new patch must be incremental: it should apply after the earlier numbered
patches in order.

When adding a patch artifact:

1. Confirm the sibling `../freebsd-src` diff contains only the intended source
   changes.
2. Generate the next numbered patch under `patches/`.
3. Verify that applying the earlier patches followed by the new patch succeeds
   against the intended FreeBSD base revision.
4. Update `patches/README.md`.
5. Update the implementation tracking section below.

Commit review artifacts and project notes in this repository. For changes
outside `docs/`, `patches/`, and this `AGENT.md`, summarize the file list and
wait for explicit user confirmation before including them in a commit.

## Implementation Tracking

Last updated: 2026-06-01

### Deliverable 1: group_fwd_mask

Status: implemented in the local FreeBSD source tree.

- Added bridge ioctl get/set controls.
- Added `ifconfig bridge0 group_fwd_mask <mask>` support.
- Added bridge status output, `bridge(4)` documentation, and ATF control-path coverage.
- Patch artifact: `patches/0001-if-bridge-group-fwd-mask.patch`.

### Deliverable 2: MDB Foundation

Status: implemented as scaffolding in the local FreeBSD source tree.

- Added internal MDB group and member structures in `sys/net/if_bridge.c`.
- Added MDB helper routines for key creation, lookup, member add/update, member removal, member flush, pruning, and teardown.
- Added MDB member cleanup when a bridge member is removed.
- Added MDB teardown when a bridge is destroyed.
- Patch artifact: `patches/0002-if-bridge-mdb-foundation.patch`.

Deferred:

- IGMP/MLD packet parsing.
- Updating the MDB from observed IGMP/MLD reports and leaves.
- Multicast forwarding decisions based on MDB contents.
- User-visible MDB inspection commands.

### Deliverable 3: MDB Timer And Cleanup

Status: implemented as lifecycle scaffolding in the local FreeBSD source tree.

- Added an MDB aging callout.
- Started the MDB callout when the bridge starts.
- Stopped and drained the MDB callout during bridge stop/destroy.
- Added periodic pruning for expired MDB memberships.

### Deliverable 4: VNET Test Topology

Status: implemented.

- Added an ATF topology scaffold test in `tests/sys/net/if_bridge_test.sh`.
- Added `scripts/mdb-vnet-topology.sh` for manual VM setup.
- The topology creates one bridge with sender, listener, and idle VNET jails.

Deferred:

- Packet-level multicast receive assertions.
- IGMP/MLD-driven listener learning tests.
- Negative forwarding tests for non-listener ports.

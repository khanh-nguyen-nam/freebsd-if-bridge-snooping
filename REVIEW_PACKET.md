# Review Packet

This packet is prepared for review of the FreeBSD `if_bridge(4)` IGMP/MLD snooping proposal work.

## Proposal Alignment

The proposal defines a phased project:

1. add a small `group_fwd_mask` bridge control patch,
2. add MDB infrastructure keyed by `(VLAN, group)`,
3. learn IPv4 listener state from IGMP,
4. prune IPv4 multicast forwarding only on positive listener state,
5. add tests, observability, and documentation,
6. consider IPv6 MLD after the IPv4 MVP is stable.

This review packet contains the first reviewable deliverable: the `group_fwd_mask` starter patch, plus supporting design and validation notes for the later snooping work.

## Included Review Artifact

- `patches/0001-if-bridge-add-group-fwd-mask-control.patch`

The patch was exported from a sibling FreeBSD `src` checkout.

It touches:

- `sys/net/if_bridge.c`
- `sys/net/if_bridgevar.h`
- `sbin/ifconfig/ifbridge.c`
- `lib/libifconfig/libifconfig.h`
- `lib/libifconfig/libifconfig_bridge.c`
- `share/man/man4/bridge.4`
- `tests/sys/net/if_bridge_test.sh`

## What The Patch Does

The patch adds a bridge-scoped `group_fwd_mask` control:

```sh
ifconfig bridge0 group_fwd_mask <mask>
```

The mask is 16 bits wide. Bit `n` controls forwarding for reserved Ethernet destination:

```text
01:80:c2:00:00:0n
```

Default behavior remains conservative: a zero mask preserves the existing reserved-link-local filtering behavior.

## Validation Status

The control-plane path was validated on a patched FreeBSD VM:

```sh
ifconfig bridge0 group_fwd_mask 0x4000
ifconfig bridge0 | grep group_fwd_mask
```

Observed result:

```text
group_fwd_mask 0x4000
```

The full walkthrough is in `docs/group-fwd-mask-validation.md`.

## Suggested Reviewer Path

1. Read `patches/0001-if-bridge-add-group-fwd-mask-control.patch`.
2. Check `docs/design/group-fwd-mask-methodology.md` for implementation rationale.
3. Check `docs/group-fwd-mask-validation.md` for validation notes and debugging history.
4. Check `docs/design/bridge-mdb-overview.md` and `docs/test-plan.md` for how this starter patch fits the larger IGMP/MLD snooping proposal.

## Apply And Test

From a FreeBSD `src` checkout:

```sh
git apply /path/to/patches/0001-if-bridge-add-group-fwd-mask-control.patch
```

Build and install the patched kernel/userland components as appropriate for the test host, then run:

```sh
kldload if_bridge || true
bridge=$(ifconfig bridge create)
ifconfig ${bridge} | grep group_fwd_mask
ifconfig ${bridge} group_fwd_mask 0x4000
ifconfig ${bridge} | grep group_fwd_mask
ifconfig ${bridge} group_fwd_mask 0x8
ifconfig ${bridge} | grep group_fwd_mask
ifconfig ${bridge} destroy
```

Expected readbacks:

```text
group_fwd_mask 0x0000
group_fwd_mask 0x4000
group_fwd_mask 0x0008
```

The patch also adds an ATF case named `group_fwd_mask` under `tests/sys/net/if_bridge_test.sh`.

## Scope Notes

This packet does not claim the full IGMP/MLD snooping implementation is complete. It packages the first intentionally small review step from the proposal and the supporting material needed for reviewers to understand the direction of the remaining MDB, IGMP, pruning, and test work.

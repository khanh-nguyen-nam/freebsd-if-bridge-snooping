# 2026-05-22 Deliverable 1 Review Packet

Prepared the first reviewable deliverable from the proposal: the `group_fwd_mask` starter patch for `if_bridge(4)`.

## Review Artifact

- `patches/0001-if-bridge-add-group-fwd-mask-control.patch`

## Scope

This patch adds a bridge-scoped `group_fwd_mask` control for selected reserved Ethernet link-local multicast destinations in the `01:80:c2:00:00:00` through `01:80:c2:00:00:0f` range.

The default remains `0x0000`, preserving the existing conservative filtering behavior unless forwarding is explicitly enabled.

## Supporting Notes

- `REVIEW_PACKET.md`
- `docs/design/group-fwd-mask-methodology.md`
- `docs/group-fwd-mask-validation.md`
- `docs/design/bridge-mdb-overview.md`
- `docs/test-plan.md`

## Validation Recorded

- patch exported from a sibling FreeBSD `src` checkout,
- whitespace check passed with `git diff --check`,
- reverse-apply check passed against the modified FreeBSD tree,
- helper shell scripts passed syntax checks,
- patched FreeBSD VM accepted `ifconfig bridge0 group_fwd_mask 0x4000` and reported `group_fwd_mask 0x4000` on readback.

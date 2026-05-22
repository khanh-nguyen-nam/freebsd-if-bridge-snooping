# freebsd-if-bridge-snooping

Public working repository for the FreeBSD `if_bridge(4)` IGMP/MLD snooping project.

The project goal is to teach `if_bridge(4)` to learn multicast listener location from IGMP/MLD control traffic and prune multicast forwarding only when positive listener state exists. Unknown, exempt, malformed, or unsupported multicast traffic must continue to use the existing safe flood behavior.

## Current Review Item

Deliverable 1 is ready for review:

- [Review packet](REVIEW_PACKET.md)
- [Patch: `0001-if-bridge-add-group-fwd-mask-control.patch`](patches/0001-if-bridge-add-group-fwd-mask-control.patch)
- [Implementation notes](docs/design/group-fwd-mask-methodology.md)
- [Validation walkthrough](docs/group-fwd-mask-validation.md)

This first patch adds a bridge-scoped `group_fwd_mask` control for selected reserved Ethernet link-local multicast destinations in the `01:80:c2:00:00:00` through `01:80:c2:00:00:0f` range. The default mask is `0x0000`, preserving existing conservative filtering behavior unless forwarding is explicitly enabled.

## Proposal Scope

The initial MVP follows the proposal phases:

1. add a reviewable `group_fwd_mask` bridge control patch,
2. build multicast database (MDB) infrastructure keyed by multicast group and VLAN context,
3. learn IPv4 listener state from IGMP,
4. prune IPv4 multicast forwarding only when positive listener state exists,
5. preserve legacy flooding for unknown, exempt, or unsafe-to-interpret traffic,
6. add tests, observability, and documentation before expanding to IPv6/MLD.

## Repository Layout

- `patches/` exported patch series and review-ready change sets
- `docs/` design notes, test planning, reading notes, and validation writeups
- `scripts/` reproducible environment and VNET test helpers
- `tests/` ATF/Kyua and manual VNET test scaffolding
- `src/` notes about expected upstream FreeBSD touch points
- `dev-notes/` active project notes, tasks, decisions, and debug logs

The full FreeBSD source tree is intentionally not vendored into this repository.

## Suggested Reviewer Path

1. Start with [REVIEW_PACKET.md](REVIEW_PACKET.md).
2. Review the patch in [patches/](patches/).
3. Check the rationale in [docs/design/group-fwd-mask-methodology.md](docs/design/group-fwd-mask-methodology.md).
4. Check validation notes in [docs/group-fwd-mask-validation.md](docs/group-fwd-mask-validation.md).
5. Use [docs/design/bridge-mdb-overview.md](docs/design/bridge-mdb-overview.md) and [docs/test-plan.md](docs/test-plan.md) for the larger IGMP/MLD snooping direction.

## Development Workflow

1. Keep kernel changes in a separate FreeBSD `src` checkout.
2. Export small reviewable patches into `patches/`.
3. Capture design decisions and validation notes in `docs/`.
4. Track active work and debugging notes in `dev-notes/`.
5. Add automated and manual coverage under `tests/`.

## Initial Milestones

- `group_fwd_mask` starter patch
- MDB core data structures and lifetime rules
- IPv4 IGMP listener learning
- IPv4 multicast forwarding-path pruning
- observability counters and `if_bridge(4)` documentation

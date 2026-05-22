# freebsd-if-bridge-snooping

Public working repository for the proposed `if_bridge(4)` IGMP/MLD snooping project on FreeBSD.

The initial scope follows the proposal MVP:

- add a reviewable `group_fwd_mask` bridge control patch,
- build multicast database (MDB) infrastructure keyed by `(VLAN, group)`,
- learn IPv4 listener state from IGMP,
- prune IPv4 multicast forwarding only when positive listener state exists,
- preserve legacy flooding for unknown, exempt, or unsafe-to-interpret traffic.

This repository is organized to keep kernel work, design notes, test procedures, and review artifacts separate and easy to follow.

## Repository layout

- `docs/` design notes, test planning, and progress notes
- `patches/` exported patch series and review-ready change sets
- `scripts/` reproducible environment and VNET test helpers
- `src/` notes about expected upstream touch points in FreeBSD
- `tests/` ATF/Kyua and manual VNET test scaffolding

## Expected workflow

1. Capture design decisions in `docs/design/`.
2. Develop and stage small reviewable changes.
3. Validate behavior with manual VNET topology scripts in `scripts/`.
4. Preserve non-regression coverage in `tests/atf/`.
5. Export reviewable patch series into `patches/`.

## Initial milestones

- `group_fwd_mask` starter patch
- MDB core data structures and lifetime rules
- IPv4 IGMP listener learning
- IPv4 multicast forwarding-path pruning
- observability counters and `if_bridge(4)` documentation

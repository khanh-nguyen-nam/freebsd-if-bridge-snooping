# freebsd-if-bridge-snooping

Working repository for the FreeBSD `if_bridge(4)` IGMP/MLD snooping project.

## Deliverable 1

- Patch: `patches/0001-if-bridge-group-fwd-mask.patch`
- Notes: `docs/group-fwd-mask.md`

This first deliverable adds a bridge-scoped `group_fwd_mask` control for selected reserved Ethernet link-local multicast destinations.

The full IGMP/MLD snooping work is intentionally not included in this patch.

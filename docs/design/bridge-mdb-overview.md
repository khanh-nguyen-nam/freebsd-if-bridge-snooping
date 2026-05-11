# Bridge MDB Overview

This note captures the initial working model for multicast snooping in `if_bridge(4)`.

## MVP goals

- keep pruning subordinate to positive listener state,
- preserve current flooding on unknown multicast,
- preserve current flooding on exempt link-local and control-plane traffic,
- limit the MVP to IPv4 ASM-safe IGMP listener learning,
- structure the design so IPv6 MLD support can reuse the same MDB model later.

## Proposed MDB key

The multicast database should be keyed by:

- VLAN ID
- address family
- multicast group address

For IP multicast this avoids incorrect aliasing between distinct IP groups that share the same mapped Ethernet multicast MAC.

## Proposed MDB value

Each entry should carry enough state for:

- interested-port membership,
- membership expiry,
- safe removal on member detach,
- eventual observability counters and debug dumps.

## Safety invariants

1. Unknown multicast must continue to flood.
2. Non-IP multicast must continue to follow legacy bridge behavior.
3. Exempt control or link-local traffic must not be pruned.
4. Malformed or ambiguous control traffic must not create unsafe prune state.
5. Forwarding lookups should be safe under the bridge's read-side synchronization model.
6. Write-side updates, timer expiry, and member-detach cleanup must not leave stale port references behind.

## Expected implementation phases

1. `group_fwd_mask` starter patch
2. MDB structures and lifetime rules
3. IPv4 IGMP parsing and listener learning
4. IPv4 multicast forwarding-path pruning
5. counters, tests, and man-page updates
6. optional IPv6 MLD extension

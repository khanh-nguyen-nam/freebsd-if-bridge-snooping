# Test Plan

The primary correctness signal is suppression: a bridge port that did not join a multicast group should not receive the multicast stream once snooping has positive listener state.

## Baseline topology

The initial VNET topology should include:

- one sender jail,
- one interested receiver jail,
- one uninterested receiver jail,
- optionally one router or querier jail.

An additional topology should exercise VLAN separation so that membership on one VLAN does not affect forwarding on another VLAN.

## Core assertions

1. With snooping disabled, multicast floods exactly as it does today.
2. With snooping enabled but no MDB entry present, multicast still floods.
3. After a valid join on one port, only the interested receiver gets the stream.
4. After expiry or teardown, forwarding returns to safe fallback behavior.
5. Exempt IPv4 `224.0.0.0/24` traffic is not pruned.
6. Repeated join, leave, add, and detach cycles do not leak stale state.

## Observability targets

- current MDB entry count,
- prune-hit count,
- flood-fallback count,
- parse-reject count,
- listener-expiration count.

## Automation target

Deliver at least one ATF/Kyua VNET smoke test that covers:

- listener-state creation,
- delivery to one interested port,
- zero delivery to one uninterested port,
- safe fallback after teardown or expiry.

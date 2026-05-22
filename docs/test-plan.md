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

## Manual test procedures

These procedures assume the baseline topology described above and use `tcpdump(1)` on the receiver-side interfaces to determine whether multicast was delivered or pruned.

### 1. Baseline flood with snooping disabled

1. Build the baseline VNET topology with one sender jail, one interested receiver jail, and one uninterested receiver jail.
2. Explicitly disable snooping on the bridge under test.
3. Start `tcpdump(1)` on both receiver-side interfaces for one test multicast group outside `224.0.0.0/24`.
4. Send a short multicast stream from the sender without creating any listener state.
5. Confirm that both receiver ports observe the packets.

Expected result: both receivers capture the multicast stream because legacy flooding remains active when snooping is disabled.

### 2. Safe fallback flood on MDB miss

1. Enable snooping on the bridge under test.
2. Verify that no MDB entry exists for the chosen `(VLAN, group)` pair.
3. Start `tcpdump(1)` on both receiver-side interfaces.
4. Send the same multicast stream from the sender without issuing any IGMP join.
5. Inspect the captures and any MDB-related observability counters.

Expected result: both receivers still capture the stream and the bridge falls back to flooding instead of pruning on unknown state.

### 3. Positive listener state prunes the uninterested port

1. Keep snooping enabled and start with an empty MDB entry for the chosen group.
2. Issue an IGMP join from the interested receiver only.
3. Confirm that the bridge learns one listener entry for the expected `(VLAN, group)` pair.
4. Start `tcpdump(1)` on both receiver-side interfaces.
5. Send the multicast stream from the sender.
6. Compare the packet counts on the interested and uninterested receivers.

Expected result: the interested receiver captures the multicast stream, the uninterested receiver captures zero packets, and MDB state shows a single active listener.

### 4. Listener teardown returns to fallback behavior

1. Reuse the topology from the previous procedure after confirming that pruning is active.
2. Remove listener state by issuing a leave, tearing down the receiver, or waiting for the listener to expire.
3. Verify that the MDB entry is deleted or marked inactive.
4. Start fresh `tcpdump(1)` captures on both receiver-side interfaces.
5. Send the multicast stream again from the sender.

Expected result: forwarding returns to safe fallback behavior and both receivers capture the stream after listener state is removed.

### 5. Exempt link-local multicast is never pruned

1. Enable snooping and leave the bridge in a state where a previous test would otherwise prune an uninterested port.
2. Select an IPv4 destination inside `224.0.0.0/24`.
3. Start `tcpdump(1)` on both receiver-side interfaces.
4. Send a short multicast stream to the exempt address.
5. Inspect both captures.

Expected result: both receivers capture the exempt traffic even when snooping is enabled, because link-local control multicast must not be pruned.

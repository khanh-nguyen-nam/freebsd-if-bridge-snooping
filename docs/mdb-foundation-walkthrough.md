# MDB Foundation Implementation Walkthrough

Last updated: 2026-05-30

This document explains the MDB foundation work added for the FreeBSD
`if_bridge(4)` IGMP/MLD snooping project. It is written as if a senior engineer
is walking an intern through the change: what each piece does, why it exists,
how the code flows, and what is intentionally left for later.

## Big Picture

IGMP/MLD snooping needs a place to remember multicast listeners. A bridge should
eventually be able to answer this question:

```text
For multicast group G on VLAN V, which bridge member ports should receive it?
```

That answer lives in an MDB: a multicast database.

The current implementation is deliberately only the foundation. It adds:

- MDB data structures.
- MDB helper routines.
- MDB aging and cleanup scaffolding.
- Cleanup when a bridge member leaves.
- A VNET test topology for future multicast tests.
- A manual script for building the same topology in a FreeBSD VM.
- Tracking status in `AGENT.md`.

It does not yet add:

- IGMP packet parsing.
- MLD packet parsing.
- Learning MDB entries from reports or leaves.
- Forwarding multicast based on MDB state.
- User-visible MDB dump commands.

That separation matters. The first step is to create safe internal state and
lifetime management. Packet parsing and forwarding decisions are much easier to
review after the storage layer is boring and correct.

## Terms You Need First

MDB means multicast database. It maps a multicast group to bridge member ports.

Example:

```text
239.1.1.1 on VLAN 42 -> epair0a, epair1a
ff02::1:ff00:1234 -> epair2a
```

`bridge_softc` is the per-bridge kernel state object. Every bridge interface has
one. If you create `bridge0` and `bridge1`, each gets its own `bridge_softc`.

`bridge_iflist` represents one member port of a bridge. For example, if
`epair0a` is added to `bridge0`, there is a `bridge_iflist` for that membership.

`callout` is the FreeBSD kernel timer mechanism used here. A callout runs a
function later, usually while holding a configured lock.

`CK_LIST` is a concurrency-friendly linked list macro family used throughout
`if_bridge.c`. This patch follows the existing bridge style instead of adding a
new container style.

## File-Level Change Summary

### `freebsd-src/sys/net/if_bridge.c`

This is the main kernel implementation file. The changes here add the MDB data
model, helper functions, timer lifecycle, and member cleanup hook.

### `freebsd-src/tests/sys/net/if_bridge_test.sh`

This adds a reusable VNET topology scaffold and an ATF test that proves the
topology can be created.

### `freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh`

This adds a manual helper script for creating, checking, and destroying the same
basic topology on a FreeBSD VM.

### `freebsd-if-bridge-snooping/AGENT.md`

This adds tracking status so future work can see what is done and what remains
deferred.

## Kernel Change: MDB Prune Period

Added:

```c
#ifndef BRIDGE_MDB_PRUNE_PERIOD
#define BRIDGE_MDB_PRUNE_PERIOD (5 * 60)
#endif
```

Purpose:

The MDB contains memberships that can expire. A host may join a group and then
go away without cleanly sending a leave. The bridge needs a periodic cleanup pass
so stale state does not live forever.

Why five minutes:

This mirrors the existing route table pruning style. It is a conservative
scaffolding value. Later IGMP/MLD logic may adjust membership lifetimes based on
protocol timers, but the cleanup mechanism itself needs to exist first.

How it works:

The value is used when scheduling `sc_mdbcallout`. Every period, the bridge runs
`bridge_mdb_timer()`, which calls `bridge_mdb_prune()`.

## Kernel Change: Locking Comment Update

Changed the bridge locking comment from:

```text
BRIDGE_RT_LOCK, for any change to bridge_rtnodes
```

to:

```text
BRIDGE_RT_LOCK, for any change to bridge_rtnodes or MDB state
```

Purpose:

This tells future readers which lock protects MDB mutations. The MDB is shared
state, just like the bridge forwarding table. It must not be modified from two
paths at once.

Why use `BRIDGE_RT_LOCK`:

The MDB is forwarding-related state. It will eventually be read from packet
paths and updated from snooping paths. The existing route-table lock is already
the non-sleepable lock used for forwarding state, so using it keeps the locking
model simple.

Important rule:

Any function that mutates `sc_mdb`, `sc_mdbcnt`, or `sc_mdbmembercnt` must hold
`BRIDGE_RT_LOCK`.

## Kernel Change: MDB Data Structures

Three new internal structures were added.

### `struct bridge_mdb_key`

Purpose:

This identifies one multicast group entry.

Fields:

```c
sa_family_t bmk_family;
ether_vlanid_t bmk_vlan;
union {
        struct in_addr bmk_ip4;
        struct in6_addr bmk_ip6;
} bmk_addr;
```

How to read it:

- `bmk_family` tells us whether the group is IPv4 multicast (`AF_INET`) or IPv6
  multicast (`AF_INET6`).
- `bmk_vlan` distinguishes the same multicast group on different VLANs.
- `bmk_addr` stores either the IPv4 or IPv6 multicast address.

Why the key includes VLAN:

Bridges can carry VLAN-tagged traffic. The same group address on VLAN 10 and VLAN
20 should be treated as separate listener state. Without VLAN in the key, traffic
could leak between VLANs.

### `struct bridge_mdb_member`

Purpose:

This records that one bridge member interface has listeners for a group.

Fields:

```c
CK_LIST_ENTRY(bridge_mdb_member) bmm_next;
struct bridge_iflist *bmm_bif;
unsigned long bmm_expire;
```

How to read it:

- `bmm_next` links this member into a group's member list.
- `bmm_bif` points to the bridge member port.
- `bmm_expire` is the time when the membership should expire. A value of `0`
  means no expiry.

Why store `bridge_iflist *` instead of `ifnet *`:

The bridge code already represents membership through `bridge_iflist`. That
object is the bridge-specific relationship between the bridge and the interface.
It is the right level of abstraction for MDB state.

### `struct bridge_mdb_entry`

Purpose:

This is one multicast group entry in the database.

Fields:

```c
CK_LIST_ENTRY(bridge_mdb_entry) bmd_next;
struct bridge_mdb_key bmd_key;
CK_LIST_HEAD(, bridge_mdb_member) bmd_members;
```

How to read it:

- `bmd_next` links the group into the bridge-wide MDB list.
- `bmd_key` identifies the group and VLAN.
- `bmd_members` is the list of bridge ports that have listeners.

Mental model:

```text
bridge_softc
  sc_mdb
    group 239.1.1.1 vlan 0
      member epair0a expires at 1000
      member epair1a expires at 1030
    group ff02::1 vlan 0
      member epair2a expires at 0
```

## Kernel Change: New `bridge_softc` Fields

Added fields:

```c
struct callout sc_mdbcallout;
CK_LIST_HEAD(, bridge_mdb_entry) sc_mdb;
uint32_t sc_mdbcnt;
uint32_t sc_mdbmembercnt;
```

Purpose:

These make the MDB part of each bridge instance.

Why per bridge:

Each bridge has independent member ports and independent forwarding behavior.
`bridge0` should not share listener state with `bridge1`.

Field-by-field:

- `sc_mdbcallout`: timer used to periodically remove expired memberships.
- `sc_mdb`: the head of the bridge's multicast database list.
- `sc_mdbcnt`: number of group entries in the MDB.
- `sc_mdbmembercnt`: total number of member records across all groups.

Why keep counters:

They are not used for user output yet, but they are useful for assertions,
future sysctls, future diagnostics, and sanity checks while developing.

## Function: `bridge_mdb_init()`

Purpose:

Initialize the MDB fields for a newly created bridge.

Code behavior:

```c
CK_LIST_INIT(&sc->sc_mdb);
sc->sc_mdbcnt = 0;
sc->sc_mdbmembercnt = 0;
```

How it works:

It sets the MDB list to empty and resets counters. This runs from
`bridge_clone_create()` after the bridge softc is allocated.

Why it exists:

Kernel memory is zeroed on allocation in this path, but relying only on zeroed
memory is fragile. Initializing the list explicitly makes ownership and lifecycle
clear.

Intern note:

If a structure contains a linked-list head, look for an explicit `LIST_INIT` or
`CK_LIST_INIT`. That is usually the point where the data structure becomes safe
to use.

## Function: `bridge_mdb_key_init()`

Purpose:

Create a normalized key from caller-provided address information.

Inputs:

- `key`: output key to fill.
- `family`: `AF_INET` or `AF_INET6`.
- `addr`: pointer to `struct in_addr` or `struct in6_addr`.
- `vlan`: VLAN identifier.

How it works:

1. Clears the key with `memset()`.
2. Stores the address family.
3. Stores the VLAN.
4. Copies the address into the correct union field.
5. Returns `0` for supported families.
6. Returns `EAFNOSUPPORT` for unsupported families.

Why clear the key first:

The key contains a union. Clearing it avoids stale bytes in unused parts of the
union. That makes equality checks more predictable and avoids confusing future
debugging.

Why return `EAFNOSUPPORT`:

The MDB foundation is only for IPv4 and IPv6 multicast. If a future caller tries
to add another address family, failing explicitly is better than storing garbage.

## Function: `bridge_mdb_key_equal()`

Purpose:

Compare two MDB keys.

How it works:

1. Compare address family.
2. Compare VLAN.
3. If both match, compare the correct address field based on family.
4. Return `true` only if all relevant fields match.

Why not just `memcmp()` the whole struct:

The key contains a union, and struct padding can exist. Whole-struct `memcmp()`
can accidentally compare irrelevant bytes. Field-by-field comparison is more
robust and easier to read.

What correctness means:

These should match:

```text
AF_INET, VLAN 0, 239.1.1.1
AF_INET, VLAN 0, 239.1.1.1
```

These should not match:

```text
AF_INET, VLAN 0, 239.1.1.1
AF_INET, VLAN 42, 239.1.1.1
```

These also should not match:

```text
AF_INET,  VLAN 0, 239.1.1.1
AF_INET6, VLAN 0, ff02::1
```

## Function: `bridge_mdb_lookup()`

Purpose:

Find an existing MDB group entry for a key.

How it works:

1. Requires `BRIDGE_RT_LOCK`.
2. Iterates over `sc->sc_mdb`.
3. Uses `bridge_mdb_key_equal()` to compare each entry.
4. Returns the matching `bridge_mdb_entry *`.
5. Returns `NULL` if not found.

Why it requires the lock:

The MDB list can be modified by add, remove, prune, and teardown paths. Walking
the list without the lock risks reading a node while another path removes it.

Complexity:

This is currently a linear scan. That is acceptable for scaffolding. If the MDB
gets large later, this can become a hash table without changing the higher-level
learning logic much.

## Function: `bridge_mdb_member_lookup()`

Purpose:

Find whether a specific bridge member already belongs to a specific group entry.

How it works:

1. Walks `bmd->bmd_members`.
2. Compares each member's `bmm_bif` pointer with the requested `bif`.
3. Returns the matching member or `NULL`.

Why it exists:

When a host sends another membership report, we should refresh the existing
membership rather than adding a duplicate member record for the same port.

Example:

Before:

```text
239.1.1.1 -> epair0a expires at 1000
```

If another report arrives from `epair0a`, the correct result is:

```text
239.1.1.1 -> epair0a expires at 1300
```

Not:

```text
239.1.1.1 -> epair0a expires at 1000
239.1.1.1 -> epair0a expires at 1300
```

## Function: `bridge_mdb_destroy_entry()`

Purpose:

Destroy an entire multicast group entry and all member records under it.

How it works:

1. Requires `BRIDGE_RT_LOCK`.
2. Repeatedly removes the first member from `bmd_members`.
3. Decrements `sc_mdbmembercnt` for each removed member.
4. Frees each member.
5. Removes the group entry from `sc_mdb`.
6. Decrements `sc_mdbcnt`.
7. Frees the group entry.

When it is used:

- During full MDB teardown in `bridge_mdb_fini()`.
- During allocation rollback in `bridge_mdb_add_member()` if a new group was
  inserted but the member allocation failed.

Why it destroys members first:

The group owns the member list. If you free the group first, you lose the list
head and leak the members.

## Function: `bridge_mdb_remove_member()`

Purpose:

Remove one member from one MDB group, and optionally remove the group if it
becomes empty.

How it works:

1. Requires `BRIDGE_RT_LOCK`.
2. Removes the member from the group list.
3. Decrements `sc_mdbmembercnt`.
4. Frees the member.
5. If the group still has members, returns `false`.
6. If the group is empty, removes and frees the group entry, decrements
   `sc_mdbcnt`, and returns `true`.

Why the return value matters:

Some callers are iterating the group while removing a member. If the group entry
itself gets freed, the caller must stop touching that group immediately.
Returning `true` tells the caller: "the group is gone now."

Intern note:

This is a common C kernel pattern. When a helper may free the object you are
currently iterating, make the helper's contract explicit.

## Function: `bridge_mdb_add_member()`

Purpose:

Add or refresh membership for a multicast group and bridge member port.

This is the main write helper future IGMP/MLD parsing code will call after it
learns that a listener exists on a port.

Inputs:

- `sc`: bridge instance.
- `family`: `AF_INET` or `AF_INET6`.
- `addr`: group address.
- `vlan`: VLAN associated with the report.
- `bif`: bridge member that heard the report.
- `lifetime`: number of seconds before the membership expires. `0` means no
  expiration.

How it works:

1. Builds a normalized MDB key with `bridge_mdb_key_init()`.
2. Allocates a possible new group entry before taking the lock.
3. Allocates a possible new member entry before taking the lock.
4. Takes `BRIDGE_RT_LOCK`.
5. Looks for the group.
6. If the group does not exist, inserts the preallocated group.
7. Looks for the member under that group.
8. If the member does not exist, inserts the preallocated member.
9. Sets or refreshes `bmm_expire`.
10. Releases the lock.
11. Frees any preallocated object that was not used.

Why allocate before taking the lock:

The code uses `M_NOWAIT`, so it should not sleep. Still, doing allocation before
taking the lock keeps the locked section smaller and follows a good habit: hold
locks for data structure mutation, not for unrelated setup work.

Why it preallocates both group and member:

The function does not know whether the group or member already exists until it
checks the MDB. Preallocating allows the function to handle both the "create"
and "refresh" cases cleanly.

Why there is rollback logic:

There is a corner case where the group does not exist, so the function inserts a
new group, but the member allocation failed. An empty group should not remain in
the MDB. The code calls `bridge_mdb_destroy_entry()` to roll back the newly
created empty group.

How expiration is calculated:

```c
bmm->bmm_expire = lifetime == 0 ? 0 : time_uptime + lifetime;
```

Meaning:

- `lifetime == 0`: permanent until explicitly removed.
- `lifetime > 0`: expire at current uptime plus the requested lifetime.

Why it is marked `__unused` for now:

No IGMP/MLD parser calls this helper yet. Marking it `__unused` allows this
foundation patch to compile before the learning path exists. Later, once packet
parsing calls it, the marker should be removed.

## Function: `bridge_mdb_flush_member()`

Purpose:

Remove all MDB memberships for a bridge member port.

When it is called:

`bridge_delete_member()` calls it when an interface is removed from the bridge.

Why it exists:

If `epair0a` leaves the bridge, no multicast group should still point to
`epair0a`. Keeping those pointers would be wrong and dangerous because the
membership object may later reference freed bridge-member state.

How it works:

1. Requires `BRIDGE_RT_LOCK`.
2. Walks every MDB group.
3. Walks every member in each group.
4. If `bmm_bif` matches the removed bridge member, removes it.
5. If removing that member empties the group, stops touching that group because
   it has been freed.

Example:

Before removing `epair0a`:

```text
239.1.1.1 -> epair0a, epair1a
239.2.2.2 -> epair0a
```

After:

```text
239.1.1.1 -> epair1a
```

The second group disappears because it became empty.

## Function: `bridge_mdb_prune()`

Purpose:

Remove expired MDB memberships.

How it works:

1. Requires `BRIDGE_RT_LOCK`.
2. Walks every group.
3. Walks every member in each group.
4. If `bmm_expire` is nonzero and `time_uptime >= bmm_expire`, removes it.
5. Removes empty groups as a side effect through `bridge_mdb_remove_member()`.

Why `bmm_expire != 0` is checked:

A zero expiration means permanent membership. This is useful scaffolding for
future static entries or tests.

Why pruning is separate from the timer:

The timer decides when to run. `bridge_mdb_prune()` performs the actual cleanup.
Separating those makes the cleanup logic callable from tests or future code
without pretending a timer fired.

## Function: `bridge_mdb_fini()`

Purpose:

Destroy the entire MDB during bridge teardown.

How it works:

1. Requires `BRIDGE_RT_LOCK`.
2. Removes every group with `bridge_mdb_destroy_entry()`.
3. Asserts that group and member counters are zero.

Why the assertion is useful:

If a future change forgets to decrement a counter or free a member, this assert
can catch the accounting bug during development.

When it is called:

`bridge_clone_destroy()` drains the MDB callout first, then takes
`BRIDGE_RT_LOCK`, then calls `bridge_mdb_fini()`.

Why drain before teardown:

A callout can run asynchronously. Draining it ensures the timer callback is not
still running or about to run while the MDB is being destroyed.

## Function: `bridge_mdb_timer()`

Purpose:

Periodic callout handler for MDB cleanup.

How it works:

1. Runs with `BRIDGE_RT_LOCK` held because `sc_mdbcallout` was initialized with
   `callout_init_mtx(&sc->sc_mdbcallout, &sc->sc_rt_mtx, 0)`.
2. Sets the correct vnet context with `CURVNET_SET(sc->sc_ifp->if_vnet)`.
3. Calls `bridge_mdb_prune()`.
4. If the bridge is still running, reschedules itself.
5. Restores the previous vnet context.

Why vnet context matters:

FreeBSD VNET gives each jail or virtual network stack its own network namespace.
Timer callbacks may not naturally run in the bridge's vnet. Setting the vnet
context avoids operating on the wrong virtual network state.

Why the timer reschedules itself:

FreeBSD callouts are one-shot unless rescheduled. To make periodic cleanup, the
callback must call `callout_reset()` again.

## Lifecycle Integration

### Bridge Creation: `bridge_clone_create()`

New behavior:

```c
bridge_mdb_init(sc);
callout_init_mtx(&sc->sc_mdbcallout, &sc->sc_rt_mtx, 0);
```

Purpose:

Every new bridge starts with an empty MDB and a timer object ready to use.

Important sequence:

1. Allocate `bridge_softc`.
2. Initialize locks.
3. Initialize route table.
4. Initialize MDB.
5. Initialize route-table callout.
6. Initialize MDB callout.

### Bridge Start: `bridge_init()`

New behavior:

```c
callout_reset(&sc->sc_mdbcallout, BRIDGE_MDB_PRUNE_PERIOD * hz,
    bridge_mdb_timer, sc);
```

Purpose:

When the bridge starts running, start periodic MDB cleanup.

Why start here:

The bridge should only run periodic forwarding-state maintenance while it is up.
This matches the existing route-table aging callout pattern.

### Bridge Stop: `bridge_stop()`

New behavior:

```c
callout_stop(&sc->sc_mdbcallout);
```

Purpose:

Stop scheduling MDB pruning when the bridge is not running.

Why stop is not enough for destroy:

`callout_stop()` prevents future runs if possible, but destroy needs stronger
cleanup. That is why `bridge_clone_destroy()` uses `callout_drain()`.

### Bridge Destroy: `bridge_clone_destroy()`

New behavior:

```c
callout_drain(&sc->sc_mdbcallout);

BRIDGE_RT_LOCK(sc);
bridge_mdb_fini(sc);
BRIDGE_RT_UNLOCK(sc);
```

Purpose:

Make sure no MDB timer is running, then free all MDB state.

Why after member deletion:

Bridge destroy first removes all bridge members. That already flushes their MDB
memberships. `bridge_mdb_fini()` is still necessary as a final cleanup guard.
Good teardown code is defensive.

### Member Removal: `bridge_delete_member()`

New behavior:

```c
BRIDGE_RT_LOCK(sc);
bridge_mdb_flush_member(sc, bif);
bridge_rtdelete(sc, ifs, IFBF_FLUSHALL);
BRIDGE_RT_UNLOCK(sc);
```

Purpose:

When a port leaves the bridge, remove both unicast forwarding state and multicast
listener state for that port.

Why it is placed near `bridge_rtdelete()`:

Both operations clean forwarding-related state associated with a member. Keeping
them together makes the lifecycle easy to reason about.

## Existing Context: `group_fwd_mask`

The diff also contains the earlier `group_fwd_mask` implementation. That feature
is separate from MDB snooping, but it lives in the same bridge code.

Relevant function:

```c
bridge_rsvd_link_local_enabled()
```

Purpose:

Check whether a reserved Ethernet link-local multicast destination is explicitly
allowed by `group_fwd_mask`.

How it works:

1. Verifies that the destination is in `01:80:c2:00:00:00` through
   `01:80:c2:00:00:0f`.
2. Converts the last byte into a bit number.
3. Checks whether that bit is set in `sc_group_fwd_mask`.

Example:

```text
destination 01:80:c2:00:00:0e -> bit 14 -> mask 0x4000
```

This is not the MDB. It is a bridge control for a special Ethernet reserved
range. MDB snooping will deal with IP multicast listener groups.

## ATF Change: `bridge_mdb_vnet_topology_create()`

File:

```text
freebsd-src/tests/sys/net/if_bridge_test.sh
```

Purpose:

Create a repeatable virtual topology for future MDB and snooping tests.

Topology:

```text
sender jail      listener jail      idle jail
    |                 |                |
 epair b           epair b          epair b
 epair a           epair a          epair a
    +-----------------+----------------+
                    bridge
```

How it works:

1. Creates three epair interfaces with `vnet_mkepair()`.
2. Creates three VNET jails:
   - `mdbs` for sender.
   - `mdbl` for listener.
   - `mdbi` for idle/non-listener.
3. Moves one side of each epair into a jail.
4. Assigns IPv4 addresses:
   - `192.0.2.1` sender.
   - `192.0.2.2` listener.
   - `192.0.2.3` idle.
5. Creates a bridge.
6. Brings up the bridge and host-side epair interfaces.
7. Adds all host-side epair interfaces as bridge members.

Why this matters:

IGMP/MLD snooping needs tests with at least three roles:

- A sender that emits multicast.
- A listener that should receive multicast.
- A non-listener that should not receive multicast.

This patch does not assert multicast behavior yet. It only builds the shape that
those future tests need.

## ATF Change: `mdb_vnet_topology`

Purpose:

Smoke-test the topology scaffold.

How it works:

1. Calls `vnet_init`.
2. Calls `vnet_init_bridge`.
3. Calls `bridge_mdb_vnet_topology_create`.
4. Verifies the bridge has three members.
5. Verifies basic unicast connectivity from sender to listener.
6. Verifies basic unicast connectivity from sender to idle.

Why test unicast connectivity:

Before testing multicast behavior, prove the virtual topology is wired
correctly. If basic ping does not work, multicast failures would be meaningless.

What later tests should add:

- Start a listener in `mdbl`.
- Send multicast from `mdbs`.
- Prove `mdbl` receives it.
- Prove `mdbi` does not receive it after snooping is active.

## Manual Script: `scripts/mdb-vnet-topology.sh`

Purpose:

Give developers a quick way to create the same topology by hand in a FreeBSD VM.
This is useful before the full ATF test suite exists or when debugging interactively.

Commands:

```sh
scripts/mdb-vnet-topology.sh create
scripts/mdb-vnet-topology.sh check
scripts/mdb-vnet-topology.sh destroy
```

Environment variables:

```sh
MDB_VNET_PREFIX=mdbtest
MDB_VNET_STATE=/tmp/mdbtest.state
```

### `usage()`

Prints valid command syntax and exits with code `2`.

### `require_root()`

Checks that the script is running as root.

Why root is required:

Creating bridges, epairs, and jails requires privilege on FreeBSD.

### `load_modules()`

Loads `if_epair` and `if_bridge` if needed.

Why failures are ignored:

The modules may already be loaded, built into the kernel, or unavailable in a
restricted environment. The actual interface creation commands will fail later
if support is missing.

### `jail_exists()`

Checks whether a jail name exists using `jls`.

Why it exists:

Destroy should be idempotent. If a previous cleanup partly succeeded, the script
should not fail just because one jail is already gone.

### `destroy_jail()`

Destroys one jail-side interface and removes the jail.

Why destroy the interface inside the jail:

Once an interface is moved into a VNET jail, the host cannot manage it the same
way. Destroying it from inside the jail is the clean path.

### `destroy_topology()`

Reads the state file and removes all topology resources.

Resources cleaned:

- Sender jail.
- Listener jail.
- Idle jail.
- Bridge.
- Host-side epair interfaces.
- State file.

Why use a state file:

Interface names are allocated dynamically. The script needs to remember which
bridge and epair names were created so `destroy` can clean the right objects.

### `create_topology()`

Creates the full topology.

Important flow:

1. Calls `destroy_topology` first so repeated `create` commands start cleanly.
2. Loads modules.
3. Creates one bridge and three epairs.
4. Derives epair base names.
5. Creates three VNET jails.
6. Assigns jail-side IP addresses.
7. Brings up bridge and host-side interfaces.
8. Adds host-side interfaces as bridge members.
9. Writes the state file.

Why destroy first:

Manual networking experiments often leave partial state behind. Starting by
cleaning existing state makes the script repeatable.

### `check_topology()`

Verifies the topology is usable.

Checks:

- Shows bridge members.
- Pings listener from sender.
- Pings idle from sender.

This does not test multicast snooping. It only proves the virtual lab is wired.

## Tracking Change: `AGENT.md`

Purpose:

Record implementation status for future agents and contributors.

Why this matters:

This project has staged deliverables. Without a tracker, a future contributor may
mistake scaffolding for complete snooping or redo work that already exists.

The tracking section records:

- `group_fwd_mask`: implemented.
- MDB foundation: implemented as scaffolding.
- MDB timer and cleanup: implemented as lifecycle scaffolding.
- VNET topology: implemented.
- Deferred IGMP/MLD parsing and forwarding behavior.

## Expected Future Flow

Once IGMP/MLD parsing exists, the intended flow is:

```text
packet arrives on bridge member
  -> detect IGMP or MLD control packet
  -> parse multicast group and listener lifetime
  -> call bridge_mdb_add_member()
  -> MDB records group -> member
  -> periodic callout removes stale memberships
  -> forwarding path consults MDB for multicast data packets
```

The current patch implements the middle storage and cleanup pieces. It does not
yet implement packet detection or forwarding lookup.

## Review Notes And Risks

### Linear MDB Lookup

The MDB currently uses a linked list. That is simple and reviewable, but not
ideal for many groups. If scale becomes important, replace `sc_mdb` with a hash
table keyed by `bridge_mdb_key`.

### `bridge_mdb_add_member()` Is Not Called Yet

This is intentional. The function is marked `__unused` until IGMP/MLD learning
is added. Once a real caller exists, remove the marker.

### No Multicast Forwarding Behavior Yet

This patch should not change multicast forwarding behavior. That keeps the blast
radius small and makes regressions easier to isolate.

### Timer Lifetime Is The Most Important Safety Detail

The correct order is:

```text
stop/drain callout
then free MDB
```

Freeing MDB state while a callout can still run would be a use-after-free risk.
This implementation drains the callout before final MDB teardown.

## How To Explain This In One Sentence

This change gives `if_bridge(4)` a safe internal place to store multicast
listener state, cleans that state up over time and when ports leave, and adds the
test topology needed before implementing real IGMP/MLD learning and multicast
forwarding decisions.

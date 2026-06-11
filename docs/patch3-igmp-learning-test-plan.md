# Patch 3 IGMP Learning Test Plan

This plan covers `patches/0003-if-bridge-ipv4-igmp-learning.patch`.

Patch 3 teaches `if_bridge(4)` to observe IPv4 IGMP reports and refresh MDB
listener entries. It does not yet use the MDB to prune multicast forwarding, and
it does not expose a user-visible MDB dump command. Tests should therefore prove
safe behavior that is observable today, and clearly separate that from behavior
that needs the next patches.

## Scope

Covered by this plan:

- patch application and kernel build sanity;
- existing bridge regression coverage;
- MDB topology smoke coverage;
- unknown IPv4 multicast flood fallback;
- manual IGMP report generation and bridge stability checks;
- timer and member-removal lifecycle checks.

Not directly provable yet:

- exact learned MDB contents, because there is no MDB dump interface;
- MDB-based multicast pruning, because forwarding still floods multicast;
- immediate MDB removal from IGMP leave messages, because patch 3 validates
  leaves but does not delete members yet;
- IPv6 MLD behavior.

## Test Environment

Use the Mac workspace as the source of truth:

```sh
cd /Users/macboookpro/khanh-dev/freebsd-if-bridge-snooping
```

Use the existing FreeBSD VM:

```sh
ssh freebsd-test
```

Expected source tree:

```sh
cd /usr/src/freebsd-src
```

Expected staging directory on the VM:

```sh
mkdir -p ~/freebsd-if-bridge-snooping/patches \
    ~/freebsd-if-bridge-snooping/docs \
    ~/freebsd-if-bridge-snooping/scripts
```

Required tools:

```sh
which kyua
which tcpdump
which timeout
```

Optional tools for manual IGMP generation:

```sh
which mcjoin || true
which python3 || true
```

## Phase 1: Prepare And Transfer From Mac

Prepare the patch and test files on the Mac. Do not use VM-side Git for this
workflow.

```sh
cd /Users/macboookpro/khanh-dev/freebsd-if-bridge-snooping
test -f patches/0003-if-bridge-ipv4-igmp-learning.patch
test -f docs/patch3-igmp-learning-test-plan.md
```

Create the VM staging directory and transfer the Mac-side artifacts:

```sh
ssh freebsd-test 'mkdir -p ~/freebsd-if-bridge-snooping/patches \
    ~/freebsd-if-bridge-snooping/docs \
    ~/freebsd-if-bridge-snooping/scripts'

scp patches/0001-if-bridge-group-fwd-mask.patch \
    patches/0002-if-bridge-mdb-foundation.patch \
    patches/0003-if-bridge-ipv4-igmp-learning.patch \
    freebsd-test:~/freebsd-if-bridge-snooping/patches/

scp docs/patch3-igmp-learning-test-plan.md \
    freebsd-test:~/freebsd-if-bridge-snooping/docs/
```

If the local topology helper is present, transfer it as a convenience for the
manual packet-capture phases. It is not required for patch application or Kyua
coverage.

```sh
test ! -f scripts/mdb-vnet-topology.sh || \
    scp scripts/mdb-vnet-topology.sh \
        freebsd-test:~/freebsd-if-bridge-snooping/scripts/
```

Expected result on the VM:

```sh
ssh freebsd-test 'ls -l ~/freebsd-if-bridge-snooping/patches/0003-if-bridge-ipv4-igmp-learning.patch \
    ~/freebsd-if-bridge-snooping/docs/patch3-igmp-learning-test-plan.md
ls -l ~/freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh 2>/dev/null || true'
```

## Phase 2: Apply On The VM With `patch(1)`

Start from the VM source tree with patches 1 and 2 already applied. Use
`patch(1)`, not Git, because the VM source snapshot is the test target, not the
source of truth.

```sh
ssh freebsd-test
cd /usr/src/freebsd-src
```

Confirm whether patch 3 is already present:

```sh
grep -n 'bridge_mdb_input' sys/net/if_bridge.c || true
grep -n 'mdb_unknown_multicast_flood' tests/sys/net/if_bridge_test.sh || true
```

If patch 3 is not already present, run a dry run first:

```sh
patch --batch --forward --dry-run -p1 \
    < /home/nkhanh/freebsd-if-bridge-snooping/patches/0003-if-bridge-ipv4-igmp-learning.patch
```

Apply only after the dry run succeeds:

```sh
patch --batch --forward -p1 \
    < /home/nkhanh/freebsd-if-bridge-snooping/patches/0003-if-bridge-ipv4-igmp-learning.patch
```

Expected result:

- the `patch --dry-run` succeeds before applying;
- `sys/net/if_bridge.c` contains `bridge_mdb_input()`;
- `tests/sys/net/if_bridge_test.sh` contains `mdb_unknown_multicast_flood`.

Quick source checks:

```sh
grep -n 'bridge_mdb_input' sys/net/if_bridge.c
grep -n 'bridge_mdb_learn_igmp' sys/net/if_bridge.c
grep -n 'bridge_mdb_igmp_v3_report' sys/net/if_bridge.c
grep -n 'mdb_unknown_multicast_flood' tests/sys/net/if_bridge_test.sh
```

## Phase 3: Build And Install

Build and install the kernel with the patched bridge code. If the patch changes
`tests/sys/net/if_bridge_test.sh`, also install the updated test suite before
running Kyua from `/usr/tests`.

```sh
cd /usr/src/freebsd-src
make -j$(sysctl -n hw.ncpu) buildkernel
make installkernel
reboot
```

After reboot:

```sh
uname -a
kldstat | grep if_bridge || true
```

If `if_bridge` is built as a module in the test setup, rebuild and install the
module according to the local VM workflow instead of rebuilding the whole kernel.

Expected result:

- system boots cleanly;
- no bridge-related panic during boot;
- patched `if_bridge` is the running implementation.

## Phase 4: Install And Verify Tests

Run these commands as `root`. The VNET bridge tests require root privileges, and
new ATF cases do not appear under `/usr/tests` until the updated tests are
installed.

Confirm the source test has the patch 3 case:

```sh
cd /usr/src/freebsd-src
grep -n 'mdb_unknown_multicast_flood' tests/sys/net/if_bridge_test.sh
sh -n tests/sys/net/if_bridge_test.sh
```

If `/usr/tests` does not list the new case, install the updated tests. The full
world install path is:

```sh
cd /usr/src/freebsd-src
make installworld
```

After installation, verify the installed test suite sees patch 3:

```sh
test -x /usr/tests/sys/net/if_bridge_test
kyua list -k /usr/tests/Kyuafile | grep 'sys/net/if_bridge_test:mdb_unknown_multicast_flood'
```

Interpretation:

- `Requires root privileges` means Kyua was run as a non-root user; rerun as
  `root`.
- `No test cases matched` means the installed `/usr/tests` copy does not include
  patch 3 yet; install the updated tests before treating the patch 3 ATF check
  as covered.
- A full run that reports `17/19 passed` is a useful baseline regression result,
  but it is not patch 3 ATF coverage because patch 3 adds another test case.

## Phase 5: Targeted Kyua Tests

Run the existing and new targeted tests first.

```sh
kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:group_fwd_mask

kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:mdb_vnet_topology

kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:mdb_unknown_multicast_flood
```

Expected result:

- `group_fwd_mask` passes;
- `mdb_vnet_topology` passes;
- `mdb_unknown_multicast_flood` passes.

The important patch 3 assertion is the third test: unknown IPv4 multicast still
reaches the idle bridge port. This protects the safe fallback behavior while MDB
learning is incomplete.

## Phase 6: Full Bridge Regression Run

Run the full bridge test file.

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test
```

Expected result:

- all previously passing bridge tests still pass;
- known environment-dependent skips remain skips;
- no new failure appears in unicast, VLAN, STP, static FDB, or member address
  behavior.

Save the result identifier:

```sh
kyua report
```

Record the results database path printed by Kyua.

## Phase 7: Manual Unknown-Multicast Fallback

This repeats the new ATF behavior manually so packet traces can be inspected.

Create the topology:

```sh
chmod +x /home/nkhanh/freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh
/home/nkhanh/freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh create
. /tmp/mdbtest.state
/home/nkhanh/freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh check
```

Start a capture on the idle jail:

```sh
jexec "${idle_jail}" tcpdump --immediate-mode -n \
    -i "${idle_epair}b" \
    'icmp and dst host 239.1.1.1'
```

In another shell, send unknown multicast from the sender:

```sh
. /tmp/mdbtest.state
jexec "${sender_jail}" route add -net 224.0.0.0/4 \
    -interface "${sender_epair}b" >/dev/null 2>&1 || true
jexec "${sender_jail}" ping -c 1 -t 1 239.1.1.1
```

Expected result:

- idle jail sees the multicast packet;
- no bridge panic or lock warning;
- this confirms patch 3 did not accidentally prune unknown multicast.

Destroy the topology after the capture finishes:

```sh
/home/nkhanh/freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh destroy
```

Adjust interface names if the local script prints different generated epair
names.

## Phase 8: Manual IGMP Report Smoke Test

This checks that IGMP report traffic can pass through the new parser without
destabilizing the bridge. Because there is no MDB dump yet, this is a stability
and packet-observation test, not proof of exact MDB contents.

Create the topology:

```sh
/home/nkhanh/freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh create
. /tmp/mdbtest.state
```

Start capture on the bridge-side listener interface:

```sh
tcpdump --immediate-mode -en -i "${listener_epair}a" igmp
```

Generate a join from the listener jail. Prefer `mcjoin` if installed:

```sh
jexec "${listener_jail}" mcjoin -i "${listener_epair}b" 239.1.1.1
```

If `mcjoin` is not available, use any local tool that causes the jail to join
`239.1.1.1` and emit an IGMP membership report.

Expected result:

- IGMP report is visible in tcpdump;
- bridge remains stable;
- no malformed-packet warning, panic, or lock-order issue appears.

Important limitation:

- this does not prove the MDB entry was created unless observability is added;
- it does exercise `bridge_mdb_input()`, `bridge_mdb_learn_igmp()`, and likely
  `bridge_mdb_add_member()` for valid reports.

Destroy the topology:

```sh
/home/nkhanh/freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh destroy
```

## Phase 9: Leave And Expiry Behavior

Patch 3 validates IGMP leave messages but does not delete MDB members
immediately. The expected removal path is still aging or bridge member removal.

Manual leave check:

```sh
/home/nkhanh/freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh create
. /tmp/mdbtest.state
tcpdump --immediate-mode -en -i "${listener_epair}a" igmp
```

Trigger a join and then a leave from the listener jail using the available local
tool.

Expected result:

- leave packet is visible;
- bridge remains stable;
- no claim is made that the MDB member disappeared immediately.

Expiry check:

- keep the bridge alive past `BRIDGE_MDB_IGMP_MAXAGE`;
- keep it alive until at least one `BRIDGE_MDB_PRUNE_PERIOD` callout has run;
- verify the bridge can still pass ordinary traffic.

Current constants:

```text
BRIDGE_MDB_IGMP_MAXAGE = 260 seconds
BRIDGE_MDB_PRUNE_PERIOD = 300 seconds
```

Because pruning is periodic, a member can remain until the next prune tick after
its expiration time.

Member-removal check:

```sh
ifconfig "${bridge}" deletem "${listener_epair}a"
ifconfig "${bridge}" addm "${listener_epair}a"
```

Expected result:

- member removal does not panic;
- re-adding the member works;
- ordinary unicast and unknown multicast still work afterward.

## Phase 10: Malformed And Non-IGMP Safety

Exercise parser rejection paths without requiring exact MDB visibility.

Cases to try with packet crafting if available:

- non-IGMP IPv4 multicast packet;
- IGMP packet with bad checksum;
- fragmented IGMP packet;
- IGMP packet with TTL other than 1;
- IGMPv3 report with source-specific records;
- IPv6 multicast packet.

Expected result:

- malformed or unsupported traffic is ignored or rejected internally;
- forwarding fallback remains safe;
- no bridge panic, memory leak symptom, or lock warning appears.

## Pass Criteria

Patch 3 is ready for the next implementation step when:

- patch applies cleanly after patches 1 and 2;
- patched kernel or module builds and boots;
- targeted Kyua tests pass;
- full `if_bridge_test` has no new regressions;
- manual unknown multicast still floods;
- manual IGMP report traffic does not destabilize the bridge;
- leave behavior is documented as non-immediate removal;
- all limitations are recorded in the test result notes.

## Result Template

Use this template when recording a run:

```text
Date:
Host:
FreeBSD version:
Source tree:
Patch set applied:

Targeted tests:
- group_fwd_mask:
- mdb_vnet_topology:
- mdb_unknown_multicast_flood:

Full if_bridge_test:

Manual unknown multicast fallback:

Manual IGMP report smoke:

Leave/expiry/member-removal checks:

Notes:
```

## Follow-Up Tests For Later Patches

After MDB-aware forwarding is implemented:

- listener joins `239.1.1.1`;
- idle jail does not join;
- sender sends traffic to `239.1.1.1`;
- listener receives traffic;
- idle jail receives zero matching packets;
- unknown multicast still floods;
- member removal clears learned state.

After MDB observability is implemented:

- verify empty MDB output;
- verify populated MDB output after IGMPv2 join;
- verify conservative IGMPv3 empty-source EXCLUDE learning;
- verify leave and expiry state transitions;
- add Kyua assertions for the visible MDB entries.

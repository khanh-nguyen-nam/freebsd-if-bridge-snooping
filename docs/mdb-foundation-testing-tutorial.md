# MDB Foundation Testing Tutorial

This tutorial explains how to test the current `if_bridge(4)` MDB foundation
patches in a disposable FreeBSD virtual machine. It is written as a practical
checklist: each section says what to run, what the command proves, and what
result to expect.

The patch series under test is:

1. `patches/0001-if-bridge-group-fwd-mask.patch`
2. `patches/0002-if-bridge-mdb-foundation.patch`

The second patch is incremental. Apply it only after the first patch.

## Important Scope Boundary

The current implementation is foundation work. It adds:

- internal MDB group and member structures;
- MDB lookup, insertion, removal, pruning, and teardown helpers;
- a five-minute MDB pruning callout;
- bridge-member cleanup and bridge-destroy cleanup;
- a three-jail VNET topology scaffold;
- the existing `group_fwd_mask` control path from Deliverable 1.

The current implementation does **not** yet add:

- IGMP packet parsing;
- MLD packet parsing;
- calls from packet processing into `bridge_mdb_add_member()`;
- MDB-aware multicast forwarding decisions;
- a user-visible command that prints MDB entries.

This distinction matters when reading the test results. The current test suite
can prove that the control path works, the topology can be created, lifecycle
cleanup runs without obvious errors, and the timer can run safely against an
empty MDB. It cannot yet prove that a multicast listener receives traffic while
an idle port is excluded. That behavior belongs to a later patch.

## Test Environment

Use a disposable FreeBSD 14 VM or a dedicated test host. Do not test a
development kernel for the first time on a machine that stores important work.
A kernel bug can panic or hang the system.

Recommended VM resources:

- 2 or more virtual CPUs;
- 4 GB or more RAM;
- 20 GB or more free disk space;
- a FreeBSD 14 installation with network access;
- a VM snapshot before installing the patched kernel.

Run the commands in this guide as `root` unless the section says otherwise.

## Understand The Test Topology

The ATF topology scaffold creates three independent VNET jails:

```text
sender jail              listener jail              idle jail
192.0.2.1                192.0.2.2                  192.0.2.3
    |                         |                         |
epair(s)b                  epair(l)b                  epair(i)b
epair(s)a                  epair(l)a                  epair(i)a
    +-------------------------+-------------------------+
                              |
                           bridgeN
```

Each jail acts like a separate host with its own network stack. Each `epair(4)`
pair acts like a virtual Ethernet cable:

- the `b` side is moved into a jail;
- the `a` side remains on the host;
- the host-side `a` interfaces become members of one bridge.

The `listener` and `idle` names describe their intended roles in future
multicast tests. At the current scaffold stage, both are ordinary IPv4 peers.

## Existing `freebsd-test` VM Fast Path

Use this section for the existing development VM before following the general
reference workflow below.

The VM already has:

- passwordless host-side SSH and SCP through the `freebsd-test` alias;
- a complete FreeBSD source snapshot at `/usr/src/freebsd-src`;
- Deliverable 1 already applied in that source snapshot;
- patch artifacts staged under
  `/home/nkhanh/freebsd-if-bridge-snooping/patches`;
- Kyua installed as `/usr/bin/kyua`.

The VM does **not** currently have:

- a Git checkout under `/usr/src/freebsd-src`;
- the new MDB foundation patch applied;
- `/usr/tests/sys/net/if_bridge_test` installed;
- reliable DNS through its VMware DNS forwarder.

Current VM policy:

- use SCP from the Mac for all project changes;
- do not depend on VM-side `pkg`, `git clone`, or remote fetching;
- prepare patches, docs, and helper scripts on the Mac;
- copy them into `/home/nkhanh/freebsd-if-bridge-snooping/` with `scp`;
- use the VM console or `su -` only for privileged build, install, and test
  commands.

Use `/usr/src/freebsd-src`, not `/usr/src`, as the source root. `/usr/src` is
only a container directory on this VM.

Do not apply patch `0001` again. A dry run detects that it is already present.
Apply only patch `0002`.

### 1. Transfer Current Files From The Mac

Run these commands in a Mac terminal:

```sh
cd /Users/macboookpro/khanh-dev/freebsd-if-bridge-snooping

ssh freebsd-test 'mkdir -p ~/freebsd-if-bridge-snooping/patches \
    ~/freebsd-if-bridge-snooping/docs \
    ~/freebsd-if-bridge-snooping/scripts'

scp patches/0001-if-bridge-group-fwd-mask.patch \
    patches/0002-if-bridge-mdb-foundation.patch \
    freebsd-test:~/freebsd-if-bridge-snooping/patches/

scp docs/mdb-foundation-testing-tutorial.md \
    freebsd-test:~/freebsd-if-bridge-snooping/docs/

scp scripts/mdb-vnet-topology.sh \
    freebsd-test:~/freebsd-if-bridge-snooping/scripts/
```

No password prompt is expected. The alias logs in as the non-root user
`nkhanh`.

### 2. Switch To The VM Root Console

Use the VM console and log in as `root`. Do not depend on direct root SSH.

Confirm the correct source root:

```sh
cd /usr/src/freebsd-src
pwd
test -f sys/net/if_bridge.c
test -f tests/sys/net/if_bridge_test.sh
echo $?
```

Expected result:

```text
/usr/src/freebsd-src
0
```

### 3. Confirm That Patch `0001` Is Already Present

Run:

```sh
cd /usr/src/freebsd-src
grep -n 'group_fwd_mask' sys/net/if_bridge.c
```

Expected result: several matching lines.

Do not apply `0001-if-bridge-group-fwd-mask.patch` again.

### 4. Back Up The Files Changed By Patch `0002`

The VM source snapshot is not a Git checkout. Create a small backup archive
before changing it:

```sh
cd /usr/src/freebsd-src
tar -czf /root/mdb-foundation-before-0002.tar.gz \
    sys/net/if_bridge.c \
    sys/net/if_bridgevar.h \
    tests/sys/net/if_bridge_test.sh
```

This backup is enough because patch `0002` changes only those three files.

### 5. Dry-Run And Apply Patch `0002`

Run:

```sh
cd /usr/src/freebsd-src

patch --batch --forward --dry-run -p1 \
    < /home/nkhanh/freebsd-if-bridge-snooping/patches/0002-if-bridge-mdb-foundation.patch
```

Expected result:

- all hunks succeed;
- no `File to patch:` prompt appears;
- no failed hunks appear.

Apply the patch:

```sh
patch --batch --forward -p1 \
    < /home/nkhanh/freebsd-if-bridge-snooping/patches/0002-if-bridge-mdb-foundation.patch
```

Confirm the new code markers:

```sh
grep -n 'BRIDGE_MDB_PRUNE_PERIOD\|bridge_mdb_init\|bridge_mdb_timer' \
    sys/net/if_bridge.c
grep -n 'mdb_vnet_topology' tests/sys/net/if_bridge_test.sh
sh -n tests/sys/net/if_bridge_test.sh
```

Expected result:

- the `grep` commands print matching lines;
- the shell syntax check prints nothing and exits successfully.

### 6. Enable Tests

Run as `root`:

```sh
grep -qxF 'WITH_TESTS=yes' /etc/src.conf 2>/dev/null || \
    echo 'WITH_TESTS=yes' >> /etc/src.conf
cat /etc/src.conf
```

Expected result: `/etc/src.conf` includes:

```text
WITH_TESTS=yes
```

### 7. Read Update Notes

Run:

```sh
cd /usr/src/freebsd-src
less UPDATING
```

Read the entries relevant to the installed FreeBSD version before continuing.

### 8. Build World And Kernel

Run as `root`:

```sh
cd /usr/src/freebsd-src
make -j4 buildworld
make -j4 buildkernel
```

The build uses root-owned `/usr/obj`. Adjust `-j4` if the VM has fewer or more
CPUs:

```sh
sysctl -n hw.ncpu
```

### 9. Install Kernel And World

Take a VM snapshot before installation.

Install the kernel:

```sh
cd /usr/src/freebsd-src
make installkernel
shutdown -r now
```

After rebooting, log in as `root` from the VM console:

```sh
etcupdate -p -s /usr/src/freebsd-src
cd /usr/src/freebsd-src
make installworld
etcupdate -B -s /usr/src/freebsd-src
shutdown -r now
```

After the second reboot:

```sh
uname -a
test -x /usr/tests/sys/net/if_bridge_test
echo $?
```

Expected result: `echo $?` prints `0`.

### 10. Run The Tests

Continue at [Step 8: Load The Required Modules](#step-8-load-the-required-modules)
and run the remaining validation steps in order.

### 11. Kernel-Only Smoke Tests When `buildworld` Is Deferred

Use this sequence after a kernel-only build, kernel install, and reboot. This
is the practical next step when `buildworld` is too slow or the VM is not yet
ready for full world validation.

Load the bridge modules:

```sh
kldload if_bridge || true
kldload if_epair || true
```

Confirm the patched source markers are still present:

```sh
cd /usr/src/freebsd-src

grep -n 'BRIDGE_MDB_PRUNE_PERIOD\|bridge_mdb_init\|bridge_mdb_timer' \
    sys/net/if_bridge.c
grep -n 'mdb_vnet_topology' tests/sys/net/if_bridge_test.sh
sh -n tests/sys/net/if_bridge_test.sh
```

Run a repeated bridge member lifecycle smoke test:

```sh
cd /usr/src/freebsd-src

for iteration in $(jot 20 1); do
    bridge=$(ifconfig bridge create) || exit 1
    epair_a=$(ifconfig epair create) || exit 1

    ifconfig "${epair_a}" up || exit 1
    ifconfig "${bridge}" addm "${epair_a}" up || exit 1
    ifconfig "${bridge}" deletem "${epair_a}" || exit 1

    ifconfig "${epair_a}" destroy || exit 1
    ifconfig "${bridge}" destroy || exit 1
done

dmesg | tail -n 100
```

Expected result:

- bridge and epair create/destroy operations complete;
- `dmesg` shows normal link-state and promiscuous-mode messages;
- no panic, trap, fault, bridge error, or `swap_pager` failure appears.

Run a timer lifecycle smoke test:

```sh
bridge=$(ifconfig bridge create)
ifconfig "${bridge}" up
sleep 310
ifconfig "${bridge}" down
ifconfig "${bridge}" destroy

dmesg | tail -n 100
```

Expected result:

- the bridge survives at least one MDB prune interval;
- teardown completes after the timer has had a chance to run;
- no callout, bridge, or memory-safety fault appears in `dmesg`.

Run the optional manual VNET topology script:

```sh
chmod +x /home/nkhanh/freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh

/home/nkhanh/freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh create
/home/nkhanh/freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh check
/home/nkhanh/freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh destroy

dmesg | tail -n 100
```

Expected result:

- the script creates one bridge and three VNET jails;
- the sender jail can ping the listener and idle jails;
- cleanup removes the topology;
- no bridge or jail cleanup fault appears in `dmesg`.

When the VM has enough memory for full validation, continue with the next
section.

### 12. Next Testing After Kernel-Only Smoke Passes

At this point the patched kernel has passed the manual smoke tests. The next
testing target is full userland/test-suite validation. Run these commands as
`root`.

Confirm the VM has enough memory and no leftover test topology:

```sh
sysctl -n hw.ncpu
sysctl -n hw.physmem
swapinfo -h
ifconfig -l
jls
```

Expected result:

- memory is several GB, not hundreds of MB;
- no `bridge` or `epair` interfaces remain unless you intentionally created
  them;
- no `mdbtest_*` jails remain.

Ensure tests stay enabled:

```sh
grep -qxF 'WITH_TESTS=yes' /etc/src.conf 2>/dev/null || \
    echo 'WITH_TESTS=yes' >> /etc/src.conf
cat /etc/src.conf
```

Build world and kernel:

```sh
cd /usr/src/freebsd-src
make -j4 buildworld
make -j4 buildkernel
```

If the VM starts swapping heavily or `swap_pager` messages appear, stop and
retry with lower parallelism:

```sh
make -j2 buildworld
make -j2 buildkernel
```

Take a VM snapshot after successful builds and before installation.

Install the kernel:

```sh
cd /usr/src/freebsd-src
make installkernel
shutdown -r now
```

After reboot, log in as `root` and install world:

```sh
etcupdate -p -s /usr/src/freebsd-src
cd /usr/src/freebsd-src
make installworld
etcupdate -B -s /usr/src/freebsd-src
shutdown -r now
```

After the second reboot, confirm the installed test exists:

```sh
test -x /usr/tests/sys/net/if_bridge_test
echo $?
```

Expected result:

```text
0
```

Run the targeted ATF/Kyua tests:

```sh
kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:group_fwd_mask

kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:mdb_vnet_topology

kyua report --verbose
```

Run the full bridge regression file:

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test
kyua report --verbose
```

Collect final kernel messages:

```sh
dmesg | tail -n 200
```

Expected result:

- targeted ATF tests pass;
- full `if_bridge_test` regression run has no new failures caused by this
  patch;
- no bridge, callout, panic, trap, fault, or `swap_pager` failure appears in
  recent `dmesg`.

### Why The Earlier Patch Command Failed

The failed command used:

```sh
cd /usr/src
patch -p1 < ...
```

The patch contains paths such as:

```text
a/sys/net/if_bridge.c
```

After `-p1` removes the leading `a/`, `patch` searches for:

```text
sys/net/if_bridge.c
```

That file exists under `/usr/src/freebsd-src`, not directly under `/usr/src`.
Running from the wrong directory caused the `File to patch:` prompt. Entering a
patch filename at that prompt does not fix the directory mismatch.

## Step 1: Prepare The FreeBSD VM

Install Git if the VM does not already provide it:

```sh
pkg install git
```

Kyua is part of the FreeBSD base system on supported FreeBSD 14 installations.
Confirm that it is available:

```sh
command -v kyua
```

Expected result:

```text
/usr/bin/kyua
```

Ensure that the test suite is enabled when building the world. Add this line to
`/etc/src.conf`:

```text
WITH_TESTS=yes
```

Why this is needed:

- FreeBSD installs its test suite under `/usr/tests`;
- the new ATF cases are part of that installed test suite;
- without the tests, the patched kernel may build correctly but the new Kyua
  cases will not appear under `/usr/tests/sys/net`.

## Step 2: Fetch The Exact FreeBSD Base Revision

Clone the FreeBSD `stable/14` source tree:

```sh
git clone --branch stable/14 https://git.FreeBSD.org/src.git /usr/src
cd /usr/src
```

Check out the base revision used by this patch series:

```sh
git checkout 97cc6bd98fc4b3fe1ec9ee3ba9d5c091d1f0dcb3
```

Confirm that the worktree is clean before applying patches:

```sh
git status --short
```

Expected result: no output.

Why use the exact base revision:

- patch review artifacts are generated against a known starting point;
- applying them to the same starting point removes unrelated branch drift;
- if a patch fails, the failure is easier to diagnose.

## Step 3: Fetch The Patch Repository

Clone the companion repository:

```sh
git clone \
    https://codeberg.org/khanh-nguyen-nam/freebsd-if-bridge-snooping.git \
    /root/freebsd-if-bridge-snooping
```

Inspect the patch order:

```sh
sed -n '1,120p' /root/freebsd-if-bridge-snooping/patches/README.md
```

Expected result: the index lists patch `0001` first and patch `0002` second.

## Step 4: Check And Apply The Patch Series

First, ask Git to validate each patch without modifying the source tree:

```sh
cd /usr/src
git apply --check \
    /root/freebsd-if-bridge-snooping/patches/0001-if-bridge-group-fwd-mask.patch
git apply \
    /root/freebsd-if-bridge-snooping/patches/0001-if-bridge-group-fwd-mask.patch

git apply --check \
    /root/freebsd-if-bridge-snooping/patches/0002-if-bridge-mdb-foundation.patch
git apply \
    /root/freebsd-if-bridge-snooping/patches/0002-if-bridge-mdb-foundation.patch
```

Then check for whitespace errors:

```sh
git diff --check
```

Expected result: no output.

Check the modified files:

```sh
git status --short
```

Expected modified files:

```text
 M lib/libifconfig/libifconfig.h
 M lib/libifconfig/libifconfig_bridge.c
 M sbin/ifconfig/ifbridge.c
 M share/man/man4/bridge.4
 M sys/net/if_bridge.c
 M sys/net/if_bridgevar.h
 M tests/sys/net/if_bridge_test.sh
```

Run a shell syntax check before starting the expensive build:

```sh
sh -n tests/sys/net/if_bridge_test.sh
```

Expected result: no output.

What this proves:

- the patches apply in the intended order;
- the patch artifacts do not contain whitespace errors;
- the ATF shell script is syntactically valid;
- the source tree contains only the expected changed files.

## Step 5: Read `UPDATING`

Before building and installing a FreeBSD world or kernel, inspect the source
tree's update notes:

```sh
cd /usr/src
less UPDATING
```

Why this is needed:

- FreeBSD records special build and upgrade instructions in this file;
- branch-specific instructions can change over time;
- the commands below are the normal path, but `UPDATING` has priority if it
  requires an extra step.

## Step 6: Build The Patched World And Kernel

Build the world and kernel:

```sh
cd /usr/src
make -j4 buildworld
make -j4 buildkernel
```

Adjust `-j4` for the VM size. A reasonable starting value is the VM's CPU count:

```sh
sysctl -n hw.ncpu
```

Why both builds are needed:

- `sys/net/if_bridge.c` changes require a new kernel;
- `ifconfig(8)` and `libifconfig` changes require a new world;
- the ATF additions must be installed into `/usr/tests`.

Expected result: both `make` commands exit successfully.

## Step 7: Install The Patched Kernel And World

Take a VM snapshot before this step if you have not already done so.

Install the kernel:

```sh
cd /usr/src
make installkernel
shutdown -r now
```

After the VM reboots, log in as `root` and install the world:

```sh
etcupdate -p
cd /usr/src
make installworld
etcupdate -B
shutdown -r now
```

On the existing `freebsd-test` VM, use the actual source path explicitly:

```sh
etcupdate -p -s /usr/src/freebsd-src
cd /usr/src/freebsd-src
make installworld
etcupdate -B -s /usr/src/freebsd-src
shutdown -r now
```

After the second reboot, confirm that the system is running and the test file
was installed:

```sh
uname -a
test -x /usr/tests/sys/net/if_bridge_test
echo $?
```

Expected result: `echo $?` prints `0`.

Why the install order matters:

- `installkernel` places the new kernel and kernel modules on disk;
- the first reboot starts the patched kernel;
- `etcupdate -p` applies required pre-world configuration merges;
- `installworld` installs the updated userland, including `ifconfig(8)` and
  tests;
- `etcupdate -B` merges remaining configuration-file updates;
- the second reboot starts a consistent patched kernel and userland.

On a source tree that is not located at `/usr/src`, pass `-s <source-root>` to
`etcupdate`. The existing `freebsd-test` VM uses `/usr/src/freebsd-src`.

## Step 8: Load The Required Modules

Load bridge and epair support:

```sh
kldload if_bridge || true
kldload if_epair || true
```

Confirm that they are available:

```sh
kldstat | egrep 'if_bridge|if_epair'
```

Why this is needed:

- `if_bridge(4)` provides the software bridge;
- `epair(4)` provides the virtual Ethernet cable pairs;
- the ATF helpers may load modules automatically, but loading them explicitly
  makes manual testing predictable.

## Step 9: Test `group_fwd_mask` Manually

Create a temporary bridge:

```sh
bridge=$(ifconfig bridge create)
echo "${bridge}"
```

Expected result: a bridge name such as `bridge0`.

Inspect the default mask:

```sh
ifconfig "${bridge}" | grep group_fwd_mask
```

Expected result:

```text
group_fwd_mask 0x0000
```

Set one bit and inspect the value:

```sh
ifconfig "${bridge}" group_fwd_mask 0x4000
ifconfig "${bridge}" | grep group_fwd_mask
```

Expected result:

```text
group_fwd_mask 0x4000
```

Set a different bit:

```sh
ifconfig "${bridge}" group_fwd_mask 0x8
ifconfig "${bridge}" | grep group_fwd_mask
```

Expected result:

```text
group_fwd_mask 0x0008
```

Try an invalid value that does not fit in the supported 16-bit mask:

```sh
if ifconfig "${bridge}" group_fwd_mask 0x10000; then
    echo "ERROR: invalid mask was accepted"
else
    echo "PASS: invalid mask was rejected"
fi
```

Expected result:

```text
PASS: invalid mask was rejected
```

Destroy the temporary bridge:

```sh
ifconfig "${bridge}" destroy
```

What this proves:

- the new ioctl control path reaches the kernel;
- `ifconfig(8)` can set and print the value;
- the default value is zero;
- valid values persist;
- an out-of-range value is rejected.

## Step 10: Confirm That Kyua Sees The New ATF Cases

List the bridge tests:

```sh
kyua list -k /usr/tests/Kyuafile | grep 'sys/net/if_bridge_test'
```

Confirm that these names appear in the output:

```text
sys/net/if_bridge_test:group_fwd_mask
sys/net/if_bridge_test:mdb_vnet_topology
```

Why this is needed:

- it proves that the patched test program was installed;
- it catches mistakes where the new kernel was installed but the new world or
  test suite was not installed.

## Step 11: Run The Targeted ATF Cases

Run the `group_fwd_mask` automated test:

```sh
kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:group_fwd_mask
```

Expected result: the test passes.

Run the MDB VNET topology scaffold test:

```sh
kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:mdb_vnet_topology
```

Expected result: the test passes.

Print the latest detailed Kyua report:

```sh
kyua report --verbose
```

What `group_fwd_mask` checks:

1. A bridge starts with `group_fwd_mask 0x0000`.
2. Setting `0x4000` changes the displayed value to `0x4000`.
3. Setting `0x8` changes the displayed value to `0x0008`.
4. Setting `0x10000` fails.

What `mdb_vnet_topology` checks:

1. Three `epair(4)` interfaces are created.
2. Three VNET jails are created: sender, listener, and idle.
3. Each jail gets a separate IPv4 address.
4. The host-side epair interfaces are added to one bridge.
5. The bridge reports exactly three member interfaces.
6. The sender jail can ping the listener jail.
7. The sender jail can ping the idle jail.
8. ATF cleanup removes the temporary topology.

The topology test proves that the test lab is valid. It does not yet prove
listener learning or selective multicast forwarding.

## Step 12: Run The Existing Bridge Regression Tests

Run the full `if_bridge` test program:

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test
```

Print the detailed report:

```sh
kyua report --verbose
```

Expected result: all applicable `if_bridge` tests pass.

Why this is needed:

- the new bridge fields and lifecycle hooks touch shared bridge code;
- a targeted test can pass while an older bridge workflow regresses;
- the existing bridge tests provide a wider safety check.

## Step 13: Smoke-Test Member Add And Remove Cleanup

Run repeated bridge-member add and remove operations:

```sh
for iteration in $(jot 20 1); do
    bridge=$(ifconfig bridge create) || exit 1
    epair_a=$(ifconfig epair create) || exit 1

    ifconfig "${epair_a}" up || exit 1
    ifconfig "${bridge}" addm "${epair_a}" up || exit 1
    ifconfig "${bridge}" deletem "${epair_a}" || exit 1

    ifconfig "${epair_a}" destroy || exit 1
    ifconfig "${bridge}" destroy || exit 1
done
```

Inspect recent kernel messages:

```sh
dmesg | tail -n 100
```

Expected result:

- the loop exits successfully;
- the system does not panic or hang;
- recent kernel messages do not show bridge-related faults.

What this exercises:

- bridge creation;
- bridge-member insertion;
- `bridge_delete_member()`;
- the new call to `bridge_mdb_flush_member()`;
- bridge teardown.

Current limitation:

- no IGMP/MLD parser populates the MDB yet;
- `bridge_mdb_flush_member()` traverses an empty MDB during this smoke test;
- the test confirms lifecycle integration, not removal of a learned listener.

## Step 14: Smoke-Test Timer Startup And Teardown

The MDB prune period is currently five minutes:

```c
#define BRIDGE_MDB_PRUNE_PERIOD (5 * 60)
```

Create and start a bridge, wait long enough for one timer period, then destroy
the bridge:

```sh
bridge=$(ifconfig bridge create)
ifconfig "${bridge}" up
sleep 310
ifconfig "${bridge}" down
ifconfig "${bridge}" destroy
```

Inspect recent kernel messages:

```sh
dmesg | tail -n 100
```

Expected result:

- the bridge starts and destroys successfully;
- the system does not panic or hang;
- recent kernel messages do not show bridge-related faults.

What this exercises:

- `bridge_init()` scheduling the MDB callout;
- `bridge_mdb_timer()` running against an empty MDB;
- `bridge_stop()` stopping the callout;
- bridge destruction draining the callout before freeing MDB state.

Current limitation:

- the code does not print a log message when the timer fires;
- this is a safety smoke test, not a direct assertion that an expired member was
  removed;
- pruning populated MDB entries becomes testable after packet learning or a
  test-only insertion hook exists.

## Step 15: Repeat Bridge Start And Destroy

Run a shorter lifecycle stress loop:

```sh
for iteration in $(jot 50 1); do
    bridge=$(ifconfig bridge create) || exit 1
    ifconfig "${bridge}" up || exit 1
    sleep 1
    ifconfig "${bridge}" down || exit 1
    ifconfig "${bridge}" destroy || exit 1
done
```

Inspect recent kernel messages:

```sh
dmesg | tail -n 200
```

Expected result:

- all iterations complete;
- there are no bridge-related kernel faults.

Why this is useful:

- callout lifecycle bugs often appear during repeated start/stop or destroy
  sequences;
- the loop repeatedly exercises callout initialization, scheduling, stopping,
  draining, and MDB finalization.

## Step 16: Use The Optional Manual Topology Script

The development workspace contains a local helper script:

```text
scripts/mdb-vnet-topology.sh
```

The script is intentionally local-only and is not part of the committed review
artifact. If you have a copy, transfer it to the FreeBSD VM:

```sh
scp scripts/mdb-vnet-topology.sh root@<vm-address>:/root/
```

On the VM, make it executable and create the topology:

```sh
chmod +x /root/mdb-vnet-topology.sh
/root/mdb-vnet-topology.sh create
```

Inspect bridge membership and basic connectivity:

```sh
/root/mdb-vnet-topology.sh check
```

Destroy the topology:

```sh
/root/mdb-vnet-topology.sh destroy
```

Why this script exists:

- ATF creates and removes the topology quickly;
- manual setup leaves the topology running while you inspect interfaces, jails,
  packet captures, or future MDB behavior;
- the script is a development convenience, not part of the patch series.

Useful inspection commands while the topology exists:

```sh
jls
ifconfig -a
jexec mdbtest_sender ifconfig
jexec mdbtest_listener ifconfig
jexec mdbtest_idle ifconfig
```

## Step 17: Collect Failure Information

If a test fails, collect these outputs before rebooting:

```sh
uname -a
git -C /usr/src status --short
kyua report --verbose
dmesg | tail -n 300
kldstat
jls
ifconfig -a
```

For a failed targeted test, rerun only that case:

```sh
kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:mdb_vnet_topology
kyua report --verbose
```

What to look for:

- a missing `/usr/tests/sys/net/if_bridge_test` file means the test suite was
  not installed;
- a missing test case name usually means the patched world was not installed;
- a module-load failure means `if_bridge(4)` or `epair(4)` support is missing;
- leftover jails or interfaces after ATF indicate a cleanup bug;
- a kernel panic, use-after-free report, or hang during bridge destroy suggests
  a callout or MDB teardown bug.

## Step 18: Record The Result

Record at least:

- FreeBSD version from `uname -a`;
- FreeBSD source base revision;
- patch artifact names and order;
- whether `git diff --check` passed;
- whether `sh -n tests/sys/net/if_bridge_test.sh` passed;
- whether the patched world and kernel built successfully;
- whether `group_fwd_mask` manual checks passed;
- whether both targeted ATF cases passed;
- whether the full `sys/net/if_bridge_test` run passed;
- whether the member cleanup loop passed;
- whether the timer smoke test passed;
- any relevant `dmesg` output.

Use precise wording for the final conclusion:

```text
The MDB foundation, callout lifecycle scaffolding, group_fwd_mask control path,
and three-jail VNET topology scaffold passed the current tests. IGMP/MLD-driven
listener learning, populated-entry pruning, and MDB-aware multicast forwarding
remain deferred and were not validated by this test run.
```

## Step 19: Next Steps After Passing Validation

Use this section after the current MDB foundation patch has passed the installed
Kyua tests.

Current passing result:

```text
group_fwd_mask targeted test: passed
mdb_vnet_topology targeted test: passed
full if_bridge_test run: 17/19 passed, 2 environment skips, 0 failures
```

The two skipped tests are environment skips:

```text
sys/net/if_bridge_test:span
sys/net/if_bridge_test:stp_validation
```

Reason:

```text
Required program 'scapy' not found in PATH
```

These skips are not failures in the MDB foundation patch.

### Preserve The Result

Keep the result record:

```text
docs/result.md
```

The VM copy should also exist at:

```text
/home/nkhanh/freebsd-if-bridge-snooping/docs/result.md
```

Use SCP for any future VM updates:

```sh
cd /Users/macboookpro/khanh-dev/freebsd-if-bridge-snooping
scp docs/result.md \
    freebsd-test:~/freebsd-if-bridge-snooping/docs/
scp docs/mdb-foundation-testing-tutorial.md \
    freebsd-test:~/freebsd-if-bridge-snooping/docs/
```

Do not depend on VM-side `pkg`, `git clone`, or remote fetching for this
project. The current VM workflow is SCP-only for project files.

### Generate A Proper Kyua Report If Needed

If this command fails:

```sh
kyua report --verbose
```

use the explicit result file:

```sh
kyua report \
    -r /root/.kyua/store/results.usr_tests.20260603-211227-963858.db \
    --verbose
```

To save the report:

```sh
kyua report \
    -r /root/.kyua/store/results.usr_tests.20260603-211227-963858.db \
    --verbose \
    --output=/root/if_bridge_test-report.txt
```

If the report is generated as `root`, copy it into `nkhanh`'s home before using
SCP from the Mac:

```sh
cp /root/if_bridge_test-report.txt /home/nkhanh/
chown nkhanh:nkhanh /home/nkhanh/if_bridge_test-report.txt
```

Then copy it from the Mac:

```sh
scp freebsd-test:~/if_bridge_test-report.txt .
```

### Commit Review Checkpoint

Before committing anything, stop and list the intended files for review.

Allowed commit candidates:

```text
docs/mdb-foundation-testing-tutorial.md
docs/result.md
patches/0002-if-bridge-mdb-foundation.patch
patches/README.md
```

Do not commit:

```text
AGENT.md
scripts/mdb-vnet-topology.sh
```

`AGENT.md` is local-only. The manual topology script also remains local unless
the project rule changes.

### Next Implementation Patch: IGMP Learning

The next source patch should teach the bridge to observe IGMP reports and
update the MDB.

High-level tasks:

```text
1. Locate the receive path where bridge member traffic is inspected.
2. Detect IPv4 multicast control traffic.
3. Parse IGMP membership reports and leaves.
4. Convert each report into an MDB key.
5. Call bridge_mdb_add_member() for listener reports.
6. Shorten or remove membership state for leave messages when appropriate.
7. Keep MDB mutations under the existing bridge route/MDB lock.
```

Likely source files:

```text
sys/net/if_bridge.c
tests/sys/net/if_bridge_test.sh
```

Potential helper names:

```text
bridge_mdb_input()
bridge_mdb_learn_igmp()
bridge_mdb_leave_igmp()
```

The exact names can change if the surrounding FreeBSD style suggests a better
local pattern.

### Add IGMP Learning Tests

Extend the topology so the listener jail sends an IGMP join.

Target shape:

```text
sender jail    -> multicast traffic source
listener jail  -> joins multicast group
idle jail      -> does not join
bridge         -> learns listener membership
```

If there is still no user-visible MDB dump, do not claim learned-state behavior
that cannot be observed. Either add observability first, or keep the test to
safe lifecycle/connectivity behavior.

### Next Implementation Patch: MDB-Aware Forwarding

After learning works, update multicast forwarding.

Desired forwarding behavior:

```text
Known multicast group:
    forward only to learned listener ports, plus required router/control ports
    once router-port tracking exists.

Unknown multicast group:
    preserve current flooding behavior unless the project explicitly chooses a
    stricter policy.
```

Important checks:

- do not suppress required link-local control traffic;
- preserve `group_fwd_mask` behavior;
- keep unicast, broadcast, STP, and VLAN behavior unchanged;
- rely on `bridge_mdb_flush_member()` when a bridge member is removed.

### Add Forwarding Tests

Once forwarding exists, add packet-level VNET tests:

```text
1. listener joins group;
2. idle host does not join;
3. sender transmits multicast packet;
4. listener receives packet;
5. idle host does not receive packet;
6. member removal cleans learned state;
7. bridge destroy drains MDB and callout state.
```

If packet crafting needs `scapy`, document the skip condition like the existing
bridge tests do.

### Add MLD Support

After IGMP works, repeat the same approach for IPv6 MLD:

```text
1. Detect IPv6 multicast listener reports.
2. Parse MLD messages.
3. Build AF_INET6 MDB keys.
4. Add or refresh listener membership.
5. Handle leave/done messages.
6. Extend VNET tests with IPv6 addresses and multicast groups.
```

Keep IGMP and MLD parsing separate enough that both paths remain readable.

### Add MDB Observability

Reviewers will eventually need to inspect learned bridge multicast state.

Possible user-facing shape:

```text
ifconfig bridge0 mdb
```

Expected work:

```text
1. Add kernel ioctl data structures.
2. Add libifconfig wrappers if needed.
3. Add ifconfig display support.
4. Add man page documentation.
5. Add ATF coverage for empty and populated MDB output.
```

This should be a separate patch if it grows beyond a small test helper.

### Keep The Patch Series Incremental

Recommended future patch order:

```text
0001-if-bridge-group-fwd-mask.patch
0002-if-bridge-mdb-foundation.patch
0003-if-bridge-igmp-learning.patch
0004-if-bridge-mdb-forwarding.patch
0005-if-bridge-mld-learning.patch
0006-if-bridge-mdb-observability.patch
```

Each patch should apply after the previous one and should be independently
testable.

### Minimum Test Gate For Future Patches

For each future patch, run at least:

```sh
cd /usr/src/freebsd-src
sh -n tests/sys/net/if_bridge_test.sh
make -j4 buildkernel
make installkernel
shutdown -r now
```

After reboot:

```sh
kldload if_bridge || true
kldload if_epair || true

kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:group_fwd_mask
kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:mdb_vnet_topology
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test

dmesg | tail -n 200
```

For userland, command, library, man page, or installed-test changes, do full
world validation:

```sh
cd /usr/src/freebsd-src
make -j4 buildworld
make -j4 buildkernel
make installkernel
shutdown -r now
etcupdate -p -s /usr/src/freebsd-src
make installworld
etcupdate -B -s /usr/src/freebsd-src
shutdown -r now
```

### Definition Of Done For The Next Patch

The next patch is done when:

```text
source patch applies cleanly from /usr/src/freebsd-src
kernel builds successfully
installed tests pass as root
full if_bridge_test has no new failures
result is saved under docs/
patch index is updated
AGENT.md remains local-only and unstaged
```

## Quick Command Summary

After the patched world and kernel are installed, the core validation commands
are:

```sh
kldload if_bridge || true
kldload if_epair || true

kyua list -k /usr/tests/Kyuafile | grep 'sys/net/if_bridge_test'

kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:group_fwd_mask
kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:mdb_vnet_topology
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test

kyua report --verbose
```

## References

- FreeBSD `tests(7)`:
  <https://man.freebsd.org/cgi/man.cgi?query=tests&sektion=7>
- FreeBSD `kyua-test(1)`:
  <https://man.freebsd.org/cgi/man.cgi?query=kyua-test&sektion=1>
- FreeBSD Handbook: Updating FreeBSD From Source:
  <https://docs.freebsd.org/en/books/handbook/cutting-edge/#makeworld>
- MDB foundation implementation walkthrough:
  `docs/mdb-foundation-walkthrough.md`
- Patch index:
  `patches/README.md`

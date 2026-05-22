# Manual VNET Validation

This document describes a repeatable manual test workflow for the proposed
`if_bridge(4)` IGMP snooping work. The goal is to prove that the bridge:

- floods multicast when snooping is disabled,
- floods multicast on unknown listener state,
- prunes uninterested ports when positive listener state exists,
- returns to safe fallback behavior after listener teardown, and
- never prunes exempt IPv4 `224.0.0.0/24` traffic.

Use this guide together with [../../docs/test-plan.md](../../docs/test-plan.md).

## Scope

This procedure validates forwarding behavior on a patched FreeBSD kernel. It
does not depend on ATF/Kyua automation and is intended for early bring-up and
review evidence.

## Prerequisites

- a FreeBSD host with VNET jail support enabled,
- root access,
- a kernel under test that includes the bridge snooping patch,
- `if_bridge(4)` and `epair(4)` available,
- `jail(8)`, `jexec(8)`, `ifconfig(8)`, `tcpdump(1)`, and `mtest(8)` installed,
- a UDP sender such as `nc(1)`.

Optional but recommended:

- a separate terminal for each packet capture,
- a shell session with [../../scripts/freebsd-env.sh](../../scripts/freebsd-env.sh) sourced,
- an implementation-specific command to inspect bridge snooping state, MDB
  contents, and observability counters.

## Prerequisite setup

This section assumes your FreeBSD VM is already installed, boots cleanly, and
has basic network connectivity. The host and guest roles are:

- macOS host: keep your original working trees and SSH into the guest
- FreeBSD VM: install packages, build the kernel under test, and run the VNET
  bridge validation

The examples below assume a host-side workspace with sibling checkouts:

- proposal repo: `~/src/freebsd-if-bridge-snooping`
- FreeBSD source tree: `~/src/freebsd-src`

The `freebsd-src` tree under `khanh-dev` is a source checkout. It is not the
test host. All bridge and VNET commands in the rest of this document are meant
to be run inside the FreeBSD VM.

### 1. Verify the running FreeBSD VM

From the VM console, confirm that the guest has:

- an active interface such as `em0`,
- a default route,
- working connectivity by IP.

Useful checks inside the VM:

```sh
uname -a
ifconfig
netstat -rn
ping -c 3 1.1.1.1
```

If `ping 1.1.1.1` fails, fix the VM network before continuing.

### 2. Fix DNS if needed

VMware NAT DNS may not work correctly out of the box. If raw IP connectivity
works but DNS lookups fail, inspect the resolver:

```sh
cat /etc/resolv.conf
ping -c 3 freebsd.org
```

If name resolution fails, replace `/etc/resolv.conf` temporarily:

```sh
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
ping -c 3 freebsd.org
```

This is enough to continue setup. If you want a more permanent DHCP or
`resolvconf` fix, record it separately for your VM image.

### 3. Set up SSH access into the VM

The simplest workflow is to keep the VM running in Fusion and do the rest of
the setup over SSH from the macOS host.

Inside the VM, make sure `sshd` is enabled and running:

```sh
service sshd status
sysrc sshd_enable=YES
service sshd onestart
```

Find the VM IP from `ifconfig`, then connect from the macOS host:

```sh
ssh YOURUSER@VM_IP
```

The VM must remain powered on for SSH to work, but the VMware window does not
need to stay active or in the foreground.

### 4. Create a normal user and install an SSH key

If the VM does not already have a normal login account, create one from the VM
console:

```sh
adduser
```

Recommended choices:

- create a user such as `nkhanh`,
- add that user to `wheel`,
- set a known password.

On the macOS host, create a key if you do not already have one:

```sh
ssh-keygen -t ed25519 -C "macbookpro"
cat ~/.ssh/id_ed25519.pub
```

Inside the VM as that user, install the key:

```sh
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cat > ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Paste the one-line public key after `cat > ~/.ssh/authorized_keys`, press
`Enter`, then press `Ctrl-D`.

From the macOS host, verify the login:

```sh
ssh YOURUSER@VM_IP
```

If you need root after login:

```sh
su -
```

### 5. Install required tools inside the VM

Once DNS and SSH are working, install the packages you need inside the FreeBSD
VM:

```sh
pkg
pkg update
pkg install -y git-lite tcpdump tmux rsync
pkg search mtest
```

If `mtest` exists in the package repository:

```sh
pkg install -y mtest
```

Then verify the required commands:

```sh
which git tcpdump mtest nc jail jexec ifconfig
```

Expected common paths include:

- `/usr/sbin/jail`
- `/usr/sbin/jexec`
- `/sbin/ifconfig`
- `/usr/sbin/tcpdump`
- `/usr/sbin/mtest`
- `/usr/bin/nc`

### 6. Create a guest-side workspace

Inside the VM, keep a dedicated source workspace:

```sh
mkdir -p ~/src
cd ~/src
```

You can either clone the repositories directly in the VM or copy them from the
macOS host with `rsync`.

Direct clone example:

```sh
git clone <freebsd-src-remote> freebsd-src
git clone <proposal-repo-remote> freebsd-if-bridge-snooping
```

Copy from the host example:

```sh
rsync -av ~/src/freebsd-src/ YOURUSER@VM_IP:~/src/freebsd-src/
rsync -av ~/src/freebsd-if-bridge-snooping/ YOURUSER@VM_IP:~/src/freebsd-if-bridge-snooping/
```

### 7. Patch and build the kernel under test inside the VM

All kernel builds for this workflow should happen inside the FreeBSD VM, not on
the macOS host.

Inside the VM:

```sh
cd ~/src/freebsd-src
git status
make -j$(sysctl -n hw.ncpu) buildkernel
make installkernel
reboot
```

If you use a custom kernel configuration, include `KERNCONF`:

```sh
cd ~/src/freebsd-src
make -j$(sysctl -n hw.ncpu) buildkernel KERNCONF=YOURKERNEL
make installkernel KERNCONF=YOURKERNEL
reboot
```

For long-running builds, `tmux` is recommended:

```sh
tmux new -s build
```

After reboot, verify that the VM is running the kernel you intended to test.

### 8. Verify root access

The VNET and bridge tests require root privileges. Check:

```sh
id
```

Expected result: the command reports `uid=0(root)` before you continue.

If you are logged in as your normal user, switch first:

```sh
su -
```

### 9. Verify VNET jail support

`security.jail.vnet` reports whether the current jail owns a VNET. On the
host it normally prints `0`, and it is not a runtime switch to enable VNET.
Use it only as a diagnostic:

```sh
sysctl security.jail.vnet
```

Expected result on the host:

```sh
security.jail.vnet: 0
```

The real VNET check is creating a VNET jail:

```sh
jail -c name=vnetcheck persist vnet
jexec vnetcheck sysctl security.jail.vnet
jail -r vnetcheck
```

Expected result inside `vnetcheck`:

```sh
security.jail.vnet: 1
```

### 10. Ensure `if_bridge(4)` and `epair(4)` are available

Load the modules if needed:

```sh
kldload if_bridge || true
kldload if_epair || true
```

Check whether they are loaded:

```sh
kldstat | egrep 'if_bridge|if_epair'
```

Some systems may have these built into the kernel rather than loaded as
modules. In that case, validate by creating test interfaces:

```sh
test_bridge=$(ifconfig bridge create)
test_epair=$(ifconfig epair create)
ifconfig ${test_bridge} destroy
ifconfig ${test_epair} destroy
```

### 11. Run a quick readiness check

Before building the full topology, run this short checklist inside the
FreeBSD VM:

```sh
ping -c 3 freebsd.org
sysctl security.jail.vnet
which jail jexec ifconfig tcpdump mtest nc
kldload if_bridge || true
kldload if_epair || true
test_bridge=$(ifconfig bridge create)
test_epair=$(ifconfig epair create)
ifconfig ${test_bridge} destroy
ifconfig ${test_epair} destroy
```

Expected result: DNS works, all tools are found, and both interface types can
be created successfully. `security.jail.vnet` may print `0` on the host; that
is normal. If any tool or interface creation check fails, fix the VM
environment before continuing to the topology setup.

### 12. Validate `group_fwd_mask` after install and reboot

After installing the patched kernel and patched `ifconfig(8)`, reboot into the
new kernel before testing the control:

```sh
uname -a
kldload if_bridge || true
kldload if_epair || true
```

Create a temporary bridge and set the mask:

```sh
bridge0=$(ifconfig bridge create)
ifconfig ${bridge0} group_fwd_mask 0x4000
ifconfig ${bridge0} | grep group_fwd_mask
```

Expected result:

```sh
        group_fwd_mask 0x4000
```

This confirms that the running kernel accepts `BRDGSFWDMASK` and the installed
`ifconfig(8)` can read the value back. If setting the mask fails with
`Invalid argument`, the installed `ifconfig(8)` is newer than the running
kernel; install and boot the patched kernel before continuing.

Destroy the temporary bridge before creating the full VNET topology:

```sh
ifconfig ${bridge0} destroy
```

## Topology

Create one bridge on the host and connect three VNET jails through `epair(4)`
interfaces:

- `sender`: generates multicast traffic,
- `recv1`: interested receiver that joins the multicast group,
- `recv2`: uninterested receiver that should be pruned when snooping works.

Suggested addressing:

- `sender`: `192.0.2.10/24`
- `recv1`: `192.0.2.11/24`
- `recv2`: `192.0.2.12/24`
- primary test group: `239.1.1.1`
- exempt test group: `224.0.0.251`
- UDP port: `5000`

## Step 1: Prepare the host

Load the required modules if they are not already present:

```sh
kldload if_bridge || true
kldload if_epair || true
```

Confirm the tools you need are installed:

```sh
which jail jexec ifconfig tcpdump mtest nc
```

If your patch adds bridge-specific sysctls or `ifconfig` controls, record them
before testing. You will need:

- one command to disable snooping,
- one command to enable snooping,
- one command to inspect MDB or listener state,
- one command to inspect counters such as prune hits and fallback floods.

## Step 2: Build the VNET topology

Create three `epair(4)` devices and one bridge on the host:

```sh
epair_sender_host=$(ifconfig epair create)
epair_recv1_host=$(ifconfig epair create)
epair_recv2_host=$(ifconfig epair create)

epair_sender_jail=${epair_sender_host%a}b
epair_recv1_jail=${epair_recv1_host%a}b
epair_recv2_jail=${epair_recv2_host%a}b

bridge0=$(ifconfig bridge create)
```

`ifconfig epair create` returns the `a` side, for example `epair0a`. Do not
append another `a` or `b` to that returned value. Use `${name%a}b` to derive
the peer side.

Attach the host sides to the bridge:

```sh
ifconfig ${epair_sender_host} up
ifconfig ${epair_recv1_host} up
ifconfig ${epair_recv2_host} up
ifconfig ${bridge0} addm ${epair_sender_host}
ifconfig ${bridge0} addm ${epair_recv1_host}
ifconfig ${bridge0} addm ${epair_recv2_host}
ifconfig ${bridge0} up
```

Create the VNET jails and assign the peer interfaces:

```sh
jail -c name=sender persist vnet path=/ vnet.interface=${epair_sender_jail}
jail -c name=recv1 persist vnet path=/ vnet.interface=${epair_recv1_jail}
jail -c name=recv2 persist vnet path=/ vnet.interface=${epair_recv2_jail}
```

Configure the jail-side addresses:

```sh
jexec sender ifconfig ${epair_sender_jail} 192.0.2.10/24 up
jexec recv1 ifconfig ${epair_recv1_jail} 192.0.2.11/24 up
jexec recv2 ifconfig ${epair_recv2_jail} 192.0.2.12/24 up
```

Verify that unicast connectivity works before testing multicast:

```sh
jexec sender ping -c 2 192.0.2.11
jexec sender ping -c 2 192.0.2.12
```

Expected result: both pings succeed. If unicast fails, stop and fix the
topology before continuing.

## Step 3: Learn the observation points

Use `tcpdump(1)` on both receiver interfaces to see whether the bridge actually
forwarded multicast frames.

Capture on the interested receiver:

```sh
jexec recv1 tcpdump -ni ${epair_recv1_jail} udp and dst 239.1.1.1
```

Capture on the uninterested receiver:

```sh
jexec recv2 tcpdump -ni ${epair_recv2_jail} udp and dst 239.1.1.1
```

Use `mtest(8)` to create and remove IGMP listener state on `recv1`.

Join and keep the membership active:

```sh
jexec recv1 sh -c "printf 'j 239.1.1.1 ${epair_recv1_jail}\ns 300\n' | mtest"
```

Leave the group:

```sh
jexec recv1 sh -c "printf 'l 239.1.1.1 ${epair_recv1_jail}\nq\n' | mtest"
```

Use a simple UDP sender from `sender` to generate test traffic:

```sh
jexec sender sh -c "for i in 1 2 3 4 5; do echo test-\$i | nc -u 239.1.1.1 5000; sleep 1; done"
```

For the exempt case, change the destination to `224.0.0.251`.

## Step 4: Test baseline flooding with snooping disabled

Disable snooping using the control added by your patch:

```sh
ifconfig bridge0 <disable-snooping-here>
```

Start `tcpdump(1)` on both `recv1` and `recv2`, then send the UDP stream from
`sender`.

Expected result:

- `recv1` captures the multicast packets,
- `recv2` captures the multicast packets.

This confirms that legacy flooding still works when snooping is disabled.

## Step 5: Test fallback flooding on MDB miss

Enable snooping using the control added by your patch:

```sh
ifconfig bridge0 <enable-snooping-here>
```

Do not issue any join from `recv1`. If your patch exposes MDB inspection,
confirm there is no entry for `239.1.1.1`.

Start `tcpdump(1)` on both receivers and send the UDP stream again.

Expected result:

- `recv1` captures the multicast packets,
- `recv2` captures the multicast packets.

This proves that the bridge uses safe fallback flooding when snooping is
enabled but there is no positive listener state.

## Step 6: Test pruning with positive listener state

Keep snooping enabled and create listener state only on `recv1`:

```sh
jexec recv1 sh -c "printf 'j 239.1.1.1 ${epair_recv1_jail}\ns 300\n' | mtest"
```

If your patch exposes an MDB dump, inspect it now and verify that one listener
is associated with `recv1` for the chosen group.

Start `tcpdump(1)` on both receivers and send the UDP stream from `sender`.

Expected result:

- `recv1` captures the multicast packets,
- `recv2` captures zero packets.

This is the primary correctness check for the snooping implementation.

## Step 7: Test teardown and fallback restoration

Remove the listener state from `recv1`:

```sh
jexec recv1 sh -c "printf 'l 239.1.1.1 ${epair_recv1_jail}\nq\n' | mtest"
```

If your implementation relies on expiry rather than immediate leave handling,
wait for the listener timeout and verify that the MDB entry is gone or marked
inactive.

Start fresh `tcpdump(1)` sessions on both receivers and send the same UDP
stream again.

Expected result:

- `recv1` captures the multicast packets,
- `recv2` captures the multicast packets.

This confirms that pruning state is not left behind after the listener goes
away.

## Step 8: Test exempt `224.0.0.0/24` forwarding

Keep snooping enabled. Start `tcpdump(1)` on both receivers for an exempt
destination such as `224.0.0.251`:

```sh
jexec recv1 tcpdump -ni ${epair_recv1_jail} udp and dst 224.0.0.251
jexec recv2 tcpdump -ni ${epair_recv2_jail} udp and dst 224.0.0.251
```

Send a short UDP stream to the exempt destination:

```sh
jexec sender sh -c "for i in 1 2 3 4 5; do echo exempt-\$i | nc -u 224.0.0.251 5000; sleep 1; done"
```

Expected result:

- `recv1` captures the packets,
- `recv2` captures the packets.

This confirms that link-local control multicast stays flooded even when
snooping is enabled.

## Step 9: Repeatability and stale-state checks

Run the following loop several times:

1. Join `239.1.1.1` on `recv1`.
2. Send traffic and confirm that `recv2` is pruned.
3. Leave the group on `recv1`.
4. Send traffic again and confirm fallback flooding resumes.
5. Destroy and recreate `recv1` if you want to test interface teardown.
6. Recheck MDB state and counters after each cycle.

You are looking for:

- stale MDB entries after leave or jail teardown,
- incorrect prune state after listener expiry,
- counters that do not match observed behavior,
- crashes, warnings, or use-after-free style symptoms in `dmesg`.

## What to record for review

Capture the following for each test run:

- the FreeBSD branch and commit under test,
- the exact snooping enable and disable commands,
- bridge state before and after the test,
- MDB output before and after join and leave,
- observability counters before and after traffic runs,
- `tcpdump(1)` output from `recv1` and `recv2`,
- any relevant `dmesg` output.

Useful commands:

```sh
ifconfig bridge0
dmesg | tail -100
```

## Cleanup

Destroy the jails and interfaces after the test:

```sh
jail -r sender || true
jail -r recv1 || true
jail -r recv2 || true
ifconfig bridge0 destroy || true
ifconfig ${epair_sender_host} destroy || true
ifconfig ${epair_recv1_host} destroy || true
ifconfig ${epair_recv2_host} destroy || true
```

## Notes

- Use a multicast group outside `224.0.0.0/24` for the main pruning checks.
- Keep the `mtest(8)` join process alive while you send traffic, or the
  membership may disappear before the forwarding test runs.
- Treat `tcpdump(1)` as the forwarding truth source. Application-level receive
  behavior is useful, but it is not the primary signal for bridge pruning.

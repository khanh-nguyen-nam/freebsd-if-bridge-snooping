# group_fwd_mask Validation Walkthrough

This document explains the `group_fwd_mask` validation work at a level suitable
for someone new to FreeBSD bridge development. The goal is not just to list
commands, but to explain what each command proves and why the result matters.

## What We Are Testing

The patch adds a new `if_bridge(4)` control:

```sh
ifconfig bridge0 group_fwd_mask <mask>
```

This control decides whether the bridge may forward selected Ethernet
link-local reserved multicast destinations:

```text
01:80:c2:00:00:00 through 01:80:c2:00:00:0f
```

Before this patch, FreeBSD bridge forwarding treated that reserved destination
range as an unconditional drop. The new mask keeps the old behavior by default,
but allows an operator or test to opt in to forwarding specific destinations.

The mask is 16 bits wide. Bit `n` controls destination
`01:80:c2:00:00:0n`.

Examples:

- `0x0000` forwards none of the reserved destinations.
- `0x4000` forwards `01:80:c2:00:00:0e`.
- `0xffff` forwards all 16 destinations.

The validation we completed proves that the kernel and userland are both using
the new control correctly.

## Why This Test Matters

For this kind of FreeBSD networking change, there are two halves that must
match:

- Kernel side: `if_bridge(4)` must define and handle the new bridge ioctl.
- Userland side: `ifconfig(8)` must know how to send that ioctl and display the
  stored value.

If only userland is updated, `ifconfig` can parse the command but the kernel
rejects it. That is the failure we saw earlier:

```text
ifconfig: BRDGSFWDMASK 0x4000: Invalid argument
```

That error is useful. It means the command reached the kernel, but the running
kernel did not recognize or accept the new bridge command. After installing and
booting the patched kernel, the same command succeeded.

The successful readback is the key signal:

```text
group_fwd_mask 0x4000
```

That proves:

- `ifconfig(8)` accepted the command-line syntax.
- The installed headers and userland binary know `BRDGSFWDMASK`.
- The running kernel accepted the set operation.
- The running kernel stored the bridge-scoped value.
- The get operation returned the same value back to `ifconfig(8)`.
- Bridge status output prints the new field.

This is a control-plane validation. It does not prove all forwarding behavior
by itself, but it proves the new bridge knob is wired end to end.

## Test Environment

The validation was run inside the FreeBSD VM:

```text
host: freebsd-test
user: root for kernel, module, bridge, and jail operations
kernel after reboot: FreeBSD 14.4-STABLE GENERIC arm64
```

The patched source tree was present at:

```text
/home/nkhanh/src/freebsd-src
```

The installed userland command was:

```text
/sbin/ifconfig
```

The bridge and epair modules were loaded with:

```sh
kldload if_bridge || true
kldload if_epair || true
```

The `|| true` suffix is used because the module may already be loaded or built
into the kernel. In either case, the test should continue as long as bridge and
epair interfaces can be created.

## Methodology

The methodology is deliberately small:

1. Boot the patched kernel.
2. Load bridge support.
3. Create a temporary bridge.
4. Set `group_fwd_mask`.
5. Read the bridge state back through `ifconfig`.
6. Destroy the temporary bridge.

This is a good first validation because it removes VNET jails, multicast
traffic generation, packet captures, and timing from the equation. When a small
control-plane test fails, debugging is much easier than debugging a full
traffic test.

The test command sequence is:

```sh
uname -a
kldload if_bridge || true
kldload if_epair || true

bridge0=$(ifconfig bridge create)
ifconfig ${bridge0} group_fwd_mask 0x4000
ifconfig ${bridge0} | grep group_fwd_mask
ifconfig ${bridge0} destroy
```

Expected output:

```text
        group_fwd_mask 0x4000
```

The temporary bridge is enough because `group_fwd_mask` is bridge-scoped state.
We do not need any member interfaces just to prove that the set and get ioctls
work.

## What Happened During Debugging

Several failures helped narrow down the problem.

First, the original patch application failed because `/usr/src` on the VM was
empty:

```text
No file found--skip this patch?
```

That meant the patch was being applied from a directory that did not contain
paths like:

```text
lib/libifconfig/libifconfig.h
sys/net/if_bridge.c
sbin/ifconfig/ifbridge.c
```

The fix was to place the patched FreeBSD source tree on the VM at:

```text
/home/nkhanh/src/freebsd-src
```

Second, building `ifconfig` initially failed because the build saw an old
installed kernel header:

```text
error: no member named 'ifbrp_group_fwd_mask' in 'struct ifbrparam'
error: use of undeclared identifier 'BRDGSFWDMASK'
```

That showed the source file had been patched, but the installed
`/usr/include/net/if_bridgevar.h` did not yet expose the new ABI definitions to
userland. Once the header/userland build was corrected, `ifconfig` built and
installed successfully.

Third, the new `ifconfig` command initially failed at runtime:

```text
ifconfig: BRDGSFWDMASK 0x4000: Invalid argument
```

That indicated userland was now patched, but the running kernel was still old.
Installing and rebooting into the patched kernel fixed that mismatch.

## Result

After installing the patched kernel and rebooting, the validation succeeded:

```sh
ifconfig ${bridge0} group_fwd_mask 0x4000
ifconfig ${bridge0} | grep group_fwd_mask
```

Observed output:

```text
        group_fwd_mask 0x4000
```

This is a successful result.

It confirms that the running system has the `group_fwd_mask` control wired from
`ifconfig(8)` into `if_bridge(4)` and back into bridge status output.

## How This Helps The Larger Project

The larger project is about adding IGMP and MLD snooping to `if_bridge(4)`.
That future work will need more than one feature:

- bridge-scoped configuration,
- kernel state stored per bridge,
- userland controls,
- bridge status reporting,
- forwarding-path decisions,
- and tests that prove whether traffic is flooded or pruned.

The `group_fwd_mask` patch is intentionally smaller than full snooping. It
creates a low-risk review step that exercises the same development muscles:

- adding bridge ABI constants,
- extending `ifbrparam`,
- adding bridge softc state,
- adding get and set ioctl handlers,
- adding `ifconfig` syntax,
- displaying the value in bridge status,
- and changing one controlled forwarding decision.

For an intern, the lesson is this: do not jump straight into the most complex
version of a networking feature. First land a small end-to-end control that
uses the same plumbing. Once that control is proven, the next patch can build
on known-good patterns instead of inventing everything at once.

## What This Test Does Not Prove Yet

This smoke test does not prove that frames are actually forwarded or dropped
according to the mask. It proves the control plane works.

A complete data-plane test still needs to:

- create a bridge with member interfaces,
- send traffic to a reserved destination such as `01:80:c2:00:00:0e`,
- verify that the frame is dropped when the mask bit is clear,
- verify that the frame is forwarded when `0x4000` is set,
- capture packets on the receiver side with `tcpdump(1)`.

That follow-up is the bridge behavior test. The smoke test in this document is
the prerequisite that tells us the knob exists and can be controlled.

## Practical Checklist

Use this checklist when repeating the validation on a new VM:

1. Make sure the patched source tree exists on the VM.
2. Install patched headers and `ifconfig(8)`.
3. Install and boot the patched kernel.
4. Confirm the running kernel with `uname -a`.
5. Load `if_bridge` and `if_epair`.
6. Create a temporary bridge.
7. Set `group_fwd_mask 0x4000`.
8. Read it back with `ifconfig bridgeN | grep group_fwd_mask`.
9. Treat `Invalid argument` as a kernel/userland mismatch until proven otherwise.
10. Destroy the temporary bridge after the check.

The expected successful readback is:

```text
group_fwd_mask 0x4000
```


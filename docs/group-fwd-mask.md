# group_fwd_mask Patch Notes

## Purpose

This is Deliverable 1 from the `if_bridge(4)` IGMP/MLD snooping proposal. It is a small starter patch before the multicast database and IGMP listener-learning work.

The patch adds a bridge-scoped `group_fwd_mask` control for reserved Ethernet link-local multicast destinations:

```text
01:80:c2:00:00:00 through 01:80:c2:00:00:0f
```

By default, FreeBSD `if_bridge(4)` filters this reserved range. The new mask keeps that behavior by default while allowing selected destinations to be forwarded when explicitly configured.

## What Was Added

- `BRDGGFWDMASK` and `BRDGSFWDMASK` bridge ioctl commands.
- A `uint16_t sc_group_fwd_mask` field in `struct bridge_softc`.
- `ifconfig bridge0 group_fwd_mask <mask>` support.
- Bridge status display of the current mask.
- `bridge(4)` documentation for the new control.
- An ATF control-path test covering:
  - default value,
  - set and readback,
  - zero-padded display,
  - rejection of values larger than 16 bits.

## Methodology

The mask is 16 bits because the reserved range has 16 destinations. Bit `n` controls:

```text
01:80:c2:00:00:0n
```

Examples:

```text
0x0000  forward none of the reserved destinations
0x0008  forward 01:80:c2:00:00:03
0x4000  forward 01:80:c2:00:00:0e
0xffff  forward all 16 reserved destinations
```

The forwarding-path change is intentionally narrow. It only changes the existing reserved-link-local multicast decision in `bridge_forward()`. Ordinary unicast, broadcast, non-reserved multicast, and later IGMP/MLD snooping behavior are outside this patch.

The default value is `0x0000`, so existing behavior is preserved unless an operator explicitly opts in.

## Testing Results

Control-plane validation was run on a patched FreeBSD VM.

Test sequence:

```sh
kldload if_bridge || true
bridge=$(ifconfig bridge create)
ifconfig ${bridge} | grep group_fwd_mask
ifconfig ${bridge} group_fwd_mask 0x4000
ifconfig ${bridge} | grep group_fwd_mask
ifconfig ${bridge} group_fwd_mask 0x8
ifconfig ${bridge} | grep group_fwd_mask
ifconfig ${bridge} destroy
```

Expected readbacks:

```text
group_fwd_mask 0x0000
group_fwd_mask 0x4000
group_fwd_mask 0x0008
```

Observed result:

```text
group_fwd_mask 0x0000
group_fwd_mask 0x4000
group_fwd_mask 0x0008
```

Additional checks:

- `git diff --check` passed in the FreeBSD source tree.
- `git apply --reverse --check` passed against the modified FreeBSD tree.
- The patch adds an ATF test case named `group_fwd_mask` in `tests/sys/net/if_bridge_test.sh`.

## Review Artifact

The patch for review is:

```text
patches/0001-if-bridge-group-fwd-mask.patch
```

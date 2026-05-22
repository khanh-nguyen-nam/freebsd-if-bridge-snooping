# group_fwd_mask Methodology

This note explains the `group_fwd_mask` starter patch for FreeBSD `if_bridge(4)`: what changed, why each change was made, and how the pieces fit together.

The patch is intentionally small. It does not implement IGMP or MLD snooping yet. It adds one bridge-wide control that makes one existing forwarding decision configurable: whether frames destined to selected reserved link-local Ethernet multicast groups may be forwarded.

## Problem Statement

Before this patch, `if_bridge(4)` treated the reserved link-local destination range as an unconditional drop:

- `01:80:c2:00:00:00`
- through `01:80:c2:00:00:0f`

The decision lived in `sys/net/if_bridge.c`, inside `bridge_forward()`, after the bridge had already identified a frame as broadcast or multicast and before it called `bridge_broadcast()`.

That is a useful hook point for a starter patch because it already sits at the boundary between:

- dropping a reserved link-local control frame,
- and flooding a multicast frame to other bridge members.

For the larger snooping project, this patch gives us a reviewed pattern for adding bridge-scoped forwarding policy without introducing multicast database state yet.

## User-Visible Behavior

The new control is:

```sh
ifconfig bridge0 group_fwd_mask <mask>
```

The mask is 16 bits wide. Bit `n` controls destination `01:80:c2:00:00:0n`.

Examples:

- `0x0000` preserves the old behavior and forwards none of the reserved groups.
- `0x0008` allows forwarding `01:80:c2:00:00:03`.
- `0x4000` allows forwarding `01:80:c2:00:00:0e`.
- `0xffff` allows forwarding all 16 destinations in the reserved range.

The configured value appears in normal bridge status output:

```text
group_fwd_mask 0x4000
```

Values above `0xffff` are rejected by `ifconfig` before the ioctl is sent.

## Why a 16-Bit Mask

The reserved address range has exactly 16 destinations. The low nibble of the last octet is the selector:

```text
01:80:c2:00:00:00  -> bit 0
01:80:c2:00:00:01  -> bit 1
...
01:80:c2:00:00:0f  -> bit 15
```

A `uint16_t` is therefore the smallest natural representation:

- it matches the number of controlled groups,
- it has a direct address-to-bit mapping,
- it is simple to validate in userland,
- and it follows the established `group_fwd_mask` model used by Linux bridges.

The important design point is that the mask controls only the reserved link-local range. It does not change how ordinary multicast, broadcast, or unicast frames are handled.

## Why Bridge-Wide State

The first version stores one mask per bridge, not per member port.

That choice keeps the patch focused:

- one bridge field,
- one get ioctl,
- one set ioctl,
- one `ifconfig` command,
- one forwarding-path check.

Per-port forwarding policy would need additional member state, member-list reporting changes, more userland syntax, and more complex forwarding rules. That can be added later if there is a concrete need, but it would make this starter patch harder to review and less useful as a small first step.

## Kernel ABI Changes

### `sys/net/if_bridgevar.h`

Two new driver-specific ioctl command numbers were added:

```c
#define BRDGGFWDMASK 31 /* get group_fwd_mask (ifbrparam) */
#define BRDGSFWDMASK 32 /* set group_fwd_mask (ifbrparam) */
```

Why:

- `if_bridge(4)` uses `SIOCGDRVSPEC` and `SIOCSDRVSPEC` with bridge-specific command numbers.
- Existing bridge parameters such as cache size, timeout, STP priority, and hold count already use this pattern.
- Adding explicit get and set commands keeps the API consistent with the rest of `if_bridge`.

The patch also extends the existing `struct ifbrparam` union accessors:

```c
#define ifbrp_group_fwd_mask ifbrp_ifbrpu.ifbrpu_int16
```

Why:

- `ifbrparam` is the existing small bridge-parameter carrier.
- The mask is 16 bits, so the existing `uint16_t` union member is enough.
- Reusing `ifbrparam` avoids adding a new request structure for one scalar value.
- This follows the same style as `ifbrp_prio`, which also uses `ifbrpu_int16`.

This is an ABI-visible change because userland includes `net/if_bridgevar.h` and uses these command numbers and accessors to talk to the kernel.

## Kernel State Changes

### `struct bridge_softc`

The patch adds:

```c
uint16_t sc_group_fwd_mask;
```

Why:

- The mask is bridge-scoped configuration, so it belongs in `struct bridge_softc`.
- It must be available from the forwarding path without looking at userland or global state.
- It is not VNET-global because different bridge instances should be configurable independently.

The field is initialized during bridge creation:

```c
sc->sc_group_fwd_mask = 0;
```

Why:

- A zero mask preserves existing behavior.
- New bridge instances start from the same policy FreeBSD had before this patch.
- Operators must opt in before any reserved link-local group is forwarded.

The allocation uses `M_ZERO`, so this explicit assignment is technically redundant. It is still useful because it documents the default policy at the place where other bridge defaults are initialized.

## Kernel Ioctl Plumbing

This section explains how an `ifconfig` command reaches the bridge code that actually changes or reads `group_fwd_mask`.

The easiest way to think about it is:

1. userland builds a request,
2. the kernel receives it,
3. the bridge driver checks which command it is,
4. the bridge driver calls the correct helper function,
5. that helper reads or updates the bridge setting.

For example, when an operator runs:

```sh
ifconfig bridge0 group_fwd_mask 0x4000
```

the path is roughly:

```text
ifconfig -> ioctl(...) -> bridge_ioctl() -> bridge_control_table
-> bridge_ioctl_sfwdmask() -> sc->sc_group_fwd_mask updated
```

For a read operation, the path is similar:

```text
ifconfig -> ioctl(...) -> bridge_ioctl() -> bridge_control_table
-> bridge_ioctl_gfwdmask() -> current mask copied back to userland
```

### Why this plumbing exists

The bridge driver already has one common entry point for bridge control operations:

- `bridge_ioctl()`

That function acts like a front desk:

- it receives the request,
- checks which bridge-specific command was asked for,
- checks how the data should be handled,
- and passes the request to the correct small helper.

This design avoids putting all bridge control logic in one giant function. Instead:

- one function receives requests,
- a table tells the kernel how to route them,
- and small handlers perform the actual work.

### Function Declarations

The patch adds declarations for:

```c
static int bridge_ioctl_gfwdmask(struct bridge_softc *, void *);
static int bridge_ioctl_sfwdmask(struct bridge_softc *, void *);
```

What these mean:

- `bridge_ioctl_gfwdmask` is the helper for reading the current mask.
- `bridge_ioctl_sfwdmask` is the helper for setting a new mask.

Why this change was needed:

- once new ioctl command numbers were added, the bridge driver needed actual functions to handle them,
- and those functions follow the same pattern as the other small bridge ioctl handlers.

### `bridge_control_table`

The patch registers two new entries:

```c
{ bridge_ioctl_gfwdmask, sizeof(struct ifbrparam), BC_F_COPYOUT },
{ bridge_ioctl_sfwdmask, sizeof(struct ifbrparam), BC_F_COPYIN | BC_F_SUSER },
```

This table is the routing map for bridge ioctl commands.

When `bridge_ioctl()` receives a bridge command number, it uses that number to look up the correct row in `bridge_control_table`. That row tells it:

- which function should handle the request,
- how large the request data is,
- whether data should be copied from userland into the kernel,
- whether data should be copied from the kernel back to userland,
- and whether the operation requires privilege.

What the flags mean here:

- `BC_F_COPYIN`: userland is sending data into the kernel.
- `BC_F_COPYOUT`: the kernel will return data back to userland.
- `BC_F_SUSER`: only a privileged user may perform this operation.

Why the two new rows are different:

- `BRDGGFWDMASK` is a get operation, so the kernel must return the current mask to userland. That is why it uses `BC_F_COPYOUT`.
- `BRDGSFWDMASK` is a set operation, so userland provides the new mask value. That is why it uses `BC_F_COPYIN`.
- setting bridge forwarding policy changes live network behavior, so `BRDGSFWDMASK` also requires `BC_F_SUSER`.

Why this table change matters:

- without these rows, `bridge_ioctl()` would receive the command number but would not know which handler to call,
- so the new ioctl commands would exist in the header but not actually work.

### What `bridge_ioctl()` does with the table

Once a request reaches `bridge_ioctl()`, it does several important checks before the handler runs:

1. Is the command number valid?
2. Is this a get or set operation, and does it match the allowed flags?
3. Does the caller have permission if the command is privileged?
4. Is the request structure the expected size?
5. If needed, copy the request data from userland into kernel memory.
6. Call the specific handler.
7. If needed, copy the result back to userland.

Why this is important:

- it protects the kernel from malformed requests,
- it keeps userland and kernel in sync about request size and direction,
- and it keeps each individual handler small and simple.

### Get Handler

The get handler is:

```c
static int
bridge_ioctl_gfwdmask(struct bridge_softc *sc, void *arg)
{
	struct ifbrparam *param = arg;

	param->ifbrp_group_fwd_mask = sc->sc_group_fwd_mask;
	return (0);
}
```

What it does:

- it takes the current mask stored in the bridge,
- puts that value into the request structure,
- and returns success.

What happens next:

- after the handler returns, the common ioctl path copies that filled structure back to userland,
- then `ifconfig` can print the value.

Why this is small:

- the common ioctl framework already handles permissions, size checks, and copyout,
- so the handler only needs to move the bridge value into the response structure.

### Set Handler

The set handler is:

```c
static int
bridge_ioctl_sfwdmask(struct bridge_softc *sc, void *arg)
{
	struct ifbrparam *param = arg;

	sc->sc_group_fwd_mask = param->ifbrp_group_fwd_mask;
	return (0);
}
```

What it does:

- it reads the mask value that userland sent in the request structure,
- stores that value into `sc->sc_group_fwd_mask`,
- and returns success.

What has already happened before this function runs:

- `ifconfig` parsed the command-line text,
- `ifconfig` built an `ifbrparam`,
- the kernel copied that structure in from userland,
- and `bridge_ioctl()` confirmed this is a valid privileged set operation.

Why the handler itself stays simple:

- all of the “is this request well-formed?” work is done by the common ioctl path,
- so this function only applies the already-validated value to the bridge state.

### Locking and safety

The bridge ioctl path holds `BRIDGE_LOCK(sc)` while handling bridge control operations.

Why that matters:

- bridge configuration is shared kernel state,
- and the lock prevents concurrent changes from racing with each other while the mask is being updated or read.

There is no extra per-bit validation in the kernel handler because:

- the mask is already a 16-bit value,
- each bit corresponds to one valid address in the reserved range,
- and userland already rejects values larger than `0xffff`.

## Forwarding Path Changes

### Helper Function

The patch adds:

```c
static bool
bridge_rsvd_link_local_enabled(struct bridge_softc *sc, const uint8_t *dst)
{
	uint16_t bit;

	if (dst[0] != 0x01 || dst[1] != 0x80 || dst[2] != 0xc2 ||
	    dst[3] != 0x00 || dst[4] != 0x00 || dst[5] > 0x0f)
		return (false);

	bit = (uint16_t)1 << dst[5];
	return ((sc->sc_group_fwd_mask & bit) != 0);
}
```

Why:

- The address matching and bit mapping are policy logic, so isolating them makes `bridge_forward()` easier to read.
- The helper returns `false` for addresses outside the reserved range, which keeps it narrowly scoped.
- The bit calculation is direct: the last octet selects the mask bit.

Example:

```text
dst[5] = 0x03 -> bit = 1 << 3  -> 0x0008
dst[5] = 0x0e -> bit = 1 << 14 -> 0x4000
```

### `bridge_forward()`

Before this patch, the bridge dropped all frames in the reserved range:

```c
if (dst[0] == 0x01 && dst[1] == 0x80 &&
    dst[2] == 0xc2 && dst[3] == 0x00 &&
    dst[4] == 0x00 && dst[5] <= 0x0f)
	goto drop;
```

After this patch, the drop still happens unless the relevant mask bit is enabled:

```c
if (!bridge_rsvd_link_local_enabled(sc, dst) &&
    dst[0] == 0x01 && dst[1] == 0x80 &&
    dst[2] == 0xc2 && dst[3] == 0x00 &&
    dst[4] == 0x00 && dst[5] <= 0x0f)
	goto drop;
```

Why:

- The default case is unchanged because `sc_group_fwd_mask` starts at `0`.
- If the destination is outside the reserved range, this code behaves like it did before.
- If the destination is inside the reserved range and the bit is clear, the frame is dropped.
- If the destination is inside the reserved range and the bit is set, the code falls through to the existing multicast accounting and `bridge_broadcast()` path.

The patch deliberately does not change `bridge_broadcast()`. Once a reserved group is permitted, it follows the same flood path as other multicast frames. That keeps the new behavior limited to the existing drop-or-flood decision.

## libifconfig Changes

### `lib/libifconfig/libifconfig.h`

The bridge status structure now includes:

```c
uint16_t group_fwd_mask;
```

Why:

- `ifconfig` gets bridge status through libifconfig.
- If status output should show the mask, libifconfig needs to expose it.
- This keeps `ifconfig` from making a second private ioctl outside the existing bridge status helper.

### `lib/libifconfig/libifconfig_bridge.c`

The bridge status helper now performs a `BRDGGFWDMASK` ioctl and stores the result:

```c
if (ifconfig_bridge_ioctlwrap(h, name, BRDGGFWDMASK,
    &fwd_mask_param, sizeof(fwd_mask_param), false) != 0) {
	free(bridge);
	return (-1);
}
bridge->inner.group_fwd_mask = fwd_mask_param.ifbrp_group_fwd_mask;
```

Why:

- Bridge status already gathers cache size, cache lifetime, STP params, and member data.
- Adding the mask there keeps all bridge status collection in one function.
- Error handling follows the existing pattern: if the ioctl fails, free the partially allocated status object and return failure.

## ifconfig Changes

### Status Output

`sbin/ifconfig/ifbridge.c` now prints:

```c
printf("\tgroup_fwd_mask 0x%04x\n", bridge->group_fwd_mask);
```

Why:

- Operators need to see the current bridge setting.
- Four hex digits make the 16-bit width explicit.
- This matches examples such as `0x0000`, `0x0008`, and `0x4000`.

### Command Parser

The patch adds:

```c
setbridge_group_fwd_mask()
```

This function:

1. Parses the argument with the existing `get_val()` helper.
2. Rejects values that do not fit in 16 bits.
3. Stores the value in `param.ifbrp_group_fwd_mask`.
4. Sends `BRDGSFWDMASK` through the existing `do_cmd()` ioctl wrapper.

Why:

- The existing bridge commands use this style for scalar values like `timeout`, `maxage`, and `priority`.
- `get_val()` already supports decimal and base-prefixed values such as `0x4000`.
- Userland validation gives immediate feedback for values such as `0x10000`.

The command is registered as:

```c
DEF_CMD_ARG("group_fwd_mask", setbridge_group_fwd_mask)
```

Why:

- `group_fwd_mask` takes exactly one argument.
- It is bridge-level configuration, so it belongs in the same command table as `timeout`, `maxaddr`, and STP bridge parameters.

## Manual Page Changes

`share/man/man4/bridge.4` now documents:

- the default reserved-range filtering behavior,
- the `ifconfig group_fwd_mask` command,
- the 16-bit bit-to-address mapping,
- and an example mask.

Why:

- The forwarding behavior is visible and operator-controlled.
- The mapping is easy to get wrong without documentation.
- The man page should explicitly state that the default remains filtered.

The documentation says bit `n` controls `01:80:c2:00:00:0n`. For example, `0x4000` sets bit 14 and allows `01:80:c2:00:00:0e`.

## Test Changes

`tests/sys/net/if_bridge_test.sh` now includes a `group_fwd_mask` ATF case.

The test verifies:

- a new bridge reports `group_fwd_mask 0x0000`,
- setting `0x4000` succeeds and is visible in status,
- setting `0x8` succeeds and is printed as `0x0008`,
- setting `0x10000` fails.

Why:

- This patch is primarily a control-surface patch, so the first test should prove the control surface works end to end.
- The test covers default value, accepted values, display formatting, and invalid input.
- The test does not require packet generation or protocol-specific setup.

Traffic-level tests are better suited for a later patch because they need a more careful test harness for injecting or observing reserved link-local multicast frames across bridge member interfaces.

## Safety Properties

The patch is conservative in these ways:

- Default behavior is preserved because the mask starts at `0`.
- Existing ioctl command numbers are not renumbered.
- Only privileged users can set the mask.
- The forwarding-path change applies only to the reserved `01:80:c2:00:00:00` through `01:80:c2:00:00:0f` range.
- Normal unicast forwarding is untouched.
- Normal multicast flooding is untouched.
- Bridge member lifecycle is untouched.
- STP, learning, private-port checks, pfil hooks, and `bridge_broadcast()` are left as they were.

This matters because the patch is meant to be a stable foundation for later snooping work, not the snooping implementation itself.

## How This Supports the Snooping Roadmap

Future IGMP and MLD snooping work will need to make forwarding decisions in the multicast path. This patch establishes the first small piece of that model:

- a bridge-scoped policy field,
- a kernel get/set control path,
- userland configuration,
- status visibility,
- tests for round-tripping policy,
- and a small forwarding-path predicate.

The later MDB work can build on the same discipline:

- keep unknown multicast behavior explicit,
- preserve defaults unless the operator enables a feature,
- isolate policy predicates from packet plumbing,
- and add tests in phases as the behavior becomes more protocol-aware.

In short, `group_fwd_mask` is the smallest useful change that introduces configurable multicast-adjacent bridge policy while keeping the review focused and understandable.

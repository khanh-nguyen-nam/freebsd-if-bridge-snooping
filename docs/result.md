# MDB Foundation Test Result

Date: 2026-06-03

Host:

```text
freebsd-test
```

System:

```text
FreeBSD freebsd-test 14.4-STABLE FreeBSD 14.4-STABLE GENERIC arm64
kernel:  14.4-STABLE
userland: 14.4-STABLE
```

Source tree:

```text
/usr/src/freebsd-src
```

Installed test path check:

```sh
test -x /usr/tests/sys/net/if_bridge_test
echo $?
```

Result:

```text
0
```

## Patch Scope Tested

The test run covered:

- Deliverable 1 `group_fwd_mask` control path;
- MDB structure and helper scaffolding in the patched kernel;
- MDB member cleanup lifecycle path;
- MDB timer/callout lifecycle path;
- VNET topology scaffold;
- existing `if_bridge` regression cases installed under `/usr/tests`.

The current patch still does not implement IGMP/MLD listener learning or
MDB-aware multicast forwarding, so those behaviors were not validated by this
run.

## Targeted Kyua Tests

Command:

```sh
kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:group_fwd_mask
```

Result:

```text
sys/net/if_bridge_test:group_fwd_mask  ->  passed  [0.030s]
1/1 passed (0 broken, 0 failed, 0 skipped)
```

Results file:

```text
/root/.kyua/store/results.usr_tests.20260603-211217-758296.db
```

Command:

```sh
kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:mdb_vnet_topology
```

Result:

```text
sys/net/if_bridge_test:mdb_vnet_topology  ->  passed  [0.050s]
1/1 passed (0 broken, 0 failed, 0 skipped)
```

Results file:

```text
/root/.kyua/store/results.usr_tests.20260603-211217-914397.db
```

## Full `if_bridge_test` Run

Command:

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test
```

Result:

```text
17/19 passed (0 broken, 0 failed, 2 skipped)
```

Results file:

```text
/root/.kyua/store/results.usr_tests.20260603-211227-963858.db
```

Passed tests:

```text
sys/net/if_bridge_test:bridge_transmit_ipv4_unicast
sys/net/if_bridge_test:delete_with_members
sys/net/if_bridge_test:gif
sys/net/if_bridge_test:group_fwd_mask
sys/net/if_bridge_test:inherit_mac
sys/net/if_bridge_test:mac_conflict
sys/net/if_bridge_test:many_bridge_members
sys/net/if_bridge_test:mdb_vnet_topology
sys/net/if_bridge_test:member_ifaddrs_disabled
sys/net/if_bridge_test:member_ifaddrs_enabled
sys/net/if_bridge_test:member_ifaddrs_vlan
sys/net/if_bridge_test:mtu
sys/net/if_bridge_test:static
sys/net/if_bridge_test:stp
sys/net/if_bridge_test:stp_vlan
sys/net/if_bridge_test:vlan
sys/net/if_bridge_test:vstatic
```

Skipped tests:

```text
sys/net/if_bridge_test:span
sys/net/if_bridge_test:stp_validation
```

Skip reason:

```text
Required program 'scapy' not found in PATH
```

These skips are environment skips, not failures in the bridge patch.

## Kyua Report Note

Running:

```sh
kyua report --verbose
```

from `/root` printed:

```text
kyua: E: No previous results file found for test suite root.
```

Reason:

- Kyua uses the current directory as the default test suite name when no result
  file is specified;
- the tests were run with `/usr/tests/Kyuafile`, so the result IDs are under the
  `usr_tests` suite, not a suite named `root`.

Use an explicit result file or result ID:

```sh
kyua report -r /root/.kyua/store/results.usr_tests.20260603-211227-963858.db \
    --verbose
```

or:

```sh
kyua report -r usr_tests.20260603-211227-963858 --verbose
```

## Conclusion

The MDB foundation patch passed the current kernel smoke tests and installed
ATF/Kyua validation:

```text
group_fwd_mask targeted test: passed
mdb_vnet_topology targeted test: passed
full if_bridge_test run: 17/19 passed, 2 environment skips, 0 failures
```

This is a successful validation for the current scaffold scope.

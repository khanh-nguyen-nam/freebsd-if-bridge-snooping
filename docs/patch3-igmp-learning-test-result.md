# Patch 3 IGMP Learning Test Result

Recorded: 2026-06-11

Host:

```text
freebsd-test
```

System:

```text
FreeBSD freebsd-test 14.4-STABLE FreeBSD 14.4-STABLE GENERIC arm64
```

Source tree:

```text
/usr/src/freebsd-src
```

Patch:

```text
patches/0003-if-bridge-ipv4-igmp-learning.patch
```

## Scope Tested

This run covered the patch 3 IPv4 IGMP learning path and safe fallback behavior:

- patch 3 source markers present in `sys/net/if_bridge.c`;
- patch 3 ATF test case present in `tests/sys/net/if_bridge_test.sh`;
- installed test-suite refresh for `/usr/tests/sys/net/if_bridge_test`;
- existing bridge regression baseline;
- unknown IPv4 multicast flood fallback;
- manual IGMPv3 report smoke test through the VNET topology.

Patch 3 still does not implement MDB-based multicast pruning or user-visible MDB
dump output, so those behaviors were not claimed as tested.

## Source Checks

Patch 3 test case was present in the source test file:

```text
875:atf_test_case "mdb_unknown_multicast_flood" "cleanup"
876:mdb_unknown_multicast_flood_head()
883:mdb_unknown_multicast_flood_body()
890:    capture="${PWD}/mdb_unknown_multicast_flood.tcpdump"
911:mdb_unknown_multicast_flood_cleanup()
1060:   atf_add_test_case "mdb_unknown_multicast_flood"
```

## Installed Test Refresh

Initial installed-test lookup did not find the new patch 3 test:

```sh
kyua list -k /usr/tests/Kyuafile | grep 'mdb_unknown_multicast_flood' || echo missing-from-installed-tests
```

Result:

```text
missing-from-installed-tests
```

The installed tests were refreshed from the source tree:

```sh
cd /usr/src/freebsd-src/tests/sys/net
make install
```

The install copied the updated `if_bridge_test` into:

```text
/usr/tests/sys/net/if_bridge_test
```

## Baseline Bridge Regression

Before the installed test refresh, the existing installed bridge suite passed
with the expected environment skips:

```text
17/19 passed (0 broken, 0 failed, 2 skipped)
```

Results file:

```text
/root/.kyua/store/results.usr_tests.20260610-160542-852405.db
```

Skipped tests:

```text
sys/net/if_bridge_test:span          Required program 'scapy' not found in PATH
sys/net/if_bridge_test:stp_validation Required program 'scapy' not found in PATH
```

This was treated as a regression baseline only. Because patch 3 adds
`mdb_unknown_multicast_flood`, `17/19` does not by itself prove the new patch 3
ATF test ran.

## Unknown Multicast Flood Fallback

Manual topology test:

```sh
. /tmp/mdbtest.state
jexec "${idle_jail}" tcpdump --immediate-mode -n \
    -i "${idle_epair}b" \
    'icmp and dst host 239.1.1.1'
```

Captured packet on the idle port:

```text
16:21:04.340601 IP 192.0.2.1 > 239.1.1.1: ICMP echo request, id 55817, seq 0, length 64
```

Sender command:

```sh
. /tmp/mdbtest.state
jexec "${sender_jail}" route add -net 224.0.0.0/4 \
    -interface "${sender_epair}b" >/dev/null 2>&1 || true
jexec "${sender_jail}" ping -c 1 -t 1 239.1.1.1
```

Sender result:

```text
1 packets transmitted, 0 packets received, 100.0% packet loss
```

Result:

```text
passed
```

The ping reply was not expected. The pass condition was that the idle jail saw
the multicast echo request, proving unknown multicast still floods while MDB
forwarding pruning is not implemented.

## Manual IGMPv3 Report Smoke Test

`mcjoin` was not installed in the jail:

```text
jexec: execvp: mcjoin: No such file or directory
```

A temporary local helper was used instead to call `IP_ADD_MEMBERSHIP` inside the
listener jail.

Capture command:

```sh
. /tmp/mdbtest.state
tcpdump --immediate-mode -en -i "${listener_epair}a" igmp
```

Captured packets:

```text
16:26:57.222881 02:a8:98:ad:ca:0b > 01:00:5e:00:00:16, ethertype IPv4 (0x0800), length 54: 192.0.2.2 > 224.0.0.22: igmp v3 report, 1 group record(s)
16:26:58.707801 02:a8:98:ad:ca:0b > 01:00:5e:00:00:16, ethertype IPv4 (0x0800), length 54: 192.0.2.2 > 224.0.0.22: igmp v3 report, 1 group record(s)
```

Capture summary:

```text
2 packets captured
2 packets received by filter
0 packets dropped by kernel
```

Result:

```text
passed
```

This exercised the patch 3 IGMP input path with an IGMPv3 report observed on the
bridge-side listener member. Because there is still no MDB dump interface, this
test proves report observation and parser-path smoke coverage, not visible MDB
contents.

## Patch 3 Targeted ATF

After `make install`, patch 3 testing was reported as working. The exact
post-refresh Kyua output and result database for
`sys/net/if_bridge_test:mdb_unknown_multicast_flood` were not preserved in
these notes.

Recommended command for the final record:

```sh
kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:mdb_unknown_multicast_flood
```

Expected result:

```text
1/1 passed
```

## Cleanup Notes

When running as `root`, use the non-root staging path for the topology helper:

```sh
/home/nkhanh/freebsd-if-bridge-snooping/scripts/mdb-vnet-topology.sh destroy
```

Do not use `~/freebsd-if-bridge-snooping/...` from a root shell, because `~`
expands to `/root`.

## Summary

Patch 3 is working for the behaviors that are testable at this stage:

- existing installed bridge tests had no regressions in the baseline run;
- unknown IPv4 multicast still floods to idle ports;
- listener-side IGMPv3 reports are observable through the VNET bridge topology;
- the installed test suite was refreshed after initially missing the new patch 3
  ATF case.

Remaining unverified by design:

- exact MDB entry contents;
- immediate IGMP leave removal;
- MDB-based multicast forwarding pruning;
- IPv6 MLD behavior.

# Patch 4 MDB Forward Test Result

Recorded: 2026-06-30

Host:

```text
freebsd-test
```

System:

```text
FreeBSD freebsd-test 14.4-STABLE GENERIC aarch64
```

Compiler:

```text
FreeBSD clang version 19.1.7 (llvmorg-19.1.7-0-gcd708029e0b2)
Target: aarch64-unknown-freebsd14.4
```

Source tree:

```text
/usr/src/freebsd-src
```

Patch:

```text
patches/0004-if-bridge-mdb-forward.patch
```

---

## Scope Tested

- epoch-deferred reclamation of MDB nodes (`NET_EPOCH_CALL` replacing `free()`);
- relaxed `bridge_mdb_lookup` assertion (`BRIDGE_RT_LOCK_OR_NET_EPOCH_ASSERT`);
- `bridge_mdb_forward()` selective forwarding — multicast pruned to listener ports only;
- flood fallback when no MDB entry is present;
- patch 4 ATF test case `mdb_selective_forward`;
- full bridge regression suite with patch 4 applied.

---

## Pre-test Fix: Duplicate Test Block

The 2026-06-23 partial apply had left a duplicate `mdb_selective_forward` block
in `tests/sys/net/if_bridge_test.sh`. The `grep -c` count was 11 (clean = 6).

The duplicate ran from line 1003 to line 1089. Removed with:

```sh
ex -s /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh <<'EOF'
1003,1089d
wq
EOF
```

Post-fix count:

```text
6
```

Syntax check:

```sh
sh -n /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh
```

Result: no output (clean).

---

## Build

```sh
cd /usr/src/freebsd-src
make -j4 buildkernel KERNCONF=GENERIC
make installkernel KERNCONF=GENERIC
reboot
```

Post-reboot dmesg check:

```sh
dmesg | grep -iE 'panic|fault|trap|if_bridge' | head -20
```

Output:

```text
Release APs...Trying to mount root from zfs:zroot/ROOT/default []...
```

No panics, faults, or traps. `if_bridge` is compiled statically into GENERIC
and does not print a separate attach message.

---

## Installed Test Refresh

```sh
cd /usr/src/freebsd-src/tests/sys/net
make if_bridge_test
install -m 0555 "$(make -V .OBJDIR)/if_bridge_test" \
    /usr/tests/sys/net/if_bridge_test
```

Kyua visibility check:

```sh
kyua list -k /usr/tests/Kyuafile | grep 'mdb_selective_forward'
```

Output:

```text
sys/net/if_bridge_test:mdb_selective_forward
```

---

## Targeted ATF Test

```sh
kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:mdb_selective_forward
```

Output:

```text
sys/net/if_bridge_test:mdb_selective_forward  ->  passed  [7.251s]

Results file id is usr_tests.20260630-162234-136778
Results saved to /root/.kyua/store/results.usr_tests.20260630-162234-136778.db

1/1 passed (0 broken, 0 failed, 0 skipped)
```

Result: **passed**

---

## Full Bridge Regression

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test
```

Output:

```text
sys/net/if_bridge_test:bridge_transmit_ipv4_unicast  ->  passed  [2.075s]
sys/net/if_bridge_test:delete_with_members           ->  passed  [0.043s]
sys/net/if_bridge_test:gif                           ->  passed  [0.072s]
sys/net/if_bridge_test:group_fwd_mask                ->  passed  [0.040s]
sys/net/if_bridge_test:inherit_mac                   ->  passed  [0.022s]
sys/net/if_bridge_test:mac_conflict                  ->  passed  [2.104s]
sys/net/if_bridge_test:many_bridge_members           ->  passed  [0.952s]
sys/net/if_bridge_test:mdb_selective_forward         ->  passed  [7.283s]
sys/net/if_bridge_test:mdb_unknown_multicast_flood   ->  passed  [2.116s]
sys/net/if_bridge_test:mdb_vnet_topology             ->  passed  [0.083s]
sys/net/if_bridge_test:member_ifaddrs_disabled       ->  passed  [0.063s]
sys/net/if_bridge_test:member_ifaddrs_enabled        ->  passed  [1.060s]
sys/net/if_bridge_test:member_ifaddrs_vlan           ->  passed  [2.159s]
sys/net/if_bridge_test:mtu                           ->  passed  [0.071s]
sys/net/if_bridge_test:span                          ->  skipped: Required program 'scapy' not found in PATH  [0.000s]
sys/net/if_bridge_test:static                        ->  passed  [0.040s]
sys/net/if_bridge_test:stp                           ->  passed  [5.169s]
sys/net/if_bridge_test:stp_validation                ->  skipped: Required program 'scapy' not found in PATH  [0.002s]
sys/net/if_bridge_test:stp_vlan                      ->  passed  [5.292s]
sys/net/if_bridge_test:vlan                          ->  passed  [1.181s]
sys/net/if_bridge_test:vstatic                       ->  passed  [0.079s]

Results file id is usr_tests.20260630-162300-520217
Results saved to /root/.kyua/store/results.usr_tests.20260630-162300-520217.db

19/21 passed (0 broken, 0 failed, 2 skipped)
```

Skipped tests (environment, not patch regressions):

```text
span          Required program 'scapy' not found in PATH
stp_validation Required program 'scapy' not found in PATH
```

Regression delta vs patch 3 baseline (17/19): **+2 tests** (`mdb_selective_forward`
added, suite grew from 19 to 21 cases). No previously passing test regressed.

---

## Summary

Patch 4 is working for all behaviors testable at this stage:

- `mdb_selective_forward` ATF test passed: multicast for a known group is
  pruned to listener ports only and does not reach idle ports;
- all previously passing bridge tests continue to pass (19/21, same 2 scapy skips);
- no kernel panics or faults on boot after installing the new kernel.

Remaining deferred (future patches):

- user-visible MDB dump ioctl / `ifconfig bridge0 mdb` output;
- IGMPv3 source-filter (SSM) fidelity;
- MLD / IPv6 listener learning.

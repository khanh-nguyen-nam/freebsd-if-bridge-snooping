# Patch 8 Link-Local Exemption Test Result

Recorded: 2026-08-06

Patch:

```text
patches/0008-if-bridge-link-local-exempt.patch
```

Status: **Complete — all VM checks pass.** This patch exists because of a
real bug found by `scripts/snooping-edge-cases.sh` (full account in
`docs/edge-case-test-suite.md`), not by inspection or an ATF regression.

---

## Scope

- `bridge_mdb_igmp_group_snoopable()` predicate excluding `224.0.0.0/24`
  from listener-state learning, called from both the IGMPv2/v1 and IGMPv3
  record paths;
- an independent forwarding-side guard in `bridge_mdb_forward()` that
  floods `224.0.0.0/24` regardless of any MDB state;
- `bridge.4` documentation of the exemption;
- `mdb_link_local_exempt` ATF test.

No new sysctls, counters, or structures.

---

## Host-side verification (done)

A scratch worktree pinned to base `97cc6bd98` had patches `0001`–`0008`
applied in order with `patch --batch --forward -p1`: all eight applied
cleanly (no fuzz, no rejects). All three touched files
(`sys/net/if_bridge.c`, `share/man/man4/bridge.4`,
`tests/sys/net/if_bridge_test.sh`) came out byte-identical to the
implementation worktree. `sh -n` on the test script is clean; `mandoc -T
lint` on `bridge.4` shows 19 warnings both before and after, all
pre-existing (missing cross-reference targets not installed on the macOS
host), none introduced by the new paragraph.

---

## VM build (done)

```sh
cd /usr/src/freebsd-src
make -j4 buildkernel KERNCONF=GENERIC && make installkernel KERNCONF=GENERIC
shutdown -r now
```

Post-reboot:

```text
dmesg | grep -iE '\b(panic|fault|trap)\b'
```

Empty. No panics, faults, or traps.

## ATF — targeted (done)

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_link_local_exempt
```

```text
sys/net/if_bridge_test:mdb_link_local_exempt  ->  passed  [4.419s]
```

## Edge-case suite — full run (done)

```sh
RUN_SLOW=1 sh /tmp/snooping-edge-cases.sh
```

```text
passed:  29
failed:  0
skipped: 0
```

**29/29, zero failures.** This is the same suite that found the bug: before
patch 8 it reported `T1a`/`T1b` failing (link-local state created and then
used to prune); after patch 8, both pass — `mdb_entries` stays `0` after a
join to `224.0.0.251`, and an uninterested port still receives the traffic.
The suite was extended to T0–T17 (29 checks total, including the slow
`RUN_SLOW=1` aging test) after patch 8 was already applied, in a second
coverage pass looking for anything the original 12-test version missed —
see `docs/edge-case-test-suite.md` for what T12–T17 cover, including the
first-ever confirmation that the aging/expiry path (`mdb_expired`,
proposal assertion 4) actually works. Every test in the suite (T0, T2–T17)
was already passing before this patch or was added after and passes now,
confirming the fix didn't disturb VLAN keying,
runtime disable, unrelated-group flooding, member-detach cleanup, churn,
parser hardening, IGMPv3 record handling, router-port flush, counter
resets, or bridge-destroy safety. Full per-test breakdown and what each
test covers: `docs/edge-case-test-suite.md`.

## Full regression (done)

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test
```

```text
23/25 passed (0 broken, 0 failed, 2 skipped)
```

The 2 skips are `span` and `stp_validation`, both missing `scapy` on this
VM — the same environment-only gap present in every prior patch's run, not
a patch 8 regression. **23/25 is +1 over patch 7's 22/24** —
`mdb_link_local_exempt` is the new pass. No previously passing test
regressed. Full per-test output:

```text
bridge_transmit_ipv4_unicast   passed  [2.140s]
delete_with_members            passed  [0.042s]
gif                            passed  [0.073s]
group_fwd_mask                 passed  [0.045s]
inherit_mac                    passed  [0.027s]
mac_conflict                   passed  [2.173s]
many_bridge_members            passed  [0.960s]
mdb_counters                   passed  [4.234s]
mdb_igmpv3_source_join         passed  [7.357s]
mdb_link_local_exempt          passed  [4.349s]
mdb_router_forward             passed  [9.111s]
mdb_selective_forward          passed  [7.242s]
mdb_unknown_multicast_flood    passed  [2.208s]
mdb_vnet_topology              passed  [0.089s]
member_ifaddrs_disabled        passed  [0.064s]
member_ifaddrs_enabled         passed  [1.068s]
member_ifaddrs_vlan            passed  [2.166s]
mtu                            passed  [0.065s]
span                           skipped (scapy missing)
static                         passed  [0.040s]
stp                            passed  [5.307s]
stp_validation                 skipped (scapy missing)
stp_vlan                       passed  [5.217s]
vlan                           passed  [1.183s]
vstatic                        passed  [0.087s]
```

---

## Summary

Patch 8 closes a real correctness gap: the bridge could learn and act on
IGMP membership state for the link-local `224.0.0.0/24` block, which RFC
4541 requires to always flood. The gap was reachable under FreeBSD's own
default configuration (`net.inet.igmp.sendlocal=1`), and its effect —
silent loss of traffic for listeners who suppressed their own report
because another host on the segment already reported the same group — was
confirmed directly by the edge-case suite (T1a: `mdb_entries` went `0 → 1`
on a join to `224.0.0.251`; T1b: an uninterested port stopped receiving the
traffic once that state existed).

The fix is two independent, minimal guards (learn-side and forward-side)
using FreeBSD's own `IN_LOCAL_GROUP` macro, verified end to end: clean
build/boot, the new ATF test passes, the full extended edge-case suite is
29/29 with no regressions elsewhere (including the aging/expiry path,
mass-join, dedup, and multi-listener checks added in a second coverage
pass), and the full ATF regression is 23/25 — one more than patch 7's
baseline, same two environment-only skips, nothing broken.

Of everything the edge-case suite initially flagged (6 failing checks on
the first run), this is the only one that was a genuine kernel defect —
the rest were two bugs in the test harness itself, found and fixed while
building the suite; see `docs/edge-case-test-suite.md` for the full
account.

---

## Supplementary: suppression-efficiency benchmark

After patch 8 (and the whole series) was otherwise verified, a small
supplementary benchmark quantified the series' suppression behavior in
concrete delivery-count terms, using `mcjoin` as the traffic generator
per Bruce Simpson's explicit guidance during proposal review that
suppression/correctness — not throughput — is what matters here. Full
writeup: `docs/suppression-benchmark-result.md`. Headline result: with
4 idle ports and a 500-packet run, snooping off delivered the full
stream to all 4 idle ports (2000 total); snooping on delivered **zero**
to any idle port while the real listener still received all 500 packets
in both conditions — a 100% suppression ratio with no cost to the real
listener. This is supplementary evidence for the project, not part of
the Phabricator patch series itself — it quantifies behavior already
proven correct by the ATF suite and the edge-case suite, it doesn't test
anything new.

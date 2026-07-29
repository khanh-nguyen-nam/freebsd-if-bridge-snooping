# Patch 5 Test Plan — `0005-if-bridge-snooping-counters.patch`

Patch 5 adds the `igmp_snooping` enable knob (default **off**) and five
read-only observability counters. It also flips existing behavior: snooping is
no longer always-on. These tests verify the knob gates learning/forwarding,
the counters move correctly, and no regressions were introduced.

Apply after patches 0001–0004 are already on the VM (they are, per the patch 4
test result from 2026-06-30).

---

## Phase 0 — Check VM state

```sh
ssh freebsd-test
```

Confirm patches 1–4 are present and patch 5 is not yet applied:

```sh
grep -c 'igmp_snooping\|mdb_prune_hits' /usr/src/freebsd-src/sys/net/if_bridge.c
```

- `0` → patch 5 not applied yet (expected). Proceed to Phase 1.
- `> 0` → already applied; skip to Phase 2.

---

## Phase 1 — Apply patch 5

```sh
# On host
scp /Users/macboookpro/khanh-dev/freebsd-if-bridge-snooping/patches/0005-if-bridge-snooping-counters.patch \
    nkhanh@172.16.167.140:/tmp/

# On VM (as root)
cd /usr/src/freebsd-src
patch --batch --forward --dry-run -p1 < /tmp/0005-if-bridge-snooping-counters.patch
patch --batch --forward -p1 < /tmp/0005-if-bridge-snooping-counters.patch
```

Verify the three files patched cleanly and the test script is well-formed:

```sh
grep -c 'igmp_snooping' /usr/src/freebsd-src/sys/net/if_bridge.c        # expect >= 3
grep -c 'mdb_counters'  /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh  # expect 6
sh -n /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh              # expect no output
```

---

## Phase 2 — Build and install

```sh
cd /usr/src/freebsd-src
make -j4 buildkernel KERNCONF=GENERIC
make installkernel KERNCONF=GENERIC
reboot
```

Post-reboot:

```sh
dmesg | grep -iE 'panic|fault|trap' | head    # expect nothing
```

---

## Phase 3 — Sysctl surface smoke test

Confirm the new knob and counters are present and read as expected on a bare
system (no bridge yet):

```sh
sysctl net.link.bridge.igmp_snooping        # expect: ... = 0   (default off)
sysctl net.link.bridge | grep -E 'mdb_(entries|prune_hits|flood_fallback|parse_reject|expired)'
```

Expected: five counter lines, all `= 0`.

Confirm a counter zeroes on write:

```sh
sysctl net.link.bridge.mdb_flood_fallback=0  # expect no error
```

---

## Phase 4 — Install updated test binary

```sh
cd /usr/src/freebsd-src/tests/sys/net
make if_bridge_test
install -m 0555 "$(make -V .OBJDIR)/if_bridge_test" \
    /usr/tests/sys/net/if_bridge_test

kyua list -k /usr/tests/Kyuafile | grep 'mdb_counters'
```

Expected: `sys/net/if_bridge_test:mdb_counters`

---

## Phase 5 — ATF targeted tests

Run the new counter test plus the two behavior-changed tests:

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_counters
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_selective_forward
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_unknown_multicast_flood
```

Expected: all three `passed`.

The critical regression check: `mdb_selective_forward` must still pass **with
the new default-off knob**, proving the test correctly enables snooping before
relying on pruning.

---

## Phase 6 — Manual gating check (the core behavior change)

This is the assertion patch 5 is really about: with snooping **off**, a joined
group is NOT pruned (idle port receives); with snooping **on**, it is. No
existing ATF test checks the OFF-by-default case on a *joined* group — the
suite only checks ON-pruning (`mdb_selective_forward`) and OFF/ON-flooding on
an *unjoined* group (`mdb_unknown_multicast_flood`). This phase closes that
gap, standalone, outside kyua.

The topology and commands below are the same ones `bridge_mdb_vnet_topology_create`
and `mdb_selective_forward_body` use in `tests/sys/net/if_bridge_test.sh` /
`tests/sys/common/vnet.subr`, written out directly so they can be run
interactively as root without the ATF harness.

Paste each step below **one at a time, in order, in the same shell session**
(the shell variables one step sets — `sender_epair`, `bridge`, `joiner_pid`,
etc. — must still be set when the next step runs). Everything it writes
(`mcast_join_bridge_test*`, the two tcpdump captures) goes to `/tmp`, not
`$PWD`: `jexec` always `chdir`s into the jail's root before exec'ing the
command, so a cwd-relative redirect from inside a `jexec ... sh -c "..."`
call lands relative to the jail's root (`/` here, since these jails aren't
chrooted), not the operator's actual working directory. Using absolute
`/tmp/` paths sidesteps that entirely.

### Step 0 — Prerequisites

```sh
kldstat -q -m if_bridge || kldload if_bridge
kldstat -q -m if_epair  || kldload if_epair
```

### Step 1 — Build the topology: 3 jails (sender/listener/idle), 3 epairs, 1 bridge

```sh
sender_epair=$(ifconfig epair create); ifconfig ${sender_epair} -txcsum -txcsum6
listener_epair=$(ifconfig epair create); ifconfig ${listener_epair} -txcsum -txcsum6
idle_epair=$(ifconfig epair create); ifconfig ${idle_epair} -txcsum -txcsum6
sender_epair=${sender_epair%a}
listener_epair=${listener_epair%a}
idle_epair=${idle_epair%a}

jail -c name=mdbs persist vnet vnet.interface=${sender_epair}b
jail -c name=mdbl persist vnet vnet.interface=${listener_epair}b
jail -c name=mdbi persist vnet vnet.interface=${idle_epair}b

jexec mdbs ifconfig ${sender_epair}b   192.0.2.1/24 up
jexec mdbl ifconfig ${listener_epair}b 192.0.2.2/24 up
jexec mdbi ifconfig ${idle_epair}b     192.0.2.3/24 up

bridge=$(ifconfig bridge create)
ifconfig ${bridge} up
ifconfig ${sender_epair}a up
ifconfig ${listener_epair}a up
ifconfig ${idle_epair}a up
ifconfig ${bridge} addm ${sender_epair}a addm ${listener_epair}a addm ${idle_epair}a

jexec mdbs route add -net 224.0.0.0/4 -interface ${sender_epair}b
```

### Step 2 — Compile the join helper (reachable from jails via shared `/tmp`)

The heredoc body below uses spaces, not tabs — pasting a literal tab into an
interactive `/bin/sh` session (FreeBSD's `libedit`) triggers filename
completion instead of inserting the tab, which garbles the paste.

```sh
cat > /tmp/mcast_join_bridge_test.c << 'CSRC'
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv)
{
    struct ip_mreq mreq;
    int s, on = 1, secs;
    if (argc != 4) return 1;
    secs = atoi(argv[3]);
    s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s < 0) return 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    memset(&mreq, 0, sizeof(mreq));
    mreq.imr_multiaddr.s_addr = inet_addr(argv[1]);
    mreq.imr_interface.s_addr = inet_addr(argv[2]);
    if (setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) < 0)
        return 1;
    sleep(secs);
    return 0;
}
CSRC
cc -o /tmp/mcast_join_bridge_test /tmp/mcast_join_bridge_test.c
```

### Step 3 — Case A: snooping OFF (the default) — expect FLOOD, idle port SEES it

```sh
sysctl net.link.bridge.igmp_snooping=0

jexec mdbl /tmp/mcast_join_bridge_test 239.1.1.1 192.0.2.2 30 &
joiner_pid=$!
sleep 2   # let the IGMP report traverse the bridge

rm -f /tmp/off.tcpdump
jexec mdbi sh -c "timeout 4 tcpdump --immediate-mode -n \
    -i ${idle_epair}b -c 1 'icmp and dst host 239.1.1.1' > /tmp/off.tcpdump 2>&1" &
tcpdump_pid=$!
sleep 1

jexec mdbs ping -c 1 -t 1 239.1.1.1 >/dev/null 2>&1
wait ${tcpdump_pid}
off_status=$?
kill ${joiner_pid} 2>/dev/null

if [ ${off_status} -eq 0 ]; then
    echo "PASS: snooping OFF floods to idle port (expected)"
    cat /tmp/off.tcpdump
else
    echo "FAIL: idle port received nothing with snooping OFF — should have flooded"
fi
```

### Step 4 — Case B: snooping ON — expect PRUNE, idle port sees NOTHING

```sh
sysctl net.link.bridge.igmp_snooping=1

jexec mdbl /tmp/mcast_join_bridge_test 239.1.1.1 192.0.2.2 30 &
joiner_pid=$!
sleep 2

rm -f /tmp/on.tcpdump
jexec mdbi sh -c "timeout 4 tcpdump --immediate-mode -n \
    -i ${idle_epair}b -c 1 'icmp and dst host 239.1.1.1' > /tmp/on.tcpdump 2>&1" &
tcpdump_pid=$!
sleep 1

jexec mdbs ping -c 1 -t 1 239.1.1.1 >/dev/null 2>&1
wait ${tcpdump_pid}
on_status=$?
kill ${joiner_pid} 2>/dev/null

if [ ${on_status} -ne 0 ]; then
    echo "PASS: snooping ON prunes the idle port (expected)"
else
    echo "FAIL: idle port received multicast that MDB should have pruned"
    cat /tmp/on.tcpdump
fi
```

### Step 5 — Read the counters while the topology is still up

```sh
sysctl net.link.bridge.mdb_entries          # >= 1 — the listener's entry is still live
sysctl net.link.bridge.mdb_prune_hits       # >= 1 — from case B's ping
sysctl net.link.bridge.mdb_flood_fallback   # >= 1 — from case A's ping
```

### Step 6 — Cleanup (destroys the entries too, so `mdb_entries` drops back to 0)

```sh
jexec mdbs ifconfig ${sender_epair}b destroy 2>/dev/null
jexec mdbl ifconfig ${listener_epair}b destroy 2>/dev/null
jexec mdbi ifconfig ${idle_epair}b destroy 2>/dev/null
jail -r mdbs; jail -r mdbl; jail -r mdbi
ifconfig ${bridge} destroy
ifconfig ${sender_epair}a destroy
ifconfig ${listener_epair}a destroy
ifconfig ${idle_epair}a destroy
rm -f /tmp/mcast_join_bridge_test /tmp/mcast_join_bridge_test.c /tmp/off.tcpdump /tmp/on.tcpdump
```

Expected result: both `PASS` lines print. If Case A prints `FAIL`, multicast
routing/join setup is broken (unrelated to MDB). If Case B prints `FAIL`,
`bridge_mdb_forward()` pruning itself is broken — that would be a real patch
4/5 regression, not a test artifact.

Note on step 5 — read the counters *before* step 6's cleanup, matching the
gauge-vs-event-counter distinction: `mdb_entries` is a live gauge that drops
back to `0` once the bridge/jails are torn down, while `mdb_prune_hits` /
`mdb_flood_fallback` are cumulative event counters tied to the VNET's
lifetime, not to this topology's — they persist until explicitly reset
(`sysctl net.link.bridge.mdb_prune_hits=0`) or the VNET itself is destroyed.

---

## Phase 7 — Full regression

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test
```

Expected: **20/22 passed, 2 skipped** (span + stp_validation for missing
`scapy`). That is +1 vs the patch 4 baseline of 19/21 — `mdb_counters` is the
new pass. No previously passing test may regress.

---

## Pass criteria summary

| Check | Expected |
|-------|----------|
| Patch applies, `sh -n` clean | yes |
| Kernel builds, no panic on boot | yes |
| `igmp_snooping` defaults to 0 | yes |
| All 5 counters present, start at 0, zero on write | yes |
| `mdb_counters` ATF | passed |
| `mdb_selective_forward` still passes (with enable knob) | passed |
| Snooping OFF → no pruning; ON → pruning (manual) | yes |
| Counters advance: entries / prune_hits / flood_fallback | yes |
| Full regression | 20/22, +1 vs patch 4, no new fails |

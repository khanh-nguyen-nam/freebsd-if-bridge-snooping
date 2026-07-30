# Patch 7 Test Plan — `0007-if-bridge-igmpv3-asm-refinement.patch`

Patch 7 widens IGMPv3 record handling to the conservative ASM reduction:
any record expressing positive interest creates/refreshes `(*,G)` state;
revocation-only records never remove state eagerly. No new sysctls or
counters.

Apply after patches 0001–0006 are already on the VM.

---

## Phase 0 — Check VM state

```sh
ssh freebsd-test
su -
```

Confirm patch 6 is present and patch 7 is not yet applied:

```sh
grep -c 'IGMP_ALLOW_NEW_SOURCES' /usr/src/freebsd-src/sys/net/if_bridge.c
```

- `0` → patch 7 not applied yet (expected). Proceed to Phase 1.
- `> 0` → already applied; skip to Phase 2.

---

## Phase 1 — Apply patch 7

```sh
# On host
scp /Users/macboookpro/khanh-dev/freebsd-if-bridge-snooping/patches/0007-if-bridge-igmpv3-asm-refinement.patch \
    nkhanh@172.16.167.140:/tmp/

# On VM (as root)
cd /usr/src/freebsd-src
patch --batch --forward --dry-run -p1 < /tmp/0007-if-bridge-igmpv3-asm-refinement.patch
patch --batch --forward -p1 < /tmp/0007-if-bridge-igmpv3-asm-refinement.patch
```

Verify:

```sh
grep -c 'IGMP_ALLOW_NEW_SOURCES' /usr/src/freebsd-src/sys/net/if_bridge.c          # expect 1
grep -c 'mdb_igmpv3_source_join' /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh  # expect 5
sh -n /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh                         # expect no output
```

---

## Phase 2 — Build and install

```sh
cd /usr/src/freebsd-src
make -j4 buildkernel KERNCONF=GENERIC
make installkernel KERNCONF=GENERIC
shutdown -r now
```

Post-reboot (word-bounded so `zroot/ROOT/default` doesn't false-match):

```sh
dmesg | grep -iE '\b(panic|fault|trap)\b'    # expect nothing
```

---

## Phase 3 — Install updated test binary

```sh
cd /usr/src/freebsd-src/tests/sys/net
make if_bridge_test
install -m 0555 "$(make -V .OBJDIR)/if_bridge_test" \
    /usr/tests/sys/net/if_bridge_test

kyua list -k /usr/tests/Kyuafile | grep 'mdb_igmpv3_source_join'
```

Expected: `sys/net/if_bridge_test:mdb_igmpv3_source_join`

---

## Phase 4 — ATF targeted tests

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_igmpv3_source_join
# regression guard on the IGMP parse and forwarding paths patch 7 touches:
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_selective_forward
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_counters
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_router_forward
```

Expected: all `passed`.

If `mdb_igmpv3_source_join` fails at the `mdb_entries` match, the
INCLUDE-family record did not create state — check with
`tcpdump -i <listener-epair>a igmp` on the host side that the join
actually emits an IGMPv3 report (`igmp v3 report`) and not a v2 report.

---

## Phase 5 — Manual gating check (leave is not eager)

The one behavior no ATF test covers: a revocation record must NOT remove
state immediately (aging handles it). Run as root, in one shell.

```sh
kldstat -q -m if_bridge || kldload if_bridge
kldstat -q -m if_epair  || kldload if_epair

e=$(ifconfig epair create); ifconfig ${e} -txcsum -txcsum6
ep=${e%a}
jail -c name=mdbl persist vnet vnet.interface=${ep}b
jexec mdbl ifconfig ${ep}b 192.0.2.2/24 up
jexec mdbl sysctl net.inet.igmp.default_version=3
bridge=$(ifconfig bridge create); ifconfig ${bridge} up
ifconfig ${ep}a up; ifconfig ${bridge} addm ${ep}a
sysctl net.link.bridge.igmp_snooping=1
```

Compile the source-join helper (same source as the ATF heredoc; also in
`/tmp` after any `mdb_igmpv3_source_join` run):

```sh
cat > /tmp/srcjoin.c << 'CSRC'
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv)
{
    struct ip_mreq_source mreqs;
    int s, on = 1;
    if (argc != 4) return 1;
    s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s < 0) return 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    memset(&mreqs, 0, sizeof(mreqs));
    mreqs.imr_multiaddr.s_addr = inet_addr(argv[1]);
    mreqs.imr_sourceaddr.s_addr = inet_addr(argv[2]);
    mreqs.imr_interface.s_addr = inet_addr(argv[3]);
    if (setsockopt(s, IPPROTO_IP, IP_ADD_SOURCE_MEMBERSHIP,
        &mreqs, sizeof(mreqs)) < 0)
        return 1;
    sleep(30);
    return 0;
}
CSRC
cc -o /tmp/srcjoin /tmp/srcjoin.c
```

Join, confirm state, then kill the joiner (the kernel sends the
state-change/leave records) and confirm the state survives the leave:

```sh
jexec mdbl /tmp/srcjoin 239.1.1.1 192.0.2.1 192.0.2.2 &
jpid=$!
sleep 2
sysctl net.link.bridge.mdb_entries     # expect >= 1 (INCLUDE record learned)

kill ${jpid}
sleep 2
sysctl net.link.bridge.mdb_entries     # expect STILL >= 1 (no eager removal)
```

Cleanup:

```sh
jail -r mdbl 2>/dev/null
ifconfig ${bridge} destroy
ifconfig ${ep}a destroy 2>/dev/null
rm -f /tmp/srcjoin /tmp/srcjoin.c
```

Note: `mdb_entries` here is a gauge over live state; other bridges/jails on
the system would add to it. On the quiet test VM it should read exactly the
state this topology created.

---

## Phase 6 — Full regression

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test
```

Expected: **22/24 passed, 2 skipped** (span + stp_validation, missing
`scapy`). That is +1 vs the patch 6 baseline of 21/23 —
`mdb_igmpv3_source_join` is the new pass. No previously passing test may
regress.

---

## Pass criteria summary

| Check | Expected |
|-------|----------|
| Patch applies, `sh -n` clean | yes |
| Kernel builds, no panic on boot | yes |
| `mdb_igmpv3_source_join` ATF | passed |
| Source-specific join creates `(*,G)` state | yes (`mdb_entries` >= 1) |
| Listener receives; idle port pruned | yes |
| Leave does not remove state eagerly | yes (entries survive the kill) |
| `mdb_selective_forward` / `mdb_counters` / `mdb_router_forward` still pass | yes |
| Full regression | 22/24, +1 vs patch 6, no new fails |

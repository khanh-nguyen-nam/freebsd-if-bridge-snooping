# Patch 6 Test Plan — `0006-if-bridge-router-port-learning.patch`

Patch 6 adds multicast-router-port learning: ports on which IGMP membership
queries are seen are learned as router ports (keyed by VLAN), and a learned
group is forwarded to its listeners **plus** any router port on the same VLAN.
It also adds the `net.link.bridge.mdb_routers` gauge counter.

These tests verify that (a) a router port is learned from queries, (b) a
learned group reaches the router port even though it never joined, (c) an idle
port is still pruned, and (d) nothing regressed.

Apply after patches 0001–0005 are already on the VM.

---

## Phase 0 — Check VM state

```sh
ssh freebsd-test
su -
```

Confirm patches 1–5 are present and patch 6 is not yet applied:

```sh
grep -c 'bridge_mdb_add_router\|sc_mdbrouters' /usr/src/freebsd-src/sys/net/if_bridge.c
```

- `0` → patch 6 not applied yet (expected). Proceed to Phase 1.
- `> 0` → already applied; skip to Phase 2.

---

## Phase 1 — Apply patch 6

```sh
# On host
scp /Users/macboookpro/khanh-dev/freebsd-if-bridge-snooping/patches/0006-if-bridge-router-port-learning.patch \
    nkhanh@172.16.167.140:/tmp/

# On VM (as root)
cd /usr/src/freebsd-src
patch --batch --forward --dry-run -p1 < /tmp/0006-if-bridge-router-port-learning.patch
patch --batch --forward -p1 < /tmp/0006-if-bridge-router-port-learning.patch
```

Verify the three files patched and the test script is well-formed:

```sh
grep -c 'bridge_mdb_add_router' /usr/src/freebsd-src/sys/net/if_bridge.c        # expect >= 2
grep -c 'mdb_router_forward'    /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh  # expect 5
sh -n /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh                      # expect no output
```

---

## Phase 2 — Build and install

```sh
cd /usr/src/freebsd-src
make -j4 buildkernel KERNCONF=GENERIC
make installkernel KERNCONF=GENERIC
shutdown -r now
```

Post-reboot:

```sh
dmesg | grep -iE 'panic|fault|trap' | head    # expect nothing
```

---

## Phase 3 — Sysctl surface smoke test

```sh
kldload if_bridge   # if_bridge is a module; load it so the sysctl tree appears
sysctl net.link.bridge.mdb_routers            # expect: ... = 0   (nothing learned yet)
sysctl net.link.bridge.mdb_routers=0          # expect no error (writable-to-zero reset)
```

---

## Phase 4 — Install updated test binary

```sh
cd /usr/src/freebsd-src/tests/sys/net
make if_bridge_test
install -m 0555 "$(make -V .OBJDIR)/if_bridge_test" \
    /usr/tests/sys/net/if_bridge_test

kyua list -k /usr/tests/Kyuafile | grep 'mdb_router_forward'
```

Expected: `sys/net/if_bridge_test:mdb_router_forward`

---

## Phase 5 — ATF targeted tests

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_router_forward
# regression guard on the paths patch 6 refactored:
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_selective_forward
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test:mdb_counters
```

Expected: all `passed`.

If `mdb_router_forward` fails at the `sysctl -n net.link.bridge.mdb_routers`
match step, the query helper did not produce a query the bridge accepted — see
the note in Phase 6 about the raw-socket query sender, which is the most
likely thing to need a tweak on first run. If it fails at the tcpdump asserts,
the forwarding union itself is wrong.

---

## Phase 6 — Manual gating check (the core behavior)

This proves router learning directly: a group with a listener on one port is
delivered to a **router** port (queries seen, no join) while a truly idle port
is still pruned.

Paste each step below **one at a time, in order, in the same root shell**
(variables set by one step must survive to the next). Everything it writes
goes to `/tmp` — `jexec` chdirs into the jail root before running the command,
so a cwd-relative redirect would not land where you expect. The C helper
heredocs use spaces, not tabs: a pasted literal tab triggers `libedit`
completion in `/bin/sh` and garbles the paste.

### Step 0 — Prerequisites

```sh
kldstat -q -m if_bridge || kldload if_bridge
kldstat -q -m if_epair  || kldload if_epair
```

### Step 1 — Build a 4-jail topology (sender / listener / router / idle)

```sh
for r in s l r i; do
    e=$(ifconfig epair create); ifconfig ${e} -txcsum -txcsum6
    eval ep_$r=${e%a}
done
jail -c name=mdbs persist vnet vnet.interface=${ep_s}b
jail -c name=mdbl persist vnet vnet.interface=${ep_l}b
jail -c name=mdbr persist vnet vnet.interface=${ep_r}b
jail -c name=mdbi persist vnet vnet.interface=${ep_i}b
jexec mdbs ifconfig ${ep_s}b 192.0.2.1/24 up
jexec mdbl ifconfig ${ep_l}b 192.0.2.2/24 up
jexec mdbr ifconfig ${ep_r}b 192.0.2.4/24 up
jexec mdbi ifconfig ${ep_i}b 192.0.2.3/24 up
bridge=$(ifconfig bridge create); ifconfig ${bridge} up
for r in s l r i; do eval e=\$ep_$r; ifconfig ${e}a up; ifconfig ${bridge} addm ${e}a; done
jexec mdbs route add -net 224.0.0.0/4 -interface ${ep_s}b
jexec mdbr route add -net 224.0.0.0/4 -interface ${ep_r}b
sysctl net.link.bridge.igmp_snooping=1
```

The router jail also needs a multicast route: it originates the IGMP query in Step 3,
and without a route to `224.0.0.0/4` the `sendto()` in the query helper fails with
`ENETUNREACH` even though `IP_MULTICAST_IF` names the right interface — the kernel
still does a routing-table lookup first, and the jail's table only has its own `/24`.

### Step 2 — Compile the join and query helpers

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

cat > /tmp/mcast_query_bridge_test.c << 'CSRC'
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/igmp.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
static unsigned short cksum(const unsigned char *b, int len)
{
    unsigned long sum = 0; int i;
    for (i = 0; i + 1 < len; i += 2) sum += (b[i] << 8) | b[i + 1];
    if (len & 1) sum += b[len - 1] << 8;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (unsigned short)(~sum);
}
int main(int argc, char **argv)
{
    struct sockaddr_in dst; struct in_addr mif;
    unsigned char igmp[8], ttl = 1; unsigned short sum; int s, i, n;
    if (argc != 3) return 1;
    n = atoi(argv[2]);
    s = socket(AF_INET, SOCK_RAW, IPPROTO_IGMP);
    if (s < 0) return 1;
    mif.s_addr = inet_addr(argv[1]);
    if (setsockopt(s, IPPROTO_IP, IP_MULTICAST_IF, &mif, sizeof(mif)) < 0) return 1;
    setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));
    memset(igmp, 0, sizeof(igmp));
    igmp[0] = IGMP_HOST_MEMBERSHIP_QUERY;   /* 0x11 */
    igmp[1] = 100;                          /* max resp 10s */
    sum = cksum(igmp, sizeof(igmp));
    igmp[2] = sum >> 8; igmp[3] = sum & 0xff;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_addr.s_addr = inet_addr("224.0.0.1");
    for (i = 0; i < n; i++) {
        if (sendto(s, igmp, sizeof(igmp), 0, (struct sockaddr *)&dst, sizeof(dst)) < 0)
            return 1;
        usleep(200000);
    }
    return 0;
}
CSRC
cc -o /tmp/mcast_query_bridge_test /tmp/mcast_query_bridge_test.c
```

### Step 3 — Learn a listener and a router port

```sh
jexec mdbl /tmp/mcast_join_bridge_test 239.1.1.1 192.0.2.2 30 &
joiner_pid=$!
sleep 2
jexec mdbr /tmp/mcast_query_bridge_test 192.0.2.4 3
sleep 1
sysctl net.link.bridge.mdb_routers      # expect >= 1  (router port learned)
sysctl net.link.bridge.mdb_entries      # expect >= 1  (listener learned)
```

### Step 4 — Send to the group; router receives, idle is pruned

```sh
rm -f /tmp/router.tcpdump /tmp/idle.tcpdump
jexec mdbr sh -c "timeout 4 tcpdump --immediate-mode -n -i ${ep_r}b -c 1 \
    'icmp and dst host 239.1.1.1' > /tmp/router.tcpdump 2>&1" &
rpid=$!
jexec mdbi sh -c "timeout 4 tcpdump --immediate-mode -n -i ${ep_i}b -c 1 \
    'icmp and dst host 239.1.1.1' > /tmp/idle.tcpdump 2>&1" &
ipid=$!
sleep 1
jexec mdbs ping -c 3 -t 1 239.1.1.1 >/dev/null 2>&1
wait ${rpid}; router_status=$?
wait ${ipid}; idle_status=$?
kill ${joiner_pid} 2>/dev/null

[ ${router_status} -eq 0 ] && echo "PASS: router port received the group" \
    || echo "FAIL: router port did not receive it"
[ ${idle_status} -ne 0 ] && echo "PASS: idle port pruned" \
    || { echo "FAIL: idle port received it"; cat /tmp/idle.tcpdump; }
```

### Step 5 — Cleanup

```sh
for j in mdbs mdbl mdbr mdbi; do jail -r $j 2>/dev/null; done
ifconfig ${bridge} destroy
for r in s l r i; do eval e=\$ep_$r; ifconfig ${e}a destroy 2>/dev/null; done
rm -f /tmp/mcast_join_bridge_test* /tmp/mcast_query_bridge_test* \
    /tmp/router.tcpdump /tmp/idle.tcpdump
```

Expected: both `PASS` lines in Step 4. If the router `FAIL`s while
`mdb_routers` was >= 1 in Step 3, the learning worked but the forwarding union
is wrong. If `mdb_routers` was 0 in Step 3, the query helper did not emit a
query the bridge accepted (the raw-socket sender is the fragile part; confirm
with `tcpdump -i ${ep_r}b igmp` in mdbr that a type-0x11 query actually goes
out).

---

## Phase 7 — Full regression

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test
```

Expected: **21/23 passed, 2 skipped** (span + stp_validation for missing
`scapy`). That is +1 vs the patch 5 baseline of 20/22 — `mdb_router_forward`
is the new pass. No previously passing test may regress.

---

## Pass criteria summary

| Check | Expected |
|-------|----------|
| Patch applies, `sh -n` clean | yes |
| Kernel builds, no panic on boot | yes |
| `mdb_routers` present, starts at 0, zero on write | yes |
| Router port learned from queries (`mdb_routers` >= 1) | yes |
| Group delivered to router port (no join) | yes |
| Idle port still pruned | yes |
| `mdb_selective_forward` / `mdb_counters` still pass | yes |
| `mdb_router_forward` ATF | passed |
| Full regression | 21/23, +1 vs patch 5, no new fails |

# FreeBSD Bridge IGMP Snooping

An eight-patch implementation of IPv4 multicast snooping for FreeBSD's
`if_bridge(4)`: learn which bridge ports have multicast listeners, then forward
known multicast streams to those listeners and multicast routers instead of
replicating them to every port.

This repository contains the kernel and userland patch series, implementation
notes, VNET test scripts, and recorded verification results. It is a companion
repository for work on the FreeBSD source tree, rather than a standalone
application or a full fork of FreeBSD.

## The problem

A bridge can learn where unicast destinations live, but without multicast
listener tracking it floods multicast traffic to eligible member ports. On a
host connecting VNET jails or virtual machines, that means guests receive and
discard streams they never joined. Replication also sends unnecessary traffic
across their virtual interfaces.

The goal is to suppress those unnecessary deliveries while preserving delivery
to interested receivers, multicast routers, and essential control protocols.
Correctness comes first: pruning requires positive listener state, and unknown
groups retain the bridge's existing flood behavior.

```text
                    FreeBSD bridge
                         |
       +-----------------+-----------------+
       |                 |                 |
    Sender          Joined listener     Idle guest
       |                 |                 |
       +-- multicast --->|                 |
                         |                 |
  Snooping disabled: listener and idle guest both receive the stream.
  Snooping enabled, group learned: listener receives; idle guest is pruned.
  A learned multicast-router port also receives the stream on its VLAN.
```

## Scope and status

The supplied series implements **IPv4 IGMP snooping with Any-Source Multicast
(ASM) forwarding**. It includes IGMPv1/v2 listener reports, conservative IGMPv3
listener learning, router-port learning, runtime controls, counters, man-page
updates, and ATF/Kyua tests. Snooping is disabled by default.

The original proposal also explored IPv6/MLD. **IPv6/MLD snooping and true
per-source multicast filtering are not implemented in this series.** IGMPv3
source lists are validated, but positive interest is reduced to `(*,G)` state:
any source for group `G`.

Development and initial VM testing used `stable/14`. The published patch files
were subsequently rebased onto FreeBSD `main` at **`86199f1a74ab` (August 7,
2026)** and verified there. This is the recorded compatibility baseline, not a
claim that the series applies unchanged to newer FreeBSD revisions.

The [submission log](docs/phabricator-submission-guide.md) records eight
Phabricator revisions filed in August 2026:
[D58729](https://reviews.freebsd.org/D58729),
[D58730](https://reviews.freebsd.org/D58730),
[D58731](https://reviews.freebsd.org/D58731),
[D58732](https://reviews.freebsd.org/D58732),
[D58744](https://reviews.freebsd.org/D58744),
[D58745](https://reviews.freebsd.org/D58745),
[D58746](https://reviews.freebsd.org/D58746), and
[D58747](https://reviews.freebsd.org/D58747).
Submission is distinct from upstream acceptance; this repository documents the
implementation and its recorded tests.

## How it works

### 1. Learn listener and router state

The bridge inspects incoming IGMP control packets and records listener ports in
a per-bridge multicast database (MDB), keyed by address family, VLAN ID, and
multicast group. Learning a group on one VLAN does not create membership on
another VLAN.

IGMP reports create or refresh membership. IGMPv3 EXCLUDE records and
INCLUDE/ALLOW records expressing positive source interest create ASM `(*,G)`
membership. Revocation-only records and IGMPv2 leaves do not immediately remove
membership; timer-based aging avoids eagerly cutting off other listeners behind
the same port. Valid membership queries separately create or refresh
VLAN-scoped multicast-router-port state.

The parser validates packet lengths, checksums, TTL, fragmentation, and IGMPv3
record boundaries before learning state. Rejected control packets do not create
new membership.

### 2. Select forwarding destinations

With snooping enabled, the IPv4 multicast forwarding path looks up the group in
the MDB:

| Condition | Forwarding behavior |
| --- | --- |
| Snooping disabled | Use existing bridge forwarding. |
| No learned group | Fall back to flooding. |
| Learned group | Deliver to eligible listener ports plus router ports on the same VLAN. |
| Port is both listener and router | Deliver one copy. |
| IPv4 destination in `224.0.0.0/24` | Bypass snooping and retain flooding. |
| IPv6 or other traffic outside the IPv4 snooping path | Retain existing bridge behavior. |

The destination checks preserve the bridge's port eligibility rules, including
STP state and private-port restrictions. Link-local IPv4 groups such as mDNS's
`224.0.0.251` are excluded from both learning and pruning, so a report from one
host cannot suppress delivery to other hosts on the segment.

### 3. Keep concurrent forwarding and teardown safe

MDB mutations use `BRIDGE_RT_LOCK`; forwarding readers traverse `CK_LIST`
structures under `NET_EPOCH`. Removed group, listener, and router nodes are
reclaimed through epoch-deferred callbacks so concurrent readers cannot access
freed memory. Periodic aging removes stale state, and member detach and bridge
destruction clean up associated memberships and router entries.

The implementation uses linked-list lookups. Large-table scaling and resource
limits remain areas for further work; the recorded tests do not establish
production-scale performance.

### 4. Expose controls and observability

After installing the patched kernel, enable or disable snooping in the relevant
VNET as root:

```sh
sysctl net.link.bridge.igmp_snooping=1
sysctl net.link.bridge.igmp_snooping=0
```

This switch is **per VNET**, rather than per individual bridge. The following
per-VNET counters report learned state and forwarding activity:

| Sysctl suffix under `net.link.bridge` | Meaning |
| --- | --- |
| `mdb_entries` | Number of learned group entries. |
| `mdb_routers` | Number of learned router-port entries. |
| `mdb_prune_hits` | Frames handled by selective forwarding. |
| `mdb_flood_fallback` | Frames falling back to flooding after a group lookup miss. |
| `mdb_parse_reject` | Rejected malformed or unsupported IGMP control packets. |
| `mdb_expired` | Listener memberships removed by aging. |

The counters use FreeBSD's `counter(9)` primitives and support reset writes.
Read them with, for example, `sysctl net.link.bridge.mdb_prune_hits`.

The first patch also adds a separate, **per-bridge** `group_fwd_mask` ioctl and
`ifconfig` interface for selected reserved Ethernet multicast addresses in
`01:80:c2:00:00:00`–`01:80:c2:00:00:0f`. It defaults to zero. This Ethernet
control is separate from the IPv4 IGMP snooping switch; see the
[mask documentation](docs/group-fwd-mask.md).

## Patch series

Apply the patches in numeric order. They change FreeBSD's bridge driver,
`libifconfig`/`ifconfig` where needed, `bridge(4)` documentation, and the bridge
ATF tests.

| Patch | Purpose |
| --- | --- |
| [0001 — Group forwarding mask](patches/0001-if-bridge-group-fwd-mask.patch) | Add the reserved Ethernet multicast control and userland support. |
| [0002 — MDB foundation](patches/0002-if-bridge-mdb-foundation.patch) | Add group/member storage, lifetime management, and VNET topology coverage. |
| [0003 — IGMP learning](patches/0003-if-bridge-ipv4-igmp-learning.patch) | Learn IPv4 listener state and test unknown-group flooding. |
| [0004 — Selective forwarding](patches/0004-if-bridge-mdb-forward.patch) | Consult the MDB in the data path and add epoch-safe reclamation. |
| [0005 — Controls and counters](patches/0005-if-bridge-snooping-counters.patch) | Make snooping opt-in and expose per-VNET observability. |
| [0006 — Router-port learning](patches/0006-if-bridge-router-port-learning.patch) | Learn querier-facing ports and include them in delivery. |
| [0007 — IGMPv3 ASM refinement](patches/0007-if-bridge-igmpv3-asm-refinement.patch) | Recognize additional positive-interest records without claiming source filtering. |
| [0008 — Link-local exemption](patches/0008-if-bridge-link-local-exempt.patch) | Protect `224.0.0.0/24` from learning and pruning. |

## Applying and testing

Use a disposable FreeBSD development VM with root access, VNET/jail support,
`if_bridge`, `if_epair`, a compiler, `tcpdump`, and ATF/Kyua. The scripts create
and destroy network topologies and change snooping settings; run them in an
isolated test environment.

To reproduce the published source baseline, place the two repositories next
to each other:

```sh
git clone https://github.com/khanh-nguyen-nam/freebsd-if-bridge-snooping.git
git clone --filter=blob:none https://git.FreeBSD.org/src.git freebsd-src
cd freebsd-src
git switch --detach 86199f1a74ab
for patch_file in ../freebsd-if-bridge-snooping/patches/000*.patch; do
    git apply "$patch_file" || exit 1
done
```

Build and install the patched kernel, matching userland components, and updated
ATF tests before running the checks. A matching source/kernel/userland setup
matters: the recorded `main` regression run encountered failures from stale VM
userland. The [rebase verification](docs/main-rebase-verification.md) and
[MDB testing tutorial](docs/mdb-foundation-testing-tutorial.md) describe the
environment and build/test workflow. Earlier per-patch instructions may refer
to the original `stable/14` base.

After installation and reboot, run as root:

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test

# From this companion repository; includes the slower aging/expiry checks:
RUN_SLOW=1 sh scripts/snooping-edge-cases.sh
```

The [VNET topology helper](scripts/mdb-vnet-topology.sh) supports manual
experiments. The [suppression benchmark](scripts/suppression-benchmark.sh)
uses `mcjoin` and `tcpdump`; its `MCJOIN` path is specific to the original VM
and must match your installation. See the
[benchmark setup and results](docs/suppression-benchmark-result.md).

## Recorded validation

These are historical VM results committed with the project, rather than new
test runs against your current machine or a newer FreeBSD release:

- **`stable/14`:** 23 of 25 bridge ATF tests passed; two were skipped because
  `scapy` was unavailable. See the [final patch test report](docs/patch8-link-local-exempt-test-result.md).
- **Rebased `main`:** the kernel built and booted, all eight tests added by the
  series passed, and the edge-case suite passed all 29 checks, including aging.
  The full 36-test bridge run also had 11 failures documented as VM environment
  issues, including stale userland lacking newer VLAN controls; it was not a
  fully passing regression run. See the [rebase report](docs/main-rebase-verification.md).
- **Suppression experiment:** one sender transmitted 500 packets with one
  listener and four idle ports. The listener received all 500 packets in both
  conditions. Idle-port deliveries fell from 2,000 with snooping disabled to
  zero with snooping enabled: 100% suppression in that controlled run. This
  measures avoided deliveries, not throughput, latency, or CPU savings.

The edge-case tests exercise VLAN isolation, unknown-group fallback, runtime
disable, malformed control packets, member detach, bridge destruction,
join/leave churn, router/listener deduplication, and link-local exemptions.

## Further reading

- [Original proposal and design goals](docs/proposal-khanh-final.md) — historical
  intent and planned work; the scope above reflects the delivered series.
- [MDB foundation walkthrough](docs/mdb-foundation-walkthrough.md).
- [Forwarding and epoch lifetime design](docs/patch4-implementation-details.md).
- [Router-port learning](docs/patch6-router-port-implementation.md).
- [IGMPv3 ASM behavior](docs/patch7-igmpv3-asm-implementation.md).
- [Link-local bug and fix](docs/patch8-link-local-exempt-implementation.md).
- [Patch index](patches/README.md) and [change log](docs/changes.md).

## License

[BSD 2-Clause](LICENSE).

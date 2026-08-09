# Suppression Benchmark Result

Recorded: 2026-08-09

## Why this exists, and why it isn't a throughput benchmark

During proposal review, Bruce Simpson explicitly cautioned against
performance/throughput testing as the priority for this project:

> Using iperf is probably overkill unless there's a specific need for
> performance testing. In this case, it's more important that the
> *suppression* of traffic is what is exercised. Correctness and
> conformance are more important; historically, it is primarily a
> unicast testing tool. Something like ports/net/mcjoin would perhaps be
> easier, but that's up to you.

This benchmark follows that guidance directly: it uses `mcjoin`
(https://github.com/troglobit/mcjoin) as the traffic generator, and it
measures exactly one thing — how many multicast deliveries to
*uninterested* ports the bridge suppresses, compared to the pre-snooping
flood-everywhere baseline. It is supplementary evidence for this project,
not a substitute for the correctness testing (ATF suite,
`scripts/snooping-edge-cases.sh`) that already covers the actual
behavior in depth, and it was **not** included in the Phabricator patch
series itself — it quantifies behavior already proven correct elsewhere,
it doesn't test anything new.

## What it measures

One sender, one real listener (joins the group), and *N* idle ports
(never join) on a single bridge. For each of two conditions — snooping
off, snooping on — the sender transmits a fixed number of packets and:

- the **listener**'s own delivery count is measured via `mcjoin`'s own
  receive/count accounting (the tool Bruce suggested, used as intended);
- each **idle port**'s delivery count is measured via a link-layer
  `tcpdump` packet count on that port's interface, deliberately *not*
  via `mcjoin`'s own join/receive path. This isolates what the bridge
  itself delivers to the wire from any additional filtering an idle
  port's own IP stack might separately apply, which would conflate two
  different layers of suppression and muddy the result.

Full script: `scripts/suppression-benchmark.sh`.

## Building mcjoin on the test VM

The VM's ports tree doesn't carry `net/mcjoin`, and `pkg`/ports have no
usable network path (the VM's DNS forwarder can't resolve external
hosts — an existing, previously-documented constraint of this VM, not
new). `mcjoin`'s actual upstream (github.com/troglobit/mcjoin) was
cloned on the Mac and its `src/` transferred to the VM for a hand
compile, since it has no dependencies beyond libc (verified: no
`PKG_CHECK`/`AC_CHECK_LIB` in `configure.ac`, only standard headers in
every `.c` file) — the only real obstacle was replacing what
`./configure` would normally generate.

### Bug found and fixed: missing `HAVE_STRUCT_SOCKADDR_STORAGE_SS_LEN`

A hand-written `config.h` (autotools' generated header replaced with 4
`PACKAGE_*` string defines) compiled cleanly, but the built binary's
receiver path failed every join with `EINVAL`:

```
Failed * group (239.77.77.1,joining) on sd 5 ... 22: Invalid argument
Failed initializing receiver, return code 1, aborting.
```

Root cause: `mcjoin.c` sets `ss_len` on the group's `sockaddr_storage`
inside `#ifdef HAVE_STRUCT_SOCKADDR_STORAGE_SS_LEN` — a macro a real
`./configure` run auto-detects via `AC_CHECK_MEMBER`, true on FreeBSD
(confirmed directly: `struct sockaddr_storage` in
`/usr/include/sys/_sockaddr_storage.h` has `ss_len` as its first field)
but absent from the hand-written header. Without it, `ss_len` was never
set, and the kernel's `MCAST_JOIN_GROUP` validation in
`sys/netinet/in_mcast.c` rejects a `group_req` whose embedded address
has no length — hence `EINVAL` on every join attempt, on every
interface (an earlier `lo0` smoke test showing the same error was
initially — incorrectly — assumed to be loopback-specific).

Fixed by adding the macro to `config.h`; rebuilt clean, joins then
succeeded (`sent=500 listener_received=500`).

This is a build artifact of hand-replacing `./configure`'s output for a
third-party tool, unrelated to FreeBSD or to any of the 8 patches in
this series — no changes to the patch series follow from it.

## Bug found and fixed: benchmark script itself

Two bugs were found and fixed in `scripts/suppression-benchmark.sh`
while running it, both in the harness, not in what it measures:

1. **Idle-port `tcpdump` had no timeout.** With snooping genuinely
   working (the case under test), idle ports receive zero packets, so
   `tcpdump -c 500` never reaches its target count and hangs
   indefinitely. Fixed by wrapping it in `timeout ${CAPT}`, matching the
   bounded-wait pattern already used for the sender/listener via
   `mcjoin`'s own `-W` flag.
2. **No cleanup on interrupt.** `topo_destroy()` only ran at the natural
   end of the script; killing a hung run (from bug 1, before it was
   fixed) left a full topology — one bridge, six `epair`s — orphaned.
   The next run's fresh `topo_create` then collided with that leftover
   state and produced an all-zeros result that looked like a
   measurement failure. Fixed by adding `stale_cleanup()`, called at the
   start of every run, that removes any jails/bridges/epairs a prior
   interrupted run might have left behind before building a fresh
   topology.

Both fixes are in the script now committed to this repo.

## Result

Configuration: 4 idle ports, 500 packets/run, 500-byte payload, 5ms send
interval (~2.5s/run). Listener joins and the harness waits 1s (well
past the join → IGMP report → MDB-learn round trip, which is
millisecond-scale) before the sender starts, so there is no
join-still-in-flight race affecting the count.

```text
=== Run 1/2: snooping OFF (baseline flood) ===
  sent=500 listener_received=500 idle_total=2000 (across 4 ports) idle_max=500

=== Run 2/2: snooping ON (pruned) ===
  sent=500 listener_received=500 idle_total=0 (across 4 ports) idle_max=0

=== Results ===
Listener delivery:  OFF 500/500   ON 500/500
Idle-port delivery: OFF 2000 total across 4 ports (max 500/port)   ON 0 total (max 0/port)
Suppression ratio: 100% of would-be-flooded idle deliveries avoided
Unnecessary deliveries avoided this run: 2000 packets across 4 idle ports
```

- The real listener received all 500 packets in **both** conditions —
  the one invariant that must never regress: pruning removes only
  uninterested ports, never the real listener. Confirmed unaffected.
- With snooping off, all 4 idle ports received the full 500-packet
  stream each (2000 total) — the pre-patch-series baseline, and exactly
  what the proposal's problem statement describes: "every uninterested
  guest still pays the cost of receiving, filtering, and discarding
  traffic it never joined."
- With snooping on, all 4 idle ports received **zero** — not reduced,
  zero. 2000 unnecessary deliveries avoided in a single ~2.5-second run,
  with zero cost to the real listener.
- The clean 100% (rather than e.g. 97-99%) is a direct consequence of
  the test design, not a suspiciously perfect number: the listener's
  join is given a full second to become real MDB state before any
  traffic is sent, so there is no window where early packets could leak
  through before the MDB catches up.

This scales linearly with idle-port count by construction — each
additional uninterested jail/VM on the bridge pays ~0 instead of the
full flood cost, which is the concrete, measured version of the
project's stated value proposition in VNET/jail-heavy environments.

## What this is not

Not a throughput, latency, or CPU-cost measurement, and not a stress
test at scale. It's a small, controlled demonstration that the
suppression behavior — already proven correct by the ATF suite and the
29-check edge-case suite — actually eliminates the specific class of
waste the project set out to address, in concrete delivery-count terms,
using the tool and framing Bruce asked for.

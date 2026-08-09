# Phabricator Submission Guide

Recorded: 2026-08-08

How to submit the 8-patch series to `reviews.freebsd.org`, following
Joseph's clarification that Phabricator is the concrete venue Bruce meant
by "submit patches in the usual way."

Note: the `arc diff` calls below have to be run by you. Submitting under
your own name to an external community is not something I can or should
do on your behalf; everything here is written to be executed directly.

## Where the work lives

- `/Users/macboookpro/khanh-dev/freebsd-src-main` — the `main`-based tree,
  branch `submission-main`, 8 git commits on top of `main-tip`
  (`86199f1a74ab`, 2026-08-07). This is what `arc diff` runs against.
  It already carries the in-tree `.arcconfig` FreeBSD ships, pointing at
  `reviews.freebsd.org` with callsign `G` — no manual repo config needed.
- `/Users/macboookpro/khanh-dev/freebsd-src` — the original `stable/14`
  tree, untouched.
- This companion repo (`docs/`, `patches/`) — implementation notes, VM
  test results, and the edge-case suite. Reference material for when
  reviewers ask how something was tested.

## One-time setup

### 1. Install Arcanist

There is no straightforward package-manager install on macOS. The usual
route is cloning from Phacility directly:

```sh
mkdir -p ~/tools && cd ~/tools
git clone https://github.com/phacility/arcanist.git
git clone https://github.com/phacility/libphutil.git
```

(Recent Arcanist bundles `libphutil`; the second clone is only needed for
older versions. Cloning it anyway is harmless.)

Add `arc` to your `PATH` (in `~/.zshrc` or equivalent):

```sh
export PATH="$HOME/tools/arcanist/bin:$PATH"
```

Verify: `arc help` should print usage.

### 2. Get a FreeBSD Phabricator account and link `arc`

1. Register/log in at `https://reviews.freebsd.org/` in a browser.
2. From `freebsd-src-main`, run:

   ```sh
   cd /Users/macboookpro/khanh-dev/freebsd-src-main
   arc install-certificate
   ```

   It prints a URL to open; the page generates an API token that you paste
   back at the prompt. The token is stored in `~/.arcrc` and covers all
   later `arc diff` calls.

## Submitting the stack

Each commit becomes one Differential Revision. Submit oldest first so each
revision can declare the one before it as a dependency:

```sh
cd /Users/macboookpro/khanh-dev/freebsd-src-main
git log --oneline main-tip..submission-main   # confirm the 8, oldest last
```

For the **first** (oldest) commit:

```sh
git checkout 97ac9f96e   # "if_bridge: add group_fwd_mask ioctl..."
arc diff main-tip
```

`arc` opens an editor with a template. Paste in the Summary and Test Plan
for that patch from the per-revision sections below, add `Reviewers: bms`
(confirm the exact handle against his Phabricator account first), then save
and close. `arc` prints the new revision URL (`D<N>`).

For **each subsequent** commit, diff against the previous commit rather
than `main-tip`:

```sh
git checkout ecc35d552   # patch 2
arc diff 97ac9f96e
```

...repeating through all 8.

To express the stack, add a line

```text
Depends on D<N>
```

to the revision's Summary, naming the revision created for the previous
commit. Phabricator parses this and links the stack. Some Arcanist versions
also accept `arc diff --depends-on D<N>`; if yours does, it does the same
thing. Failing both, set "Depends On" from the revision's web UI after
creation.

## Per-revision Summary / Test Plan text

Each block below is ready to paste into `arc diff`'s editor. Supporting
detail is in this repo's `docs/patchN-*-implementation.md` and
`docs/patchN-*-test-result.md`.

**Progress: all 8 revisions filed (2026-08-08 through 2026-08-09).**
D1 → https://reviews.freebsd.org/D58729 (summary added via web UI edit
after the fact). D2 → https://reviews.freebsd.org/D58730. D3 →
https://reviews.freebsd.org/D58731. D4 → https://reviews.freebsd.org/D58732.
D5 → https://reviews.freebsd.org/D58744. D6 → https://reviews.freebsd.org/D58745.
D7 → https://reviews.freebsd.org/D58746. D8 → https://reviews.freebsd.org/D58747.
Each commit gets amended by `arc diff` (adds `Subscribers:`/
`Differential Revision:` trailers), which changes its hash and requires
rebasing everything still ahead of it in the stack — the hashes below are
the final, post-amend ones. D57559, a stale duplicate of D2 from an
earlier attempt, was found and abandoned.

Parent-revision links across the entire chain (D1→D2→D3→D4→D5→D6→D7→D8)
are confirmed real via the Conduit API (`edge.search` with
`revision.parent`/`revision.child` edge types, not just the cosmetic
"Depends on Dxxx" prose text — see the note below). D1-D4's links were
set explicitly via the "Edit Parent Revisions" UI dialog; D4→D5 through
D7→D8 turned out to be linked automatically, apparently because each
`arc diff <parent-hash>` picked up the `Differential Revision:` trailer
already present on the parent commit and set the dependency itself.

Reviewers: only D1 has `bms` attached. Adding him to D2-D8 is deferred by
choice to whenever the submitter is ready — not a blocker on anything
above.

---

### D1 — group_fwd_mask (`97ac9f96e`)

**Summary:**
Adds a `group_fwd_mask` control to `if_bridge(4)` (new `BRDGGFWDMASK`/
`BRDGSFWDMASK` ioctls, exposed as `ifconfig bridge0 group_fwd_mask
<mask>`), modeled after the Linux bridge control of the same name. The
mask selects which of the reserved link-local multicast MAC destinations
(`01:80:C2:00:00:0x`) the bridge forwards rather than filters. The
default is unchanged and conservative: no reserved groups are forwarded
unless an operator opts in.

This is the smallest change in the series and touches only the bridge's
ioctl control surface. The multicast snooping work follows in D2-D8.

**Test Plan:**
`group_fwd_mask` ATF test covers get/set and bounds checking. Manual VNET
test confirms selected link-local traffic is forwarded only when the mask
is explicitly widened, and filtered by default. Kernel built and booted on
both `stable/14` and current `main` (2026-08-07); ATF passes on both.

---

### D2 — MDB foundation (`ecc35d552`)

**Summary:**
Adds the multicast database (MDB) data structures to `if_bridge(4)`:
`struct bridge_mdb_entry` and `struct bridge_mdb_member`, keyed by
`(VLAN, multicast group)` rather than by the mapped Ethernet MAC alone, so
distinct IP groups sharing an L2 destination are not conflated. Includes
the aging callout scaffolding and the member-detach cleanup path.

No learning or forwarding behavior yet; this patch establishes the data
model only. Also adds a VNET topology helper,
`bridge_mdb_vnet_topology_create`, reused by every subsequent patch's tests.

**Test Plan:**
`mdb_vnet_topology` ATF test exercises the topology helper. No forwarding
behavior changes at this stage, so there is no forwarding-path test.
Built and booted on both bases; ATF passes.

---

### D3 — IPv4 IGMP listener learning (`e6da718fa`)

**Summary:**
Parses IGMPv1/v2/v3 membership reports in the bridge forward path and
populates the MDB from them. Lengths and headers are validated before
parsing. IGMPv3 records are accepted only where they reduce to ASM `(*,G)`
interest — at this stage, an EXCLUDE-mode record with an empty source list;
D7 widens this. Parse failures and unsupported record types create no state.

The MDB is populated but not yet consulted; forwarding is unchanged.

**Test Plan:**
`mdb_unknown_multicast_flood` ATF test confirms flood fallback is
unaffected by the new learning path. Built and booted on both bases; ATF
passes.

---

### D4 — MDB-aware forwarding (`66ec06b84`)

**Summary:**
IPv4 multicast data frames now perform an MDB lookup keyed by
`(VLAN, group)` before replication. On a hit with positive listener state,
delivery is pruned to the interested ports. On a miss, a parse failure, or
any other uncertainty, the bridge floods exactly as it did before this
series. Pruning is subordinate to positive listener state and is never the
default.

**Test Plan:**
`mdb_selective_forward` ATF test: a joined listener receives the group; an
uninterested port on the same segment does not. Built and booted on both
bases; ATF passes.

---

### D5 — igmp_snooping knob and counters (`3d5f1461c`, filed as D58744)

**Summary:**
Adds the `net.link.bridge.igmp_snooping` runtime enable knob, default off —
everything added in D2-D4 is inert until it is set — and five counters:
`mdb_entries`, `mdb_prune_hits`, `mdb_flood_fallback`, `mdb_parse_reject`,
`mdb_expired`. Writing zero resets a counter. This makes learned state and
fallback behavior inspectable without a packet capture.

**Test Plan:**
`mdb_counters` ATF test exercises all five counters advancing under traffic
and resetting on write. Manual check of the default-off to explicit-on
transition, which no ATF test covers. Full bridge regression at this point
in development: 20/22, with 2 skips for missing `scapy` on the test VM.
Built and booted on both bases; ATF passes.

---

### D6 — router-port learning (`3af2e81cd`, filed as D58745)

**Summary:**
Learns multicast-router ports from observed IGMP membership queries
(`struct bridge_mdb_router`, keyed by VLAN, aged independently of listener
state) and extends the forwarding path to deliver learned groups to
listener ports and to router ports on the same VLAN, so pruning does not
blackhole traffic a router needs to relay. Adds the `mdb_routers` counter.

Router forwarding is additive: it can only add destinations to a frame that
was already going to be pruned, never remove one. With no router ports
learned, delivery is unchanged from D4.

**Test Plan:**
`mdb_router_forward` ATF test: in a 4-jail topology, a router port (queries
seen, no join) receives a learned group while a genuinely idle port stays
pruned. Two bugs were found and fixed during VM verification, both in the
test scaffolding rather than the kernel change: a missing `<sys/types.h>`
include and a missing multicast route for the router jail — account in
`docs/patch6-router-port-test-result.md`. Full regression 21/23 after
those fixes, +1 over D5. Built and booted on both bases; ATF passes.

---

### D7 — conservative IGMPv3 ASM refinement (`468c9551c`, filed as D58746)

**Summary:**
Widens the IGMPv3 record handling from D3, which created `(*,G)` state only
for EXCLUDE-mode records with an empty source list. Any record expressing
positive interest now creates or refreshes `(*,G)` state: EXCLUDE with any
source list, and INCLUDE-family or `ALLOW_NEW_SOURCES` with a non-empty
list. Revocation-only records (`BLOCK_OLD_SOURCES`, and the empty-list
`TO_IN` that constitutes the IGMPv3 leave) still drive no state change and
are left to the existing aging path, matching IGMPv2 leave handling.

Before this change, a legitimate source-specific (SSM-style) join produced
a record class the bridge ignored, so that listener's traffic could be
pruned away entirely once another port made the group known to the MDB.

The reduction is to `(*,G)` only; source lists are never used to narrow
delivery, so a source-specific joiner receives a superset of what it asked
for. Per-source (SSM) forwarding fidelity remains deferred.

**Test Plan:**
`mdb_igmpv3_source_join` ATF test uses `IP_ADD_SOURCE_MEMBERSHIP` (a
genuine INCLUDE-mode record) and confirms state creation and correct
delivery. Manual check of the leave path: state survives the joiner's
departure rather than being removed eagerly. Full regression 22/24, +1 over
D6. Built and booted on both bases; ATF passes.

---

### D8 — link-local 224.0.0.0/24 exemption (`3e9e28c04`, filed as D58747)

**Summary:**
Neither the learn path nor the forward path excluded the link-local
`224.0.0.0/24` block, which RFC 4541 §2.1.1 requires always be flooded and
never snooped. Under FreeBSD's own default (`net.inet.igmp.sendlocal=1`)
hosts do emit IGMP reports for groups in this range — mDNS's
`224.0.0.251`, for instance — so the bridge would learn state from one
reporting host and prune the group to that port alone, silently dropping it
for every other listener that had suppressed its own report under normal
IGMPv2 report suppression.

Fixed with two independent guards, one learn-side and one forward-side, so
MDB state carried over from a pre-fix kernel cannot prune control traffic
after an upgrade either.

Found by an edge-case suite in this series' companion repo
(`scripts/snooping-edge-cases.sh`) written after the core ATF coverage was
otherwise complete — not by inspection or by an ATF regression.

**Test Plan:**
`mdb_link_local_exempt` ATF test: joining `224.0.0.251` creates no MDB
state, and an uninterested port continues to receive the traffic. The
edge-case suite (29 checks; `docs/edge-case-test-suite.md` describes what
each verifies, including two bugs found and fixed in the test script
itself) passes 29/29 after this fix. Full ATF regression 23/25 on
`stable/14`, +1 over D7. Re-confirmed against current `main`
(`docs/main-rebase-verification.md`): all of this series' own tests pass
individually within a 36-test run. The 11 unrelated failures in that run
are diagnosed as pre-existing userland staleness on the test VM against
upstream's own new VLAN-filtering feature, not a regression from this
series.

---

## A note for the cover context (D1's description, or a reply)

Worth stating up front, either as an addendum to D1 or in the
revision-linking comment: this is a from-scratch IGMP snooping
implementation for `if_bridge(4)`, developed and tested as a small
sequential series. The core IPv4 ASM path is D1-D5. D6-D8 are the stretch
items: router-port learning, IGMPv3 ASM refinement, and a bug the
edge-case suite caught. IPv6/MLD is out of scope for this series and
deferred. Full history, test plans, and VM verification logs for every
patch are in the project's public companion repository, which can be
linked if useful context for reviewers.

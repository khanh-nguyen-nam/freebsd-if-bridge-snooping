# Improving Network Efficiency With `if_bridge(4)` IGMP/MLD Snooping

Source: `/Users/macboookpro/Downloads/proposal_khanh_final.pdf`

## General Information

- Name: Khanh Nguyen
- Email: namkhanh052005@gmail.com
- IM/IRC: nkhanh on Libera.Chat
- Availability: I am budgeting the standard ~175 hours for this medium-sized
  project across the extended GSoC schedule. That works out to roughly 8-12
  focused hours per week on average, with flexibility to spend more during
  implementation-heavy or review-heavy weeks. I am taking one light summer
  class requiring about 5 hours a week, but have no full-time job or major
  vacations planned.

## Biography

I am a junior student at Purdue University pursuing a Bachelor of Science in
Computer Engineering. I have a strong focus on systems programming, operating
systems, and advanced networking. I bring a solid foundation in C and low-level
development to this project.

Previously, I designed a MAC layer to parse Ethernet, IP, and UDP headers for
hardware level packet decoding, and developed a SLIP (Serial Line Internet
Protocol) framework for real-time IP over UART communication (improving
throughput by 8%). My experience writing bare-metal C for STM32
microcontrollers and migrating firmware to RTOS environments has equipped me
with the debugging and architecture skills necessary for kernel-level
development.

For this project, the areas I most want to deepen are FreeBSD's bridge
synchronization model, safe mbuf parsing in the forwarding path, and the
protocol details of modern multicast listener tracking, especially the gap
between ASM-safe snooping and full IGMPv3/MLDv2 source filtering.

I have already studied the high-level structure of `sys/net/if_bridge.c`,
`sys/net/if_bridge.h`, and the multicast code in `sys/netinet` and
`sys/netinet6`, and I want to turn that reading into a small, reviewable
sequence of patches.

I plan to do all project work in a public git repository, send small patch
series instead of one large late drop, and keep short written progress notes so
mentors and reviewers can follow the work without relying on private or
proprietary document workflows.

Technical skills and environment:

- OS/environment: FreeBSD 14.0, Linux/Unix, Vim, GDB Debugger.
- Version control: I am highly comfortable using Git for version control and
  patch management.
- Languages and tools: Proficient in C/C++, Python, Bash. Experienced with
  oscilloscopes, logic analyzers, and x86_64/ARM boards.
- Relevant knowledge: I am familiar with the concepts behind IEEE 802.1d MAC
  bridges and IP multicast routing. I have studied the `sys/net/if_bridge.c`
  and `sys/net/if_bridge.h` codebases, the IP multicast implementations in
  `sys/netinet` and `sys/netinet6`, and reviewed RFC 3376 (IGMPv3), RFC 3810
  (MLDv2), and IEEE 802.1Q-2022.

To complete this project successfully, I anticipate needing to deepen my
understanding of the specific locking mechanisms within the FreeBSD network
stack to ensure high performance and concurrency safe kernel modifications.

## Project Information

### Project Title

`if_bridge(4)` IGMP/MLD Snooping

### Project Description

FreeBSD's `if_bridge(4)` already learns unicast destinations, but multicast is
still handled conservatively: multicast and broadcast traffic are forwarded to
all bridge member ports. In virtualized, VNET, or jail-heavy environments,
every uninterested guest still pays the cost of receiving, filtering, and
discarding traffic it never joined.

My goal is to reduce that unnecessary work by teaching `if_bridge(4)` to infer
listener location from IGMP and MLD control traffic and to prune forwarding only
when that listener state is positively known.

I want to implement this as a snooping bridge, not as a multicast router. The
bridge should keep current flooding behavior for unknown multicast, non-IP
multicast, and exempt link-local control traffic. Pruning should happen only
when the bridge has positive receiver state for a multicast group on a bridge
port.

The design has three main pieces.

First, I will add an introductory patch: a `group_fwd_mask` sysctl in the
bridge driver modeled after the Linux bridge control. This is intentionally a
self-contained starter task. It exercises the handling of reserved multicast
MAC destinations in the bridge, gives mentors something small and reviewable
early, and lets me learn the bridge control surface before modifying the
multicast forwarding path.

Second, I will add an internal multicast database (MDB) to `if_bridge(4)`. The
MDB will track which ports have expressed interest in which multicast groups,
together with expiry state. To match bridge forwarding semantics, the MDB will
be keyed by (VLAN, multicast group) rather than just the destination MAC
address. For IP multicast, keying only on the mapped Ethernet multicast MAC
would conflate distinct IP groups that share the same Layer 2 destination and
would cause false positives. Using `(VID,G)` keeps the design correct and makes
the forwarding decision match the actual IP group seen in the packet.

Third, I will modify the existing multicast forwarding path so that the bridge
consults the MDB before replicating packets to all member ports. I expect IGMP
control handling to hook into the `bridge_input()`/`bridge_forward()` path and
pruning to land in the multicast path that currently reaches
`bridge_broadcast()`. For candidate IPv4 multicast frames, the bridge will
identify VLAN context and destination multicast group, perform an epoch-safe MDB
lookup, and keep the current flood behavior on any miss or uncertainty. Only an
MDB hit with positive listener state will prune to interested ports; until
router-port learning exists, router uncertainty will also fall back to flooding.

My minimum viable project is intentionally narrower than "full IGMP/MLD
snooping in one summer." The core deliverable is a reviewable, testable IPv4
implementation: `group_fwd_mask`, MDB infrastructure, IGMP-based listener
learning, and forwarding-path pruning for IPv4 multicast, while preserving flood
behavior for unknown or exempt traffic. IPv6/MLD support is planned only after
the IPv4 path is correct, reviewable, and tested.

## MVP Protocol Semantics And Safety Invariants

For the MVP, listener learning will target IPv4 ASM semantics first.

- IGMPv1 and IGMPv2 membership reports will create or refresh `(*,G)` listener
  state for the ingress bridge port.
- IGMPv2 Leave processing will be conservative: if immediate deletion is risky
  in a shared-port scenario, I will prefer timer-based aging over aggressive
  eager pruning.
- IGMPv3 membership reports will be parsed, but the MVP will use only records
  that can be safely reduced to ASM-style `(*,G)` interest. Records that
  clearly mean "receive this group from all sources" can create or refresh
  `(*,G)` state; source-specific or ambiguous records will not drive pruning in
  the MVP.
- If an IGMPv3 record cannot be reduced safely to ASM listener state, the bridge
  will keep flooding for that group rather than guess.

The forwarding invariant for the MVP is:

1. Determine VLAN context for the frame.
2. If the frame is non-IP multicast or an exempt link-local/control
   destination, preserve legacy flooding.
3. If the frame carries IGMP control traffic, parse conservatively and update
   MDB state on the write side.
4. If the frame carries IPv4 multicast data, perform an epoch-safe `(VID,G)`
   lookup.
5. On an MDB miss, parse failure, unsupported record, or any other uncertainty,
   flood exactly as today.
6. On an MDB hit, forward only to ports with positive listener state, plus
   router ports later, if that logic is added safely.

This keeps pruning subordinate to positive listener state.

## Goals And Non-Goals

Core goals:

1. Add a reviewable `group_fwd_mask` sysctl patch for `if_bridge(4)`.
2. Add MDB infrastructure keyed by (VLAN, multicast group).
3. Learn IPv4 multicast listener state from IGMP control traffic.
4. Prune IPv4 multicast forwarding to interested bridge ports when positive
   listener state exists.
5. Preserve current flood behavior for unknown multicast and exempt
   control-plane traffic.
6. Deliver a documented VNET topology and at least one ATF/Kyua smoke test for
   the IPv4 path.

Explicit non-goals for the core proposal:

1. Implementing a full multicast router or PIM in the bridge.
2. Requiring snooping to be enabled for correctness of ordinary bridge
   forwarding.
3. Depending on an in-bridge querier for the MVP to function.
4. Reworking non-IP multicast handling beyond the `group_fwd_mask` starter
   patch.
5. Promising complete IGMPv3/MLDv2 source-filter semantics before the IPv4 ASM
   path is solid.

## Control Surface And Observability

For the MVP, I want the runtime control surface to stay simple. The introductory
`group_fwd_mask` work will use a bridge-driver sysctl, and the snooping path
will ship with a default-off runtime enable knob following existing bridge
control style.

I also want a small set of read-only counters so reviewers can inspect behavior
without depending only on packet captures.

- Current MDB entry count.
- Prune-hit count.
- Flood-fallback count.
- Parse/reject count for malformed or unsupported control traffic.
- Listener expiration count.

This gives reviewers a concrete way to inspect both learned state and fallback
behavior.

## Implementation Plan

### 1. Introductory `group_fwd_mask` Patch

I will start with a small patch that adds a bridge-driver `group_fwd_mask`
sysctl to control forwarding of selected reserved multicast MAC destinations.
The patch will be deliberately modest in scope:

- Add the sysctl and bridge-internal plumbing.
- Document the mask and reserved bits.
- Confirm the default remains standards-conservative.
- Add a simple manual test showing that selected link-local traffic can be
  widened only when explicitly requested.

This gives an early standalone deliverable and reduces risk by getting one
patch through review before the more invasive snooping changes begin.

### 2. MDB Structures And Lifetime Rules

I will then add MDB data structures in `sys/net/if_bridge.h` for multicast group
state. At a minimum, each MDB entry will carry:

- Address family.
- VLAN ID.
- Multicast group address.
- Interested-port state.
- Expiration state.
- Enough bookkeeping to remove stale membership safely during timer expiry and
  bridge member detach.

Write-side modifications will happen under the bridge's existing serialized
write-side synchronization. Read-mostly forwarding lookups will be designed for
NET_EPOCH, matching the bridge's current read-side model.

I expect the most error-prone cases to be timer expiry, member detach, and any
transition from positive listener state back to fallback flooding, so I will
make those code paths explicit in both the patch structure and the test plan.

### 3. IGMP Parsing And State Updates

The first protocol implementation will be IPv4 IGMP. For candidate IGMP frames,
I will:

- Identify IPv4 frames in the bridge receive/forward path.
- Ensure the needed IP and IGMP headers are contiguous before parsing.
- Validate lengths and reject malformed or truncated packets conservatively.
- Extract the destination group and report type.
- Update the MDB from reports and expiry events.

For the MVP, I will focus on ASM-safe listener learning rather than full
source-filter fidelity. The priority is correct creation, refresh, and expiry
of `(*,G)` state while treating unsupported or ambiguous source-filter records
as a reason to preserve flooding.

### 4. Forwarding-Path Pruning

Once MDB state is available, I will modify multicast forwarding so that IPv4
multicast data packets perform an MDB lookup keyed by (VLAN, group). The
forwarding rules for the MVP will be:

- Unknown multicast: flood exactly as today.
- Known exempt control traffic: bypass snooping and flood exactly as today.
- Known receiver state: send only to interested ports.
- Non-IP multicast: keep existing bridge behavior.
- Unsupported or ambiguous control-plane state: keep safe flood behavior until
  the bridge has positive listener state it can trust.

This keeps pruning tied to positive state rather than speculation.

### 5. Testability, Observability, And Documentation

As soon as the IPv4 path is functioning, I will wire in read-only counters and
start documenting the test workflow in parallel with coding. I want reviewers to
be able to answer three questions quickly:

1. What state did the bridge learn?
2. When did it prune?
3. When did it correctly fall back to flooding?

In the same phase, I will begin drafting the `if_bridge(4)` man-page changes so
that new knobs and behavior are documented before the final patch series is
assembled.

### 6. IPv6 / MLD Phase

After the IPv4 path is working and reviewable, I will extend the same
architecture to IPv6 multicast listener discovery. This phase will include:

- Identifying IPv6 multicast frames eligible for snooping.
- Parsing MLD carried over ICMPv6.
- Conservative handling of the extension-header walk needed to reach MLD.
- Adding IPv6 MDB entries using the same (VLAN, group) model.
- Validating that IPv6 link-local and Neighbor Discovery related traffic are
  not broken by pruning.

If IPv6 turns out to be too risky to finish cleanly within the summer, I will
keep the IPv4 implementation review-ready and document the remaining IPv6 work
rather than destabilize the project by forcing incomplete MLD support.

## Deliverables

### Deliverable 1: `group_fwd_mask` Patch

- Bridge-driver `group_fwd_mask` sysctl.
- Documentation of the mask and conservative defaults.
- Manual validation that selected link-local traffic can be widened
  intentionally.

### Deliverable 2: MDB Core And IPv4 Listener Tracking

- `if_bridge(4)` MDB structures added.
- VLAN-aware multicast membership tracking.
- Timer-based expiration for stale listener state.
- Reviewable patch series for IGMP-based membership learning.

### Deliverable 3: IPv4 Multicast Pruning

- Multicast forwarding path updated to consult MDB.
- Unknown multicast retains today's flood behavior.
- Positive membership state prunes replication to uninterested ports.
- Manual VNET test matrix demonstrating suppression on uninterested ports.

### Deliverable 4: Hardening, Tests, And Documentation

- At least one ATF/Kyua VNET smoke test that exercises listener-state creation,
  delivery to an interested port, and zero delivery to an uninterested port.
- Updated `if_bridge(4)` man page documenting the new behavior and knobs.
- Review-driven cleanup, bug fixes, and observability counters.

### Stretch Deliverables

- Conservative IGMPv3 ASM-equivalent bookkeeping beyond the MVP subset.
- Conservative router-port learning from IGMP/MLD queries.
- IPv6 MLDv1/v2 listener tracking and pruning.

## Test Plan

This project should be judged primarily on correctness and protocol conformance,
not on raw throughput benchmarks. The key validation is suppression: proving
that a port that did not join does not receive a given multicast stream.

### Test Environment

I will build deterministic VNET jail topologies using `epair(4)` interfaces and
a single `if_bridge(4)` instance. The baseline topology will have:

- One sender jail.
- One interested receiver jail.
- One uninterested receiver jail.
- Optionally one router/querier jail for control-plane tests.

A second topology will add VLAN tagging so that membership learned on one VLAN
can be shown not to affect forwarding on another VLAN.

Because `if_bridge(4)` can interact with bridge/member filtering paths, each
test run will pin the relevant bridge packet-filter settings to a documented
baseline before traffic capture. In particular, I will record the settings for
`net.link.bridge.pfil_member`, `net.link.bridge.pfil_bridge`,
`net.link.bridge.pfil_onlyip`, and `net.link.bridge.ipfw` so packet visibility
is deterministic and reviewable.

### Traffic Generation And Observation

I will use `ports/net/mcjoin` to generate joins, leaves, and multicast traffic
for ASM tests first, and later for any higher-level IGMPv3/MLDv2 work that fits
inside the schedule. I will use `tcpdump` on each member interface to confirm
exactly which ports receive multicast frames before and after snooping is
enabled.

### Core Correctness Assertions

1. With snooping disabled, multicast traffic is flooded to all member ports
   exactly as it is today.
2. With snooping enabled but no MDB entry present, multicast traffic is still
   flooded.
3. After a valid join on one port, only that receiver port receives the
   multicast stream; an uninterested jail captures zero multicast frames for the
   tested group.
4. After listener expiry or membership teardown, the bridge returns to safe
   fallback behavior rather than blackholing traffic.
5. Exempt link-local or control groups, for example IPv4 `224.0.0.0/24`
   traffic, are not pruned.
6. Repeated join/leave/member-add/member-remove cycles do not leak MDB state or
   trigger use-after-free bugs.

### Automated Testing

I will deliver at least one ATF/Kyua VNET smoke test for the IPv4 path. The
smoke test will exercise:

- Creation of listener state from control traffic.
- Forwarding to one interested port.
- Zero delivery to one uninterested port.
- Return to safe fallback behavior after state teardown or expiry.

The full multicast conformance matrix will remain mostly manual, but even one
automated VNET test is valuable as a non-regression guard.

## Project Schedule: Extended Timeline

I am proposing this as a medium-sized project on the extended GSoC timeline. The
extended schedule is not meant to expand the MVP without bound; it is meant to
leave room for review, iteration, and kernel-networking risk while keeping the
core deliverable focused.

### Community Bonding: May 1 - May 24

- Finalize the build and VNET test environment.
- Set up the public git repository and short-form project notes.
- Read through `if_bridge(4)` forwarding and synchronization paths in detail.
- Write a short design note describing the proposed MDB layout, safety
  invariants, and control surface.

### Weeks 1-2

- Implement the `group_fwd_mask` sysctl patch.
- Write a small manual test procedure and send the patch for review.

### Weeks 3-5

- Add MDB structures and helper routines.
- Add timer/callout scaffolding and member-cleanup logic.
- Build the VNET test-topology scripts.

### Weeks 6-8

- Implement IPv4 IGMP parsing for the MVP feature set.
- Update MDB on joins, refreshes, and expirations.
- Validate that unknown-multicast flood fallback remains intact.

### Weeks 9-11

- Modify the forwarding path to consult MDB for IPv4 multicast.
- Demonstrate that uninterested ports see zero packets in the manual topology.
- Begin wiring in counters and writing man-page notes.

### Midterm Checkpoint

At midterm I expect to have:

- The introductory `group_fwd_mask` patch completed.
- MDB infrastructure in tree or under active review.
- IPv4 IGMP membership learning working.
- Initial IPv4 multicast pruning working in the manual testbed.

### Weeks 12-14

- Harden the IPv4 path based on review feedback.
- Add the ATF/Kyua VNET smoke test for the IPv4 MVP.
- Continue observability and documentation work.

### Weeks 15-17

- Investigate conservative IGMPv3 ASM-equivalent handling and router-port
  learning.
- Continue review iterations and cleanup.
- Decide whether IPv6 work can begin without jeopardizing the IPv4 core
  deliverable.

### Weeks 18-22

- Implement IPv6 MLD support if the IPv4 path is stable enough.
- Otherwise use this time for hardening, documentation, test expansion, and
  upstreaming of the IPv4 implementation.
- Finalize man-page updates and prepare patches for submission.

## Risks And Mitigations

### Risk 1: Scope Creep From Trying To Do Too Much IGMPv3/MLDv2 At Once

Mitigation: keep IPv4 ASM snooping as the non-negotiable MVP. Treat source
filtering, router-port learning, and IPv6 MLD as later phases or stretch work.

### Risk 2: Unsafe Object Lifetime In MDB Teardown And Timer Expiry

Mitigation: match the bridge's existing epoch/read-side model, keep writes
serialized, and stress join/leave/member-detach loops early in testing.

### Risk 3: Blackholing Multicast By Pruning Too Aggressively

Mitigation: preserve existing flood behavior for unknown multicast, exempt
groups, malformed control traffic, and unsupported/ambiguous source-filter
state. Only prune when positive listener state exists.

### Risk 4: Review Delays On A Large Patch Series

Mitigation: split the work into small reviewable patches: `group_fwd_mask`, MDB
core, IGMP listener learning, forwarding-path pruning, tests, and documentation.

## Communication And Openness

I will avoid private or proprietary document workflows where possible. The
project will be tracked in a public git repository with short written progress
notes. I will send small reviewable patch series rather than one large late
patch, and I will keep the manual and automated test procedures reproducible so
that mentors and other developers can validate the work independently.

## Expected Outcome

The expected core outcome is a reviewable `if_bridge(4)` enhancement that can
learn IPv4 multicast listener state from IGMP and use that state to prune Layer
2 multicast delivery to uninterested bridge ports without changing the safe
fallback behavior for unknown or exempt traffic.

If time and review progress allow, the project will also deliver IPv6 MLD
support and conservative router-port or IGMPv3 refinements, but the IPv4 ASM
core remains the main success criterion.

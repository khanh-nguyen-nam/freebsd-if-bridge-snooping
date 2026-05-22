# Reading List

This note captures the minimum file set to understand both the coordination repo and the upstream FreeBSD code involved in the `if_bridge(4)` IGMP/MLD snooping project.

## Project context

Read these first:

1. `README.md`
2. `AGENT.md`
3. `dev-notes/session-bootstrap.md`
4. `dev-notes/progress.md`
5. `dev-notes/tasks.md`
6. `docs/design/bridge-mdb-overview.md`
7. `docs/test-plan.md`
8. `src/README.md`
9. `scripts/setup-freebsd-worktree.sh`
10. `tests/README.md`
11. `tests/atf/README.md`
12. `tests/vnet/README.md`

Why this order:

- `README.md` defines scope, milestones, and repo layout.
- `AGENT.md` defines working rules and note hygiene.
- `dev-notes/` captures current project state and open tasks.
- `docs/design/bridge-mdb-overview.md` defines the current MDB and snooping model.
- `docs/test-plan.md` defines the target behavioral assertions.
- `src/README.md` maps this coordination repo to the upstream FreeBSD tree.
- `scripts/setup-freebsd-worktree.sh` captures the intended upstream workflow and search strategy.
- `tests/` notes show the intended validation structure.

## Upstream FreeBSD code

Read these next inside the sibling FreeBSD source tree:

1. `../freebsd-src/sys/net/if_bridgevar.h`
2. `../freebsd-src/sys/net/if_bridge.c`
3. `../freebsd-src/tests/sys/net/if_bridge_test.sh`
4. `../freebsd-src/tests/sys/netgraph/bridge.c`
5. `../freebsd-src/sbin/ifconfig/ifbridge.c`
6. `../freebsd-src/lib/libifconfig/libifconfig_bridge.c`

Why these matter:

- `if_bridgevar.h` defines bridge-facing data structures, flags, and ioctls.
- `if_bridge.c` is the main bridge implementation, including locking, member lifecycle, forwarding, and ioctl handling.
- `if_bridge_test.sh` is the existing ATF coverage for `if_bridge`.
- `tests/sys/netgraph/bridge.c` is not `if_bridge`, but it helps with baseline bridge behavior expectations around learning and flooding.
- `sbin/ifconfig/ifbridge.c` shows the userland control surface for bridge ioctls.
- `libifconfig_bridge.c` shows the programmatic bridge configuration path.

## Second-pass protocol and interface files

Read these when moving from bridge mechanics into snooping implementation details:

1. `../freebsd-src/sys/net/if_var.h`
2. `../freebsd-src/sys/net/if_vlan_var.h`
3. `../freebsd-src/sys/net/ethernet.h`
4. `../freebsd-src/sys/netinet/ip.h`
5. `../freebsd-src/sys/netinet/igmp.h`
6. `../freebsd-src/sys/netinet6/ip6.h`
7. `../freebsd-src/sys/netinet6/icmp6.h`
8. `../freebsd-src/sys/netinet6/mld6.h`

## Current tree corrections

The earlier project notes mention files that do not exist in the current sibling `freebsd-src` checkout:

- `sys/net/if_bridge.h`
- `share/man/man4/if_bridge.4`

For this checkout, the current relevant bridge entry points are:

- `sys/net/if_bridgevar.h`
- `sys/net/if_bridge.c`
- `sbin/ifconfig/ifbridge.c`
- `lib/libifconfig/libifconfig_bridge.c`

Update this note if the FreeBSD tree layout changes or if upstream adds dedicated snooping-related files.

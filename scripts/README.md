# Scripts

Shell helpers for building the test environment and exercising manual VNET validation.

Current scripts:

- `freebsd-env.sh` load stable paths and helper aliases for the sibling FreeBSD tree
- `setup-freebsd-worktree.sh` print a concrete FreeBSD `src` checkout workflow and prioritized reading list
- `create-vnet-topology.sh` build the baseline jail and `epair(4)` topology
- `run-igmp-smoke.sh` run a minimal manual IPv4 multicast validation flow

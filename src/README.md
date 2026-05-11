# Source Scope

This repository does not vendor the FreeBSD kernel tree.

Instead, it tracks:

- design notes about expected upstream changes,
- test and review artifacts,
- exported patch series against an external FreeBSD source checkout.

Primary upstream files expected to change:

- `sys/net/if_bridge.c`
- `sys/net/if_bridge.h`
- `share/man/man4/if_bridge.4`
- `tests/sys/net/if_bridge/` or nearby ATF/Kyua coverage

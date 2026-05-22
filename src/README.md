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

Recommended first reading pass:

1. `sys/net/if_bridge.h`
2. `sys/net/if_bridge.c`
3. `share/man/man4/if_bridge.4`

Recommended second reading pass:

1. `sys/net/if.c`
2. `sys/net/if_var.h`
3. `sys/net/if_vlan_var.h`
4. `sys/net/ethernet.h`
5. `sys/netinet/ip.h`
6. `sys/netinet/igmp.h`
7. `sys/netinet6/ip6.h`
8. `sys/netinet6/icmp6.h`
9. `sys/netinet6/mld6.h`

Important directories to inspect:

- `tests/sys/net/`
- `sys/modules/if_bridge/`
- `sys/netinet/`
- `sys/netinet6/`
- `share/man/man9/`

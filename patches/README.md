# Patches

- `0001-if-bridge-group-fwd-mask.patch`: Deliverable 1 patch for FreeBSD `if_bridge(4)`.
- `0002-if-bridge-mdb-foundation.patch`: Incremental MDB structures, cleanup callout scaffolding, and VNET topology test patch. Apply after `0001`.
- `0003-if-bridge-ipv4-igmp-learning.patch`: Incremental IPv4 IGMP listener learning and unknown multicast flood fallback test. Apply after `0002`.
- `0004-if-bridge-mdb-forward.patch`: Incremental MDB-aware IPv4 multicast forwarding; prunes learned groups to listener ports only, falls back to flood for unknown groups, adds `mdb_selective_forward` ATF test. Apply after `0003`.

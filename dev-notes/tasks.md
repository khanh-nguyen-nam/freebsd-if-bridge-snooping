# Tasks

- choose the target FreeBSD branch for development: `main` or a `stable/*` branch
- clone the external FreeBSD `src` tree into a user-approved path
- read `sys/net/if_bridge.[ch]` and annotate forwarding and locking paths
- identify the exact test directory and existing bridge-related ATF coverage in `tests/sys/net/`
- draft the first design decision for MDB shape and lifetime rules

# Session Bootstrap

Use this file to start a new chat with the minimum project memory needed to continue work efficiently.

## Files to read first

- `AGENT.md`
- `README.md`
- `dev-notes/progress.md`
- `dev-notes/tasks.md`
- `dev-notes/decisions/`
- `dev-notes/debug/`

## Starter prompt

```text
This is a continuation of the same project.

Before doing anything, read these files for project memory and working rules:
- AGENT.md
- README.md
- dev-notes/progress.md
- dev-notes/tasks.md
- dev-notes/decisions/
- dev-notes/debug/

Then summarize:
1. current project state
2. open tasks
3. relevant decisions
4. immediate next step

After that, continue with: <your task here>
```

## Current project state

- This repo is the coordination repo for the `if_bridge(4)` IGMP/MLD snooping project.
- The FreeBSD source tree is intended to live in a sibling `freebsd-src` checkout.
- Use `scripts/freebsd-env.sh` to load stable paths and helper aliases between the two repos.
- Notes and lightweight project memory belong under `dev-notes/`.

## Current next steps

- finish preparing the sibling FreeBSD `src` checkout if it is still incomplete
- read `sys/net/if_bridge.h`, `sys/net/if_bridge.c`, and `share/man/man4/if_bridge.4`
- identify the exact existing bridge-related tests under `tests/sys/net/`
- draft the MDB design and forwarding-path touch points before code changes

## Maintenance rule

Update this file when the project state or recommended bootstrap files materially change.

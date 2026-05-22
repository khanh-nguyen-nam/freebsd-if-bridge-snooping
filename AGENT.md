# AGENT.md

Repository-local instructions for future Codex work in this project.

## Git rules

1. Do not run `git push` without explicit user permission.
2. Local commits are allowed when they directly support the requested task.
3. Do not rewrite history with `git commit --amend`, `git rebase`, or force-push behavior unless the user explicitly asks for it.
4. Before any commit, summarize the intended change in a short commentary update.

## Project workflow

1. Keep changes aligned with the proposal scope for `if_bridge(4)` IGMP/MLD snooping.
2. Prefer small, reviewable commits and patch-friendly changes.
3. Keep design notes in `docs/design/`, progress notes in `docs/progress/`, and test planning in `docs/` or `tests/`.
4. Do not vendor the FreeBSD source tree into this repository unless the user explicitly requests it.

## Dev notes workflow

- Use `dev-notes/` for all project notes.
- Update `dev-notes/progress.md` after meaningful code or design changes.
- Use `dev-notes/tasks.md` for TODOs and next steps.
- Use `dev-notes/decisions/` for design decisions.
- Use `dev-notes/debug/` for debugging notes, logs, and investigation summaries.
- Keep `dev-notes/session-bootstrap.md` current so a new chat can recover project context with minimal tokens.
- Keep notes concise and in Markdown.
- Do not delete existing notes unless explicitly asked.
- Before making risky changes, summarize the plan first.

## Safety rules

1. Do not delete or revert user changes unless explicitly requested.
2. Do not make network-facing or repository-publishing actions without permission.
3. If a task could affect upstream FreeBSD source outside this repository, confirm the target path before editing.

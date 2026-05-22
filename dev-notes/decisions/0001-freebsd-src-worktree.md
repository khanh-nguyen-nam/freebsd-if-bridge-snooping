# 0001 FreeBSD Src Worktree

## Context

This repository is for project coordination, notes, tests, and exported patches. The upstream FreeBSD source tree is significantly larger and should stay outside this repo unless explicitly requested.

## Decision

Use an external checkout of the official FreeBSD `src` repository and keep this repo focused on:

- design and progress notes
- helper scripts
- exported patch series
- test planning and reproduction steps

## Consequence

- kernel edits happen in a separate FreeBSD worktree
- this repo records which branch and commit are under test
- patch export and review remain small and easy to follow

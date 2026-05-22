# 0002 Sibling FreeBSD Src Layout

## Context

The project needs the full FreeBSD `src` tree nearby for kernel development and testing, but keeping it inside the proposal repo root would either fail or create a nested repository at the wrong level.

## Decision

Use a sibling checkout:

- project repo: `freebsd-if-bridge-snooping`
- FreeBSD src: sibling `freebsd-src`

## Consequence

- both repositories stay close together for testing and patch export
- the project repo stays small and review-friendly
- helper scripts can safely assume a stable sibling path

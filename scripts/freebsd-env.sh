#!/bin/sh

# Source this file from the project repo to keep paths stable.

if [ -z "$SNOOPING_PROJECT_ROOT" ]; then
	if [ -f ./scripts/freebsd-env.sh ]; then
		SNOOPING_PROJECT_ROOT=$(pwd)
	else
		SNOOPING_PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
	fi
fi

: "${FREEBSD_SRC_ROOT:=$SNOOPING_PROJECT_ROOT/../freebsd-src}"
: "${FREEBSD_PATCH_BASE:=origin/main}"

export SNOOPING_PROJECT_ROOT
export FREEBSD_SRC_ROOT
export FREEBSD_PATCH_BASE

alias fbsrc='cd "$FREEBSD_SRC_ROOT"'
alias snooprepo='cd "$SNOOPING_PROJECT_ROOT"'
alias fbstatus='git -C "$FREEBSD_SRC_ROOT" status --short --branch'
alias fbpatches='git -C "$FREEBSD_SRC_ROOT" format-patch "$FREEBSD_PATCH_BASE" -o "$SNOOPING_PROJECT_ROOT/patches"'

cat <<EOF
Environment loaded.

Project repo: $SNOOPING_PROJECT_ROOT
FreeBSD src: $FREEBSD_SRC_ROOT
Patch base: $FREEBSD_PATCH_BASE

Useful commands:
  fbsrc
  snooprepo
  fbstatus
  fbpatches

Suggested test entry points once development starts:
  cd "$FREEBSD_SRC_ROOT/tests/sys/net"
  kyua test
EOF

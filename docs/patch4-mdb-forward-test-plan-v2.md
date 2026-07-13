# Patch 4 Test Plan (v2) — `0004-if-bridge-mdb-forward.patch`

Supersedes v1. Written to account for the partial-apply state left on the VM
from the 2026-06-23 attempt: `if_bridge.c` already has all patch 4 hunks;
`if_bridge_test.sh` may have a duplicate `mdb_selective_forward` block.

---

## Phase 0 — Check current VM state

SSH into the VM:

```sh
ssh freebsd-test
```

### 0a — Check if if_bridge.c is already patched

```sh
grep -c 'bridge_mdb_forward\|bridge_mdb_destroy_member_cb\|bmm_epoch_ctx' \
    /usr/src/freebsd-src/sys/net/if_bridge.c
```

Expected if **fully applied**: number > 0 (likely 10–15 matches).
Expected if **not applied**: 0.

### 0b — Check for duplicate test function

```sh
grep -n 'mdb_selective_forward' \
    /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh
```

Three outcomes:

| Output | Meaning |
|--------|---------|
| 0 matches | Patch not applied to test script — apply the full patch |
| 4 matches (one `atf_test_case`, one `_head`, one `_body`, one `_cleanup`, one `atf_add`) | Clean, single copy — skip to Phase 2 |
| 8+ matches (function defined twice) | Duplicate block present — fix per Phase 1b |

---

## Phase 1 — Fix the source tree

Run **only the relevant sub-step** based on Phase 0 findings.

### 1a — if_bridge.c not patched (grep returned 0)

Transfer the patch and apply:

```sh
# On host
scp /Users/macboookpro/khanh-dev/freebsd-if-bridge-snooping/patches/0004-if-bridge-mdb-forward.patch \
    nkhanh@172.16.167.140:/tmp/

# On VM (as root)
cd /usr/src/freebsd-src
patch --batch --forward --dry-run -p1 < /tmp/0004-if-bridge-mdb-forward.patch
patch --batch --forward -p1 < /tmp/0004-if-bridge-mdb-forward.patch
```

Then re-run Phase 0b to check the test script state before continuing.

### 1b — if_bridge_test.sh has a duplicate block

The 2026-06-23 partial apply left a second copy of `mdb_selective_forward`
in the file. Remove it:

```sh
# Find the line numbers of both copies of the function declaration
grep -n 'atf_test_case "mdb_selective_forward"' \
    /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh
```

The output will show two line numbers, e.g. `913` and `1003`. The **second**
one (higher number) is the duplicate. Find the blank line immediately before
`atf_test_case "member_ifaddrs_enabled"` — that is the end of the duplicate
block:

```sh
grep -n 'member_ifaddrs_enabled' \
    /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh | head -3
```

Delete from the second `atf_test_case "mdb_selective_forward"` line up to
(and including) the blank line before `member_ifaddrs_enabled`. Substitute the
actual line numbers from your grep output into this command:

```sh
# Example: second copy starts at 1003, blank line before member_ifaddrs_enabled at 1089
ex -s /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh <<'EOF'
1003,1089d
wq
EOF
```

### 1c — Verify the test script is clean

```sh
grep -c 'mdb_selective_forward' \
    /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh
```

Expected: **5** (one `atf_test_case` declaration, one `_head`, one `_body`,
one `_cleanup`, one `atf_add_test_case` registration).

Syntax check:

```sh
sh -n /usr/src/freebsd-src/tests/sys/net/if_bridge_test.sh
```

Expected: no output (no syntax errors).

---

## Phase 2 — Build and install kernel

```sh
cd /usr/src/freebsd-src
make -j4 buildkernel KERNCONF=GENERIC 2>&1 | tail -5
```

Expected last line: `--------------------------------------------------------------`
followed by `>>> Kernel build for GENERIC completed on ...`

No `Error` lines. If the build fails, paste the error — do not proceed.

```sh
make installkernel KERNCONF=GENERIC
reboot
```

---

## Phase 3 — Post-reboot checks

After the VM comes back:

```sh
ssh freebsd-test
```

```sh
# Confirm the kernel booted cleanly
dmesg | grep -iE 'panic|fault|trap|if_bridge' | head -20
```

Expected: bridge-related lines only (attach messages), no panics or faults.

```sh
# Confirm if_bridge is loaded
kldstat | grep if_bridge
```

Expected: one line showing `if_bridge.ko` loaded (or built into GENERIC).

```sh
# Spot-check that the new symbol is in the running kernel
grep -c 'bridge_mdb_forward\|bmm_epoch_ctx' \
    /usr/src/freebsd-src/sys/net/if_bridge.c
```

Expected: same non-zero count as Phase 0a.

---

## Phase 4 — Install the updated test binary

`make installkernel` does not refresh `/usr/tests`. Install the updated ATF
test binary before running Kyua:

```sh
cd /usr/src/freebsd-src/tests/sys/net
make if_bridge_test
install -m 0555 "$(make -V .OBJDIR)/if_bridge_test" \
    /usr/tests/sys/net/if_bridge_test
```

Confirm the new test case is visible to Kyua:

```sh
kyua list -k /usr/tests/Kyuafile | grep 'mdb_selective_forward'
```

Expected output (exact):

```
sys/net/if_bridge_test:mdb_selective_forward
```

If this line is missing, the install did not take — repeat the install step
before continuing.

---

## Phase 5 — ATF targeted test

```sh
kyua test -k /usr/tests/Kyuafile \
    sys/net/if_bridge_test:mdb_selective_forward
```

Expected:

```
sys/net/if_bridge_test:mdb_selective_forward  ->  passed  [...]
  1/1 passed (0 broken, 0 failed, 0 skipped)
```

If it **fails**, run:

```sh
kyua report --verbose --results-filter failed
```

The ATF test compiles `/tmp/mcast_join_bridge_test.c` at runtime. If the
failure message is `could not compile mcast_join helper`, confirm `cc` is
in PATH:

```sh
which cc && cc --version
```

---

## Phase 6 — Full bridge regression

```sh
kyua test -k /usr/tests/Kyuafile sys/net/if_bridge_test
```

Expected: **18/20 passed, 2 skipped** (the `span` and `stp_validation` cases
skip for missing `scapy` — same as the patch 3 baseline of 17/19 but now with
`mdb_selective_forward` adding one more pass).

If any previously passing test now fails, that is a regression introduced by
patch 4. Paste the `kyua report --verbose` output.

---

## Pass criteria summary

| Check | Expected |
|-------|----------|
| if_bridge.c has `bridge_mdb_forward` | yes |
| if_bridge_test.sh has exactly 5 occurrences of `mdb_selective_forward` | yes |
| Kernel build completes without Error | yes |
| dmesg after reboot: no panic/fault | yes |
| `kyua list` finds `mdb_selective_forward` | yes |
| Targeted ATF: `mdb_selective_forward` | passed |
| Full regression delta vs patch 3 baseline | +1 pass, same 2 skips, 0 new fails |

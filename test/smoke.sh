#!/bin/bash
# Smoke test for scrubadub.
#
# Verifies the major paths still work without needing a real Ceph cluster:
#   1. --help exits clean
#   2. Prompt mode produces a recommendation set
#   3. --from-cluster against the bundled fixture produces a diff and
#      the expected backlog count
#   4. Error paths fail with a clear message
#
# Run from the repository root: bash test/smoke.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SB="$REPO_ROOT/scrubadub.sh"
FIXTURE="$SCRIPT_DIR/fixtures/cluster_mixed"

pass=0
fail=0

check() {
    local name=$1 actual=$2 expected_substring=$3
    if echo "$actual" | grep -q -- "$expected_substring"; then
        echo "  PASS: $name"
        pass=$((pass + 1))
    else
        echo "  FAIL: $name (expected to find: $expected_substring)"
        fail=$((fail + 1))
    fi
}

echo "Test 1: --help works"
out=$("$SB" --help 2>&1)
check "help shows --from-cluster"   "$out" "--from-cluster"
check "help shows --workload"       "$out" "--workload"
check "help shows --device-profile" "$out" "--device-profile"

echo
echo "Test 2: prompt mode (Phase 0 regression)"
out=$(printf '12\n4\n0\n2400\n800\n3\n' | "$SB" --scheduler wpq 2>&1)
check "prompt mode emits randomize_ratio" "$out" "osd_scrub_interval_randomize_ratio 0.5"
check "prompt mode emits sleep as float"  "$out" "osd_scrub_sleep 0.1"
check "prompt mode shows WPQ banner"      "$out" "Scheduler: WPQ"

echo
echo "Test 3: --from-cluster against fixture"
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
check "ingest detects 9 HDD + 3 SSD"      "$out" "HDD=9 SSD=3 NVMe=0"
check "ingest computes max OSDs/host=4"   "$out" "max OSDs/host=4"
check "ingest auto-detects wpq"           "$out" "Active OSD op scheduler: wpq"
check "ingest finds the EC pool's factor" "$out" "ec-archive"
check "diff renders proposed change"      "$out" "osd_scrub_sleep:"
check "backlog: 6 PGs past deep-scrub"    "$out" "6 past deep-scrub interval"

echo
echo "Test 4: error paths"
# We expect non-zero exit on these.
set +e
out=$("$SB" --scheduler invalid 2>&1); rc=$?
set -e
check "invalid scheduler errors out"      "$out" "--scheduler must be wpq or mclock"
[ "$rc" -ne 0 ] && pass=$((pass + 1)) || { echo "  FAIL: invalid scheduler exits non-zero"; fail=$((fail + 1)); }

set +e
out=$(CEPH_FIXTURE_DIR=/nonexistent "$SB" --from-cluster --workload mixed 2>&1); rc=$?
set -e
check "missing fixture errors out"        "$out" "Fixture not readable"
[ "$rc" -ne 0 ] && pass=$((pass + 1)) || { echo "  FAIL: missing fixture exits non-zero"; fail=$((fail + 1)); }

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

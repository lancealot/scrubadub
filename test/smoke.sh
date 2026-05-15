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

check_not() {
    local name=$1 actual=$2 unexpected=$3
    if echo "$actual" | grep -q -- "$unexpected"; then
        echo "  FAIL: $name (should NOT contain: $unexpected)"
        fail=$((fail + 1))
    else
        echo "  PASS: $name"
        pass=$((pass + 1))
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
echo "Test 5: Phase 2 emitters callable directly"
# Sourcing the script exposes the functions without running main.
# shellcheck disable=SC1090
source "$SB" >/dev/null 2>&1 || true
sample="86400,604800,604800,2,0.5,1,7,0.1,0.5,balanced"

out=$(emit_wpq_settings "$sample")
check     "wpq emits min_interval"      "$out" "osd_scrub_min_interval = 86400"
check     "wpq emits sleep"             "$out" "osd_scrub_sleep = 0.1"
check     "wpq emits load_threshold"    "$out" "osd_scrub_load_threshold = 0.5"
check_not "wpq omits mclock_profile"    "$out" "osd_mclock_profile"

out=$(emit_mclock_settings "$sample")
check     "mclock emits profile"        "$out" "osd_mclock_profile = balanced"
check     "mclock emits intervals"      "$out" "osd_scrub_max_interval = 604800"
check_not "mclock omits sleep"          "$out" "osd_scrub_sleep"
check_not "mclock omits load_threshold" "$out" "osd_scrub_load_threshold"

echo
echo "Test 6: --from-cluster against the mclock fixture"
MCLOCK_FIXTURE="$SCRIPT_DIR/fixtures/cluster_mclock"
out=$(CEPH_FIXTURE_DIR="$MCLOCK_FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
check     "mclock scheduler auto-detected"  "$out" "Active OSD op scheduler: mclock"
check     "mclock benchmark advisory fires" "$out" "suspiciously low"
check     "mclock recommends profile"       "$out" "osd_mclock_profile balanced"
check_not "mclock recommendation omits sleep" "$out" "ceph config set osd osd_scrub_sleep"

echo
echo "Test 7: Phase 3 — network ceiling"
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed --nic-gbps 1 2>&1)
check     "1 GbE × 3 hosts → 375 MB/s ceiling"  "$out" "Network ceiling:     375 MB/s"
check     "binding ceiling shows network-bound" "$out" "network-bound"
check     "deep-scrub time inflates accordingly" "$out" "Deep scrub time:     ~336 hours"

# No --nic-gbps in prompt mode → no network ceiling
out=$(printf '12\n4\n0\n2400\n800\n3\n' | "$SB" --scheduler wpq 2>&1)
check     "prompt mode w/o flags skips network" "$out" "Network ceiling:     not modeled"

echo
echo "Test 8: Phase 3.2 — mClock IOPS substitution"
out=$(CEPH_FIXTURE_DIR="$MCLOCK_FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
check     "mClock HDD IOPS used"   "$out" "12/OSD, source: mClock benchmark"
check     "mClock SSD IOPS used"   "$out" "1000/OSD, source: mClock benchmark"

echo
echo "Test 9: Phase 3.3 — shallow vs deep estimates"
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
check     "shallow scrub estimate shown"  "$out" "Shallow scrub time:"
check     "deep scrub estimate shown"     "$out" "Deep scrub time:"
check     "interval comparison shown"     "$out" "fits within deep-scrub interval"

echo
echo "Test 10: Phase 3.4 — per-host concurrency warning"
out=$(printf '12\n4\n0\n2400\n800\n3\n' | "$SB" --scheduler wpq --osds-per-host 16 --aggressive-scrubs 2>&1)
check     "concurrency line shown"        "$out" "16 simultaneous scrubs"
check     "concurrency warning > 8 fires" "$out" "high. On busy hosts"

# At 8 (boundary) the warning should NOT fire.
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed --nic-gbps 1 --aggressive-scrubs 2>&1)
check     "concurrency line shown at 8"   "$out" "8 simultaneous scrubs"
check_not "no warning at exactly 8"       "$out" "On busy hosts"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

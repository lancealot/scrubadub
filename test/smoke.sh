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
check     "deep-scrub time inflates accordingly" "$out" "Deep scrub time:     ~260 hours"

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
echo "Test 11: Phase 4.1 — per-class WPQ overrides"
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
check     "per-class section appears (WPQ + mixed classes)" "$out" "Per-class scheduler overrides"
check     "SSD sleep override emitted"                       "$out" "osd/class:ssd            osd_scrub_sleep = 0.0"
check     "apply line uses osd/class:ssd entity"             "$out" "ceph config set osd/class:ssd osd_scrub_sleep 0.0"

# mClock should skip per-class entirely (sleep is ignored under mClock).
out=$(CEPH_FIXTURE_DIR="$MCLOCK_FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
check_not "mClock skips per-class section"                   "$out" "Per-class scheduler overrides"

echo
echo "Test 12: Phase 4.2 — per-pool overrides and noscrub warnings"
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
check     "per-pool section appears"                         "$out" "Per-pool overrides"
check     "noscrub flag warning fires"                       "$out" "Pool paused-bulk: hashpspool,noscrub,nodeep-scrub"
check     "documented syntax used for clearing noscrub"      "$out" "ceph osd pool set paused-bulk noscrub false"
check     "documented syntax used for nodeep-scrub"          "$out" "ceph osd pool set paused-bulk nodeep-scrub false"
check     "hot pool deep_scrub_interval override"            "$out" "rgw.buckets.index        deep_scrub_interval = 259200"
check     "apply line uses pool set syntax"                  "$out" "ceph osd pool set rgw.buckets.index deep_scrub_interval 259200"

# Prompt mode has no pool data so no per-pool section.
out=$(printf '12\n4\n0\n2400\n800\n3\n' | "$SB" --scheduler wpq 2>&1)
check_not "prompt mode skips per-pool section"               "$out" "Per-pool overrides"

echo
echo "Test 13: --scrub-budget-percent flag"
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed --scrub-budget-percent 25 2>&1)
check     "25% override applied to budget math"  "$out" "25% of binding → 825 MB/s"
check     "budget source labelled as flag"       "$out" "source: --scrub-budget-percent"

out=$(SCRUB_BUDGET_PERCENT=42 CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
check     "env var still works"                  "$out" "42% of binding → 1386 MB/s"
check     "env source labelled correctly"        "$out" "source: SCRUB_BUDGET_PERCENT env"

out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
check     "default source labelled correctly"    "$out" "10% of binding → 330 MB/s (source: default)"

# Validation: out-of-range and non-integer values rejected.
set +e
out=$("$SB" --scrub-budget-percent 0 2>&1)
set -e
check     "rejects 0"                            "$out" "must be an integer 1-100"
set +e
out=$("$SB" --scrub-budget-percent 101 2>&1)
set -e
check     "rejects 101"                          "$out" "must be an integer 1-100"
set +e
out=$("$SB" --scrub-budget-percent 1.5 2>&1)
set -e
check     "rejects float"                        "$out" "must be an integer 1-100"

echo
echo "Test 14: Phase 5.1 — --dry-run is today's default"
out_default=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
out_dryrun=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed --dry-run 2>&1)
if [ "$out_default" = "$out_dryrun" ]; then
    echo "  PASS: --dry-run output matches default"
    pass=$((pass + 1))
else
    echo "  FAIL: --dry-run output differs from default"
    fail=$((fail + 1))
fi
help_out=$("$SB" --help 2>&1)
check     "help advertises --dry-run"               "$help_out" "--dry-run"
check     "help advertises --diff"                  "$help_out" "--diff"

echo
echo "Test 15: Phase 5.2 — --diff emits delta and exits"
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed --diff 2>&1)
check     "diff section appears"                    "$out" "Proposed Changes"
check     "per-class section appears in diff"       "$out" "Per-class scheduler overrides"
check     "per-pool section appears in diff"        "$out" "Per-pool overrides"
check     "diff exit notice shown"                  "$out" "Diff-only mode"
check_not "apply commands suppressed under --diff"  "$out" "Recommended Configuration Commands"
check_not "perf analysis suppressed under --diff"   "$out" "Performance Impact Analysis"
check_not "notes suppressed under --diff"           "$out" "osd_scrub_load_threshold is normalized"

# --diff requires --from-cluster.
set +e
out=$(printf '12\n4\n0\n2400\n800\n3\n' | "$SB" --scheduler wpq --diff 2>&1); rc=$?
set -e
check     "--diff without --from-cluster errors"    "$out" "--diff requires --from-cluster"
[ "$rc" -ne 0 ] && pass=$((pass + 1)) || { echo "  FAIL: --diff without --from-cluster should exit non-zero"; fail=$((fail + 1)); }

echo
echo "Test 16: Phase 5.3-prep — --emit-backup-plan"
PLAN=$(mktemp /tmp/scrubadub-backup-plan.XXXXXX.tsv)
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed --emit-backup-plan "$PLAN" 2>&1)
check     "writer confirms success"                  "$out" "Backup plan written to"
check     "row count reported"                       "$out" "(11 rows)"
plan_body=$(grep -v '^#' "$PLAN")
check     "global osd row captures current value"    "$plan_body" "osd	osd		osd_deep_scrub_interval	1209600"
check     "global row records current sleep"         "$plan_body" "osd	osd		osd_scrub_sleep	0.0"
check     "per-class row records unset"              "$plan_body" "osd_class	osd	class:ssd	osd_scrub_sleep	<unset>"
check     "per-pool row records unset"               "$plan_body" "pool	pool	rgw.buckets.index	deep_scrub_interval	<unset>"

# Header block is self-describing.
check     "backup file has restore comment"          "$(cat "$PLAN")" "scrubadub.sh --rollback"
check     "backup file documents columns"            "$(cat "$PLAN")" "Columns (TAB-separated)"

# --emit-backup-plan requires --from-cluster.
set +e
out=$(printf '12\n4\n0\n2400\n800\n3\n' | "$SB" --scheduler wpq --emit-backup-plan /tmp/sb-nope.tsv 2>&1); rc=$?
set -e
check     "--emit-backup-plan needs --from-cluster"  "$out" "requires --from-cluster"
[ "$rc" -ne 0 ] && pass=$((pass + 1)) || { echo "  FAIL: --emit-backup-plan w/o --from-cluster should exit non-zero"; fail=$((fail + 1)); }

rm -f "$PLAN" /tmp/sb-nope.tsv

echo
echo "Test 17: live-cluster bug fixes — EC profile + backlog floats"

# 17a. EC factor comes from `osd erasure-code-profile get`, not the
# pool size or profile name. Move the fixture aside, verify the
# warning fires AND the factor changes to the (deliberately wrong)
# m=2 fallback — proves the profile lookup is what's authoritative.
mv "$FIXTURE/ec_profile_ec-8-3.json" "$FIXTURE/ec_profile_ec-8-3.json.bak"
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
check     "warns when EC profile can't be read"     "$out" "couldn't read EC profile"
check     "fallback gives wrong-by-design 11/9"     "$out" "ec-archive' (11/9)"
mv "$FIXTURE/ec_profile_ec-8-3.json.bak" "$FIXTURE/ec_profile_ec-8-3.json"

# Restore the fixture and verify the authoritative path runs silently.
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
check_not "no warning when EC profile is readable"  "$out" "couldn't read EC profile"
check     "EC factor still 11/8 via profile lookup" "$out" "ec-archive' (11/8)"

# 17b. Backlog detection switched from per-PG timestamp parsing (which
# Reef's pgs_brief no longer carries) to Ceph's own health-check counts.
# Fixture asserts 6 deep + 2 shallow late.
check     "deep-scrub backlog count read from health" "$out" "6 past deep-scrub interval"
check     "shallow-scrub backlog count read from health" "$out" "2 past scrub interval"
check     "section header points at the right source" "$out" "from 'ceph health detail'"

# 17c. NIC auto-detect warns about local-node measurement. (Can't actually
# fire here since the test container has no live NICs, so we just verify
# the warning isn't suppressed when ethtool *would* succeed by checking
# that --nic-gbps still overrides cleanly without warning.)
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed --nic-gbps 50 2>&1)
check_not "no local-node NIC warning when overridden" "$out" "NIC speed auto-detected from THIS node"
check     "explicit --nic-gbps source shown"          "$out" "source: --nic-gbps"

# 17d. Scrub-time math uses unique PG count, not OSD-assignment sum.
# Fixture has 912 unique PGs and 1136 OSD-assignments. Estimated
# scrub-time with the old (broken) formula was ~37h; with the fix it's
# ~29h (using 912 × 28 GB × 11/8 / 330 MB/s).
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
check     "scrub-time uses unique-PG count"           "$out" "Deep scrub time:     ~29 hours"
check     "per-class label says 'PG replicas'"        "$out" "PG replicas: 896 (avg 99 per OSD)"
check_not "old 'PGs:' label gone from per-class"      "$out" "  - PGs: 896"
check     "ingest notice uses 'PG-OSD assignments'"   "$out" "PG-OSD assignments by class"

echo
echo "Test 18: Phase 3.5 — empirical bench"

# Clean cache and run from scratch.
CACHE=/tmp/sb-smoke-bench-cache.json
rm -f "$CACHE"

# 18a. First run: benches all 6 OSDs (1 per host per class).
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed \
        --bench-osds --bench-cache-file "$CACHE" 2>&1)
check     "HDD class progress line"                  "$out" "Benching 3 hdd OSDs... done. (3/3 succeeded)"
check     "SSD class progress line"                  "$out" "Benching 3 ssd OSDs... done. (3/3 succeeded)"
check     "summary identifies slow HDD by host"      "$out" "min 80 (osd.8 on host-c)"
check     "summary shows HDD max"                    "$out" "median 200 / max 220 MB/s"
check     "summary shows SSD numbers"                "$out" "SSD  (3 samples): min 580"
check     "throughput source switches to bench"      "$out" "source: median of 3 sampled, just now"
check     "outlier osd.8 flagged at default 0.5x"    "$out" "HDD outliers below 0.5× baseline: osd.8 (80 MB/s)"
check_not "no SSD outliers (all ~600 MB/s)"          "$out" "SSD outliers below"
check     "cache file written"                       "$out" "Bench results cached to"

# 18b. Second run hits the cache (no fresh benches launched).
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed \
        --bench-osds --bench-cache-file "$CACHE" 2>&1)
check     "second run loads from cache"              "$out" "Loaded bench cache"
check_not "no class-progress lines on cache hit"     "$out" "Benching 3 hdd OSDs"
check     "outlier persisted in cache"               "$out" "HDD outliers below 0.5× baseline: osd.8"
check     "source label says 'cache'"                "$out" "source: median of 3 sampled, cache "

# 18c. --refresh-bench bypasses cache.
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed \
        --bench-osds --bench-cache-file "$CACHE" --refresh-bench 2>&1)
check     "--refresh-bench re-runs benches"          "$out" "Benching 3 hdd OSDs"
check_not "--refresh-bench doesn't load cache"       "$out" "Loaded bench cache"

# 18d. --bench-aggregate p25 picks the slowest of the trio (80 MB/s for HDD).
rm -f "$CACHE"
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed \
        --bench-osds --bench-cache-file "$CACHE" --bench-aggregate p25 2>&1)
check     "p25 picks slow HDD as baseline"           "$out" "(80 MB/s/OSD, source: p25 of 3"
# At p25 baseline 80 MB/s, threshold = 40 MB/s, nothing is below it.
check_not "no outliers at p25 baseline"              "$out" "HDD outliers below"

# 18e. --outlier-threshold tightens the rule.
rm -f "$CACHE"
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed \
        --bench-osds --bench-cache-file "$CACHE" --outlier-threshold 0.95 2>&1)
# At threshold 0.95 × median 200 = 190, the 80 MB/s HDD is still flagged.
check     "tighter threshold still flags osd.8"      "$out" "HDD outliers below 0.95× baseline"

# 18f. Validation.
set +e
out=$("$SB" --bench-aggregate bogus 2>&1); rc=$?
set -e
check     "rejects bogus aggregate"                  "$out" "must be p25, median, trimmed-mean, or mean"
[ "$rc" -ne 0 ] && pass=$((pass + 1)) || { echo "  FAIL: bad --bench-aggregate should exit non-zero"; fail=$((fail + 1)); }

set +e
out=$("$SB" --outlier-threshold 1.5 2>&1); rc=$?
set -e
check     "rejects threshold > 1.0"                  "$out" "must be a fraction in (0, 1]"
[ "$rc" -ne 0 ] && pass=$((pass + 1)) || { echo "  FAIL: bad --outlier-threshold should exit non-zero"; fail=$((fail + 1)); }

# 18g. --bench-osds requires --from-cluster.
set +e
out=$(printf '12\n4\n0\n2400\n800\n3\n' | "$SB" --scheduler wpq --bench-osds 2>&1); rc=$?
set -e
check     "--bench-osds needs --from-cluster"        "$out" "requires --from-cluster"
[ "$rc" -ne 0 ] && pass=$((pass + 1)) || { echo "  FAIL: --bench-osds without --from-cluster should exit non-zero"; fail=$((fail + 1)); }

rm -f "$CACHE"

echo
echo "Test 19: numeric diff comparison + --why"

# 19a. Diff treats 86400.000000 == 86400 as no-change (formerly false positive).
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed --diff 2>&1)
check_not "no spurious 86400.000000 → 86400 row" "$out" "86400.000000 → 86400"
check     "min_interval shown as no-change"      "$out" "osd_scrub_min_interval:                    86400 (no change)"

# 19b. --why adds Reasoning section.
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed --why --diff 2>&1)
check     "Reasoning section appears"            "$out" "=== Reasoning ==="
check     "explains osd_deep_scrub_interval"     "$out" "How often each PG gets a full data-integrity deep-scrub"
check     "explains osd_scrub_sleep"             "$out" "Pause (seconds, float) between scrub-chunk reads"
check     "explains class override"              "$out" "Faster device classes don't need the global"
check     "explains pool override"               "$out" "Hot pool (small avg object size"
check_not "no-change params absent from why"     "$out" "Lower bound for shallow-scrub eligibility"

# 19c. No "Phase" references in operator-facing output.
out=$(CEPH_FIXTURE_DIR="$FIXTURE" "$SB" --from-cluster --workload mixed 2>&1)
check_not "no 'Phase X.Y' in normal output"      "$out" "Phase 0."
check_not "no 'Phase X.Y' in normal output 2"    "$out" "(Phase 3.5)"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

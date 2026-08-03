#!/bin/bash

# scrubadub - Ceph Scrub Parameter Calculator
#
# Calculates recommended scrub settings for a Ceph cluster from OSD
# composition, PG distribution, workload, and active op scheduler.
#
# v1.1 — Phase 0 corrections. See ROADMAP.md for the tracked plan.

# -----------------------------------------------------------------------------
# Configurable constants
# -----------------------------------------------------------------------------

# Device baseline performance. Order-of-magnitude defaults; override at
# runtime via --device-profile <file> or matching env vars. The current
# defaults conflate SATA vs SAS SSDs and NVMe Gen3/4/5 — operators
# running newer media should override (Phase 0.11; Phase 3.2 will pull
# real numbers from mClock self-benchmark when present).
HDD_THROUGHPUT=${HDD_THROUGHPUT:-200}      # MB/s; modern 12TB+ CMR HDD
HDD_IOPS=${HDD_IOPS:-150}                  # random IOPS, 7200rpm
SSD_THROUGHPUT=${SSD_THROUGHPUT:-500}      # MB/s; SATA SSD baseline
SSD_IOPS=${SSD_IOPS:-75000}                # random IOPS
NVME_THROUGHPUT=${NVME_THROUGHPUT:-3500}   # MB/s; Gen3/Gen4 median
NVME_IOPS=${NVME_IOPS:-600000}

# Average PG size in GB. This is a GUESS unless overridden — real PG
# size varies wildly per pool (KB to tens of GB). Phase 1.4 replaces
# this with per-pool real numbers from `ceph df detail`.
AVG_PG_SIZE_DEFAULT=4
AVG_PG_SIZE=${PG_SIZE_GB:-$AVG_PG_SIZE_DEFAULT}
AVG_PG_SIZE_SOURCE="default"
[ "${PG_SIZE_GB:-unset}" != "unset" ] && AVG_PG_SIZE_SOURCE="PG_SIZE_GB env"

# Scrub budget: scrub never gets 100% of cluster throughput. Realistic
# share is ~10-15%. Phase 0.9.
# Source is one of: "default", "SCRUB_BUDGET_PERCENT env", "--scrub-budget-percent".
# A future dynamic-tuning daemon would replace this static value with
# one derived from observed client load; out of scope for this project.
if [ -n "${SCRUB_BUDGET_PERCENT:-}" ]; then
    SCRUB_BUDGET_SOURCE="SCRUB_BUDGET_PERCENT env"
else
    SCRUB_BUDGET_PERCENT=10
    SCRUB_BUDGET_SOURCE="default"
fi

# Replication / EC factor. Default to 3x replicated (most common).
# Overridden by --replica-size or --ec-ratio.
DATA_FACTOR_NUM=3
DATA_FACTOR_DEN=1
DATA_FACTOR_SOURCE="default (3x replicated)"

# Mode flags
SCHEDULER=""
HYPERCONVERGED=0
AGGRESSIVE_SCRUBS=0
DEVICE_PROFILE=""

# Phase 1: cluster-ingested mode.
FROM_CLUSTER=0
FORCE_NON_MON=0
WORKLOAD_TYPE=""   # 1/2/3/4; if set via --workload, skips the prompt

# Phase 5: apply / diff / rollback. Default behavior stays read-only;
# mutating modes are opt-in. DRY_RUN is the named form of today's default.
DRY_RUN=1            # 0 only when --apply is given
DIFF_ONLY=0          # --diff: emit just the delta and exit
EMIT_BACKUP_PLAN=""  # --emit-backup-plan FILE: write backup plan, exit. Read-only.
SHOW_WHY=0           # --why: add a "Reasoning" section after the diff

# Phase 3: honest performance model.
NIC_GBPS=""          # --nic-gbps; per-host NIC speed in Gbps
HOST_COUNT=""        # --hosts (prompt mode); auto-detected in --from-cluster
OSDS_PER_HOST=""     # --osds-per-host (prompt mode); auto in --from-cluster
NIC_MBPS=0           # computed: NIC_GBPS * 125
NIC_SOURCE=""        # "--nic-gbps", "ethtool", or empty
NETWORK_CEILING=0    # computed: HOST_COUNT * NIC_MBPS, MB/s; 0 means unused

# Phase 3.5: empirical per-class throughput from `ceph tell osd.X bench`.
BENCH_OSDS=0                 # --bench-osds enables; default off (no I/O surprises)
BENCH_AGGREGATE="median"     # p25 | median | trimmed-mean | mean
OUTLIER_THRESHOLD="0.5"      # flag OSDs slower than this fraction × baseline
REFRESH_BENCH=0              # --refresh-bench: skip cache, re-bench
BENCH_CACHE_FILE=""          # --bench-cache-file FILE; default ~/.scrubadub/bench-<fsid>.json
BENCH_MAX_AGE_DAYS=30        # cache TTL
# Result globals, populated by load_or_run_benchmarks(). Empty when not benched.
BENCH_HDD_MBPS=""
BENCH_SSD_MBPS=""
BENCH_NVME_MBPS=""
declare -a BENCH_HDD_OUTLIERS=()
declare -a BENCH_SSD_OUTLIERS=()
declare -a BENCH_NVME_OUTLIERS=()
BENCH_HDD_SOURCE=""          # e.g. "median of 30 sampled, cache 2026-05-15"
BENCH_SSD_SOURCE=""
BENCH_NVME_SOURCE=""
BENCH_HDD_SAMPLE_COUNT=0
BENCH_SSD_SAMPLE_COUNT=0
BENCH_NVME_SAMPLE_COUNT=0

# Per-pool sizing check: flag pools whose average per-PG data exceeds this
# many GiB. Large PGs make scrub and recovery take proportionally longer.
# Modern Ceph guidance is roughly 100-500 GiB/PG; >1 TiB is worth flagging.
LARGE_PG_THRESHOLD_GIB=1024
declare -a large_pg_pools=()   # populated by ingest_pool_details

# Phase 8: admission-aware inputs (see ROADMAP Phase 8).
# MAX_POOL_WIDTH: widest acting set across pools (k+m for EC, size for
# replicated). A deep scrub must reserve slots on all `width` members at
# once, so this is the conjunction width that drives scrub admission.
# AVG_OBJECTS_PER_PG: real object density (cluster mode), used to price
# osd_scrub_sleep, which is paid per chunk of osd_scrub_chunk_max objects.
MAX_POOL_WIDTH=0               # cluster mode: from pool walk; prompt mode: DATA_FACTOR_NUM
AVG_OBJECTS_PER_PG=""          # cluster mode only; empty disables the sleep gate
declare -a pool_widths=()      # "name|width|pg_num" — populated by ingest_pool_details

# Phase 8.1: reservation sampling.
RESERVATION_SAMPLE_SIZE=${RESERVATION_SAMPLE_SIZE:-30}
ADMISSION_LIMITED_PCT=${ADMISSION_LIMITED_PCT:-10}    # P(start) below this => admission-limited
ADMISSION_TIGHT_PCT=${ADMISSION_TIGHT_PCT:-25}        # ...below this => tight
reservation_sampled=0     # OSDs that answered
reservation_at_max=0      # of those, how many were at osd_max_scrubs
reservation_cap=0         # osd_max_scrubs as reported by the OSDs themselves
reservation_f_pct=0       # at_max / sampled, as an integer percentage
reservation_mean=""       # mean slots in use, formatted

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
print_header()  { echo -e "\n${BOLD}=== $1 ===${NC}\n"; }
print_error()   { echo -e "${RED}Error: $1${NC}" >&2; }
print_warning() { echo -e "${YELLOW}Warning: $1${NC}"; }
print_notice()  { echo -e "${CYAN}Notice: $1${NC}"; }
print_success() { echo -e "${GREEN}$1${NC}"; }

# -----------------------------------------------------------------------------
# Arg parsing
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Cluster-ingested mode (Phase 1):
  --from-cluster          Read OSD inventory, PG distribution, pool sizes,
                          current scrub config, scheduler, and scrub
                          backlog directly from 'ceph' instead of prompting.
                          Requires ceph + jq on PATH. Run on a mon node.
  --force                 Allow --from-cluster on a host that doesn't look
                          like a monitor. Footgun; off by default.
  --workload {read|write|mixed|archive}
                          Skip the workload prompt by declaring up front.

Performance model:
  --nic-gbps N            Per-host NIC speed in Gbps. Caps the scrub
                          throughput estimate at hosts × NIC_GBPS.
                          Auto-detected via 'ethtool' under --from-cluster.
  --hosts N               Host count for the network-ceiling computation
                          in prompt mode. Auto-detected under --from-cluster.
  --osds-per-host N       Max OSDs per host, for the per-host scrub
                          concurrency warning in prompt mode.

Empirical throughput:
  --bench-osds            Measure per-OSD throughput by running
                          'ceph tell osd.X bench' on one OSD per host
                          per device class. Writes ~1 GiB per HDD
                          sample, ~2 GiB per NVMe sample. Runs serially
                          to avoid measuring contention. Results
                          cached for 30 days (override with
                          --refresh-bench). Default cache location:
                          ~/.scrubadub/bench-<cluster_fsid>.json.
  --bench-aggregate {p25|median|trimmed-mean|mean}
                          How to combine per-OSD samples into a class
                          baseline. Default: median. P25 is
                          appropriate for scrub-time math (slow OSDs
                          bottleneck the round).
  --outlier-threshold N   Flag OSDs whose bench result is below N ×
                          the per-class baseline. Default 0.5.
  --refresh-bench         Re-run benches even if cache is fresh.
  --bench-cache-file PATH Override the default cache file location.

Tuning options:
  --avg-pg-size-gb N      Average PG size in GB (default: 4 in prompt mode,
                          computed from 'ceph df detail' under --from-cluster).
  --replica-size N        Treat pools as N-way replicated (default: 3 in
                          prompt mode, computed per-pool under --from-cluster).
  --ec-ratio k+m          Treat pools as erasure-coded k+m (e.g. 8+3).
                          Mutually exclusive with --replica-size.
  --scheduler {wpq|mclock}
                          Active OSD op scheduler. Auto-detected under
                          --from-cluster; prompted otherwise.
  --hyperconverged        Other workloads share the OSD hosts (Proxmox,
                          OpenStack co-located VMs, etc.). Allows lower
                          osd_scrub_load_threshold values under WPQ.
  --aggressive-scrubs     Permit osd_max_scrubs up to 4 (default cap: 3,
                          matching the default in current Reef).
                          Verify per-host headroom before using.
  --scrub-budget-percent N
                          Integer 1-100. Share of the binding ceiling
                          (min of disk/network) reserved for scrub.
                          Default 10. Drop to 5 on busy clusters, raise
                          to 20-30 on idle ones to catch up backlog.
  --large-pg-threshold-gib N
                          Flag pools whose average per-PG data exceeds N
                          GiB in the sizing-observations section. Default
                          1024 (1 TiB). Large PGs slow scrub and recovery.
  --device-profile FILE   Source KEY=VALUE overrides for device constants.
                          Keys: HDD_THROUGHPUT, HDD_IOPS, SSD_THROUGHPUT,
                          SSD_IOPS, NVME_THROUGHPUT, NVME_IOPS.

Output modes:
  --dry-run               Print the full report without modifying the
                          cluster. This is the default; the flag is for
                          intent-clarity in scripts.
  --diff                  Print only the current → proposed delta
                          (requires --from-cluster) and exit.
  --emit-backup-plan FILE Write the would-rollback state to FILE as
                          a TSV (one row per setting we'd change),
                          then exit. Read-only — never touches cluster
                          state. Requires --from-cluster. Useful for
                          previewing the rollback format before --apply.
  --why                   Print a "Reasoning" section explaining each
                          proposed parameter change.

  -h, --help              Show this help.

Environment variables:
  PG_SIZE_GB              Same as --avg-pg-size-gb.
  SCRUB_BUDGET_PERCENT    Same as --scrub-budget-percent (default: 10).
  CEPH_FIXTURE_DIR        Replace live 'ceph' calls with fixture files in
                          the given directory. For testing.
  Plus any device constant from --device-profile.

See ROADMAP.md for the phased plan.
EOF
}

require_value() {
    # require_value <flag> <value-or-empty>
    if [ -z "${2:-}" ]; then
        print_error "$1 requires a value"
        exit 2
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --avg-pg-size-gb)
                require_value "$1" "${2:-}"
                AVG_PG_SIZE="$2"
                AVG_PG_SIZE_SOURCE="--avg-pg-size-gb"
                shift 2 ;;
            --replica-size)
                require_value "$1" "${2:-}"
                if ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
                    print_error "--replica-size must be a positive integer"
                    exit 2
                fi
                DATA_FACTOR_NUM="$2"
                DATA_FACTOR_DEN=1
                DATA_FACTOR_SOURCE="--replica-size $2 (replicated)"
                shift 2 ;;
            --ec-ratio)
                require_value "$1" "${2:-}"
                if ! [[ "$2" =~ ^[0-9]+\+[0-9]+$ ]]; then
                    print_error "--ec-ratio expects k+m, e.g. 8+3"
                    exit 2
                fi
                local k="${2%+*}"
                local m="${2#*+}"
                if [ "$k" -lt 1 ] || [ "$m" -lt 1 ]; then
                    print_error "--ec-ratio k and m must be >= 1"
                    exit 2
                fi
                DATA_FACTOR_NUM=$((k + m))
                DATA_FACTOR_DEN=$k
                DATA_FACTOR_SOURCE="--ec-ratio $2 (k=$k, m=$m)"
                shift 2 ;;
            --scheduler)
                require_value "$1" "${2:-}"
                case "$2" in
                    wpq|mclock) SCHEDULER="$2" ;;
                    *) print_error "--scheduler must be wpq or mclock"; exit 2 ;;
                esac
                shift 2 ;;
            --hyperconverged)
                HYPERCONVERGED=1
                shift ;;
            --aggressive-scrubs)
                AGGRESSIVE_SCRUBS=1
                shift ;;
            --dry-run)
                # Today's default behavior, named explicitly. Together
                # with the not-yet-built --apply flag this makes opt-in
                # mutation the only way to write cluster state.
                DRY_RUN=1
                shift ;;
            --diff)
                # Print only the current → proposed delta from
                # --from-cluster and exit, skipping the full report.
                DIFF_ONLY=1
                shift ;;
            --emit-backup-plan)
                # Read the current state of every setting we'd change
                # under --apply and write it to FILE as a TSV. Pure
                # read-only; exits before any state mutation. Useful
                # for verifying the rollback format on a live cluster.
                require_value "$1" "${2:-}"
                EMIT_BACKUP_PLAN="$2"
                shift 2 ;;
            --why)
                # Print a "Reasoning" section after the proposed-changes
                # diff, explaining each parameter recommendation.
                SHOW_WHY=1
                shift ;;
            --bench-osds)
                BENCH_OSDS=1
                shift ;;
            --bench-aggregate)
                require_value "$1" "${2:-}"
                case "$2" in
                    p25|median|trimmed-mean|mean) BENCH_AGGREGATE="$2" ;;
                    *) print_error "--bench-aggregate must be p25, median, trimmed-mean, or mean"; exit 2 ;;
                esac
                shift 2 ;;
            --outlier-threshold)
                require_value "$1" "${2:-}"
                if ! [[ "$2" =~ ^0\.[0-9]+$|^1\.0$|^1$ ]]; then
                    print_error "--outlier-threshold must be a fraction in (0, 1]"; exit 2
                fi
                OUTLIER_THRESHOLD="$2"
                shift 2 ;;
            --refresh-bench)
                REFRESH_BENCH=1
                shift ;;
            --bench-cache-file)
                require_value "$1" "${2:-}"
                BENCH_CACHE_FILE="$2"
                shift 2 ;;
            --large-pg-threshold-gib)
                require_value "$1" "${2:-}"
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                    print_error "--large-pg-threshold-gib must be a positive integer"; exit 2
                fi
                LARGE_PG_THRESHOLD_GIB="$2"
                shift 2 ;;
            --device-profile)
                require_value "$1" "${2:-}"
                DEVICE_PROFILE="$2"
                shift 2 ;;
            --from-cluster)
                FROM_CLUSTER=1
                shift ;;
            --force)
                FORCE_NON_MON=1
                shift ;;
            --workload)
                require_value "$1" "${2:-}"
                case "$2" in
                    read)    WORKLOAD_TYPE=1 ;;
                    write)   WORKLOAD_TYPE=2 ;;
                    mixed)   WORKLOAD_TYPE=3 ;;
                    archive) WORKLOAD_TYPE=4 ;;
                    *) print_error "--workload must be read, write, mixed, or archive"; exit 2 ;;
                esac
                shift 2 ;;
            --nic-gbps)
                require_value "$1" "${2:-}"
                if ! [[ "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    print_error "--nic-gbps must be a positive number"; exit 2
                fi
                NIC_GBPS="$2"
                NIC_SOURCE="--nic-gbps"
                shift 2 ;;
            --scrub-budget-percent)
                require_value "$1" "${2:-}"
                if ! [[ "$2" =~ ^[1-9][0-9]?$|^100$ ]]; then
                    print_error "--scrub-budget-percent must be an integer 1-100"; exit 2
                fi
                SCRUB_BUDGET_PERCENT="$2"
                SCRUB_BUDGET_SOURCE="--scrub-budget-percent"
                shift 2 ;;
            --hosts)
                require_value "$1" "${2:-}"
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                    print_error "--hosts must be a positive integer"; exit 2
                fi
                HOST_COUNT="$2"
                shift 2 ;;
            --osds-per-host)
                require_value "$1" "${2:-}"
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                    print_error "--osds-per-host must be a positive integer"; exit 2
                fi
                OSDS_PER_HOST="$2"
                shift 2 ;;
            -h|--help)
                usage
                exit 0 ;;
            *)
                print_error "Unknown option: $1"
                usage >&2
                exit 2 ;;
        esac
    done
}

load_device_profile() {
    [ -z "$DEVICE_PROFILE" ] && return
    if [ ! -r "$DEVICE_PROFILE" ]; then
        print_error "Device profile not readable: $DEVICE_PROFILE"
        exit 2
    fi
    # shellcheck disable=SC1090
    source "$DEVICE_PROFILE"
    print_notice "Loaded device profile: $DEVICE_PROFILE"
}

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
validate_number() {
    local input=$1 name=$2
    if ! [[ "$input" =~ ^[0-9]+$ ]]; then
        print_error "$name must be a non-negative number"
        return 1
    fi
    return 0
}

validate_osd_inputs() {
    local hdd=$1 ssd=$2 nvme=$3
    validate_number "$hdd"  "HDD count"  || return 1
    validate_number "$ssd"  "SSD count"  || return 1
    validate_number "$nvme" "NVMe count" || return 1
    if [ "$hdd" -eq 0 ] && [ "$ssd" -eq 0 ] && [ "$nvme" -eq 0 ]; then
        print_error "At least one type of OSD must exist"
        return 1
    fi
    return 0
}

validate_pg_inputs() {
    local count=$1 osds=$2 type=$3
    [ "$osds" -eq 0 ] && return 0
    validate_number "$count" "$type PG count" || return 1
    return 0
}

# -----------------------------------------------------------------------------
# Calculations
# -----------------------------------------------------------------------------
calculate_pg_per_osd() {
    local pg_count=$1 osd_count=$2
    [ "$osd_count" -eq 0 ] && { echo 0; return; }
    echo $((pg_count / osd_count))
}

calculate_device_performance() {
    local count=$1 throughput=$2 iops=$3
    echo "$((count * throughput)) $((count * iops))"
}

# Estimate full deep-scrub time in hours.
# Phase 0.9: applies SCRUB_BUDGET_PERCENT, not full throughput.
# Phase 0.10: applies DATA_FACTOR for replication / EC overhead.
calculate_scrub_time() {
    local pg_count=$1
    local total_throughput=$2   # MB/s, raw cluster sum

    [ "$total_throughput" -eq 0 ] && { echo 0; return; }

    local eff_throughput=$((total_throughput * SCRUB_BUDGET_PERCENT / 100))
    [ "$eff_throughput" -lt 1 ] && eff_throughput=1

    # Stored MB → bytes actually read for a full deep-scrub pass.
    # Replicated: read = stored × replica_size
    # EC k+m: read = stored × (k+m)/k
    local stored_mb=$((pg_count * AVG_PG_SIZE * 1024))
    local total_mb=$((stored_mb * DATA_FACTOR_NUM / DATA_FACTOR_DEN))

    local hours=$((total_mb / (eff_throughput * 3600)))
    if [ "$total_mb" -gt 0 ] && [ "$hours" -eq 0 ]; then
        echo 1
    else
        echo "$hours"
    fi
}

# Map workload number to scrub window {begin,end} hour pair.
# 0/0 means 24-hour (Ceph convention). Phase 0.2 fix.
scrub_window_for_workload() {
    case "$1" in
        1) echo "1 6" ;;
        2) echo "2 5" ;;
        3) echo "1 7" ;;
        4) echo "0 0" ;;
    esac
}

# -----------------------------------------------------------------------------
# Scrub settings
# -----------------------------------------------------------------------------
# Phase 2 refactor: the dispatcher computes the values shared by both
# schedulers, then delegates to a scheduler-specific emitter.
#
# Each emitter takes a single comma-separated VALUES string so it can be
# called independently — useful for unit-style tests. The format is:
#   min_interval,max_interval,deep_interval,max_scrubs,randomize_ratio,
#   begin_hour,end_hour,scrub_sleep,load_threshold,mclock_profile

# Phase 2.2: WPQ emitter. Emits all classic knobs.
emit_wpq_settings() {
    local v=$1
    IFS=',' read -r min_iv max_iv deep_iv max_scrubs rr bh eh ss lt _profile <<< "$v"
    echo "osd_scrub_min_interval = $min_iv"
    echo "osd_scrub_max_interval = $max_iv"
    echo "osd_deep_scrub_interval = $deep_iv"
    echo "osd_max_scrubs = $max_scrubs"
    echo "osd_scrub_interval_randomize_ratio = $rr"
    echo "osd_scrub_begin_hour = $bh"
    echo "osd_scrub_end_hour = $eh"
    echo "osd_scrub_sleep = $ss"
    echo "osd_scrub_load_threshold = $lt"
}

# Phase 2.3: mClock emitter. Emits intervals + max_scrubs + window +
# randomize_ratio + the mClock profile. Does NOT emit sleep or
# load_threshold (mClock ignores them).
emit_mclock_settings() {
    local v=$1
    IFS=',' read -r min_iv max_iv deep_iv max_scrubs rr bh eh _ss _lt profile <<< "$v"
    echo "osd_scrub_min_interval = $min_iv"
    echo "osd_scrub_max_interval = $max_iv"
    echo "osd_deep_scrub_interval = $deep_iv"
    echo "osd_max_scrubs = $max_scrubs"
    echo "osd_scrub_interval_randomize_ratio = $rr"
    echo "osd_scrub_begin_hour = $bh"
    echo "osd_scrub_end_hour = $eh"
    echo "osd_mclock_profile = $profile"
}

# Phase 2.1: dispatcher. Computes the shared bucket-derived values, applies
# PG-density / backlog adjustments, caps max_scrubs, and delegates to
# the appropriate emitter.
calculate_scrub_settings() {
    local total_osds=$1
    local max_pgs_per_osd=$2
    local workload_type=$3
    local scrub_time=$4
    local scheduler=$5

    local min_interval=86400 max_interval=604800 deep_interval=604800
    local max_scrubs=1 randomize_ratio="0.5"
    local load_threshold="0.5" scrub_sleep="0.0"
    local begin_hour=1 end_hour=7
    local mclock_profile="balanced"

    # Bucket → bucket-specific WPQ + mClock values.
    # mClock profile choice (Phase 2.3 spec):
    #   high_client_ops for read-heavy or hyperconverged;
    #   balanced for write/mixed/archival;
    #   high_recovery_ops is gated on Phase 6.1 (backlog drain).
    case "$workload_type" in
        1) # Heavy Read
            scrub_sleep="0.1"
            if [ "$HYPERCONVERGED" -eq 1 ]; then load_threshold="0.3"; else load_threshold="0.5"; fi
            mclock_profile="high_client_ops"
            begin_hour=1; end_hour=6 ;;
        2) # Heavy Write
            scrub_sleep="0.2"
            if [ "$HYPERCONVERGED" -eq 1 ]; then load_threshold="0.2"; else load_threshold="0.5"; fi
            min_interval=172800
            mclock_profile="balanced"
            begin_hour=2; end_hour=5 ;;
        3) # Mixed
            scrub_sleep="0.1"
            if [ "$HYPERCONVERGED" -eq 1 ]; then load_threshold="0.4"; else load_threshold="0.5"; fi
            mclock_profile="balanced"
            begin_hour=1; end_hour=7 ;;
        4) # Archival
            scrub_sleep="0.05"
            if [ "$HYPERCONVERGED" -eq 1 ]; then load_threshold="0.6"; else load_threshold="0.8"; fi
            mclock_profile="balanced"
            begin_hour=0; end_hour=0 ;;
    esac

    # Hyperconverged forces high_client_ops regardless of workload bucket.
    [ "$HYPERCONVERGED" -eq 1 ] && mclock_profile="high_client_ops"

    # PG-density adjustment.
    if [ "$max_pgs_per_osd" -gt 200 ]; then
        max_scrubs=2
        print_warning "High PG count per OSD detected (>200). Raising osd_max_scrubs to 2." >&2
    fi

    # Backlog adjustment.
    if [ -n "$scrub_time" ] && [ "$scrub_time" -gt 168 ]; then
        max_scrubs=$((max_scrubs + 1))
        print_warning "Estimated deep-scrub time exceeds 7 days. Raising osd_max_scrubs." >&2
    elif [ -n "$scrub_time" ] && [ "$scrub_time" -gt 72 ]; then
        max_scrubs=$((max_scrubs + 1))
        print_notice "Estimated deep-scrub time exceeds 3 days. Raising osd_max_scrubs." >&2
    fi

    # Cap max_scrubs (Phase 0.3, recalibrated in Phase 8). Default cap is 3,
    # matching the osd_max_scrubs default shipped in current Reef (ceph PR
    # #55173) — the old cap of 2 was a downgrade on those clusters. The
    # per-host concurrency product below is an advisory, not the cap's
    # justification: on wide-EC pools the binding constraint is reservation
    # admission, not spindle load (see ROADMAP Phase 8).
    local cap=3
    [ "$AGGRESSIVE_SCRUBS" -eq 1 ] && cap=4
    if [ "$max_scrubs" -gt "$cap" ]; then
        print_warning "osd_max_scrubs computed as $max_scrubs; capped at $cap." >&2
        if [ "$AGGRESSIVE_SCRUBS" -ne 1 ]; then
            print_warning "Use --aggressive-scrubs to allow up to 4 after reviewing per-host headroom." >&2
        fi
        max_scrubs=$cap
    fi
    if [ "$max_scrubs" -gt 1 ]; then
        print_warning "Per-host scrub concurrency = osd_max_scrubs($max_scrubs) × OSDs_per_host." >&2
        print_warning "Verify your hosts can absorb that before applying." >&2
    fi

    # Phase 8.9: do not lower osd_scrub_interval_randomize_ratio on a cluster
    # whose scrubs are admission-limited. Mean attempt cadence is
    # min_interval x (2 + ratio)/2, so lowering the ratio RAISES the attempt
    # rate. On the reference cluster, moving 7.0 -> 0.5 would have taken deep
    # demand from 0.93x measured capacity to 2.09x — more unservable attempts,
    # higher f, lower P(start). A high ratio is protective there. Only act when
    # reservation sampling shows the widest pool is NOT admission-constrained.
    if [ "${reservation_sampled:-0}" -gt 0 ] && [ "${MAX_POOL_WIDTH:-0}" -ge 1 ]; then
        local cur_rand="${current_osd_scrub_interval_randomize_ratio:-}"
        local widest_p
        widest_p=$(_p_start_pct "${reservation_f_pct:-0}" "$MAX_POOL_WIDTH")
        if [[ "$cur_rand" =~ ^[0-9.]+$ ]] \
           && awk -v c="$cur_rand" -v p="$randomize_ratio" 'BEGIN{exit !(c > p)}' \
           && awk -v p="$widest_p" -v t="$ADMISSION_TIGHT_PCT" 'BEGIN{exit !(p < t)}'; then
            print_notice "Widest pool admits at ${widest_p}% per attempt; keeping osd_scrub_interval_randomize_ratio at ${cur_rand} rather than lowering it to ${randomize_ratio} — lowering raises the attempt rate on a cluster that already cannot admit what it generates." >&2
            randomize_ratio="$cur_rand"
        fi
    fi

    # Phase 8 quick fix: object-density gate on scrub sleep. Sleep applies
    # per scrub chunk (osd_scrub_chunk_max, default 25 objects), so per-PG
    # idle time = (objects / 25) × sleep. At ~965k objects/PG a 0.1s sleep
    # adds ~64 minutes of pure idling to every scrub. When real object
    # density is known (cluster mode), scale sleep so per-PG idle stays
    # ≤ ~300s; values under 0.005s round to 0.
    if [ -n "${AVG_OBJECTS_PER_PG:-}" ] && [ "${AVG_OBJECTS_PER_PG:-0}" -gt 0 ] \
       && [ "$scrub_sleep" != "0.0" ]; then
        local idle_s capped_sleep
        idle_s=$(awk -v o="$AVG_OBJECTS_PER_PG" -v s="$scrub_sleep" \
            'BEGIN { printf "%d", (o / 25) * s }')
        if [ "$idle_s" -gt 300 ]; then
            # Floor at 0.01s: below that the value buys no meaningful
            # throttling and just adds per-chunk syscall overhead.
            capped_sleep=$(awk -v o="$AVG_OBJECTS_PER_PG" \
                'BEGIN { v = 300 * 25 / o; if (v < 0.01) v = 0; printf "%.3g", v }')
            if [ "$capped_sleep" = "0" ]; then
                capped_sleep="0.0"
                print_notice "Object-dense PGs (~${AVG_OBJECTS_PER_PG} objects/PG): sleep ${scrub_sleep}s would idle ~$((idle_s / 60)) min per PG scrub, and any useful replacement is below 0.01s/chunk. Emitting 0.0." >&2
            else
                print_notice "Object-dense PGs (~${AVG_OBJECTS_PER_PG} objects/PG): sleep ${scrub_sleep}s would idle ~$((idle_s / 60)) min per PG scrub. Reducing to ${capped_sleep}s." >&2
            fi
            scrub_sleep=$capped_sleep
        fi
    fi

    # Phase 8 quick fix: width-aware scrub window. A deep scrub must hold
    # reservations on ALL acting-set members simultaneously — for EC k+m
    # that is a (k+m)-way conjunction, and P(start) collapses exponentially
    # with width when OSDs run near their reservation cap. A narrow start
    # window shrinks the daily admission-attempt surface on top of that.
    # For pools of width >= 11 (EC 8+3 and wider), recommend a 24h window.
    # TODO(8.1-followup): width alone is a stopgap predicate — the correct
    # gate is P(start) = (1-f)^width < ADMISSION_TIGHT_PCT using measured
    # reservation saturation. Width 11 at f=5% admits at 57% (healthy, no
    # reason to force a 24h window); width 11 at f=40% admits at 0.4%
    # (dire). Key this on ingest_scrub_reservations' f once sampling data
    # is reliably available at settings-computation time.
    if [ "${MAX_POOL_WIDTH:-0}" -ge 11 ] && { [ "$begin_hour" != "0" ] || [ "$end_hour" != "0" ]; }; then
        print_notice "Widest pool needs ${MAX_POOL_WIDTH} simultaneous scrub reservations; narrow start windows starve wide-EC scrub admission. Recommending a 24h window (0-0)." >&2
        begin_hour=0
        end_hour=0
    fi

    local values="$min_interval,$max_interval,$deep_interval,$max_scrubs,$randomize_ratio,$begin_hour,$end_hour,$scrub_sleep,$load_threshold,$mclock_profile"

    if [ "$scheduler" = "mclock" ]; then
        emit_mclock_settings "$values"
    else
        emit_wpq_settings "$values"
    fi
}

# Phase 4.1: per-class WPQ overrides. SSDs/NVMes don't need the same
# throttle as HDDs; emit class-scoped overrides only when the cluster
# has more than one device class and WPQ is active. mClock ignores
# sleep/load_threshold per-class anyway, so this is a no-op under mClock.
# Reads HDD_COUNT/SSD_COUNT/NVME_COUNT and the per-class cap from the
# global flag context; appends "<entity>|<param> = <value>" rows to the
# class_overrides array.
compute_class_overrides() {
    class_overrides=()
    [ "$SCHEDULER" != "wpq" ] && return 0

    # Count non-zero device classes; per-class only makes sense in mixed clusters.
    local distinct=0
    [ "$hdd_count" -gt 0 ]  && distinct=$((distinct + 1))
    [ "$ssd_count" -gt 0 ]  && distinct=$((distinct + 1))
    [ "$nvme_count" -gt 0 ] && distinct=$((distinct + 1))
    [ "$distinct" -lt 2 ] && return 0

    # The global emitter has already chosen an HDD-leaning sleep value;
    # we override that for the faster classes. max_scrubs gets a bump
    # for NVMe (only) and only when the user has opted into the higher
    # cap via --aggressive-scrubs.
    local base_scrubs
    base_scrubs=$(printf '%s\n' "${proposed_settings[@]}" \
        | awk -F' = ' '/^osd_max_scrubs/ { print $2 }')
    : "${base_scrubs:=1}"

    if [ "$ssd_count" -gt 0 ]; then
        class_overrides+=("osd/class:ssd|osd_scrub_sleep = 0.0")
    fi
    if [ "$nvme_count" -gt 0 ]; then
        class_overrides+=("osd/class:nvme|osd_scrub_sleep = 0.0")
        if [ "$AGGRESSIVE_SCRUBS" -eq 1 ] && [ "$base_scrubs" -lt 3 ]; then
            class_overrides+=("osd/class:nvme|osd_max_scrubs = $((base_scrubs + 1))")
        fi
    fi
}


# Phase 2.3: advisory for mClock benchmark when measured IOPS look low.
# Default per-OSD baselines: 315 (HDD) / 21500 (SSD). Anything <10% of
# the expected value suggests a bad benchmark run on OSD init.
mclock_benchmark_advisory() {
    [ "$SCHEDULER" != "mclock" ] && return 0
    [ "$FROM_CLUSTER" -ne 1 ] && return 0
    local hdd_iops="${current_osd_mclock_max_capacity_iops_hdd:-}"
    local ssd_iops="${current_osd_mclock_max_capacity_iops_ssd:-}"
    local flagged=0
    if [ -n "$hdd_iops" ] && [ "$hdd_count" -gt 0 ]; then
        # Compare floor(hdd_iops) against a low-water mark of 50.
        local hi=${hdd_iops%.*}
        if [ "${hi:-0}" -lt 50 ] 2>/dev/null; then
            print_warning "mClock HDD benchmark reports $hdd_iops IOPS/OSD — suspiciously low."
            flagged=1
        fi
    fi
    if [ -n "$ssd_iops" ] && [ "$ssd_count$nvme_count" != "00" ]; then
        local si=${ssd_iops%.*}
        if [ "${si:-0}" -lt 5000 ] 2>/dev/null; then
            print_warning "mClock SSD/NVMe benchmark reports $ssd_iops IOPS/OSD — suspiciously low."
            flagged=1
        fi
    fi
    if [ "$flagged" -eq 1 ]; then
        echo "  Recommend re-running the benchmark:"
        echo "    ceph config set osd osd_mclock_force_run_benchmark_on_init true"
        echo "    # then restart OSDs one host at a time"
        echo "    # then: ceph config set osd osd_mclock_force_run_benchmark_on_init false"
    fi
}

# -----------------------------------------------------------------------------
# Phase 1 — ceph CLI shim and cluster-ingest helpers
# -----------------------------------------------------------------------------

# run_ceph runs `ceph $@` against the live cluster, OR reads from a fixture
# file under $CEPH_FIXTURE_DIR when that env var is set. The mapping
# command-line → fixture-file is explicit and limited to the calls we make.
run_ceph() {
    if [ -n "${CEPH_FIXTURE_DIR:-}" ]; then
        local fixture=""
        case "$*" in
            "osd tree --format json")              fixture="osd_tree.json" ;;
            "osd df tree --format json")           fixture="osd_df_tree.json" ;;
            "osd pool ls detail --format json")    fixture="osd_pool_ls_detail.json" ;;
            "df detail --format json")             fixture="df_detail.json" ;;
            "config dump --format json")           fixture="config_dump.json" ;;
            "config get osd osd_op_queue")         fixture="osd_op_queue.txt" ;;
            "pg dump pgs_brief --format json")     fixture="pg_dump_pgs_brief.json" ;;
            "health detail --format json")         fixture="health_detail.json" ;;
            "version")                              fixture="version.txt" ;;
            "osd pool get "*" "*" --format json")
                # Phase 5.3-prep: pool-get fixtures live at
                # pool_get_<pool>_<key>.json. Missing file means "no
                # override is set on that pool" — silently return
                # non-zero so the caller's ENOENT path runs.
                local args=($*)
                fixture="pool_get_${args[3]}_${args[4]}.json"
                [ ! -r "$CEPH_FIXTURE_DIR/$fixture" ] && return 1 ;;
            "tell osd."*" bench "*)
                # Phase 3.5: bench fixtures live at bench_osd_<id>.json.
                # Missing file silently returns non-zero so the caller
                # can skip the sample.
                local args=($*)
                local osd_part="${args[1]}"   # "osd.5"
                local osd_id="${osd_part#osd.}"
                fixture="bench_osd_${osd_id}.json"
                [ ! -r "$CEPH_FIXTURE_DIR/$fixture" ] && return 1 ;;
            "tell osd."*" dump_scrub_reservations")
                # Phase 8.1: reservation fixtures live at
                # dump_scrub_reservations_osd_<id>.json. Missing file silently
                # returns non-zero so the caller skips that sample — same
                # contract as the bench fixtures.
                local args=($*)
                local osd_part="${args[1]}"          # "osd.5"
                local osd_id="${osd_part#osd.}"
                fixture="dump_scrub_reservations_osd_${osd_id}.json"
                [ ! -r "$CEPH_FIXTURE_DIR/$fixture" ] && return 1 ;;
            "fsid")
                fixture="fsid.txt" ;;
            "osd erasure-code-profile get "*" --format json")
                # Phase 1.4 (live-cluster fix): EC profile fixtures
                # live at ec_profile_<name>.json. Missing file silently
                # returns non-zero so the caller falls back.
                local args=($*)
                fixture="ec_profile_${args[3]}.json"
                [ ! -r "$CEPH_FIXTURE_DIR/$fixture" ] && return 1 ;;
            *)
                print_error "run_ceph: no fixture mapped for: ceph $*"
                return 1 ;;
        esac
        if [ ! -r "$CEPH_FIXTURE_DIR/$fixture" ]; then
            print_error "Fixture not readable: $CEPH_FIXTURE_DIR/$fixture"
            return 1
        fi
        cat "$CEPH_FIXTURE_DIR/$fixture"
    else
        # shellcheck disable=SC2068
        ceph $@
    fi
}

# Phase 1.1, 1.9: validate prerequisites for cluster ingest.
check_ceph_environment() {
    if [ -z "${CEPH_FIXTURE_DIR:-}" ]; then
        command -v ceph >/dev/null 2>&1 || {
            print_error "'ceph' not found in PATH. --from-cluster must run on a node with the ceph client installed."
            exit 3
        }
    fi
    command -v jq >/dev/null 2>&1 || {
        print_error "'jq' not found in PATH. Install jq (it ships on Ceph nodes anyway) or omit --from-cluster."
        exit 3
    }

    # Phase 1.9: mon-node detection.
    if [ -n "${CEPH_FIXTURE_DIR:-}" ]; then
        return 0  # fixture mode bypasses
    fi
    if [ "$FORCE_NON_MON" -eq 1 ]; then
        print_warning "--force: skipping mon-node check."
        return 0
    fi
    if [ -d /var/lib/ceph/mon ] || [ -r /etc/ceph/ceph.client.admin.keyring ]; then
        return 0
    fi
    print_error "Doesn't look like a Ceph monitor node (no /var/lib/ceph/mon and no admin keyring)."
    print_error "Some 'ceph' commands are slow or unauthorized off a mon. Pass --force to override."
    exit 3
}

# Phase 1.2: device-class OSD counts + max OSDs/host + host count.
osds_per_host_max=0
ingest_osd_inventory() {
    local tree
    tree=$(run_ceph osd tree --format json) || exit 4

    hdd_count=$(echo "$tree" | jq '[.nodes[] | select(.type=="osd" and .device_class=="hdd")] | length')
    ssd_count=$(echo "$tree" | jq '[.nodes[] | select(.type=="osd" and .device_class=="ssd")] | length')
    nvme_count=$(echo "$tree" | jq '[.nodes[] | select(.type=="osd" and .device_class=="nvme")] | length')

    # max OSDs per host (Phase 0.3 / 3.4 per-host concurrency).
    osds_per_host_max=$(echo "$tree" | jq '
        [.nodes[] | select(.type=="host") | .children | length] | max // 0')

    # Host count (Phase 3.1 network ceiling).
    if [ -z "$HOST_COUNT" ]; then
        HOST_COUNT=$(echo "$tree" | jq '[.nodes[] | select(.type=="host")] | length')
    fi

    print_notice "OSD inventory: HDD=$hdd_count SSD=$ssd_count NVMe=$nvme_count; hosts=$HOST_COUNT; max OSDs/host=$osds_per_host_max"
}

# Phase 3.1: detect per-host NIC speed via ethtool. Returns Mbps via stdout,
# or 0 if no usable interface found.
detect_nic_speed_mbps() {
    command -v ip >/dev/null 2>&1 || { echo 0; return; }
    command -v ethtool >/dev/null 2>&1 || { echo 0; return; }
    local max_speed=0 iface speed
    # ip -j gives JSON. Pick UP, non-loopback, non-virtual interfaces.
    for iface in $(ip -j link show 2>/dev/null \
                    | jq -r '.[] | select(.operstate=="UP" and .ifname != "lo") | .ifname' 2>/dev/null); do
        speed=$(ethtool "$iface" 2>/dev/null | awk '/^[[:space:]]*Speed:/ { print $2 }' | grep -oE '[0-9]+' | head -1)
        if [ -n "$speed" ] && [ "$speed" -gt "$max_speed" ]; then
            max_speed=$speed
        fi
    done
    echo "$max_speed"
}

# Phase 3.1: derive the network ceiling from --nic-gbps (or ethtool in
# from-cluster mode) and HOST_COUNT. Sets the NIC_MBPS / NIC_SOURCE /
# NETWORK_CEILING globals. Leaves NETWORK_CEILING=0 when there's not
# enough information (prompt mode without --hosts and --nic-gbps).
compute_network_ceiling() {
    if [ -n "$NIC_GBPS" ]; then
        NIC_SOURCE="${NIC_SOURCE:---nic-gbps}"
    elif [ "$FROM_CLUSTER" -eq 1 ]; then
        local detected
        detected=$(detect_nic_speed_mbps)
        if [ "$detected" -gt 0 ]; then
            # Convert Mbps -> Gbps for display; keep Mbps for math.
            NIC_GBPS=$(awk "BEGIN { printf \"%g\", $detected / 1000 }")
            NIC_SOURCE="ethtool (local node)"
            # ethtool only sees THIS host's NIC. On a mon-only node the
            # OSD nodes may have a faster (or slower) NIC, in which case
            # the network ceiling is wrong. Encourage --nic-gbps when
            # the operator knows the OSD-side speed.
            print_warning "NIC speed auto-detected from THIS node's interfaces (${NIC_GBPS} Gbps)."
            print_warning "  If the OSD nodes have different NICs, pass --nic-gbps N to override."
        fi
    fi
    if [ -n "$NIC_GBPS" ] && [ -n "$HOST_COUNT" ] && [ "$HOST_COUNT" -gt 0 ]; then
        # 1 Gbps = 125 MB/s (1000/8). awk handles fractional NIC speeds.
        NIC_MBPS=$(awk "BEGIN { printf \"%d\", $NIC_GBPS * 125 }")
        NETWORK_CEILING=$((HOST_COUNT * NIC_MBPS))
    fi
}

# -----------------------------------------------------------------------------
# Phase 3.5: empirical per-class throughput via `ceph tell osd.X bench`.
# -----------------------------------------------------------------------------

# Pick one OSD per host per device class. Skips OSDs that are down, and
# skips OSDs that participate in any non-clean PG (so we don't bench an OSD
# that's currently backfilling — would give an artificially low number).
# Echoes lines: <osd_id>\t<device_class>\t<host>
select_bench_osds() {
    local tree
    tree=$(run_ceph osd tree --format json) || return 1

    # OSDs to skip: any OSD in the up_set of a PG that's genuinely busy
    # with recovery work. "active+clean+scrubbing" / "...+deep" are normal
    # background scrubs and don't make the OSD unrepresentative — earlier
    # versions of this filter excluded those too, which on busy clusters
    # (600 PGs scrubbing at once) left zero eligible HDD OSDs.
    local busy_osds
    busy_osds=" $(run_ceph pg dump pgs_brief --format json 2>/dev/null | jq -r '
        .pg_stats[]?
        | select(.state | test("backfill|recover|peering|stale|down|incomplete|creating|remapped"))
        | .up[]?
    ' | sort -u | tr '\n' ' ') "

    # One pass: walk hosts to build osd_id -> host map; then walk OSDs and
    # emit (id, class, host) for each up OSD. awk picks first per (host, class).
    echo "$tree" | jq -r '
        ([.nodes[] | select(.type=="host") | .name as $h | .children[] | {(tostring): $h}] | add) as $osd_to_host
        | .nodes[] | select(.type=="osd" and .status=="up")
        | "\(.id)\t\(.device_class)\t\($osd_to_host[(.id|tostring)])"
    ' | awk -v busy="$busy_osds" -F'\t' '
        { if (index(busy, " " $1 " ")) next }
        { key = $3 "|" $2 }
        !(key in seen) { print; seen[key] = 1 }
    '
}

# Run `ceph tell osd.<id> bench` and parse bytes_per_sec on stdout. Empty on
# failure (and the reason printed to stderr for the operator to see).
# Bench writes `total` bytes in `blocksize` chunks. Defaults match the Ceph CLI:
#   total=1073741824 (1 GiB), blocksize=4194304 (4 MiB).
# `--format json` is REQUIRED — without it Ceph emits human-readable text
# and jq returns nothing.
#
# Ceph imposes a safety cap: count <= osd_bench_large_size_max_throughput
# (100 MiB/s by default) × osd_bench_duration (30 s) = ~3 GiB for block
# sizes >= 1 MiB. If we exceed it, we get EINVAL with the cap embedded in
# the message; this function parses the cap and retries automatically.
#
# Caveat: there is no abort facility on the Ceph side; if the caller dies
# mid-bench, the OSD finishes on its own.
bench_one_osd() {
    local osd_id=$1
    local total=${2:-1073741824}
    local blocksize=${3:-4194304}
    local errfile="/tmp/scrubadub-bench-$$.err"
    local out rc cap
    out=$(run_ceph tell "osd.$osd_id" bench "$total" "$blocksize" --format json 2>"$errfile")
    rc=$?

    # Auto-retry below the Ceph safety cap when EINVAL hits it.
    if [ $rc -ne 0 ] && grep -q "'count' values greater than" "$errfile" 2>/dev/null; then
        cap=$(grep -oE "greater than [0-9]+" "$errfile" | head -1 | awk '{print $3}')
        if [ -n "$cap" ] && [ "$cap" -gt 0 ]; then
            out=$(run_ceph tell "osd.$osd_id" bench "$cap" "$blocksize" --format json 2>"$errfile")
            rc=$?
        fi
    fi

    if [ $rc -ne 0 ] || [ -z "$out" ]; then
        if [ -s "$errfile" ]; then
            echo
            head -1 "$errfile" | sed 's/^/    error: /' >&2
        fi
        rm -f "$errfile"
        return 1
    fi
    rm -f "$errfile"
    echo "$out" | jq -r '.bytes_per_sec // empty' 2>/dev/null
}

# Aggregate a list of numbers (one per line on stdin) using $1 method.
# Methods: p25 | median | trimmed-mean | mean.
aggregate_bench() {
    local method=$1
    sort -n | awk -v method="$method" '
        { values[NR] = $1 }
        END {
            n = NR
            if (n == 0) exit
            if (method == "median") {
                if (n % 2) print values[int((n+1)/2)]
                else printf "%.0f\n", (values[n/2] + values[n/2+1]) / 2
            } else if (method == "p25") {
                idx = int(n * 0.25); if (idx < 1) idx = 1
                print values[idx]
            } else if (method == "trimmed-mean") {
                trim = int(n * 0.1)
                sum = 0; count = 0
                for (i = trim + 1; i <= n - trim; i++) { sum += values[i]; count++ }
                if (count > 0) printf "%.0f\n", sum / count
            } else if (method == "mean") {
                sum = 0; for (i = 1; i <= n; i++) sum += values[i]
                printf "%.0f\n", sum / n
            }
        }
    '
}

# Resolve the default cache file path. Sets BENCH_CACHE_FILE if empty.
resolve_bench_cache_path() {
    [ -n "$BENCH_CACHE_FILE" ] && return
    local fsid
    fsid=$(run_ceph fsid 2>/dev/null | tr -d ' \n' || echo "unknown")
    [ -z "$fsid" ] && fsid="unknown"
    BENCH_CACHE_FILE="${HOME:-/tmp}/.scrubadub/bench-${fsid}.json"
}

# Load cached bench results. Sets BENCH_*_MBPS, BENCH_*_OUTLIERS, BENCH_*_SOURCE
# if the cache exists and is fresher than BENCH_MAX_AGE_DAYS. Returns 0 on
# successful load, non-zero otherwise.
load_bench_cache() {
    resolve_bench_cache_path
    [ "$REFRESH_BENCH" -eq 1 ] && return 1
    [ ! -r "$BENCH_CACHE_FILE" ] && return 1

    # Reject stale caches.
    local age_days now mtime
    now=$(date +%s)
    mtime=$(stat -c %Y "$BENCH_CACHE_FILE" 2>/dev/null || echo 0)
    age_days=$(( (now - mtime) / 86400 ))
    if [ "$age_days" -gt "$BENCH_MAX_AGE_DAYS" ]; then
        print_warning "Bench cache is $age_days days old (>$BENCH_MAX_AGE_DAYS); ignoring. Use --refresh-bench to re-run."
        return 1
    fi

    local cache_date
    cache_date=$(jq -r '.timestamp // empty' "$BENCH_CACHE_FILE" 2>/dev/null)
    [ -z "$cache_date" ] && return 1

    BENCH_HDD_MBPS=$(jq -r '.hdd.baseline_mbps // empty' "$BENCH_CACHE_FILE")
    BENCH_SSD_MBPS=$(jq -r '.ssd.baseline_mbps // empty' "$BENCH_CACHE_FILE")
    BENCH_NVME_MBPS=$(jq -r '.nvme.baseline_mbps // empty' "$BENCH_CACHE_FILE")
    BENCH_HDD_SAMPLE_COUNT=$(jq -r '.hdd.sample_count // 0' "$BENCH_CACHE_FILE")
    BENCH_SSD_SAMPLE_COUNT=$(jq -r '.ssd.sample_count // 0' "$BENCH_CACHE_FILE")
    BENCH_NVME_SAMPLE_COUNT=$(jq -r '.nvme.sample_count // 0' "$BENCH_CACHE_FILE")

    mapfile -t BENCH_HDD_OUTLIERS < <(jq -r '.hdd.outliers[]? // empty' "$BENCH_CACHE_FILE")
    mapfile -t BENCH_SSD_OUTLIERS < <(jq -r '.ssd.outliers[]? // empty' "$BENCH_CACHE_FILE")
    mapfile -t BENCH_NVME_OUTLIERS < <(jq -r '.nvme.outliers[]? // empty' "$BENCH_CACHE_FILE")

    local agg
    agg=$(jq -r '.aggregate // "median"' "$BENCH_CACHE_FILE")
    [ -n "$BENCH_HDD_MBPS" ] && BENCH_HDD_SOURCE="$agg of $BENCH_HDD_SAMPLE_COUNT sampled, cache $cache_date"
    [ -n "$BENCH_SSD_MBPS" ] && BENCH_SSD_SOURCE="$agg of $BENCH_SSD_SAMPLE_COUNT sampled, cache $cache_date"
    [ -n "$BENCH_NVME_MBPS" ] && BENCH_NVME_SOURCE="$agg of $BENCH_NVME_SAMPLE_COUNT sampled, cache $cache_date"
    return 0
}

# Save bench results (currently held in BENCH_*) to the cache file.
save_bench_cache() {
    resolve_bench_cache_path
    local cache_dir
    cache_dir=$(dirname "$BENCH_CACHE_FILE")
    mkdir -p "$cache_dir" 2>/dev/null || true
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Build JSON. Handle the outlier arrays carefully — they may be empty.
    jq -n \
        --arg ts "$now" \
        --arg agg "$BENCH_AGGREGATE" \
        --argjson hdd_b "${BENCH_HDD_MBPS:-null}" \
        --argjson ssd_b "${BENCH_SSD_MBPS:-null}" \
        --argjson nvme_b "${BENCH_NVME_MBPS:-null}" \
        --argjson hdd_n "${BENCH_HDD_SAMPLE_COUNT:-0}" \
        --argjson ssd_n "${BENCH_SSD_SAMPLE_COUNT:-0}" \
        --argjson nvme_n "${BENCH_NVME_SAMPLE_COUNT:-0}" \
        --argjson hdd_o "$(printf '%s\n' "${BENCH_HDD_OUTLIERS[@]}" | jq -R . | jq -s .)" \
        --argjson ssd_o "$(printf '%s\n' "${BENCH_SSD_OUTLIERS[@]}" | jq -R . | jq -s .)" \
        --argjson nvme_o "$(printf '%s\n' "${BENCH_NVME_OUTLIERS[@]}" | jq -R . | jq -s .)" \
        '{
            timestamp: $ts,
            aggregate: $agg,
            hdd:  { baseline_mbps: $hdd_b,  sample_count: $hdd_n,  outliers: ($hdd_o  | map(select(length > 0))) },
            ssd:  { baseline_mbps: $ssd_b,  sample_count: $ssd_n,  outliers: ($ssd_o  | map(select(length > 0))) },
            nvme: { baseline_mbps: $nvme_b, sample_count: $nvme_n, outliers: ($nvme_o | map(select(length > 0))) }
        }' > "$BENCH_CACHE_FILE"
    print_success "Bench results cached to $BENCH_CACHE_FILE"
}

# Run benches against the selected OSDs and populate result globals. Uses
# a 4 GiB total for NVMe (small samples hit cache and report bogus numbers)
# and 1 GiB for HDD. Traps SIGINT so Ctrl-C exits cleanly — the in-flight
# bench will finish on the OSD side regardless.
_bench_interrupted=0
_bench_sigint_handler() {
    _bench_interrupted=1
    print_warning "Ctrl-C received — finishing current bench (no abort facility); skipping remaining samples."
}
# Per-class min/max/median + labels for the summary line. Empty when not benched.
BENCH_HDD_MIN=""    BENCH_HDD_MAX=""    BENCH_HDD_MEDIAN=""    BENCH_HDD_MIN_LABEL=""    BENCH_HDD_MAX_LABEL=""
BENCH_SSD_MIN=""    BENCH_SSD_MAX=""    BENCH_SSD_MEDIAN=""    BENCH_SSD_MIN_LABEL=""    BENCH_SSD_MAX_LABEL=""
BENCH_NVME_MIN=""   BENCH_NVME_MAX=""   BENCH_NVME_MEDIAN=""   BENCH_NVME_MIN_LABEL=""   BENCH_NVME_MAX_LABEL=""

# Accumulated across classes; surfaced at end of run_benchmarks.
declare -a BENCH_ERRORS=()

run_benchmarks() {
    local osd_list
    osd_list=$(select_bench_osds) || { print_error "Couldn't select bench OSDs"; return 1; }
    if [ -z "$osd_list" ]; then
        print_warning "No bench-eligible OSDs found (all up+in OSDs are busy with recovery work?)."
        return 1
    fi

    # Group by class so progress + summary can be per-class.
    local -a hdd_entries=() ssd_entries=() nvme_entries=()
    local osd_id osd_class host
    while IFS=$'\t' read -r osd_id osd_class host; do
        [ -z "$osd_id" ] && continue
        case "$osd_class" in
            hdd)  hdd_entries+=("$osd_id|$host") ;;
            ssd)  ssd_entries+=("$osd_id|$host") ;;
            nvme) nvme_entries+=("$osd_id|$host") ;;
        esac
    done <<< "$osd_list"

    BENCH_ERRORS=()
    trap _bench_sigint_handler INT
    [ "${#hdd_entries[@]}"  -gt 0 ] && _bench_class hdd  1073741824 "${hdd_entries[@]}"
    [ "${#ssd_entries[@]}"  -gt 0 ] && _bench_class ssd  1073741824 "${ssd_entries[@]}"
    [ "${#nvme_entries[@]}" -gt 0 ] && _bench_class nvme 2147483648 "${nvme_entries[@]}"
    trap - INT

    # Did any class succeed? If not, surface errors and bail.
    if [ -z "$BENCH_HDD_MBPS" ] && [ -z "$BENCH_SSD_MBPS" ] && [ -z "$BENCH_NVME_MBPS" ]; then
        print_warning "All bench samples failed."
        _print_bench_errors
        return 1
    fi

    _print_bench_summary
    _print_bench_errors
    save_bench_cache
}

# Bench one device class. Prints "Benching N <class> OSDs.....", one
# dot per success / "E" per failure, then a summary line. Populates
# class-specific BENCH_<CLASS>_* globals. Quiet by default — actual
# per-OSD output is only printed if everything fails for that class.
_bench_class() {
    local class=$1 total=$2
    shift 2
    local entries=("$@")
    local count=${#entries[@]}
    printf "Benching %d %s OSD%s" "$count" "$class" "$([ "$count" -ne 1 ] && echo s)"
    local -a samples=() ids=() hosts=()
    local err_count=0 entry osd_id host bytes_per_sec mbps err_msg
    local err_capture
    err_capture=$(mktemp 2>/dev/null || echo "/tmp/scrubadub-bench-class.err.$$")
    for entry in "${entries[@]}"; do
        if [ "$_bench_interrupted" -eq 1 ]; then break; fi
        osd_id="${entry%|*}"
        host="${entry#*|}"
        bytes_per_sec=$(bench_one_osd "$osd_id" "$total" 2>"$err_capture")
        if [ -z "$bytes_per_sec" ]; then
            printf "E"
            err_count=$((err_count + 1))
            err_msg=$(head -1 "$err_capture" 2>/dev/null)
            BENCH_ERRORS+=("osd.$osd_id ($host): ${err_msg:-(no error detail)}")
            continue
        fi
        mbps=$(awk "BEGIN { printf \"%d\", $bytes_per_sec / 1048576 }")
        samples+=("$mbps")
        ids+=("$osd_id")
        hosts+=("$host")
        printf "."
    done
    rm -f "$err_capture"
    local ok=$((count - err_count))
    if [ "$_bench_interrupted" -eq 1 ]; then
        printf " interrupted. (%d/%d before stop)\n" "$ok" "$count"
    elif [ "$err_count" -gt 0 ]; then
        printf " done. (%d/%d succeeded, %d failed)\n" "$ok" "$count" "$err_count"
    else
        printf " done. (%d/%d succeeded)\n" "$ok" "$count"
    fi
    [ "${#samples[@]}" -eq 0 ] && return

    # Aggregate to baseline + compute min/max/median.
    local baseline
    baseline=$(printf '%s\n' "${samples[@]}" | aggregate_bench "$BENCH_AGGREGATE")
    local -a sorted=()
    mapfile -t sorted < <(printf '%s\n' "${samples[@]}" | sort -n)
    local n=${#sorted[@]}
    local s_min="${sorted[0]}" s_max="${sorted[$((n-1))]}" s_med
    if [ $((n % 2)) -eq 1 ]; then
        s_med="${sorted[$((n/2))]}"
    else
        s_med=$(awk "BEGIN { printf \"%d\", (${sorted[$((n/2 - 1))]} + ${sorted[$((n/2))]}) / 2 }")
    fi

    # Map min/max back to osd_id/host for the summary line.
    local i min_label="" max_label=""
    for i in "${!samples[@]}"; do
        if [ -z "$min_label" ] && [ "${samples[$i]}" -eq "$s_min" ]; then
            min_label="osd.${ids[$i]} on ${hosts[$i]}"
        fi
        if [ -z "$max_label" ] && [ "${samples[$i]}" -eq "$s_max" ]; then
            max_label="osd.${ids[$i]} on ${hosts[$i]}"
        fi
    done

    # Stash per-class globals. Avoid eval — explicit case keeps grep'ability.
    case "$class" in
        hdd)
            BENCH_HDD_MBPS=$baseline
            BENCH_HDD_SAMPLE_COUNT=${#samples[@]}
            BENCH_HDD_SOURCE="$BENCH_AGGREGATE of ${#samples[@]} sampled, just now"
            BENCH_HDD_MIN=$s_min; BENCH_HDD_MAX=$s_max; BENCH_HDD_MEDIAN=$s_med
            BENCH_HDD_MIN_LABEL=$min_label; BENCH_HDD_MAX_LABEL=$max_label
            _flag_outliers BENCH_HDD_OUTLIERS samples ids "$baseline"
            ;;
        ssd)
            BENCH_SSD_MBPS=$baseline
            BENCH_SSD_SAMPLE_COUNT=${#samples[@]}
            BENCH_SSD_SOURCE="$BENCH_AGGREGATE of ${#samples[@]} sampled, just now"
            BENCH_SSD_MIN=$s_min; BENCH_SSD_MAX=$s_max; BENCH_SSD_MEDIAN=$s_med
            BENCH_SSD_MIN_LABEL=$min_label; BENCH_SSD_MAX_LABEL=$max_label
            _flag_outliers BENCH_SSD_OUTLIERS samples ids "$baseline"
            ;;
        nvme)
            BENCH_NVME_MBPS=$baseline
            BENCH_NVME_SAMPLE_COUNT=${#samples[@]}
            BENCH_NVME_SOURCE="$BENCH_AGGREGATE of ${#samples[@]} sampled, just now"
            BENCH_NVME_MIN=$s_min; BENCH_NVME_MAX=$s_max; BENCH_NVME_MEDIAN=$s_med
            BENCH_NVME_MIN_LABEL=$min_label; BENCH_NVME_MAX_LABEL=$max_label
            _flag_outliers BENCH_NVME_OUTLIERS samples ids "$baseline"
            ;;
    esac
}

_print_bench_summary() {
    echo
    echo "Bench summary (aggregate: $BENCH_AGGREGATE):"
    if [ -n "$BENCH_HDD_MBPS" ]; then
        printf "  HDD  (%d samples): min %d (%s) / median %d / max %d MB/s\n" \
            "$BENCH_HDD_SAMPLE_COUNT" "$BENCH_HDD_MIN" "$BENCH_HDD_MIN_LABEL" \
            "$BENCH_HDD_MEDIAN" "$BENCH_HDD_MAX"
    fi
    if [ -n "$BENCH_SSD_MBPS" ]; then
        printf "  SSD  (%d samples): min %d (%s) / median %d / max %d MB/s\n" \
            "$BENCH_SSD_SAMPLE_COUNT" "$BENCH_SSD_MIN" "$BENCH_SSD_MIN_LABEL" \
            "$BENCH_SSD_MEDIAN" "$BENCH_SSD_MAX"
    fi
    if [ -n "$BENCH_NVME_MBPS" ]; then
        printf "  NVMe (%d samples): min %d (%s) / median %d / max %d MB/s\n" \
            "$BENCH_NVME_SAMPLE_COUNT" "$BENCH_NVME_MIN" "$BENCH_NVME_MIN_LABEL" \
            "$BENCH_NVME_MEDIAN" "$BENCH_NVME_MAX"
    fi
}

_print_bench_errors() {
    [ "${#BENCH_ERRORS[@]}" -eq 0 ] && return
    echo
    print_warning "Bench errors (${#BENCH_ERRORS[@]}):"
    local err
    for err in "${BENCH_ERRORS[@]}"; do
        echo "  $err"
    done
}

# Helper: populate outlier list for one class. Args: out_array_name,
# samples_array_name, ids_array_name, baseline.
_flag_outliers() {
    local out_name=$1 samples_name=$2 ids_name=$3 baseline=$4
    local -n out_ref=$out_name
    local -n samples_ref=$samples_name
    local -n ids_ref=$ids_name
    out_ref=()
    local threshold_mbps
    threshold_mbps=$(awk "BEGIN { printf \"%d\", $baseline * $OUTLIER_THRESHOLD }")
    local i
    for i in "${!samples_ref[@]}"; do
        if [ "${samples_ref[$i]}" -lt "$threshold_mbps" ]; then
            out_ref+=("osd.${ids_ref[$i]} (${samples_ref[$i]} MB/s)")
        fi
    done
}

# Top-level: load cache if fresh, else run benches. Called from main when
# --bench-osds is set. Substitutes results into HDD_THROUGHPUT etc.
load_or_run_benchmarks() {
    if load_bench_cache; then
        print_notice "Loaded bench cache from $BENCH_CACHE_FILE"
    else
        print_header "Running per-OSD benchmarks"
        echo "Sampling one OSD per host per device class. Each HDD bench writes"
        echo "~1 GiB; each NVMe bench writes ~2 GiB (Ceph caps it at 3 GiB). Run serially to avoid"
        echo "measuring cluster contention. Ctrl-C to stop launching new benches"
        echo "(the in-flight bench will finish on the OSD side — no abort exists)."
        echo
        run_benchmarks || return 1
    fi

    [ -n "$BENCH_HDD_MBPS" ]  && HDD_THROUGHPUT=$BENCH_HDD_MBPS
    [ -n "$BENCH_SSD_MBPS" ]  && SSD_THROUGHPUT=$BENCH_SSD_MBPS
    [ -n "$BENCH_NVME_MBPS" ] && NVME_THROUGHPUT=$BENCH_NVME_MBPS
}

# Phase 1.3: per-device-class PG counts + stddev/mean warning.
pg_imbalance_warning=""
ingest_pg_distribution() {
    local df
    df=$(run_ceph osd df tree --format json) || exit 4

    hdd_pg_count=$(echo "$df" | jq '[.nodes[] | select(.device_class=="hdd") | .pgs] | add // 0')
    ssd_pg_count=$(echo "$df" | jq '[.nodes[] | select(.device_class=="ssd") | .pgs] | add // 0')
    nvme_pg_count=$(echo "$df" | jq '[.nodes[] | select(.device_class=="nvme") | .pgs] | add // 0')

    # PG variance per class: stddev/mean > 0.15 triggers a rebalance hint.
    local report
    report=$(echo "$df" | jq -r '
        def avg: add / length;
        def stddev: . as $a | ($a | avg) as $m | ($a | map((. - $m) * (. - $m)) | avg | sqrt);
        ["hdd","ssd","nvme"][] as $c
        | [.nodes[] | select(.device_class==$c) | .pgs] as $pgs
        | if ($pgs | length) > 1 then
            ($pgs | avg) as $m | ($pgs | stddev) as $s
            | if $m > 0 and ($s / $m) > 0.15 then
                "\($c) imbalanced: stddev/mean=\(($s / $m * 100) | floor)% across \($pgs | length) OSDs"
              else empty end
          else empty end
    ')
    if [ -n "$report" ]; then
        pg_imbalance_warning="$report"
    fi
    # These are PG-OSD assignment counts (each PG counted once per
    # replica/chunk), not unique-PG counts. Used for per-OSD averages.
    print_notice "PG-OSD assignments by class: HDD=$hdd_pg_count SSD=$ssd_pg_count NVMe=$nvme_pg_count"
    if [ -n "$pg_imbalance_warning" ]; then
        while IFS= read -r line; do
            print_warning "PG imbalance — $line"
        done <<< "$pg_imbalance_warning"
        print_warning "Consider 'ceph osd reweight-by-pg' or the pg_autoscaler before tuning scrubs."
    fi
}

# Phase 1.4 helper: look up an EC profile's k and m by name. Caches
# results in EC_PROFILE_CACHE_<name> globals so we make at most one
# `ceph` call per profile per run. Echoes "<k> <m>" on stdout, or
# empty if the profile can't be read.
ec_profile_km() {
    local profile=$1
    [ -z "$profile" ] && return
    # Bash variable names can't contain dots / dashes; sanitize the key.
    local cache_key="EC_PROFILE_CACHE_${profile//[^A-Za-z0-9_]/_}"
    if [ -n "${!cache_key:-}" ]; then
        echo "${!cache_key}"
        return
    fi
    local json k m
    json=$(run_ceph osd erasure-code-profile get "$profile" --format json 2>/dev/null || true)
    if [ -n "$json" ]; then
        k=$(echo "$json" | jq -r '.k // empty')
        m=$(echo "$json" | jq -r '.m // empty')
    fi
    if [ -n "$k" ] && [ -n "$m" ]; then
        printf -v "$cache_key" '%s %s' "$k" "$m"
        echo "$k $m"
    fi
}

# Phase 1.4: compute weighted-average PG size from real per-pool data.
# Updates AVG_PG_SIZE and AVG_PG_SIZE_SOURCE if the user didn't override.
# Also derives DATA_FACTOR if it was left at the default — uses the
# largest pool's overhead, since deep-scrub time is dominated by it.
ingest_pool_details() {
    local pools df pool_rows
    pools=$(run_ceph osd pool ls detail --format json) || exit 4
    df=$(run_ceph df detail --format json) || exit 4

    # Per-pool rows: name, stored_bytes, pg_num, replica_size, ec_k+m_or_blank,
    # autoscale_mode. The autoscale mode lives at .pg_autoscale_mode on newer
    # Ceph, or under .options.pg_autoscale_mode on older; try both.
    pool_rows=$(echo "$pools" "$df" | jq -s -r '
        .[0] as $pools | .[1] as $df
        | $pools[] | . as $p
        | ($df.pools[] | select(.id == $p.pool_id)) as $d
        | {
            name: $p.pool_name,
            stored: ($d.stats.stored // 0),
            pg_num: $p.pg_num,
            type: $p.type,                # 1=replicated, 3=erasure
            size: $p.size,                # replica size (or k+m for EC)
            ec_profile: $p.erasure_code_profile,
            autoscale: ($p.pg_autoscale_mode // $p.options.pg_autoscale_mode // "?")
          }
        | "\(.name)\t\(.stored)\t\(.pg_num)\t\(.type)\t\(.size)\t\(.ec_profile)\t\(.autoscale)"
    ')

    # Walk rows, summing stored and weighted PG-size; pick the largest pool.
    local total_stored=0
    local total_pgs=0
    local largest_name="" largest_stored=0 largest_factor_num=3 largest_factor_den=1
    local row_count=0
    large_pg_pools=()
    pool_widths=()
    local threshold_bytes=$((LARGE_PG_THRESHOLD_GIB * 1073741824))
    while IFS=$'\t' read -r name stored pg_num ptype psize ec_profile autoscale; do
        [ -z "$name" ] && continue
        row_count=$((row_count + 1))
        total_stored=$((total_stored + stored))
        total_pgs=$((total_pgs + pg_num))

        # Flag pools whose average per-PG data is large. Big PGs make deep
        # scrub and recovery take proportionally longer, and are the usual
        # reason a single pool falls behind on scrubs while the rest keep up.
        if [ "$pg_num" -gt 0 ] && [ "$stored" -gt 0 ]; then
            local per_pg_bytes=$((stored / pg_num))
            if [ "$per_pg_bytes" -gt "$threshold_bytes" ]; then
                # Store GiB (rounded) for display; keep it integer-friendly.
                local per_pg_gib=$((per_pg_bytes / 1073741824))
                large_pg_pools+=("$name|$per_pg_gib|$pg_num|${autoscale:-?}")
            fi
        fi

        # Determine read-overhead factor for this pool.
        local factor_num=3 factor_den=1
        if [ "$ptype" = "3" ]; then
            # EC pool. We need k and m. They're authoritative on the
            # erasure-code-profile, not derivable from the pool size or
            # profile name (real-world profile names don't follow any
            # convention — "ec-16-4" doesn't always parse to 16+4).
            # Query the profile by name, cache the result.
            local k m
            read -r k m <<< "$(ec_profile_km "$ec_profile")"
            if [ -n "$k" ] && [ -n "$m" ] && [ "$k" -gt 0 ]; then
                factor_num=$((k + m))
                factor_den=$k
            else
                # Last-resort fallback: psize is k+m on Reef, but we
                # don't know how m splits from k. Assume m=2 and warn.
                factor_num=$psize
                factor_den=$((psize - 2 > 0 ? psize - 2 : 1))
                print_warning "Pool '$name': couldn't read EC profile '$ec_profile'; assuming m=2." >&2
            fi
        else
            factor_num=$psize
            factor_den=1
        fi

        if [ "$stored" -gt "$largest_stored" ]; then
            largest_stored=$stored
            largest_name=$name
            largest_factor_num=$factor_num
            largest_factor_den=$factor_den
        fi

        # Phase 8: track the widest pool. factor_num is the acting-set
        # width — k+m for EC, replica size for replicated. A deep scrub
        # must reserve slots on all `width` members at once, so this is
        # the conjunction width that drives scrub-admission probability.
        if [ "$factor_num" -gt "${MAX_POOL_WIDTH:-0}" ]; then
            MAX_POOL_WIDTH=$factor_num
        fi

        # Phase 8.1: keep every pool's reservation width for the
        # per-pool admission-feasibility table.
        pool_widths+=("$name|$factor_num|$pg_num")
    done <<< "$pool_rows"

    # Compute weighted average PG size in GB.
    if [ "$total_pgs" -gt 0 ] && [ "$total_stored" -gt 0 ] && [ "$AVG_PG_SIZE_SOURCE" = "default" ]; then
        # MB per PG = (stored bytes / 1MB) / total PGs; divide MB by 1024 to get GB.
        local mb_per_pg=$((total_stored / 1048576 / total_pgs))
        local gb_per_pg=$((mb_per_pg / 1024))
        [ "$gb_per_pg" -lt 1 ] && gb_per_pg=1
        AVG_PG_SIZE=$gb_per_pg
        AVG_PG_SIZE_SOURCE="cluster avg (${total_pgs} PGs across ${row_count} pools)"
    fi

    # Adopt the largest pool's data factor if the user didn't override.
    if [ "$DATA_FACTOR_SOURCE" = "default (3x replicated)" ] && [ -n "$largest_name" ]; then
        DATA_FACTOR_NUM=$largest_factor_num
        DATA_FACTOR_DEN=$largest_factor_den
        DATA_FACTOR_SOURCE="largest pool '$largest_name' (${largest_factor_num}/${largest_factor_den})"
    fi

    # Expose the unique PG count globally. The scrub-time calculation
    # needs this (not the sum of per-OSD assignment counts from
    # `osd df tree`, which double-counts every PG by its chunk width).
    total_unique_pgs=$total_pgs

    # Phase 4.2: walk pools again for per-pool overrides and footgun flags.
    # Metadata/index pools (CephFS metadata by role, RGW index by name, or
    # OMAP-dominant) want shorter deep-scrub intervals; the noscrub /
    # nodeep-scrub pool flags are silent integrity killers.
    pool_overrides=()
    pool_warnings=()
    local pool_row
    local total_objects=0
    # Non-whitespace separator: tab-IFS collapses empty fields, which
    # mis-aligns rows whose `flags_names` is null.
    while IFS='|' read -r pname stored objects flags is_hot; do
        [ -z "$pname" ] && continue
        total_objects=$((total_objects + objects))
        if [[ "$flags" == *noscrub* ]] || [[ "$flags" == *nodeep-scrub* ]]; then
            pool_warnings+=("$pname: $flags  (scrubbing disabled by pool flag)")
        fi
        if [ "$is_hot" = "1" ]; then
            # Tighten the deep-scrub interval to 3 days (259200s) — index /
            # metadata pools want frequent integrity verification.
            pool_overrides+=("$pname#deep_scrub_interval = 259200")
        fi
    done < <(echo "$pools" "$df" | jq -s -r '
        .[0] as $pools | .[1] as $df
        | $pools[] | . as $p
        | ($df.pools[] | select(.id == $p.pool_id)) as $d
        | ($d.stats.stored // 0) as $st
        | ($d.stats.objects // 0) as $obj
        | (($p.flags_names // "") | tostring) as $flags
        | ($p.application_metadata // {}) as $app
        # Role signals — authoritative and size-independent:
        #   1. CephFS metadata pool. Tagged "cephfs":{"metadata":"<fs>"}.
        #      Must be caught by ROLE, not OMAP ratio: a lightly-used
        #      filesystem stores more in the MDS journal (objects/DATA)
        #      than in dentry OMAP, so the pool reads as DATA-dominant.
        #   2. RGW bucket index pool. RGW tags every pool merely as
        #      "rgw":{}, with no role, so we key on the stable ".buckets
        #      .index" name suffix. Catches tiny indexes the OMAP floor
        #      would otherwise skip.
        | ((($app.cephfs // {}) | .metadata) != null) as $is_cephfs_meta
        | (($app.rgw != null) and ($p.pool_name | endswith(".buckets.index"))) as $is_rgw_index
        # OMAP/DATA breakdown catches omap-heavy pools generally. Metadata
        # lives in OMAP (RocksDB), bulk data in objects — so a small average
        # object size alone (the old heuristic) gives false positives on
        # data pools of many small files. Prefer the logical stored_* pair;
        # fall back to the raw *_bytes_used pair.
        | (if ($d.stats.stored_omap != null and $d.stats.stored_data != null)
             then {omap: $d.stats.stored_omap, data: $d.stats.stored_data}
           elif ($d.stats.omap_bytes_used != null and $d.stats.data_bytes_used != null)
             then {omap: $d.stats.omap_bytes_used, data: $d.stats.data_bytes_used}
           else null end) as $bd
        | (if $is_cephfs_meta or $is_rgw_index then "1"
           elif $bd != null then
             # OMAP dominates and is non-trivial (> 1 MiB, so empty pools
             # where tightening would be pointless are skipped).
             (if $bd.omap > $bd.data and $bd.omap > 1048576 then "1" else "0" end)
           else
             # No OMAP stats (pre-Nautilus): fall back to small-object heuristic.
             (if $obj > 0 and ($st / $obj) < 65536 and $st > 1048576 then "1" else "0" end)
           end) as $hot
        | "\($p.pool_name)|\($st)|\($obj)|\($flags)|\($hot)"
    ')

    # Phase 8: real object density, for the scrub-sleep gate. Sleep is paid
    # per chunk (osd_scrub_chunk_max objects), so objects/PG — not bytes —
    # is what prices it.
    if [ "${total_unique_pgs:-0}" -gt 0 ] && [ "$total_objects" -gt 0 ]; then
        AVG_OBJECTS_PER_PG=$((total_objects / total_unique_pgs))
    fi

    print_notice "Pools: $row_count; total stored: $((total_stored / 1073741824)) GB; avg PG size: $AVG_PG_SIZE GB; avg objects/PG: ${AVG_OBJECTS_PER_PG:-unknown}"
}

# Phase 1.6: read scheduler from the cluster.
ingest_scheduler() {
    local q
    q=$(run_ceph config get osd osd_op_queue 2>/dev/null | tr -d '[:space:]')
    case "$q" in
        wpq)
            SCHEDULER="wpq" ;;
        mclock_scheduler|mclock)
            SCHEDULER="mclock" ;;
        "")
            print_warning "Could not read osd_op_queue from cluster; defaulting to wpq."
            SCHEDULER="wpq" ;;
        *)
            print_warning "Unknown osd_op_queue value '$q'; defaulting to wpq."
            SCHEDULER="wpq" ;;
    esac
    print_notice "Active OSD op scheduler: $SCHEDULER"
}

# Phase 1.5: read current values for each parameter we recommend.
# Populates current_config_<param> globals (one per param we care about).
ingest_current_config() {
    local cfg
    cfg=$(run_ceph config dump --format json) || exit 4

    # Helper: look up by name, return value or empty string.
    _cfg_lookup() {
        echo "$cfg" | jq -r --arg name "$1" '
            [.[] | select(.name==$name) | .value] | first // ""
        '
    }

    current_osd_scrub_min_interval=$(_cfg_lookup osd_scrub_min_interval)
    current_osd_scrub_max_interval=$(_cfg_lookup osd_scrub_max_interval)
    current_osd_deep_scrub_interval=$(_cfg_lookup osd_deep_scrub_interval)
    current_osd_max_scrubs=$(_cfg_lookup osd_max_scrubs)
    current_osd_scrub_sleep=$(_cfg_lookup osd_scrub_sleep)
    current_osd_scrub_load_threshold=$(_cfg_lookup osd_scrub_load_threshold)
    current_osd_scrub_begin_hour=$(_cfg_lookup osd_scrub_begin_hour)
    current_osd_scrub_end_hour=$(_cfg_lookup osd_scrub_end_hour)
    current_osd_scrub_interval_randomize_ratio=$(_cfg_lookup osd_scrub_interval_randomize_ratio)
    # Phase 8.9: fraction of shallow-scrub attempts randomly upgraded to deep.
    current_osd_deep_scrub_randomize_ratio=$(_cfg_lookup osd_deep_scrub_randomize_ratio)
    current_osd_mclock_profile=$(_cfg_lookup osd_mclock_profile)
    # Phase 2.3: surface measured IOPS so the benchmark advisory can flag low values.
    current_osd_mclock_max_capacity_iops_hdd=$(_cfg_lookup osd_mclock_max_capacity_iops_hdd)
    current_osd_mclock_max_capacity_iops_ssd=$(_cfg_lookup osd_mclock_max_capacity_iops_ssd)
}

# Phase 1.7: scrub backlog summary. Reads Ceph's own health checks
# rather than parsing per-PG timestamps — Reef's pg dump pgs_brief
# doesn't carry scrub stamps anymore, and the date math was fragile
# anyway. PG_NOT_SCRUBBED and PG_NOT_DEEP_SCRUBBED checks are
# authoritative (they're what `ceph status` reports).
backlog_summary=""
ingest_scrub_backlog() {
    local health pgs
    health=$(run_ceph health detail --format json) || exit 4
    pgs=$(run_ceph pg dump pgs_brief --format json) || exit 4

    local total_pgs deep_late scrub_late
    total_pgs=$(echo "$pgs" | jq '.pg_stats | length')
    deep_late=$(echo "$health"  | jq -r '.checks.PG_NOT_DEEP_SCRUBBED.summary.count // 0')
    scrub_late=$(echo "$health" | jq -r '.checks.PG_NOT_SCRUBBED.summary.count // 0')

    backlog_summary="${total_pgs} PGs total; ${scrub_late} past scrub interval; ${deep_late} past deep-scrub interval"
}

# -----------------------------------------------------------------------------
# Phase 8.1: scrub admission feasibility
# -----------------------------------------------------------------------------
# A scrub of a width-W PG requires ALL W acting-set members to have a free scrub
# slot at the same instant. Slots are per-OSD and shared between "local" (this
# OSD is the scrub primary) and "remote" (this OSD is granting a reservation for
# someone else's scrub). With f = fraction of OSDs currently at osd_max_scrubs:
#
#     P(a width-W scrub can start) = (1 - f)^W
#
# The exponent is why wide EC pools starve while replicated pools on the SAME
# OSDs scrub normally. Measured on a Reef 18.2.2 cluster at f = 24.2%:
#
#     width  3 (3x replicated)  -> 43.5%
#     width  5 (5x replicated)  -> 25.0%
#     width 11 (EC 8+3)         ->  4.7%
#     width 20 (EC 16+4)        ->  0.39%
#
# A 112x spread across pools sharing one slot pool. On that cluster it produced
# a 4.9% tail of PGs that had not deep-scrubbed in 49-65 days while the cluster
# as a whole was meeting its 28-day policy on average.
#
# CAVEAT 1 -- independence. (1-f)^W assumes independent occupancy. Real clusters
# are more clustered than that: remote grants arrive W-1 at a time and CRUSH
# correlates placement. The reference cluster measured ~1.7x more clustered than
# Poisson. Treat the output as a diagnostic ranking, not a predictor.
#
# CAVEAT 2 -- f is an EQUILIBRIUM property, not a headroom measure. Raising
# osd_max_scrubs admits more PGs, occupancy rises, and f returns to roughly
# where it started. A flat f under a rising cap means the added capacity is
# being CONSUMED, not wasted. Never judge a cap change by delta-f. Judge it by
# delta-completions/day (Phase 8.2). Measured on the reference cluster:
#     cap 5 -> 8 :  mean 2.73 -> 5.45,  f 24.2% -> 30.3%  (f did not improve)
# Completions in a CONFOUNDED window on the same cluster (cap change and a
# client-load drop landed within 3h of each other) went 261/day -> 366/day —
# the right METRIC to watch, but that gain is not attributable to the cap; a
# matched-load comparison was still pending when this landed.
# -----------------------------------------------------------------------------
# P(start) = (1 - f)^W, as a percentage. Bash has no floats; awk does.
_p_start_pct() {
    awk -v f="$1" -v w="$2" 'BEGIN { printf "%.2f", (1 - f/100.0)^w * 100 }'
}

ingest_scrub_reservations() {
    reservation_sampled=0
    reservation_at_max=0
    reservation_cap=0
    local df ids
    df=$(run_ceph osd df tree --format json) || return 1
    ids=$(echo "$df" | jq -r '[.nodes[] | select(.type=="osd") | .id] | .[]')
    [ -z "$ids" ] && return 1
    # Stride across the id space rather than taking the first N, so one unhappy
    # host cannot dominate the estimate.
    local -a all=()
    while read -r id; do [ -n "$id" ] && all+=("$id"); done <<< "$ids"
    local total=${#all[@]} step
    step=$(( total / RESERVATION_SAMPLE_SIZE ))
    [ "$step" -lt 1 ] && step=1
    local sum=0 i=0 out l r c
    while [ "$i" -lt "$total" ]; do
        local id="${all[$i]}"
        i=$((i + step))
        # Down OSDs and timeouts fail here; skipping them is correct — they hold
        # no reservations and are not part of the admission population.
        out=$(run_ceph tell "osd.$id" dump_scrub_reservations 2>/dev/null) || continue
        l=$(echo "$out" | jq -r '.scrubs_local     // empty' 2>/dev/null)
        r=$(echo "$out" | jq -r '.scrubs_remote    // empty' 2>/dev/null)
        c=$(echo "$out" | jq -r '.osd_max_scrubs   // empty' 2>/dev/null)
        { [ -z "$l" ] || [ -z "$r" ] || [ -z "$c" ]; } && continue
        reservation_sampled=$((reservation_sampled + 1))
        sum=$((sum + l + r))
        reservation_cap=$c
        [ $((l + r)) -ge "$c" ] && reservation_at_max=$((reservation_at_max + 1))
    done
    [ "$reservation_sampled" -eq 0 ] && return 1
    reservation_f_pct=$(( reservation_at_max * 100 / reservation_sampled ))
    reservation_mean=$(awk -v s="$sum" -v n="$reservation_sampled" \
        'BEGIN { printf "%.2f", s/n }')
    return 0
}

report_admission_feasibility() {
    [ "$reservation_sampled" -eq 0 ] && return 0
    print_header "Scrub admission feasibility"
    echo "  Sampled ${reservation_sampled} OSDs via 'dump_scrub_reservations'"
    echo "  osd_max_scrubs (reported by OSDs) : ${reservation_cap}"
    echo "  Mean slots in use                 : ${reservation_mean} of ${reservation_cap}"
    echo "  OSDs at cap (f)                   : ${reservation_at_max}/${reservation_sampled} = ${reservation_f_pct}%"
    echo
    echo "  A width-W PG needs all W acting-set members below cap at the same"
    echo "  instant:  P(start) = (1 - f)^W"
    echo
    if [ "${#pool_widths[@]}" -eq 0 ]; then
        print_notice "No pool widths available; run with --from-cluster for per-pool detail."
        return 0
    fi
    printf "  %-34s %6s %10s   %s\n" "pool" "width" "P(start)" "assessment"
    local limited=0 seen_wide=0 row name width pg_num p verdict
    for row in "${pool_widths[@]}"; do
        IFS='|' read -r name width pg_num <<< "$row"
        [ -z "$width" ] || [ "$width" -lt 1 ] && continue
        p=$(_p_start_pct "$reservation_f_pct" "$width")
        if awk -v p="$p" -v t="$ADMISSION_LIMITED_PCT" 'BEGIN{exit !(p < t)}'; then
            verdict="ADMISSION-LIMITED"; limited=$((limited + 1))
        elif awk -v p="$p" -v t="$ADMISSION_TIGHT_PCT" 'BEGIN{exit !(p < t)}'; then
            verdict="tight"
        else
            verdict="ok"
        fi
        [ "$width" -ge 11 ] && seen_wide=1
        printf "  %-34s %6s %9s%%   %s\n" "$name" "$width" "$p" "$verdict"
    done
    if [ "$limited" -gt 0 ]; then
        echo
        print_warning "${limited} pool(s) are admission-limited at the current saturation."
        echo "  These pools are gated by reservation admission, not by scrub bandwidth."
        echo "  Lengthening osd_deep_scrub_interval or raising osd_max_scrubs will NOT"
        echo "  fix them: the interval is not the binding constraint, and raising the"
        echo "  cap admits proportionally more contenders, leaving f roughly unchanged."
        echo
        echo "  What does move the number:"
        echo "    - REDUCE DEEP-SCRUB DEMAND. osd_deep_scrub_randomize_ratio (default 0.15)"
        echo "      is the fraction of shallow-scrub attempts randomly upgraded to deep."
        echo "      On a saturated cluster that can be ~half of all deep scrubs, spent on"
        echo "      PGs that did not need one, competing for slots against genuinely"
        echo "      overdue PGs. Lowering it (e.g. 0.15 -> 0.05) is the highest-impact"
        echo "      lever measured so far. Expect total deep-scrub throughput to FALL —"
        echo "      the goal is tail clearance, not completions/day."
        echo "    - widen the scrub window (begin/end_hour 0/0) to maximise admission attempts"
        echo "    - shorten per-PG scrub time so slots free faster (PG count on the heavy pools)"
        echo "    - narrower EC profile, if the pool is being designed rather than operated"
        echo
        echo "  NOT a fix: lowering osd_scrub_interval_randomize_ratio. That RAISES the"
        echo "  attempt rate (cadence = min_interval x (2 + ratio)/2) and adds demand to a"
        echo "  cluster that already cannot admit what it generates."
        echo
        echo "  To confirm whether a cap change helped, compare deep-scrub COMPLETIONS"
        echo "  per day before and after. Do not compare f — see Phase 8.2."
    fi
    if [ "$seen_wide" -eq 1 ]; then
        echo
        print_notice "(1-f)^W assumes independent slot occupancy. Real placement is more"
        print_notice "clustered, so treat these as a ranking between pools, not a forecast."
    fi
}

# -----------------------------------------------------------------------------
# Phase 8.9a: deep-scrub demand model
# -----------------------------------------------------------------------------
# Deep scrubs are generated by two paths:
#
#   deadline : PGs / osd_deep_scrub_interval          — IRREDUCIBLE
#   random   : shallow_attempts/day x osd_deep_scrub_randomize_ratio
#   where shallow_attempts/day = PGs / (min_interval x (2 + interval_ratio) / 2)
#
# The random path exists to spread deep scrubs so they do not all bunch at
# their deadline; on a cluster with headroom it is doing useful smoothing.
# It only becomes a problem when total demand approaches capacity, at which
# point those early scrubs compete for reservations against genuinely overdue
# PGs. On the reference cluster the random path was 174/day of 360/day total
# (48%) against 388/day capacity — and cutting the ratio 0.15 -> 0.05 cleared
# 42% of the overdue tail in 37 hours.
#
# THE FLOOR MATTERS MORE THAN THE RATIO. The deadline path cannot be tuned by
# osd_deep_scrub_randomize_ratio at all, so a short deep-scrub interval can
# saturate a cluster on its own and render the lever useless:
#
#     5216 PGs, capacity 388/day:  7d -> 745/day (1.92x)   lever dead
#                                 14d -> 373/day (0.96x)   lever dead
#                                 21d -> 248/day (0.64x)   viable
#                                 28d -> 186/day (0.48x)   viable
#
# Anything recommending a short interval AND a lower randomize ratio is
# internally inconsistent — the first recommendation invalidates the second.
# -----------------------------------------------------------------------------
report_deep_scrub_demand() {
    local pgs="${total_unique_pgs:-0}"
    [ "$pgs" -gt 0 ] || return 0
    local min_iv="${current_osd_scrub_min_interval:-}"
    local deep_iv="${current_osd_deep_scrub_interval:-}"
    local irr="${current_osd_scrub_interval_randomize_ratio:-}"
    local drr="${current_osd_deep_scrub_randomize_ratio:-}"
    # Ceph serialises these as floats ("86400.000000"); awk handles them, but
    # bail if any input is missing rather than invent a number.
    for v in "$min_iv" "$deep_iv" "$irr" "$drr"; do
        [[ "$v" =~ ^[0-9.]+$ ]] || return 0
    done

    local deadline random total frac cadence attempts
    cadence=$(awk -v m="$min_iv" -v r="$irr" 'BEGIN { printf "%.2f", (m/86400) * (2 + r) / 2 }')
    attempts=$(awk -v p="$pgs" -v c="$cadence" 'BEGIN { printf "%.0f", (c > 0) ? p / c : 0 }')
    deadline=$(awk -v p="$pgs" -v d="$deep_iv" 'BEGIN { printf "%.0f", (d > 0) ? p / (d/86400) : 0 }')
    random=$(awk -v a="$attempts" -v r="$drr"  'BEGIN { printf "%.0f", a * r }')
    total=$((deadline + random))
    [ "$total" -gt 0 ] || return 0
    frac=$(awk -v r="$random" -v t="$total" 'BEGIN { printf "%.0f", r * 100 / t }')

    print_header "Deep-scrub demand model"
    printf "  PGs (unique)   : %s\n" "$pgs"
    printf "  Attempt cadence: %s d   (min_interval x (2 + %s) / 2)\n" "$cadence" "$irr"
    echo
    printf "  Deadline path  : %6s /day   (PGs / %.1fd interval) — IRREDUCIBLE\n" \
        "$deadline" "$(awk -v d="$deep_iv" 'BEGIN{printf "%.1f", d/86400}')"
    printf "  Random path    : %6s /day   (%s attempts/day x %s) — tunable\n" \
        "$random" "$attempts" "$(awk -v r="$drr" 'BEGIN{printf "%g", r}')"
    printf "  Total demand   : %6s /day   (random share: %s%%)\n" "$total" "$frac"
    echo
    echo "  The random path spreads deep scrubs so they do not bunch at the deadline."
    echo "  On a cluster with headroom that is useful smoothing — it is only a problem"
    echo "  when demand approaches capacity, where those early scrubs compete for"
    echo "  reservations against genuinely overdue PGs."
    echo "  Comparing this against measured capacity needs per-device-class"
    echo "  completions/day (Phase 8.2); until then this is a demand figure only."

    # The floor check: does our own proposed interval invalidate the lever?
    local proposed_deep proposed_floor
    proposed_deep=$(printf '%s\n' "${proposed_settings[@]}" \
        | awk -F' = ' '/^osd_deep_scrub_interval/ { print $2 }')
    if [[ "$proposed_deep" =~ ^[0-9]+$ ]] && [ "$proposed_deep" -gt 0 ]; then
        proposed_floor=$(awk -v p="$pgs" -v d="$proposed_deep" 'BEGIN { printf "%.0f", p / (d/86400) }')
        if [ "$proposed_floor" -gt "$deadline" ]; then
            echo
            print_notice "The proposed osd_deep_scrub_interval ($(awk -v d="$proposed_deep" 'BEGIN{printf "%.1fd", d/86400}')) raises the irreducible"
            print_notice "  deadline floor from ${deadline}/day to ${proposed_floor}/day. A short interval can"
            print_notice "  saturate a cluster on the deadline path alone, at which point lowering"
            print_notice "  osd_deep_scrub_randomize_ratio cannot help — the levers are then the"
            print_notice "  interval itself and PG count. Verify the floor fits measured capacity."
        fi
    fi
}

# Phase 1.5: render proposed settings as a current → proposed diff.
# Reads proposed lines (from calculate_scrub_settings) on stdin.
render_diff() {
    local changes=0
    while IFS= read -r line; do
        # Each line: "param = value"
        local param="${line% = *}"
        local proposed="${line#* = }"
        local current_var="current_${param}"
        local current="${!current_var:-(unset)}"
        if _values_equal "$current" "$proposed"; then
            printf "  %-42s %s (no change)\n" "$param:" "$current"
        else
            printf "  %-42s ${YELLOW}%s → %s${NC}\n" "$param:" "$current" "$proposed"
            changes=$((changes + 1))
        fi
    done
    echo
    if [ "$changes" -eq 0 ]; then
        print_success "No changes — current config already matches recommendations."
    else
        print_notice "$changes parameter(s) would change. Backup before applying."
    fi
}

# --why: human-readable explanation per parameter. Called with the
# parameter name + proposed value; echoes a 1-4-line explanation.
# When the cluster's current value is interesting (silly defaults,
# obvious misconfig), we name it in the reasoning.
_explain_param() {
    local param=$1 proposed=$2
    local current_var="current_${param}"
    local current="${!current_var:-(unset)}"
    case "$param" in
        osd_scrub_min_interval)
            echo "Lower bound for shallow-scrub eligibility. Below this many seconds since"
            echo "the last shallow scrub, a PG is not eligible to be re-scrubbed."
            ;;
        osd_scrub_max_interval)
            echo "Hard upper bound for shallow-scrub eligibility. After this many seconds,"
            echo "scrubs become forced regardless of cluster load."
            ;;
        osd_deep_scrub_interval)
            echo "How often each PG gets a full data-integrity deep-scrub. Default 7d on"
            echo "modern Ceph; 28d (your current value) is permissive and lets bit-rot"
            echo "go undetected longer than most operators expect."
            ;;
        osd_max_scrubs)
            echo "Number of PG scrubs an OSD will run concurrently. Higher = faster scrub"
            echo "completion but more client-IO impact. With $proposed × OSDs_per_host"
            echo "simultaneous scrubs per host, verify hosts can absorb the load."
            ;;
        osd_scrub_interval_randomize_ratio)
            echo "Spreads PG scrub eligibility within [interval, interval × (1 + ratio)] to"
            echo "prevent synchronized scrub storms. Upstream default is 0.5."
            echo "  Mean attempt cadence = min_interval × (2 + ratio) / 2, so LOWERING this"
            echo "  raises the scrub-attempt rate. On a cluster whose scrubs are limited by"
            echo "  reservation admission rather than bandwidth, a high value is protective:"
            echo "  it throttles attempts that could not be admitted anyway. Only lower it"
            echo "  when achieved scrub cadence is close to the scheduled cadence."
            if [[ "$current" =~ ^[0-9.]+$ ]] && awk "BEGIN { exit !($current > 1.0) }"; then
                echo "  Your current value ($current) is well above the default. That is often"
                echo "  deliberate on large clusters — check 'ceph config log' for provenance"
                echo "  before changing it."
            fi
            ;;
        osd_scrub_begin_hour|osd_scrub_end_hour)
            echo "Active scrub window (hours, 24h clock). 0-0 means scrub anytime."
            echo "Restricting to off-peak hours reduces client-IO impact."
            ;;
        osd_scrub_sleep)
            echo "Pause (seconds, float) between scrub-chunk reads. Higher = lower scrub"
            echo "throughput but better client-IO isolation. HDD-leaning at $proposed; the"
            echo "per-class override sets 0.0 for faster classes that don't need pacing."
            echo "mClock ignores this knob — it's WPQ-only."
            ;;
        osd_scrub_load_threshold)
            echo "Pause new scrubs when (loadavg / num_cpus) exceeds this value. A 16-core"
            echo "host with threshold 0.5 stops launching new scrubs when loadavg > 8."
            echo "Already-running scrubs continue. mClock ignores this — WPQ-only."
            ;;
        osd_mclock_profile)
            echo "mClock QoS profile. 'high_client_ops' favors client latency over scrub;"
            echo "'balanced' shares roughly evenly; 'high_recovery_ops' prioritizes recovery"
            echo "and scrub over client. The profile is the main lever under mClock —"
            echo "individual sleep/load knobs are ignored."
            ;;
        *)
            echo "(no explanation registered for $param)"
            ;;
    esac
}

# Print the "Reasoning" section. Called when --why is given and we
# have proposed_settings + class/pool override arrays in scope.
render_why() {
    print_header "Reasoning"
    local first=1
    local line param proposed current_var current
    for line in "${proposed_settings[@]}"; do
        param="${line% = *}"
        proposed="${line#* = }"
        current_var="current_${param}"
        current="${!current_var:-(unset)}"
        # Skip no-op rows — they're not changes.
        _values_equal "$current" "$proposed" && continue
        [ "$first" -eq 0 ] && echo
        first=0
        printf "${BOLD}%s = %s${NC}\n" "$param" "$proposed"
        _explain_param "$param" "$proposed" | sed 's/^/  /'
    done
    if [ "${#class_overrides[@]}" -gt 0 ]; then
        for line in "${class_overrides[@]}"; do
            local entity="${line%%|*}"
            local kv="${line#*|}"
            local p="${kv% = *}"
            local v="${kv#* = }"
            echo
            printf "${BOLD}%s %s = %s${NC}\n" "$entity" "$p" "$v"
            echo "  Per-class override. Faster device classes don't need the global"
            echo "  HDD-leaning sleep value; this lifts the throttle for $entity."
        done
    fi
    if [ "${#pool_overrides[@]}" -gt 0 ]; then
        for line in "${pool_overrides[@]}"; do
            local pname="${line%%#*}"
            local kv="${line#*#}"
            local p="${kv% = *}"
            local v="${kv#* = }"
            echo
            printf "${BOLD}pool/%s %s = %s${NC}\n" "$pname" "$p" "$v"
            echo "  Metadata/index pool (CephFS metadata by application role, RGW bucket"
            echo "  index by name, or OMAP-dominant). Tightening deep_scrub_interval to 3"
            echo "  days verifies integrity more often; bit-rot on metadata has outsized"
            echo "  impact compared to bulk-data pools."
        done
    fi
}

# Compare two scrub-config values for equivalence, handling the Ceph
# habit of serializing seconds-typed values as "604800.000000". Strings
# that parse as the same number are equal; otherwise fall back to
# literal string equality (covers the "(unset)" sentinel).
_values_equal() {
    local a=$1 b=$2
    [ "$a" = "$b" ] && return 0
    [ "$a" = "(unset)" ] || [ "$b" = "(unset)" ] && return 1
    # Both look numeric? Compare as awk floats.
    if [[ "$a" =~ ^[0-9.]+$ ]] && [[ "$b" =~ ^[0-9.]+$ ]]; then
        awk -v a="$a" -v b="$b" 'BEGIN { exit !(a + 0 == b + 0) }'
        return $?
    fi
    return 1
}

# Phase 5.3-prep: build a backup plan from the proposed-change arrays.
# Writes a self-describing TSV to $1. One row per setting we'd change.
#
# Row format: scope<TAB>section<TAB>mask<TAB>name<TAB>old_value
#   scope:     "osd" | "osd_class" | "pool"
#   section:   "osd" (config-set entity) or "pool" (no-op for pool rows)
#   mask:      "" for globals, "class:<class>" for class overrides, "<pool>" for pool tuning
#   old_value: current value as a string, or the literal "<unset>" if no override exists
#
# Read-only: only runs `ceph config dump` and `ceph osd pool get`. Never writes.
build_backup_plan() {
    local out_file=$1
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    {
        echo "# scrubadub backup plan generated at $timestamp"
        echo "# Restore with: scrubadub.sh --rollback $(basename "$out_file")"
        echo "# Columns (TAB-separated):"
        echo "#   scope     'osd' | 'osd_class' | 'pool'"
        echo "#   section   'osd' (config-set entity) or 'pool' (pool tuning, ignored on rollback)"
        echo "#   mask      empty for global, 'class:<class>' for per-class, '<pool>' for pool tuning"
        echo "#   name      config key"
        echo "#   old_value current value, or '<unset>' if no override existed pre-apply"
    } > "$out_file"

    local config_dump
    config_dump=$(run_ceph config dump --format json) || exit 4

    # 1. Global OSD config (proposed_settings entries: "key = value").
    local setting name current gcurrent
    for setting in "${proposed_settings[@]}"; do
        name="${setting% = *}"
        current=$(echo "$config_dump" | jq -r --arg n "$name" '
            [.[] | select(.section=="osd" and .name==$n and ((.mask // "")==""))][0].value // empty')
        [ -z "$current" ] && current="<unset>"
        printf "osd\tosd\t\t%s\t%s\n" "$name" "$current" >> "$out_file"
        # The two health-check-relevant intervals are also applied on the
        # 'global' section (mgr visibility) — capture that section's prior
        # state too so rollback can undo both writes.
        case "$name" in
            osd_deep_scrub_interval|osd_scrub_max_interval)
                gcurrent=$(echo "$config_dump" | jq -r --arg n "$name" '
                    [.[] | select(.section=="global" and .name==$n and ((.mask // "")==""))][0].value // empty')
                [ -z "$gcurrent" ] && gcurrent="<unset>"
                printf "osd\tglobal\t\t%s\t%s\n" "$name" "$gcurrent" >> "$out_file"
                ;;
        esac
    done

    # 2. Per-class overrides (class_overrides entries: "osd/class:<class>|<key> = <value>").
    local override entity kv mask
    for override in "${class_overrides[@]}"; do
        entity="${override%%|*}"
        kv="${override#*|}"
        name="${kv% = *}"
        mask="${entity#osd/}"   # "class:ssd"
        current=$(echo "$config_dump" | jq -r --arg n "$name" --arg m "$mask" '
            [.[] | select(.section=="osd" and .name==$n and ((.mask // "")==$m))][0].value // empty')
        [ -z "$current" ] && current="<unset>"
        printf "osd_class\tosd\t%s\t%s\t%s\n" "$mask" "$name" "$current" >> "$out_file"
    done

    # 3. Per-pool tuning (pool_overrides entries: "<pool>#<key> = <value>").
    # `ceph osd pool get` returns ENOENT-style errors when the override
    # isn't set on the pool, so suppress stderr and treat empty as unset.
    local pname pool_json
    for override in "${pool_overrides[@]}"; do
        pname="${override%%#*}"
        kv="${override#*#}"
        name="${kv% = *}"
        pool_json=$(run_ceph osd pool get "$pname" "$name" --format json 2>/dev/null || true)
        if [ -n "$pool_json" ]; then
            current=$(echo "$pool_json" | jq -r --arg n "$name" '.[$n] // empty')
        else
            current=""
        fi
        [ -z "$current" ] && current="<unset>"
        printf "pool\tpool\t%s\t%s\t%s\n" "$pname" "$name" "$current" >> "$out_file"
    done
}

prompt_workload() {
    while true; do
        echo
        echo "Select primary workload type:"
        echo "  1) Heavy Read"
        echo "  2) Heavy Write"
        echo "  3) Mixed Use"
        echo "  4) Archival"
        read -p "Enter selection (1-4): " WORKLOAD_TYPE
        [[ "$WORKLOAD_TYPE" =~ ^[1-4]$ ]] && break
        print_error "Please enter a number between 1 and 4"
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
# Skip main when the script is sourced (e.g. by the unit-style smoke test
# that calls emit_wpq_settings / emit_mclock_settings directly).
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0 2>/dev/null || true
fi

parse_args "$@"
load_device_profile

# --- Input gathering: branch on --from-cluster (Phase 1.1, 1.8) -----------
if [ "$FROM_CLUSTER" -eq 1 ]; then
    print_header "Ceph Scrub Parameter Calculator — cluster-ingested mode"
    echo "Reading OSD inventory, PG distribution, pool sizes, current scrub"
    echo "config, scheduler, and scrub backlog from 'ceph'."
    echo
    if [ -n "${CEPH_FIXTURE_DIR:-}" ]; then
        print_notice "CEPH_FIXTURE_DIR=$CEPH_FIXTURE_DIR — using fixtures instead of live ceph."
    fi
    check_ceph_environment

    ingest_osd_inventory          # 1.2
    ingest_pg_distribution        # 1.3
    ingest_pool_details           # 1.4
    ingest_scheduler              # 1.6
    ingest_current_config         # 1.5
    ingest_scrub_backlog          # 1.7
    ingest_scrub_reservations || print_notice "Reservation sampling unavailable; skipping admission analysis."   # 8.1

    if [ -z "$WORKLOAD_TYPE" ]; then
        echo
        echo "Workload type can't be auto-detected — pass --workload to skip this prompt."
        prompt_workload
    fi
else
    print_header "Ceph Scrub Parameter Calculator — prompt mode"
    echo "Calculates recommended scrub settings from OSD composition,"
    echo "PG distribution, workload type, and the active op scheduler."
    echo
    echo "For cluster auto-ingest on a mon node, re-run with --from-cluster."
    echo

    # Banners about default assumptions (Phase 0.5, 0.10, 0.11).
    if [ "$AVG_PG_SIZE_SOURCE" = "default" ]; then
        print_notice "Using default avg PG size = ${AVG_PG_SIZE_DEFAULT} GB. Real PG size varies"
        print_notice "  wildly per pool. Override with --avg-pg-size-gb N or --from-cluster."
    fi
    if [ "$DATA_FACTOR_SOURCE" = "default (3x replicated)" ]; then
        print_notice "Assuming 3x replicated pools (deep-scrub reads 3x stored bytes)."
        print_notice "  Override with --replica-size N, --ec-ratio k+m, or --from-cluster."
    fi
    if [ -z "$DEVICE_PROFILE" ]; then
        print_notice "Using built-in device baselines. Override with --device-profile <file>."
    fi

    # OSD inventory
    while true; do
        read -p "Enter number of HDD OSDs: " hdd_count
        read -p "Enter number of SSD OSDs: " ssd_count
        read -p "Enter number of NVMe OSDs: " nvme_count
        validate_osd_inputs "$hdd_count" "$ssd_count" "$nvme_count" && break
    done

    # PG counts
    if [ "$hdd_count" -gt 0 ]; then
        while true; do
            read -p "Enter total PG count for HDD OSDs: " hdd_pg_count
            validate_pg_inputs "$hdd_pg_count" "$hdd_count" "HDD" && break
        done
    else
        hdd_pg_count=0
    fi
    if [ "$ssd_count" -gt 0 ]; then
        while true; do
            read -p "Enter total PG count for SSD OSDs: " ssd_pg_count
            validate_pg_inputs "$ssd_pg_count" "$ssd_count" "SSD" && break
        done
    else
        ssd_pg_count=0
    fi
    if [ "$nvme_count" -gt 0 ]; then
        while true; do
            read -p "Enter total PG count for NVMe OSDs: " nvme_pg_count
            validate_pg_inputs "$nvme_pg_count" "$nvme_count" "NVMe" && break
        done
    else
        nvme_pg_count=0
    fi

    [ -z "$WORKLOAD_TYPE" ] && prompt_workload

    # Scheduler — Phase 0.6.
    if [ -z "$SCHEDULER" ]; then
        while true; do
            echo
            echo "Which OSD op scheduler is active on your cluster?"
            echo "  Check with: ceph config get osd osd_op_queue"
            echo "  1) WPQ   (default pre-Quincy; many production clusters still use this)"
            echo "  2) mClock (default since Ceph 17 / Quincy)"
            read -p "Enter selection (1 or 2): " sched_choice
            case "$sched_choice" in
                1) SCHEDULER="wpq"; break ;;
                2) SCHEDULER="mclock"; break ;;
                *) print_error "Please enter 1 or 2" ;;
            esac
        done
    fi
fi

# Scheduler banner — Phase 0.6.
print_header "Scheduler: ${SCHEDULER^^}"
if [ "$SCHEDULER" = "mclock" ]; then
    print_warning "mClock is active. osd_scrub_sleep and osd_scrub_load_threshold are IGNORED"
    print_warning "by Ceph; they will be OMITTED from the recommendations below. Tune the"
    print_warning "mClock profile instead."
    echo
    echo "  References:"
    echo "    https://docs.ceph.com/en/reef/rados/configuration/mclock-config-ref/"
    echo "    https://www.clyso.com/blog/ceph-how-do-disable-mclock-scheduler/"
    echo
    mclock_benchmark_advisory
else
    print_success "WPQ is active. All scrub knobs (sleep, load_threshold, intervals, ...) honored."
fi

# Phase 3.1: derive network ceiling now that all inputs are in.
compute_network_ceiling

# Phase 3.5: empirical per-class throughput. Opt-in because it runs real
# I/O against sampled OSDs (`ceph tell osd.X bench`). Replaces the
# hardcoded HDD/SSD/NVMe THROUGHPUT defaults when results are available.
if [ "$BENCH_OSDS" -eq 1 ]; then
    if [ "$FROM_CLUSTER" -ne 1 ]; then
        print_error "--bench-osds requires --from-cluster (need to talk to OSDs)."
        exit 2
    fi
    load_or_run_benchmarks
fi

# Phase 3.2: substitute mClock-measured IOPS where the cluster has them.
HDD_IOPS_SOURCE="default"
SSD_IOPS_SOURCE="default"
NVME_IOPS_SOURCE="default"
if [ "$FROM_CLUSTER" -eq 1 ]; then
    if [ -n "${current_osd_mclock_max_capacity_iops_hdd:-}" ]; then
        m_hdd=${current_osd_mclock_max_capacity_iops_hdd%.*}
        if [ -n "$m_hdd" ] && [ "$m_hdd" -gt 0 ] 2>/dev/null; then
            HDD_IOPS=$m_hdd; HDD_IOPS_SOURCE="mClock benchmark"
        fi
    fi
    if [ -n "${current_osd_mclock_max_capacity_iops_ssd:-}" ]; then
        m_ssd=${current_osd_mclock_max_capacity_iops_ssd%.*}
        if [ -n "$m_ssd" ] && [ "$m_ssd" -gt 0 ] 2>/dev/null; then
            SSD_IOPS=$m_ssd; SSD_IOPS_SOURCE="mClock benchmark"
            # mClock doesn't separate ssd/nvme; use the same number for both.
            NVME_IOPS=$m_ssd; NVME_IOPS_SOURCE="mClock benchmark (ssd)"
        fi
    fi
fi

# Analysis
print_header "Analysis Results"
echo "Device Class Distribution and Performance"
echo "(Baselines are order-of-magnitude. Override via --device-profile.)"
echo
total_throughput=0
total_iops=0

if [ "$hdd_count" -gt 0 ]; then
    read -r hdd_tp hdd_io <<< "$(calculate_device_performance "$hdd_count" "$HDD_THROUGHPUT" "$HDD_IOPS")"
    total_throughput=$((total_throughput + hdd_tp))
    total_iops=$((total_iops + hdd_io))
    hdd_tp_source="${BENCH_HDD_SOURCE:-default}"
    echo "HDD OSDs: $hdd_count"
    echo "  - PG replicas: $hdd_pg_count (avg $(calculate_pg_per_osd "$hdd_pg_count" "$hdd_count") per OSD)"
    echo "  - Throughput: $hdd_tp MB/s (${HDD_THROUGHPUT} MB/s/OSD, source: $hdd_tp_source)"
    echo "  - IOPS: $hdd_io (${HDD_IOPS}/OSD, source: $HDD_IOPS_SOURCE)"
    if [ "${#BENCH_HDD_OUTLIERS[@]}" -gt 0 ]; then
        print_warning "HDD outliers below ${OUTLIER_THRESHOLD}× baseline: ${BENCH_HDD_OUTLIERS[*]}"
    fi
fi
if [ "$ssd_count" -gt 0 ]; then
    read -r ssd_tp ssd_io <<< "$(calculate_device_performance "$ssd_count" "$SSD_THROUGHPUT" "$SSD_IOPS")"
    total_throughput=$((total_throughput + ssd_tp))
    total_iops=$((total_iops + ssd_io))
    ssd_tp_source="${BENCH_SSD_SOURCE:-default}"
    echo "SSD OSDs: $ssd_count"
    echo "  - PG replicas: $ssd_pg_count (avg $(calculate_pg_per_osd "$ssd_pg_count" "$ssd_count") per OSD)"
    echo "  - Throughput: $ssd_tp MB/s (${SSD_THROUGHPUT} MB/s/OSD, source: $ssd_tp_source)"
    echo "  - IOPS: $ssd_io (${SSD_IOPS}/OSD, source: $SSD_IOPS_SOURCE)"
    if [ "${#BENCH_SSD_OUTLIERS[@]}" -gt 0 ]; then
        print_warning "SSD outliers below ${OUTLIER_THRESHOLD}× baseline: ${BENCH_SSD_OUTLIERS[*]}"
    fi
fi
if [ "$nvme_count" -gt 0 ]; then
    read -r nvme_tp nvme_io <<< "$(calculate_device_performance "$nvme_count" "$NVME_THROUGHPUT" "$NVME_IOPS")"
    total_throughput=$((total_throughput + nvme_tp))
    total_iops=$((total_iops + nvme_io))
    nvme_tp_source="${BENCH_NVME_SOURCE:-default}"
    echo "NVMe OSDs: $nvme_count"
    echo "  - PG replicas: $nvme_pg_count (avg $(calculate_pg_per_osd "$nvme_pg_count" "$nvme_count") per OSD)"
    echo "  - Throughput: $nvme_tp MB/s (${NVME_THROUGHPUT} MB/s/OSD, source: $nvme_tp_source)"
    echo "  - IOPS: $nvme_io (${NVME_IOPS}/OSD, source: $NVME_IOPS_SOURCE)"
    if [ "${#BENCH_NVME_OUTLIERS[@]}" -gt 0 ]; then
        print_warning "NVMe outliers below ${OUTLIER_THRESHOLD}× baseline: ${BENCH_NVME_OUTLIERS[*]}"
    fi
fi

echo
echo "Cluster Totals"
echo "  - Raw disk throughput: $total_throughput MB/s (sum of per-OSD)"

# Phase 3.1: pick effective ceiling = min(disk_total, network_total).
effective_ceiling=$total_throughput
ceiling_source="disk"
if [ "$NETWORK_CEILING" -gt 0 ]; then
    echo "  - Network ceiling:     $NETWORK_CEILING MB/s ($HOST_COUNT hosts × ${NIC_GBPS} Gbps, source: $NIC_SOURCE)"
    if [ "$NETWORK_CEILING" -lt "$total_throughput" ]; then
        effective_ceiling=$NETWORK_CEILING
        ceiling_source="network"
    fi
    echo "  - Binding ceiling:     $effective_ceiling MB/s ($ceiling_source-bound)"
else
    if [ "$FROM_CLUSTER" -eq 1 ]; then
        echo "  - Network ceiling:     not modeled (ethtool not available; pass --nic-gbps to override)"
    else
        echo "  - Network ceiling:     not modeled (pass --hosts and --nic-gbps in prompt mode)"
    fi
fi
scrub_budget_mbps=$((effective_ceiling * SCRUB_BUDGET_PERCENT / 100))
echo "  - Scrub budget:        ${SCRUB_BUDGET_PERCENT}% of binding → ${scrub_budget_mbps} MB/s (source: $SCRUB_BUDGET_SOURCE)"
echo "  - IOPS estimate:       $total_iops"
echo "  - Data factor:         $DATA_FACTOR_SOURCE"
echo "  - Avg PG size:         $AVG_PG_SIZE GB ($AVG_PG_SIZE_SOURCE)"

# Use unique PG count (from ingest_pool_details), not the sum of
# per-OSD assignments. Each PG occupies size/k+m OSDs but only
# stores AVG_PG_SIZE worth of unique data; the OSD-assignment sum
# would over-count by the chunk width (~17x on EC-heavy clusters).
# total_pgs (assignments) is still used for the per-host concurrency
# check below — that's correctly per-OSD.
total_pgs=$((hdd_pg_count + ssd_pg_count + nvme_pg_count))
estimated_scrub_time=$(calculate_scrub_time "${total_unique_pgs:-$total_pgs}" "$effective_ceiling")
est_days=$((estimated_scrub_time / 24))

# Phase 3.3: shallow estimate. Shallow scrub reads object metadata and
# is typically seek-bound, not bandwidth-bound — order-of-magnitude only.
shallow_scrub_time=$((estimated_scrub_time / 20))   # ~5% of deep
[ "$shallow_scrub_time" -lt 1 ] && shallow_scrub_time=1
echo "  - Shallow scrub time:  ~${shallow_scrub_time} hours (rough; shallow is seek-bound)"
echo "  - Deep scrub time:     ~${estimated_scrub_time} hours (~${est_days} days)"

# Max PGs/OSD across classes
max_pg_per_osd=0
total_osds=$((hdd_count + ssd_count + nvme_count))
for pair in "$hdd_count:$hdd_pg_count" "$ssd_count:$ssd_pg_count" "$nvme_count:$nvme_pg_count"; do
    c="${pair%%:*}"; p="${pair##*:}"
    [ "$c" -eq 0 ] && continue
    ppo=$(calculate_pg_per_osd "$p" "$c")
    [ "$ppo" -gt "$max_pg_per_osd" ] && max_pg_per_osd=$ppo
done

# Capture the scrub window for the Notes section (Phase 0.2-aware).
read -r display_begin display_end <<< "$(scrub_window_for_workload "$WORKLOAD_TYPE")"

# Prompt mode has no pool walk; the declared data factor's numerator IS the
# acting-set width (k+m for --ec-ratio, size for --replica-size).
[ "$MAX_POOL_WIDTH" -eq 0 ] && MAX_POOL_WIDTH=$DATA_FACTOR_NUM

# Collect proposed settings once so we can render both a diff and the apply commands.
proposed_settings=()
while IFS= read -r line; do
    proposed_settings+=("$line")
done < <(calculate_scrub_settings "$total_osds" "$max_pg_per_osd" "$WORKLOAD_TYPE" "$estimated_scrub_time" "$SCHEDULER")

# Phase 4.1: per-class WPQ overrides (no-op outside WPQ or single-class).
compute_class_overrides

# Phase 1.7: backlog summary in cluster mode.
if [ "$FROM_CLUSTER" -eq 1 ] && [ -n "$backlog_summary" ]; then
    print_header "Scrub Backlog (from 'ceph health detail')"
    echo "  $backlog_summary"
fi

# Phase 8.1: admission feasibility — rendered before the proposed settings,
# because an admission-limited verdict changes what the recommendations can
# and cannot fix.
[ "$FROM_CLUSTER" -eq 1 ] && report_admission_feasibility

# Phase 8.9a: demand decomposition. Runs after proposed_settings exists so the
# floor check can compare our own proposed interval against the current one.
[ "$FROM_CLUSTER" -eq 1 ] && report_deep_scrub_demand

# Phase 1.5: current → proposed diff in cluster mode.
if [ "$FROM_CLUSTER" -eq 1 ]; then
    print_header "Proposed Changes (current → proposed)"
    printf '%s\n' "${proposed_settings[@]}" | render_diff
fi

# Phase 4.1: per-class WPQ overrides section.
if [ "${#class_overrides[@]}" -gt 0 ]; then
    print_header "Per-class scheduler overrides (WPQ)"
    echo "Faster device classes don't need the same throttle as HDDs."
    for override in "${class_overrides[@]}"; do
        entity="${override%%|*}"
        kv="${override#*|}"
        printf "  %-24s %s\n" "$entity" "$kv"
    done
fi

# Phase 5.2: --diff exits cleanly after rendering all proposed-change
# sections. Skips backup commands, apply commands, perf analysis, notes.
if [ "$DIFF_ONLY" -eq 1 ]; then
    if [ "$FROM_CLUSTER" -ne 1 ]; then
        print_error "--diff requires --from-cluster (need real current state to diff against)."
        exit 2
    fi
    # The per-class/per-pool sections still need to render — they're
    # part of the delta. Fall through to those, then exit before the
    # 'Recommended Configuration Commands' section.
    DIFF_EXIT_AFTER_OVERRIDES=1
else
    DIFF_EXIT_AFTER_OVERRIDES=0
fi

# Phase 4.2: per-pool overrides and footgun warnings.
if [ "${#pool_warnings[@]}" -gt 0 ] || [ "${#pool_overrides[@]}" -gt 0 ]; then
    print_header "Per-pool overrides"
    for warning in "${pool_warnings[@]}"; do
        print_warning "Pool $warning"
        echo "    To re-enable: ceph osd pool set ${warning%%:*} noscrub false"
        echo "                  ceph osd pool set ${warning%%:*} nodeep-scrub false"
    done
    for override in "${pool_overrides[@]}"; do
        pname="${override%%#*}"
        kv="${override#*#}"
        printf "  %-24s %s  (metadata/index pool → tighten scrub cadence)\n" "$pname" "$kv"
    done
fi

# Per-pool sizing observations: pools with very large per-PG data. This is
# advisory, not a config change — scrubadub can't safely resize pools, and
# a PG split is a heavy rebalance. But large PGs are the usual reason one
# pool falls behind on scrubs while the rest keep up, so we surface them.
if [ "${#large_pg_pools[@]}" -gt 0 ]; then
    print_header "Per-pool sizing observations"
    echo "Pools with average per-PG data over ${LARGE_PG_THRESHOLD_GIB} GiB. Large PGs make"
    echo "deep-scrub and recovery take proportionally longer per PG, and reduce"
    echo "scrub parallelism (fewer PGs to spread across OSDs)."
    echo
    printf "  %-40s %12s %8s  %s\n" "POOL" "PER-PG" "PG_NUM" "AUTOSCALE"
    for entry in "${large_pg_pools[@]}"; do
        IFS='|' read -r lp_name lp_gib lp_pgnum lp_auto <<< "$entry"
        # Format per-PG size: show TiB when >= 1024 GiB, else GiB.
        if [ "$lp_gib" -ge 1024 ]; then
            lp_disp=$(awk "BEGIN { printf \"%.1f TiB\", $lp_gib / 1024 }")
        else
            lp_disp="${lp_gib} GiB"
        fi
        printf "  %-40s %12s %8s  %s\n" "$lp_name" "$lp_disp" "$lp_pgnum" "$lp_auto"
    done
    echo
    echo "  Modern Ceph guidance is roughly 100-500 GiB per PG. To reduce PG size:"
    echo "    - Raise the autoscaler target for denser clusters:"
    echo "        ceph config set mgr mgr/pg_autoscaler/pgs_per_osd 200   (default 100)"
    echo "    - Turn AUTOSCALE back 'on' for pools showing 'off' above, or"
    echo "    - Split a specific pool manually (heavy one-time rebalance):"
    echo "        ceph osd pool set <pool> pg_num <2x current>"
    echo "  Do this on a quiet cluster, one pool at a time — a split pauses scrubs"
    echo "  on backfilling PGs, so the backlog gets worse before it gets better."
fi

# --why: print the Reasoning section after the diff and overrides
# but before backup/apply. Useful in both default and --diff modes.
[ "$SHOW_WHY" -eq 1 ] && render_why

# Phase 5.2: under --diff, stop here. The operator wanted just the delta.
if [ "$DIFF_EXIT_AFTER_OVERRIDES" -eq 1 ]; then
    echo
    print_notice "Diff-only mode — backup/apply/perf sections omitted. Re-run without --diff for full report."
    exit 0
fi

# Phase 5.3-prep: --emit-backup-plan writes the would-rollback state
# to a file and exits. Pure read-only; useful for inspecting the
# format before --apply ever runs.
if [ -n "$EMIT_BACKUP_PLAN" ]; then
    if [ "$FROM_CLUSTER" -ne 1 ]; then
        print_error "--emit-backup-plan requires --from-cluster (need real current state)."
        exit 2
    fi
    build_backup_plan "$EMIT_BACKUP_PLAN"
    plan_rowcount=$(grep -cv '^#' "$EMIT_BACKUP_PLAN" 2>/dev/null || echo 0)
    print_success "Backup plan written to $EMIT_BACKUP_PLAN ($plan_rowcount rows)."
    print_notice "Inspect with: cat $EMIT_BACKUP_PLAN"
    exit 0
fi

print_header "Current Configuration Backup Commands"
echo "# Run these on your cluster to back up the current settings:"
echo "ceph config dump | grep -E 'scrub|osd_max_scrubs|osd_mclock_profile|osd_op_queue' \\"
echo "  > ceph_scrub_settings_backup_\$(date +%Y%m%d_%H%M%S).txt"

print_header "Recommended Configuration Commands"
echo "# Run these on your cluster to apply the recommended settings:"
for setting in "${proposed_settings[@]}"; do
    param="${setting% = *}"
    case "$param" in
        osd_deep_scrub_interval|osd_scrub_max_interval)
            # The mgr evaluates PG_NOT_DEEP_SCRUBBED / PG_NOT_SCRUBBED
            # against ITS OWN view of these intervals; a who=osd override
            # is invisible to the mgr, so the health checks keep firing on
            # the default (tracker #44959). Set both: 'osd' so the OSDs
            # honor it even where an osd-section row already exists, and
            # 'global' so the mgr's health math agrees.
            echo "ceph config set osd ${setting// = / }"
            echo "ceph config set global ${setting// = / }" ;;
        *)
            echo "ceph config set osd ${setting// = / }" ;;
    esac
done
# Phase 4.1: per-class overrides (entity is osd/class:<class>).
for override in "${class_overrides[@]}"; do
    entity="${override%%|*}"
    kv="${override#*|}"
    echo "ceph config set $entity ${kv// = / }"
done
# Phase 4.2: per-pool overrides (use 'ceph osd pool set', not 'config set').
for override in "${pool_overrides[@]}"; do
    pname="${override%%#*}"
    kv="${override#*#}"
    param="${kv% = *}"
    value="${kv#* = }"
    echo "ceph osd pool set $pname $param $value"
done

print_header "Performance Impact Analysis"

# Phase 3.3: compare each estimate to its own configured interval.
# Defaults: max_interval=7d (168h), deep_interval=7d. In cluster mode we
# read whatever is actually configured.
# Strip the .000000 Ceph appends to seconds-typed config values; bash
# arithmetic errors on floats. Same fix as in ingest_scrub_backlog.
_deep_iv_raw="${current_osd_deep_scrub_interval:-604800}"
_shallow_iv_raw="${current_osd_scrub_max_interval:-604800}"
deep_iv_h=$(( ${_deep_iv_raw%.*} / 3600 ))
shallow_iv_h=$(( ${_shallow_iv_raw%.*} / 3600 ))

echo "Deep scrub:"
if [ "$estimated_scrub_time" -gt "$deep_iv_h" ]; then
    print_warning "Estimated deep-scrub time (${estimated_scrub_time} h / ${est_days} d) exceeds your"
    print_warning "  current osd_deep_scrub_interval (${deep_iv_h} h). Backlog will grow."
    echo "  Recommendations:"
    echo "    1. Verify --avg-pg-size-gb matches reality (computed automatically under --from-cluster)."
    echo "    2. Verify --replica-size / --ec-ratio matches your largest pool's overhead."
    echo "    3. Consider --aggressive-scrubs after verifying per-host headroom."
    echo "    4. Review PG distribution; rebalance if uneven."
elif [ "$estimated_scrub_time" -gt $((deep_iv_h * 60 / 100)) ]; then
    print_notice "Estimated deep-scrub time (${estimated_scrub_time} h) is >60% of the deep-scrub interval (${deep_iv_h} h)."
    echo "  Tight margin; rerun if cluster grows."
else
    print_success "Estimated deep-scrub time (${estimated_scrub_time} h) fits within deep-scrub interval (${deep_iv_h} h)."
fi

echo "Shallow scrub:"
if [ "$shallow_scrub_time" -gt "$shallow_iv_h" ]; then
    print_warning "Estimated shallow-scrub time (${shallow_scrub_time} h) exceeds osd_scrub_max_interval (${shallow_iv_h} h)."
else
    print_success "Estimated shallow-scrub time (${shallow_scrub_time} h) fits within osd_scrub_max_interval (${shallow_iv_h} h)."
fi

# Phase 3.4: per-host scrub concurrency warning.
# Use osds_per_host_max from --from-cluster, else --osds-per-host override.
ph_max="${OSDS_PER_HOST:-${osds_per_host_max:-0}}"
proposed_max_scrubs=$(printf '%s\n' "${proposed_settings[@]}" | awk -F' = ' '/^osd_max_scrubs/ { print $2 }')
if [ -n "$proposed_max_scrubs" ] && [ "$ph_max" -gt 0 ]; then
    concurrent=$((proposed_max_scrubs * ph_max))
    echo "Per-host scrub concurrency: ${proposed_max_scrubs} × ${ph_max} OSDs/host = ${concurrent} simultaneous scrubs."
    if [ "$concurrent" -gt 8 ]; then
        print_warning "${concurrent} simultaneous scrubs per host is high. On busy hosts this can"
        print_warning "  starve client I/O. Consider lowering osd_max_scrubs, or using a per-host"
        print_warning "  scrub cap (osd_scrub_max_concurrent_per_host on Squid+; rolling restart"
        print_warning "  with osd_max_scrubs=1 + scrub-window enforcement on older releases)."
    fi
fi

echo
echo "Notes:"
echo "  1. Active scrub window: ${display_begin}:00–${display_end}:00 (0–0 means 24h)."
echo "  2. osd_scrub_load_threshold is normalized: loadavg / num_cpus. A 16-core"
echo "     host with threshold 0.5 pauses scrubs when loadavg > 8."
echo "  3. osd_scrub_sleep is in SECONDS (float). Old scrubadub docs said"
echo "     microseconds; that was wrong."
echo "  4. Scrub-time estimate assumes ${SCRUB_BUDGET_PERCENT}% of the binding ceiling is"
echo "     available to scrub (source: $SCRUB_BUDGET_SOURCE). Override with"
echo "     --scrub-budget-percent N or the SCRUB_BUDGET_PERCENT env var. This is"
echo "     a static value; on busy clusters lower it (5-8%), on idle clusters"
echo "     raise it (20-30%) to catch up backlog."

print_header "Additional Recommendations"
echo "Before applying:"
echo "  - Back up current settings using the command above."
echo "  - Review and understand each proposed change."
echo "  - Test in a non-production environment if possible."
echo
echo "After applying:"
echo "  - Monitor for 24-48 hours."
echo "  - Track 'pgs not (deep-)scrubbed in time' counts in 'ceph -s'."
echo "  - Compare actual vs estimated deep-scrub completion times."
echo "  - If problems occur, restore from the backup file."
echo
echo "Re-run scrubadub when:"
echo "  - Cluster size changes significantly."
echo "  - Workload patterns change."
echo "  - You add a new OSD class (e.g. first NVMe tier)."
echo "  - Actual scrub times differ significantly from estimated."

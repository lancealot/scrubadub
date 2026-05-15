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

# Phase 3: honest performance model.
NIC_GBPS=""          # --nic-gbps; per-host NIC speed in Gbps
HOST_COUNT=""        # --hosts (prompt mode); auto-detected in --from-cluster
OSDS_PER_HOST=""     # --osds-per-host (prompt mode); auto in --from-cluster
NIC_MBPS=0           # computed: NIC_GBPS * 125
NIC_SOURCE=""        # "--nic-gbps", "ethtool", or empty
NETWORK_CEILING=0    # computed: HOST_COUNT * NIC_MBPS, MB/s; 0 means unused

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

Performance model (Phase 3):
  --nic-gbps N            Per-host NIC speed in Gbps. Caps the scrub
                          throughput estimate at hosts × NIC_GBPS.
                          Auto-detected via 'ethtool' under --from-cluster.
  --hosts N               Host count for the network-ceiling computation
                          in prompt mode. Auto-detected under --from-cluster.
  --osds-per-host N       Max OSDs per host, for the per-host scrub
                          concurrency warning in prompt mode.

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
  --aggressive-scrubs     Permit osd_max_scrubs up to 3 (default cap: 2).
                          Read ROADMAP Phase 0.3 first.
  --scrub-budget-percent N
                          Integer 1-100. Share of the binding ceiling
                          (min of disk/network) reserved for scrub.
                          Default 10. Drop to 5 on busy clusters, raise
                          to 20-30 on idle ones to catch up backlog.
  --device-profile FILE   Source KEY=VALUE overrides for device constants.
                          Keys: HDD_THROUGHPUT, HDD_IOPS, SSD_THROUGHPUT,
                          SSD_IOPS, NVME_THROUGHPUT, NVME_IOPS.

Output modes (Phase 5):
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

    # Cap max_scrubs (Phase 0.3).
    local cap=2
    [ "$AGGRESSIVE_SCRUBS" -eq 1 ] && cap=3
    if [ "$max_scrubs" -gt "$cap" ]; then
        print_warning "osd_max_scrubs computed as $max_scrubs; capped at $cap." >&2
        if [ "$AGGRESSIVE_SCRUBS" -ne 1 ]; then
            print_warning "Use --aggressive-scrubs to allow up to 3 after reviewing per-host headroom." >&2
        fi
        max_scrubs=$cap
    fi
    if [ "$max_scrubs" -gt 1 ]; then
        print_warning "Per-host scrub concurrency = osd_max_scrubs($max_scrubs) × OSDs_per_host." >&2
        print_warning "Verify your hosts can absorb that before applying." >&2
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
            "version")                              fixture="version.txt" ;;
            "osd pool get "*" "*" --format json")
                # Phase 5.3-prep: pool-get fixtures live at
                # pool_get_<pool>_<key>.json. Missing file means "no
                # override is set on that pool" — silently return
                # non-zero so the caller's ENOENT path runs.
                local args=($*)
                fixture="pool_get_${args[3]}_${args[4]}.json"
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
            NIC_SOURCE="ethtool"
        fi
    fi
    if [ -n "$NIC_GBPS" ] && [ -n "$HOST_COUNT" ] && [ "$HOST_COUNT" -gt 0 ]; then
        # 1 Gbps = 125 MB/s (1000/8). awk handles fractional NIC speeds.
        NIC_MBPS=$(awk "BEGIN { printf \"%d\", $NIC_GBPS * 125 }")
        NETWORK_CEILING=$((HOST_COUNT * NIC_MBPS))
    fi
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
    print_notice "PG distribution: HDD=$hdd_pg_count SSD=$ssd_pg_count NVMe=$nvme_pg_count"
    if [ -n "$pg_imbalance_warning" ]; then
        while IFS= read -r line; do
            print_warning "PG imbalance — $line"
        done <<< "$pg_imbalance_warning"
        print_warning "Consider 'ceph osd reweight-by-pg' or the pg_autoscaler before tuning scrubs."
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

    # Per-pool rows: name, stored_bytes, pg_num, replica_size, ec_k+m_or_blank
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
            ec_profile: $p.erasure_code_profile
          }
        | "\(.name)\t\(.stored)\t\(.pg_num)\t\(.type)\t\(.size)\t\(.ec_profile)"
    ')

    # Walk rows, summing stored and weighted PG-size; pick the largest pool.
    local total_stored=0
    local total_pgs=0
    local largest_name="" largest_stored=0 largest_factor_num=3 largest_factor_den=1
    local row_count=0
    while IFS=$'\t' read -r name stored pg_num ptype psize ec_profile; do
        [ -z "$name" ] && continue
        row_count=$((row_count + 1))
        total_stored=$((total_stored + stored))
        total_pgs=$((total_pgs + pg_num))

        # Determine read-overhead factor for this pool.
        local factor_num=3 factor_den=1
        if [ "$ptype" = "3" ]; then
            # EC pool: psize is k+m on Ceph >= reef. Try to parse k+m from ec_profile name.
            if [[ "$ec_profile" =~ ec-([0-9]+)-([0-9]+) ]]; then
                local k="${BASH_REMATCH[1]}"
                local m="${BASH_REMATCH[2]}"
                factor_num=$((k + m))
                factor_den=$k
            else
                # Fallback: assume psize == k+m and k=size-2 (typical default profile k+2).
                factor_num=$psize
                factor_den=$((psize - 2 > 0 ? psize - 2 : 1))
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

    # Phase 4.2: walk pools again for per-pool overrides and footgun flags.
    # Hot pools (small avg object size) want shorter deep-scrub intervals;
    # the noscrub / nodeep-scrub pool flags are silent integrity killers.
    pool_overrides=()
    pool_warnings=()
    local pool_row
    # Non-whitespace separator: tab-IFS collapses empty fields, which
    # mis-aligns rows whose `flags_names` is null.
    while IFS='|' read -r pname stored objects flags is_hot; do
        [ -z "$pname" ] && continue
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
        | (if $obj > 0 and ($st / $obj) < 65536 and $st > 1048576
             then "1" else "0" end) as $hot
        | "\($p.pool_name)|\($st)|\($obj)|\($flags)|\($hot)"
    ')

    print_notice "Pools: $row_count; total stored: $((total_stored / 1073741824)) GB; avg PG size: $AVG_PG_SIZE GB"
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
    current_osd_mclock_profile=$(_cfg_lookup osd_mclock_profile)
    # Phase 2.3: surface measured IOPS so the benchmark advisory can flag low values.
    current_osd_mclock_max_capacity_iops_hdd=$(_cfg_lookup osd_mclock_max_capacity_iops_hdd)
    current_osd_mclock_max_capacity_iops_ssd=$(_cfg_lookup osd_mclock_max_capacity_iops_ssd)
}

# Phase 1.7: scrub backlog summary. Counts PGs whose last_deep_scrub_stamp
# (and last_scrub_stamp) are older than the configured interval.
backlog_summary=""
ingest_scrub_backlog() {
    local pgs now_epoch
    pgs=$(run_ceph pg dump pgs_brief --format json) || exit 4
    now_epoch=$(date +%s)

    local deep_iv="${current_osd_deep_scrub_interval:-604800}"
    local scrub_iv="${current_osd_scrub_max_interval:-604800}"

    local total_pgs deep_late=0 scrub_late=0
    total_pgs=$(echo "$pgs" | jq '.pg_stats | length')

    # jq emits "<deep_stamp> <scrub_stamp>" lines; we parse each timestamp
    # with `date -d` (GNU date handles the subseconds and +0000 zone).
    local deep_stamp scrub_stamp deep_epoch scrub_epoch
    while read -r deep_stamp scrub_stamp; do
        [ -z "$deep_stamp" ] && continue
        deep_epoch=$(date -d "${deep_stamp//+0000/+00:00}" +%s 2>/dev/null || echo 0)
        scrub_epoch=$(date -d "${scrub_stamp//+0000/+00:00}" +%s 2>/dev/null || echo 0)
        if [ "$deep_epoch" -gt 0 ] && [ $((now_epoch - deep_epoch)) -gt "$deep_iv" ]; then
            deep_late=$((deep_late + 1))
        fi
        if [ "$scrub_epoch" -gt 0 ] && [ $((now_epoch - scrub_epoch)) -gt "$scrub_iv" ]; then
            scrub_late=$((scrub_late + 1))
        fi
    done < <(echo "$pgs" | jq -r '.pg_stats[] | "\(.last_deep_scrub_stamp) \(.last_scrub_stamp)"')

    backlog_summary="${total_pgs} PGs total; ${scrub_late} past scrub interval (${scrub_iv}s); ${deep_late} past deep-scrub interval (${deep_iv}s)"
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
        if [ "$current" = "$proposed" ]; then
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
    local setting name current
    for setting in "${proposed_settings[@]}"; do
        name="${setting% = *}"
        current=$(echo "$config_dump" | jq -r --arg n "$name" '
            [.[] | select(.section=="osd" and .name==$n and ((.mask // "")==""))][0].value // empty')
        [ -z "$current" ] && current="<unset>"
        printf "osd\tosd\t\t%s\t%s\n" "$name" "$current" >> "$out_file"
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
    echo "HDD OSDs: $hdd_count"
    echo "  - PGs: $hdd_pg_count (avg $(calculate_pg_per_osd "$hdd_pg_count" "$hdd_count") PGs/OSD)"
    echo "  - Raw throughput: $hdd_tp MB/s (${HDD_THROUGHPUT} MB/s/OSD)"
    echo "  - IOPS: $hdd_io (${HDD_IOPS}/OSD, source: $HDD_IOPS_SOURCE)"
fi
if [ "$ssd_count" -gt 0 ]; then
    read -r ssd_tp ssd_io <<< "$(calculate_device_performance "$ssd_count" "$SSD_THROUGHPUT" "$SSD_IOPS")"
    total_throughput=$((total_throughput + ssd_tp))
    total_iops=$((total_iops + ssd_io))
    echo "SSD OSDs: $ssd_count"
    echo "  - PGs: $ssd_pg_count (avg $(calculate_pg_per_osd "$ssd_pg_count" "$ssd_count") PGs/OSD)"
    echo "  - Raw throughput: $ssd_tp MB/s (${SSD_THROUGHPUT} MB/s/OSD)"
    echo "  - IOPS: $ssd_io (${SSD_IOPS}/OSD, source: $SSD_IOPS_SOURCE)"
fi
if [ "$nvme_count" -gt 0 ]; then
    read -r nvme_tp nvme_io <<< "$(calculate_device_performance "$nvme_count" "$NVME_THROUGHPUT" "$NVME_IOPS")"
    total_throughput=$((total_throughput + nvme_tp))
    total_iops=$((total_iops + nvme_io))
    echo "NVMe OSDs: $nvme_count"
    echo "  - PGs: $nvme_pg_count (avg $(calculate_pg_per_osd "$nvme_pg_count" "$nvme_count") PGs/OSD)"
    echo "  - Raw throughput: $nvme_tp MB/s (${NVME_THROUGHPUT} MB/s/OSD)"
    echo "  - IOPS: $nvme_io (${NVME_IOPS}/OSD, source: $NVME_IOPS_SOURCE)"
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

total_pgs=$((hdd_pg_count + ssd_pg_count + nvme_pg_count))
estimated_scrub_time=$(calculate_scrub_time "$total_pgs" "$effective_ceiling")
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

# Collect proposed settings once so we can render both a diff and the apply commands.
proposed_settings=()
while IFS= read -r line; do
    proposed_settings+=("$line")
done < <(calculate_scrub_settings "$total_osds" "$max_pg_per_osd" "$WORKLOAD_TYPE" "$estimated_scrub_time" "$SCHEDULER")

# Phase 4.1: per-class WPQ overrides (no-op outside WPQ or single-class).
compute_class_overrides

# Phase 1.7: backlog summary in cluster mode.
if [ "$FROM_CLUSTER" -eq 1 ] && [ -n "$backlog_summary" ]; then
    print_header "Scrub Backlog (from 'ceph pg dump pgs_brief')"
    echo "  $backlog_summary"
fi

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
        printf "  %-24s %s  (small avg object size → tighten scrub cadence)\n" "$pname" "$kv"
    done
fi

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
    echo "ceph config set osd ${setting// = / }"
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
deep_iv_h=$(( (${current_osd_deep_scrub_interval:-604800}) / 3600 ))
shallow_iv_h=$(( (${current_osd_scrub_max_interval:-604800}) / 3600 ))

echo "Deep scrub:"
if [ "$estimated_scrub_time" -gt "$deep_iv_h" ]; then
    print_warning "Estimated deep-scrub time (${estimated_scrub_time} h / ${est_days} d) exceeds your"
    print_warning "  current osd_deep_scrub_interval (${deep_iv_h} h). Backlog will grow."
    echo "  Recommendations:"
    echo "    1. Verify --avg-pg-size-gb matches reality (Phase 1.4 computes it under --from-cluster)."
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
echo "     microseconds; that was wrong. See ROADMAP Phase 0.1."
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

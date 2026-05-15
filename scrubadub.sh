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
SCRUB_BUDGET_PERCENT=${SCRUB_BUDGET_PERCENT:-10}

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

Options:
  --avg-pg-size-gb N      Average PG size in GB (default: 4, a guess).
  --replica-size N        Treat pools as N-way replicated (default: 3).
  --ec-ratio k+m          Treat pools as erasure-coded k+m (e.g. 8+3).
                          Mutually exclusive with --replica-size.
  --scheduler {wpq|mclock}
                          Active OSD op scheduler. Prompted if omitted.
                          mClock suppresses settings it ignores.
  --hyperconverged        Other workloads share the OSD hosts (Proxmox,
                          OpenStack co-located VMs, etc.). Allows lower
                          osd_scrub_load_threshold values under WPQ.
  --aggressive-scrubs     Permit osd_max_scrubs up to 3 (default cap: 2).
                          Read ROADMAP Phase 0.3 first.
  --device-profile FILE   Source KEY=VALUE overrides for device constants.
                          Keys: HDD_THROUGHPUT, HDD_IOPS, SSD_THROUGHPUT,
                          SSD_IOPS, NVME_THROUGHPUT, NVME_IOPS.
  -h, --help              Show this help.

Environment variables:
  PG_SIZE_GB              Same as --avg-pg-size-gb.
  SCRUB_BUDGET_PERCENT    Percent of cluster throughput available for
                          scrub (default: 10).
  Plus any device constant from --device-profile.

See ROADMAP.md for the phased plan, including --from-cluster (Phase 1).
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
            --device-profile)
                require_value "$1" "${2:-}"
                DEVICE_PROFILE="$2"
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
# Emits one "param = value" per line. Scheduler-aware: under mClock, knobs
# the scheduler ignores are suppressed (Phase 0.7) and a profile is
# recommended instead.
calculate_scrub_settings() {
    local total_osds=$1
    local max_pgs_per_osd=$2
    local workload_type=$3
    local scrub_time=$4
    local scheduler=$5

    # Defaults
    local min_interval=86400    # 24h
    local max_interval=604800   # 7d
    local deep_interval=604800  # 7d
    local max_scrubs=1
    local randomize_ratio="0.5"
    local load_threshold="0.5"
    local scrub_sleep="0.0"
    local begin_hour=1
    local end_hour=7
    local mclock_profile="balanced"

    # Phase 0.1: osd_scrub_sleep is SECONDS (float), not microseconds.
    # Phase 0.8: osd_scrub_load_threshold is loadavg/num_cpus.
    #   Aggressive (low) values only when WPQ + --hyperconverged.
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
            mclock_profile="high_client_ops"
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

    # Phase 0.3: cap max_scrubs and warn loudly. Default 2; allow 3 only
    # with --aggressive-scrubs.
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

    # Emit. Phase 0.4 includes osd_scrub_interval_randomize_ratio.
    echo "osd_scrub_min_interval = $min_interval"
    echo "osd_scrub_max_interval = $max_interval"
    echo "osd_deep_scrub_interval = $deep_interval"
    echo "osd_max_scrubs = $max_scrubs"
    echo "osd_scrub_interval_randomize_ratio = $randomize_ratio"
    echo "osd_scrub_begin_hour = $begin_hour"
    echo "osd_scrub_end_hour = $end_hour"

    if [ "$scheduler" = "mclock" ]; then
        # Phase 0.7: mClock ignores sleep and load_threshold; emit a
        # profile instead. Phase 2.3 will sharpen the choice.
        echo "osd_mclock_profile = $mclock_profile"
    else
        echo "osd_scrub_sleep = $scrub_sleep"
        echo "osd_scrub_load_threshold = $load_threshold"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
parse_args "$@"
load_device_profile

print_header "Ceph Scrub Parameter Calculator"
echo "Calculates recommended scrub settings from OSD composition,"
echo "PG distribution, workload type, and the active op scheduler."
echo
echo "See ROADMAP.md for tracked improvements (Phase 1: --from-cluster auto-ingest)."
echo

# Banners about default assumptions (Phase 0.5, 0.10, 0.11).
if [ "$AVG_PG_SIZE_SOURCE" = "default" ]; then
    print_notice "Using default avg PG size = ${AVG_PG_SIZE_DEFAULT} GB. Real PG size varies"
    print_notice "  wildly per pool. Override with --avg-pg-size-gb N; Phase 1.4 will compute"
    print_notice "  this from 'ceph df detail'."
fi
if [ "$DATA_FACTOR_SOURCE" = "default (3x replicated)" ]; then
    print_notice "Assuming 3x replicated pools (deep-scrub reads 3x stored bytes)."
    print_notice "  Override with --replica-size N or --ec-ratio k+m."
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

# Workload
while true; do
    echo
    echo "Select primary workload type:"
    echo "  1) Heavy Read"
    echo "  2) Heavy Write"
    echo "  3) Mixed Use"
    echo "  4) Archival"
    read -p "Enter selection (1-4): " workload_type
    [[ "$workload_type" =~ ^[1-4]$ ]] && break
    print_error "Please enter a number between 1 and 4"
done

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
else
    print_success "WPQ is active. All scrub knobs (sleep, load_threshold, intervals, ...) honored."
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
    echo "  - IOPS: $hdd_io"
fi
if [ "$ssd_count" -gt 0 ]; then
    read -r ssd_tp ssd_io <<< "$(calculate_device_performance "$ssd_count" "$SSD_THROUGHPUT" "$SSD_IOPS")"
    total_throughput=$((total_throughput + ssd_tp))
    total_iops=$((total_iops + ssd_io))
    echo "SSD OSDs: $ssd_count"
    echo "  - PGs: $ssd_pg_count (avg $(calculate_pg_per_osd "$ssd_pg_count" "$ssd_count") PGs/OSD)"
    echo "  - Raw throughput: $ssd_tp MB/s (${SSD_THROUGHPUT} MB/s/OSD)"
    echo "  - IOPS: $ssd_io"
fi
if [ "$nvme_count" -gt 0 ]; then
    read -r nvme_tp nvme_io <<< "$(calculate_device_performance "$nvme_count" "$NVME_THROUGHPUT" "$NVME_IOPS")"
    total_throughput=$((total_throughput + nvme_tp))
    total_iops=$((total_iops + nvme_io))
    echo "NVMe OSDs: $nvme_count"
    echo "  - PGs: $nvme_pg_count (avg $(calculate_pg_per_osd "$nvme_pg_count" "$nvme_count") PGs/OSD)"
    echo "  - Raw throughput: $nvme_tp MB/s (${NVME_THROUGHPUT} MB/s/OSD)"
    echo "  - IOPS: $nvme_io"
fi

echo
echo "Cluster Totals"
echo "  - Raw cluster throughput: $total_throughput MB/s (sum of per-OSD; ignores"
echo "    network/CPU ceilings — Phase 3.1 will model these)"
scrub_budget_mbps=$((total_throughput * SCRUB_BUDGET_PERCENT / 100))
echo "  - Scrub budget: ${SCRUB_BUDGET_PERCENT}% of raw → ${scrub_budget_mbps} MB/s"
echo "  - IOPS estimate: $total_iops"
echo "  - Data factor: $DATA_FACTOR_SOURCE"
echo "  - Avg PG size:  $AVG_PG_SIZE GB ($AVG_PG_SIZE_SOURCE)"

total_pgs=$((hdd_pg_count + ssd_pg_count + nvme_pg_count))
estimated_scrub_time=$(calculate_scrub_time "$total_pgs" "$total_throughput")
est_days=$((estimated_scrub_time / 24))
echo "  - Estimated full deep-scrub time: ${estimated_scrub_time} hours (~${est_days} days)"

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
read -r display_begin display_end <<< "$(scrub_window_for_workload "$workload_type")"

print_header "Current Configuration Backup Commands"
echo "# Run these on your cluster to back up the current settings:"
echo "ceph config dump | grep -E 'scrub|osd_max_scrubs|osd_mclock_profile|osd_op_queue' \\"
echo "  > ceph_scrub_settings_backup_\$(date +%Y%m%d_%H%M%S).txt"

print_header "Recommended Configuration Commands"
echo "# Run these on your cluster to apply the recommended settings:"
IFS=$'\n'
for setting in $(calculate_scrub_settings "$total_osds" "$max_pg_per_osd" "$workload_type" "$estimated_scrub_time" "$SCHEDULER"); do
    echo "ceph config set osd ${setting// = / }"
done
unset IFS

print_header "Performance Impact Analysis"
echo "Scrub Schedule Analysis:"
if [ "$estimated_scrub_time" -gt 168 ]; then
    print_warning "Estimated deep-scrub time ($estimated_scrub_time h / ${est_days} d) exceeds 7 days."
    echo "  Recommendations to address this:"
    echo "    1. Verify --avg-pg-size-gb matches reality (Phase 1.4 will compute it)."
    echo "    2. Verify --replica-size / --ec-ratio matches your largest pool's overhead."
    echo "    3. Consider --aggressive-scrubs after verifying per-host headroom."
    echo "    4. Review PG distribution; rebalance if uneven."
elif [ "$estimated_scrub_time" -gt 72 ]; then
    print_notice "Estimated deep-scrub time ($estimated_scrub_time h) exceeds 3 days."
    echo "  The settings above have been adjusted to improve completion time."
else
    print_success "Estimated deep-scrub time ($estimated_scrub_time h) is within acceptable range."
fi

echo
echo "Notes:"
echo "  1. Active scrub window: ${display_begin}:00–${display_end}:00 (0–0 means 24h)."
echo "  2. osd_scrub_load_threshold is normalized: loadavg / num_cpus. A 16-core"
echo "     host with threshold 0.5 pauses scrubs when loadavg > 8."
echo "  3. osd_scrub_sleep is in SECONDS (float). Old scrubadub docs said"
echo "     microseconds; that was wrong. See ROADMAP Phase 0.1."
echo "  4. Scrub-time estimate assumes ${SCRUB_BUDGET_PERCENT}% of cluster throughput is"
echo "     available to scrub. Override with SCRUB_BUDGET_PERCENT env var."

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

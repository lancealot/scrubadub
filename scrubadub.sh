#!/bin/bash

# scrubadub - Ceph Scrub Parameter Calculator
# This script helps calculate optimal scrub settings for Ceph clusters
# based on OSD types, PG distribution, and workload patterns.

# Constants for device performance characteristics
# Throughput in MB/s, IOPS as operations/second
HDD_THROUGHPUT=150    # Average HDD throughput
HDD_IOPS=125         # Average HDD IOPS
SSD_THROUGHPUT=475    # Average SSD throughput
SSD_IOPS=70000       # Average SSD IOPS
NVME_THROUGHPUT=2750  # Average NVMe throughput
NVME_IOPS=600000     # Average NVMe IOPS

# Average PG size in GB (used for scrub time estimation)
AVG_PG_SIZE=4

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Utility functions for output formatting and calculations
print_header() {
    echo -e "\n${BOLD}=== $1 ===${NC}\n"
}

print_error() {
    echo -e "${RED}Error: $1${NC}" >&2
}

print_warning() {
    echo -e "${YELLOW}Warning: $1${NC}"
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

# Input validation functions
validate_number() {
    local input=$1
    local name=$2
    
    if ! [[ "$input" =~ ^[0-9]+$ ]]; then
        print_error "$name must be a non-negative number"
        return 1
    fi
    return 0
}

validate_osd_inputs() {
    local hdd=$1
    local ssd=$2
    local nvme=$3
    
    validate_number "$hdd" "HDD count" || return 1
    validate_number "$ssd" "SSD count" || return 1
    validate_number "$nvme" "NVMe count" || return 1
    
    if [ "$hdd" -eq 0 ] && [ "$ssd" -eq 0 ] && [ "$nvme" -eq 0 ]; then
        print_error "At least one type of OSD must exist"
        return 1
    fi
    
    return 0
}

validate_pg_inputs() {
    local count=$1
    local osds=$2
    local type=$3
    
    # Skip validation if this OSD type doesn't exist
    if [ "$osds" -eq 0 ]; then
        return 0
    fi
    
    validate_number "$count" "$type PG count" || return 1
    return 0
}

# Calculation functions
calculate_pg_per_osd() {
    local pg_count=$1
    local osd_count=$2
    
    if [ "$osd_count" -eq 0 ]; then
        echo "0"
        return
    fi
    
    echo "$(($pg_count/$osd_count))"
}

# Calculate total throughput and IOPS for a device type
calculate_device_performance() {
    local count=$1
    local throughput=$2
    local iops=$3
    
    echo "$((count * throughput)) $((count * iops))"
}

# Calculate estimated scrub time in hours
calculate_scrub_time() {
    local pg_count=$1
    local total_throughput=$2  # MB/s
    
    if [ "$total_throughput" -eq 0 ]; then
        echo "0"
        return
    fi
    
    # Calculate total data to scrub (PG count * avg PG size in GB * 1024 for MB)
    local total_mb=$((pg_count * AVG_PG_SIZE * 1024))
    
    # Calculate hours using integer division
    local hours=$((total_mb / (total_throughput * 3600)))
    
    # Ensure minimum of 1 hour if there's any data
    if [ "$total_mb" -gt 0 ] && [ "$hours" -eq 0 ]; then
        echo "1"
    else
        echo "$hours"
    fi
}

calculate_scrub_settings() {
    local total_osds=$1
    local max_pgs_per_osd=$2
    local workload_type=$3
    local scrub_time=$4
    
    # Base values
    local base_min_interval=86400  # 24 hours in seconds
    local base_max_interval=604800 # 7 days in seconds
    local base_deep_interval=604800 # 7 days in seconds
    local base_max_scrubs=1
    local base_load_threshold=0.5
    local base_sleep=0
    local scrub_begin_hour=1  # Default to early morning
    local scrub_end_hour=7    # Default window of 6 hours

    # Adjust based on PGs per OSD
    if [ "$max_pgs_per_osd" -gt 200 ]; then
        base_max_scrubs=3
        base_load_threshold=0.4
        print_warning "High PG count per OSD detected. Increasing max_scrubs and reducing load threshold."
    fi

    # Adjust based on workload type
    case $workload_type in
        1) # Heavy Read
            base_load_threshold=0.3
            base_sleep=20
            scrub_begin_hour=1
            scrub_end_hour=6
            ;;
        2) # Heavy Write
            base_load_threshold=0.2
            base_sleep=30
            base_min_interval=172800 # 48 hours
            scrub_begin_hour=2
            scrub_end_hour=5
            ;;
        3) # Mixed Use
            base_load_threshold=0.4
            base_sleep=15
            scrub_begin_hour=1
            scrub_end_hour=7
            ;;
        4) # Archival
            base_load_threshold=0.6
            base_sleep=10
            scrub_begin_hour=0
            scrub_end_hour=23  # Allow scrubbing all day for archival
            ;;
    esac

    # Adjust max_scrubs based on scrub time estimation
    if [ -n "$scrub_time" ] && [ "$scrub_time" -gt 168 ]; then  # More than 7 days (168 hours)
        base_max_scrubs=$((base_max_scrubs + 2))
        print_warning "Estimated scrub time exceeds 7 days. Increasing max_scrubs to prevent falling behind."
    elif [ -n "$scrub_time" ] && [ "$scrub_time" -gt 72 ]; then  # More than 3 days
        base_max_scrubs=$((base_max_scrubs + 1))
        print_warning "Estimated scrub time exceeds 3 days. Increasing max_scrubs to optimize completion time."
    fi

    # Output recommendations
    echo "osd_scrub_min_interval = $base_min_interval"
    echo "osd_scrub_max_interval = $base_max_interval"
    echo "osd_deep_scrub_interval = $base_deep_interval"
    echo "osd_max_scrubs = $base_max_scrubs"
    echo "osd_scrub_load_threshold = $base_load_threshold"
    echo "osd_scrub_sleep = $base_sleep"
    echo "osd_scrub_begin_hour = $scrub_begin_hour"
    echo "osd_scrub_end_hour = $scrub_end_hour"
}

# Main script
print_header "Ceph Scrub Parameter Calculator"

echo "This script will help calculate optimal scrub settings for your Ceph cluster."
echo "Please gather the following information from your cluster:"
echo "1. Number of OSDs per device type"
echo "2. Number of PGs per device type"
echo "3. Workload characteristics"
echo -e "4. Maximum concurrent scrubs (optional)\n"

# Collect OSD information
while true; do
    read -p "Enter number of HDD OSDs: " hdd_count
    read -p "Enter number of SSD OSDs: " ssd_count
    read -p "Enter number of NVMe OSDs: " nvme_count
    
    if validate_osd_inputs "$hdd_count" "$ssd_count" "$nvme_count"; then
        break
    fi
done

# Collect PG information
if [ "$hdd_count" -gt 0 ]; then
    while true; do
        read -p "Enter total PG count for HDD OSDs: " hdd_pg_count
        if validate_pg_inputs "$hdd_pg_count" "$hdd_count" "HDD"; then
            break
        fi
    done
else
    hdd_pg_count=0
fi

if [ "$ssd_count" -gt 0 ]; then
    while true; do
        read -p "Enter total PG count for SSD OSDs: " ssd_pg_count
        if validate_pg_inputs "$ssd_pg_count" "$ssd_count" "SSD"; then
            break
        fi
    done
else
    ssd_pg_count=0
fi

if [ "$nvme_count" -gt 0 ]; then
    while true; do
        read -p "Enter total PG count for NVMe OSDs: " nvme_pg_count
        if validate_pg_inputs "$nvme_pg_count" "$nvme_count" "NVMe"; then
            break
        fi
    done
else
    nvme_pg_count=0
fi

# Collect workload information
while true; do
    echo -e "\nSelect primary workload type:"
    echo "1) Heavy Read"
    echo "2) Heavy Write"
    echo "3) Mixed Use"
    echo "4) Archival"
    read -p "Enter selection (1-4): " workload_type
    
    if [[ "$workload_type" =~ ^[1-4]$ ]]; then
        break
    else
        print_error "Please enter a number between 1 and 4"
    fi
done

# Calculate and display results
print_header "Analysis Results"

echo "Device Class Distribution and Performance:"
total_throughput=0
total_iops=0

if [ "$hdd_count" -gt 0 ]; then
    read hdd_tp hdd_io <<< $(calculate_device_performance $hdd_count $HDD_THROUGHPUT $HDD_IOPS)
    total_throughput=$((total_throughput + hdd_tp))
    total_iops=$((total_iops + hdd_io))
    echo "HDD OSDs: $hdd_count"
    echo "  - PGs: $hdd_pg_count (avg $(calculate_pg_per_osd $hdd_pg_count $hdd_count) PGs/OSD)"
    echo "  - Estimated throughput: $hdd_tp MB/s"
    echo "  - Estimated IOPS: $hdd_io"
fi

if [ "$ssd_count" -gt 0 ]; then
    read ssd_tp ssd_io <<< $(calculate_device_performance $ssd_count $SSD_THROUGHPUT $SSD_IOPS)
    total_throughput=$((total_throughput + ssd_tp))
    total_iops=$((total_iops + ssd_io))
    echo "SSD OSDs: $ssd_count"
    echo "  - PGs: $ssd_pg_count (avg $(calculate_pg_per_osd $ssd_pg_count $ssd_count) PGs/OSD)"
    echo "  - Estimated throughput: $ssd_tp MB/s"
    echo "  - Estimated IOPS: $ssd_io"
fi

if [ "$nvme_count" -gt 0 ]; then
    read nvme_tp nvme_io <<< $(calculate_device_performance $nvme_count $NVME_THROUGHPUT $NVME_IOPS)
    total_throughput=$((total_throughput + nvme_tp))
    total_iops=$((total_iops + nvme_io))
    echo "NVMe OSDs: $nvme_count"
    echo "  - PGs: $nvme_pg_count (avg $(calculate_pg_per_osd $nvme_pg_count $nvme_count) PGs/OSD)"
    echo "  - Estimated throughput: $nvme_tp MB/s"
    echo "  - Estimated IOPS: $nvme_io"
fi

echo -e "\nCluster Totals:"
echo "- Total throughput: $total_throughput MB/s"
echo "- Total IOPS: $total_iops"

# Calculate estimated scrub time
total_pgs=$((hdd_pg_count + ssd_pg_count + nvme_pg_count))
estimated_scrub_time=$(calculate_scrub_time $total_pgs $total_throughput)
echo "- Estimated full scrub time: $estimated_scrub_time hours"

# Find highest PG per OSD ratio
max_pg_per_osd=0
total_osds=$((hdd_count + ssd_count + nvme_count))

if [ "$hdd_count" -gt 0 ]; then
    pg_per_osd=$(calculate_pg_per_osd $hdd_pg_count $hdd_count)
    if [ "$pg_per_osd" -gt "$max_pg_per_osd" ]; then
        max_pg_per_osd=$pg_per_osd
    fi
fi

if [ "$ssd_count" -gt 0 ]; then
    pg_per_osd=$(calculate_pg_per_osd $ssd_pg_count $ssd_count)
    if [ "$pg_per_osd" -gt "$max_pg_per_osd" ]; then
        max_pg_per_osd=$pg_per_osd
    fi
fi

if [ "$nvme_count" -gt 0 ]; then
    pg_per_osd=$(calculate_pg_per_osd $nvme_pg_count $nvme_count)
    if [ "$pg_per_osd" -gt "$max_pg_per_osd" ]; then
        max_pg_per_osd=$pg_per_osd
    fi
fi

print_header "Current Configuration Backup Commands"
echo "# Run these commands on your cluster to backup current settings:"
echo "ceph config dump | grep -E 'scrub|osd_max_scrubs' > ceph_scrub_settings_backup_\$(date +%Y%m%d).txt"

print_header "Recommended Configuration Commands"
echo "# Run these commands on your cluster to apply the recommended settings:"
IFS=$'\n'
for setting in $(calculate_scrub_settings $total_osds $max_pg_per_osd $workload_type $estimated_scrub_time); do
    echo "ceph config set osd ${setting// = / }"
done

print_header "Performance Impact Analysis"
echo "Scrub Schedule Analysis:"
if [ -n "$estimated_scrub_time" ] && [ "$estimated_scrub_time" -gt 168 ]; then
    print_warning "WARNING: Estimated scrub time ($estimated_scrub_time hours) exceeds 7 days!"
    echo "Recommendations to address this:"
    echo "1. Consider increasing osd_max_scrubs (already adjusted in settings above)"
    echo "2. Review PG distribution and consider rebalancing if uneven"
    echo "3. Monitor scrub completion times closely after applying changes"
elif [ -n "$estimated_scrub_time" ] && [ "$estimated_scrub_time" -gt 72 ]; then
    print_warning "NOTICE: Estimated scrub time ($estimated_scrub_time hours) exceeds 3 days"
    echo "The settings above have been adjusted to optimize scrub completion time."
else
    print_success "Estimated scrub time ($estimated_scrub_time hours) is within acceptable range"
fi

echo -e "\nPerformance Expectations:"
echo "1. Scrub Impact Windows:"
echo "   - Active scrubbing allowed between ${scrub_begin_hour}:00 and ${scrub_end_hour}:00"
echo "   - Reduced cluster impact during peak hours"
echo
echo "2. Resource Utilization:"
echo "   - Load threshold set to maintain responsiveness"
echo "   - Sleep intervals tuned for workload pattern"
echo "   - Concurrent scrubs balanced for efficiency"
echo
echo "3. Monitoring Recommendations:"
echo "   - Track actual vs. estimated scrub times"
echo "   - Monitor OSD load during scrub windows"
echo "   - Watch for scrub queue buildup"

print_header "Additional Recommendations"
echo "1. Before applying these changes:"
echo "   - Back up your current settings using the command above"
echo "   - Review the proposed changes"
echo "   - Consider testing in a non-production environment first"
echo
echo "2. After applying changes:"
echo "   - Monitor cluster performance for 24-48 hours"
echo "   - Watch for any scrub-related issues in the cluster logs"
echo "   - Monitor actual scrub completion times vs. estimated ($estimated_scrub_time hours)"
echo "   - If problems occur, restore original settings from your backup"
echo
echo "3. Re-run this tool if:"
echo "   - Your cluster size changes significantly"
echo "   - Your workload patterns change"
echo "   - You add different types of OSDs"
echo "   - Actual scrub times differ significantly from estimated times"

# Scrubadub Usage Guide

## Overview
Scrubadub is a tool that helps calculate optimal scrub settings for Ceph clusters. It takes into account your cluster's OSD composition, PG distribution, and workload patterns to recommend scrub parameters that balance data integrity with cluster performance.

## Prerequisites
Before running scrubadub, gather the following information from your Ceph cluster:

```bash
# Get OSD tree showing device classes (HDD/SSD/NVMe)
ceph osd tree --format json-pretty

# Get PG distribution per pool
ceph pg dump pools --format json-pretty

# Get current scrub settings (save this for backup)
ceph config dump | grep -E 'scrub|osd_max_scrubs'
```

## Required Information
You will need to provide:
1. Number of OSDs for each device type (HDD/SSD/NVMe)
2. Total PG count for each device type
3. Primary workload characteristics

## Workload Types
The script supports four workload profiles:
1. Heavy Read: Optimized for read-intensive workloads
   - Reduces scrub impact on read operations
   - Uses moderate sleep values
   - Maintains standard intervals

2. Heavy Write: Optimized for write-intensive workloads
   - Uses longer intervals between scrubs
   - Implements higher sleep values
   - Reduces load threshold to minimize impact

3. Mixed Use: Balanced configuration
   - Uses moderate values for all parameters
   - Suitable for general-purpose clusters

4. Archival: Optimized for cold storage
   - Allows higher load during scrubs
   - Uses shorter sleep values
   - Maintains standard intervals

## Output
The script provides:
1. Analysis of your cluster's device distribution
2. Commands to backup current settings
3. Recommended configuration commands
4. Additional operational recommendations

## Configuration Parameters

### Key Parameters Explained
- `osd_scrub_min_interval`: Minimum time between scrubs (seconds)
- `osd_scrub_max_interval`: Maximum time between scrubs (seconds)
- `osd_deep_scrub_interval`: Time between deep scrubs (seconds)
- `osd_max_scrubs`: Maximum concurrent scrubs per OSD
- `osd_scrub_load_threshold`: Maximum load before scrubs are deferred
- `osd_scrub_sleep`: Time to sleep between operations (microseconds)

### Default Values
- `osd_scrub_min_interval`: 86400 (24 hours)
- `osd_scrub_max_interval`: 604800 (7 days)
- `osd_deep_scrub_interval`: 604800 (7 days)
- `osd_max_scrubs`: 1
- `osd_scrub_load_threshold`: 0.5
- `osd_scrub_sleep`: 0

## Best Practices

### Before Applying Changes
1. Backup current settings:
   ```bash
   ceph config dump | grep -E 'scrub|osd_max_scrubs' > ceph_scrub_settings_backup_$(date +%Y%m%d).txt
   ```
2. Review the proposed changes
3. Consider testing in a non-production environment

### After Applying Changes
1. Monitor cluster performance for 24-48 hours
2. Watch for scrub-related issues in cluster logs
3. Be prepared to restore original settings if needed

### When to Re-run
Re-run the scrubadub tool when:
- Cluster size changes significantly
- Workload patterns change
- New OSD types are added
- Performance issues are observed

## Troubleshooting

### Common Issues
1. Scrubs taking too long
   - Check PG distribution
   - Consider increasing max_scrubs
   - Review load threshold

2. Performance impact too high
   - Increase scrub_sleep
   - Decrease load threshold
   - Reduce max_scrubs

3. Scrubs falling behind
   - Increase max_scrubs
   - Review interval settings
   - Check for other cluster issues

### Monitoring
Monitor these metrics to assess scrub impact:
- OSD load averages
- Client latency during scrubs
- Scrub completion times
- Recovery queue length

## Example Usage

```bash
$ ./scrubadub.sh

=== Ceph Scrub Parameter Calculator ===

Enter number of HDD OSDs: 12
Enter number of SSD OSDs: 4
Enter number of NVMe OSDs: 0
Enter total PG count for HDD OSDs: 2400
Enter total PG count for SSD OSDs: 800

Select primary workload type:
1) Heavy Read
2) Heavy Write
3) Mixed Use
4) Archival
Enter selection (1-4): 3

[Script will display analysis and recommendations...]

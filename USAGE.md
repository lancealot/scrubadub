# Scrubadub Usage Guide

> **Roadmap:** scrubadub is being reshaped from a prompt-driven helper
> into a cluster-ingested tool that detects WPQ vs mClock and emits
> appropriate recommendations. See [ROADMAP.md](ROADMAP.md) for the
> phased plan and tracked work.

## Overview
Scrubadub helps calculate optimal scrub settings for Ceph clusters. It
takes your cluster's OSD composition, PG distribution, and workload
pattern, and recommends scrub parameters that balance data integrity
with cluster performance.

### Known v1 caveats

Several items below describe v1 behavior that is being corrected in
[ROADMAP.md Phase 0](ROADMAP.md#phase-0--correctness-fixes). Where the
caveat affects you operationally, it's called out inline.

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
- `osd_scrub_load_threshold`: Maximum normalized load (`loadavg / num_cpus`, **not** raw loadavg) before scrubs are deferred. On a 16-core host with the default `0.5`, scrubs pause when loadavg exceeds 8. Ignored when the **mClock** scheduler is active. Tightened semantics in ROADMAP Phase 0.8.
- `osd_scrub_sleep`: Time to sleep between scrub chunks, in **seconds** (float, e.g. `0.1`). Ignored when the **mClock** scheduler is active. v1 currently emits integer values (e.g. `30`) — those are wrong; treat them as seconds and divide by ~150 for a sane starting point. Fixed in ROADMAP Phase 0.1.
- `osd_scrub_begin_hour`: Hour to begin allowing scrubs (0-23)
- `osd_scrub_end_hour`: Hour to stop allowing scrubs (0-23)

### Default Values
- `osd_scrub_min_interval`: 86400 (24 hours)
- `osd_scrub_max_interval`: 604800 (7 days)
- `osd_deep_scrub_interval`: 604800 (7 days)
- `osd_max_scrubs`: 1 (may be increased based on scrub time estimates)
- `osd_scrub_load_threshold`: 0.5
- `osd_scrub_sleep`: 0
- `osd_scrub_begin_hour`: 1 (1 AM)
- `osd_scrub_end_hour`: 7 (7 AM)

### Performance Characteristics
The tool uses these baseline performance metrics for calculations:
- HDDs: ~150 MB/s, ~125 IOPS
- SSDs: ~475 MB/s, ~70,000 IOPS
- NVMe: ~2,750 MB/s, ~600,000 IOPS

These values are used to estimate:
- Total cluster throughput
- Expected scrub completion times
- Whether adjustments to max_scrubs are needed

> **Caveats (tracked in ROADMAP Phase 0.9 / 0.11):**
> - The baselines above are dated and conflate SATA vs SAS SSDs and NVMe
>   generations (Gen3 ≠ Gen4 ≠ Gen5). Treat them as order-of-magnitude.
> - The completion-time estimate divides total data by full cluster
>   throughput. In practice scrub gets ~10–15% of bandwidth, so v1
>   estimates are optimistic by roughly an order of magnitude.
> - Real ceilings (NIC bandwidth, replication factor, EC parity reads)
>   are not yet modeled. Phase 3 of the roadmap addresses this.

## OSD op scheduler: WPQ vs mClock

Ceph 17 (Quincy) made **mClock** the default OSD op scheduler;
**WPQ** remains available and is what many production operators
(including [Clyso](https://www.clyso.com/blog/ceph-how-do-disable-mclock-scheduler/))
currently recommend. Which scheduler is active matters because mClock
**silently ignores** several knobs that v1 of scrubadub emits.

Check yours:

```bash
ceph config get osd osd_op_queue
```

| Active scheduler | What scrubadub v1 emits | What's honored |
|---|---|---|
| `wpq` | All of v1's knobs (sleep, load_threshold, intervals, max_scrubs, window) | All of them |
| `mclock_scheduler` | Same set | Only intervals, `osd_max_scrubs`, and the scrub window. `osd_scrub_sleep` and `osd_scrub_load_threshold` are **ignored**. |

If you're on mClock, prefer setting `osd_mclock_profile` to one of
`high_client_ops`, `balanced`, or `high_recovery_ops` over tuning
sleep/load_threshold. ROADMAP Phase 2.3 adds a proper mClock emitter to
scrubadub.

References:
- [Ceph mClock Config Reference](https://docs.ceph.com/en/reef/rados/configuration/mclock-config-ref/)
- [Clyso — how to disable mClock](https://www.clyso.com/blog/ceph-how-do-disable-mclock-scheduler/)
- [Ceph mClock vs WPQ comparison study](https://docs.ceph.com/en/reef/dev/osd_internals/mclock_wpq_cmp_study/)

## Best Practices

### Before Applying Changes
1. Backup current settings:
   ```bash
   ceph config dump | grep -E 'scrub|osd_max_scrubs' > ceph_scrub_settings_backup_$(date +%Y%m%d).txt
   ```
2. Review the proposed changes and performance impact analysis
3. Consider testing in a non-production environment
4. Note the estimated scrub completion time for monitoring

### After Applying Changes
1. Monitor cluster performance for 24-48 hours
2. Watch for scrub-related issues in cluster logs
3. Compare actual scrub completion times with estimates
4. Be prepared to restore original settings if needed

### When to Re-run
Re-run the scrubdub tool when:
- Cluster size changes significantly
- Workload patterns change
- New OSD types are added
- Performance issues are observed
- Actual scrub times differ significantly from estimates
- PG distribution changes substantially

## Troubleshooting

### Common Issues
1. Scrubs taking too long
   - Check PG distribution
   - Consider increasing max_scrubs
   - Review load threshold
   - Verify scrub window hours are appropriate

2. Performance impact too high
   - Increase scrub_sleep
   - Decrease load threshold
   - Reduce max_scrubs
   - Adjust scrub window to off-peak hours

3. Scrubs falling behind
   - Compare actual vs. estimated scrub times
   - Review throughput estimates vs. actual
   - Increase max_scrubs if needed
   - Consider extending scrub window
   - Check for other cluster issues

4. Uneven scrub distribution
   - Review PG distribution across OSDs
   - Check for device performance outliers
   - Consider rebalancing if necessary

### Monitoring
Monitor these metrics to assess scrub impact:
- OSD load averages
- Client latency during scrubs
- Scrub completion times vs. estimates
- Recovery queue length
- Device throughput vs. estimates
- IOPS impact during scrubs
- Scrub window utilization

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

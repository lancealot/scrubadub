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

## Two modes: prompt vs cluster-ingested

scrubadub runs in either of two modes:

- **Prompt mode** (default). You type in OSD counts, PG counts, and
  pick a workload type. Useful for off-cluster modeling and for
  exploring "what would scrubadub recommend if...?" scenarios.
- **Cluster-ingested mode** (`--from-cluster`, Phase 1). Run on a Ceph
  monitor node; scrubadub reads OSD inventory, PG distribution, pool
  sizes, current scrub config, the active scheduler, and the scrub
  backlog directly from the `ceph` CLI. Requires `ceph` and `jq` on
  PATH. By default refuses to run if it doesn't detect a mon node;
  pass `--force` to override.

Workload type isn't auto-detectable. In cluster mode, either pass
`--workload {read|write|mixed|archive}` or let scrubadub prompt you
for it.

### Cluster-mode output

In `--from-cluster` mode scrubadub adds two sections to the report:

1. **Scrub Backlog** — total PG count and how many are past their
   scrub / deep-scrub interval (the same signal `ceph health detail`
   raises as `PG_NOT_(DEEP_)SCRUBBED_IN_TIME`).
2. **Proposed Changes** — each recommended parameter rendered as
   `current → proposed`, highlighting only what would change. This
   is the foundation for the Phase 5 apply/diff/rollback workflow.

## Command-line flags

```
--from-cluster          Read OSD inventory, PG distribution, pool
                        sizes, current config, scheduler, and scrub
                        backlog from 'ceph' (run on a mon node).
--force                 Allow --from-cluster on a non-mon host.
--workload {read|write|mixed|archive}
                        Declare workload up front; skips the prompt.
--nic-gbps N            Per-host NIC speed in Gbps. Caps the scrub
                        throughput estimate at hosts × NIC. Auto-
                        detected via 'ethtool' under --from-cluster.
--hosts N               Host count (prompt mode only; auto-detected
                        under --from-cluster).
--osds-per-host N       Max OSDs per host (prompt mode only); enables
                        the per-host concurrency warning.
--avg-pg-size-gb N      Average PG size in GB. Default: 4 (a guess)
                        in prompt mode; computed from 'ceph df detail'
                        under --from-cluster.
--replica-size N        Treat pools as N-way replicated (default: 3).
--ec-ratio k+m          Treat pools as erasure-coded k+m (e.g. 8+3).
                        Mutually exclusive with --replica-size.
--scheduler {wpq|mclock}
                        Active OSD op scheduler. Auto-detected under
                        --from-cluster; prompted otherwise. mClock
                        suppresses the knobs it ignores.
--hyperconverged        Other workloads share the OSD hosts. Allows
                        more aggressive osd_scrub_load_threshold under
                        WPQ.
--aggressive-scrubs     Allow osd_max_scrubs up to 3 (default cap: 2).
                        Verify per-host headroom first.
--device-profile FILE   Override device baselines (KEY=VALUE file).
-h, --help              Show help.
```

Environment variables: `PG_SIZE_GB`, `SCRUB_BUDGET_PERCENT`,
`CEPH_FIXTURE_DIR` (testing — replaces live `ceph` calls with fixture
JSON files), and any of the device constants from `--device-profile`.

## Prerequisites
Before running scrubadub, gather the following information from your Ceph cluster:

```bash
# Get OSD tree showing device classes (HDD/SSD/NVMe)
ceph osd tree --format json-pretty

# Get PG distribution per pool
ceph pg dump pools --format json-pretty

# Get current scrub settings (save this for backup)
ceph config dump | grep -E 'scrub|osd_max_scrubs'

# Check the active OSD op scheduler (wpq or mclock_scheduler)
ceph config get osd osd_op_queue
```

## Required Information
You will need to provide:
1. Number of OSDs for each device type (HDD/SSD/NVMe)
2. Total PG count for each device type
3. Primary workload characteristics
4. Active OSD op scheduler (WPQ or mClock)

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
- `osd_scrub_sleep`: Time to sleep between scrub chunks, in **seconds** (float, e.g. `0.1`). Ignored when the **mClock** scheduler is active.
- `osd_scrub_interval_randomize_ratio`: Spreads scheduled scrubs in time to avoid synchronized scrub storms after tightening intervals. Default `0.5` (a PG's actual interval is randomized within ±50%).
- `osd_scrub_begin_hour`: Hour to begin allowing scrubs (0–23). Pair with `_end_hour=0` for an open-ended (24-hour) window.
- `osd_scrub_end_hour`: Hour to stop allowing scrubs. **`0` is the Ceph convention for "no end" / 24 hours**, not "midnight".
- `osd_mclock_profile`: mClock profile (`high_client_ops` / `balanced` / `high_recovery_ops`). Recommended only when the mClock scheduler is active.

### Default Values (what scrubadub recommends as a starting point)
- `osd_scrub_min_interval`: 86400 (24 hours)
- `osd_scrub_max_interval`: 604800 (7 days)
- `osd_deep_scrub_interval`: 604800 (7 days)
- `osd_max_scrubs`: 1 (capped at 2; `--aggressive-scrubs` allows 3)
- `osd_scrub_load_threshold`: 0.5 (lower under `--hyperconverged` + WPQ)
- `osd_scrub_sleep`: 0.1 seconds (WPQ only; omitted under mClock)
- `osd_scrub_interval_randomize_ratio`: 0.5
- `osd_scrub_begin_hour`: 1 (1 AM); Archival profile uses 0
- `osd_scrub_end_hour`: 7 (7 AM); Archival profile uses 0 (24h)

### Performance Characteristics
The tool uses these baseline performance metrics for calculations
(refreshed in Phase 0.11 — these are still order-of-magnitude):
- HDDs: ~200 MB/s, ~150 IOPS (modern 12 TB+ CMR)
- SSDs: ~500 MB/s, ~75,000 IOPS (SATA SSD baseline; SAS SSDs are ~3× faster)
- NVMe: ~3,500 MB/s, ~600,000 IOPS (Gen3–Gen4 median; Gen5 is ~2× faster)

Override via `--device-profile <file>` (a `KEY=VALUE` shell-sourceable
file with any of `HDD_THROUGHPUT`, `HDD_IOPS`, `SSD_THROUGHPUT`,
`SSD_IOPS`, `NVME_THROUGHPUT`, `NVME_IOPS`) or by exporting the same
names as environment variables.

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

scrubadub picks an emitter based on whichever scheduler is active —
it does **not** force one over the other.

| Active scheduler | What scrubadub emits |
|---|---|
| `wpq` | `osd_scrub_min_interval`, `osd_scrub_max_interval`, `osd_deep_scrub_interval`, `osd_max_scrubs`, `osd_scrub_interval_randomize_ratio`, `osd_scrub_begin_hour`, `osd_scrub_end_hour`, **`osd_scrub_sleep`**, **`osd_scrub_load_threshold`** |
| `mclock_scheduler` | Same set **minus** `osd_scrub_sleep` and `osd_scrub_load_threshold` (mClock ignores them), **plus** `osd_mclock_profile` |

### mClock profile mapping

scrubadub picks the profile from the workload bucket plus
`--hyperconverged`:

| Workload | Profile |
|---|---|
| Heavy Read | `high_client_ops` |
| Heavy Write | `balanced` |
| Mixed | `balanced` |
| Archival | `balanced` |
| any + `--hyperconverged` | `high_client_ops` |

`high_recovery_ops` is reserved for the Phase 6.1 backlog-drain mode
(not implemented yet).

### Suspiciously low mClock IOPS

Under `--from-cluster`, scrubadub reads
`osd_mclock_max_capacity_iops_hdd` and `..._ssd` from `ceph config
dump`. If either looks too low (HDD < 50 IOPS, SSD < 5000 IOPS),
scrubadub prints an advisory to re-run the benchmark:

```bash
ceph config set osd osd_mclock_force_run_benchmark_on_init true
# restart OSDs one host at a time
ceph config set osd osd_mclock_force_run_benchmark_on_init false
```

Bad benchmarks are usually caused by a noisy host during OSD init —
the benchmark runs once on first boot and the value sticks until you
ask for a re-run.

### Switching schedulers

To move from mClock to WPQ:

```bash
ceph config set osd osd_op_queue wpq
# restart OSDs one host at a time
```

The reverse:

```bash
ceph config rm osd osd_op_queue      # drop the override; the default since Ceph 17 is mClock
# or explicitly:
ceph config set osd osd_op_queue mclock_scheduler
# then restart OSDs
```

Clyso's [post on disabling mClock](https://www.clyso.com/blog/ceph-how-do-disable-mclock-scheduler/)
walks through the rationale and gotchas. The
[Ceph mClock config reference](https://docs.ceph.com/en/reef/rados/configuration/mclock-config-ref/)
documents every mClock-specific knob.

References:
- [Ceph mClock Config Reference](https://docs.ceph.com/en/reef/rados/configuration/mclock-config-ref/)
- [Clyso — how to disable mClock](https://www.clyso.com/blog/ceph-how-do-disable-mclock-scheduler/)
- [Ceph mClock vs WPQ comparison study](https://docs.ceph.com/en/reef/dev/osd_internals/mclock_wpq_cmp_study/)

## Performance model: what scrubadub estimates

Phase 3 of the roadmap rebuilt the scrub-time math to be honest. The
analysis section in the report shows:

- **Raw disk throughput** — sum of per-OSD MB/s from baselines (or
  `--device-profile` overrides). On its own this is the wrong upper
  bound for scrub: networks are usually slower than the disk pool.
- **Network ceiling** — `hosts × per-host NIC × 125 MB/s/Gbps`.
  Auto-detected via `ethtool` under `--from-cluster`; in prompt mode,
  pass `--hosts N --nic-gbps N`. Skipped (and clearly labelled "not
  modeled") when the inputs aren't available.
- **Binding ceiling** — `min(disk, network)`. Whichever is lower is
  the real upper bound; scrubadub labels it `disk-bound` or
  `network-bound`.
- **Scrub budget** — share of the binding ceiling reserved for scrub.
  Default 10%; tune via `--scrub-budget-percent N` (or the
  `SCRUB_BUDGET_PERCENT` env var). Real scrubs don't get 100% of
  cluster bandwidth, and the value should reflect how loaded the
  cluster actually is:

  | Cluster state    | Reasonable budget |
  |------------------|------------------:|
  | Heavy production load (steady client I/O near ceiling) | 5–8% |
  | Normal mixed workload                                  | 10–15% (default) |
  | Light load / off-hours                                 | 20–30% |
  | Idle / backlog-recovery window                         | 40–50% |

  scrubadub prints the value's source (`default`, `--scrub-budget-percent`,
  or `SCRUB_BUDGET_PERCENT env`) in the analysis section so it's clear
  which knob is in play. The value is **static** — scrubadub is a
  one-shot tool, not a daemon. A separate dynamic-tuning daemon is the
  right home for "auto-raise the budget when the cluster is idle";
  that's intentionally out of scope here.
- **Shallow vs deep estimates** — shallow scrub reads metadata, deep
  scrub reads object data. scrubadub prints both and compares each
  against its own configured interval (`osd_scrub_max_interval` for
  shallow, `osd_deep_scrub_interval` for deep). Shallow is typically
  seek-bound, not bandwidth-bound; treat its estimate as
  order-of-magnitude.

### IOPS source

In `--from-cluster` mode, scrubadub reads
`osd_mclock_max_capacity_iops_hdd` and `..._ssd` from `ceph config
dump`. When non-zero, those measured values replace the hardcoded
device baselines in the analysis section (the script's defaults are
labelled `source: default`; substitutions are labelled `source:
mClock benchmark`).

If the measured values look wildly low, the mClock benchmark advisory
fires (see the previous section) and the script keeps using whichever
value is in `ceph config` — re-run the benchmark before relying on the
estimate.

### Empirical throughput (`--bench-osds`)

The hardcoded throughput baselines (200 MB/s HDD, 500 MB/s SSD,
3500 MB/s NVMe) are order-of-magnitude guesses for typical hardware
and are usually wrong for any specific cluster — disks, controllers,
NVMe generation, and bluestore tuning all matter. For a real number,
opt in to `--bench-osds`.

What it does:

- Picks **one OSD per host per device class** from `ceph osd tree`,
  skipping OSDs that are `down` or that participate in any non-clean
  PG (so backfilling OSDs don't drag the sample).
- Runs `ceph tell osd.<id> bench` against each sampled OSD. HDD
  samples write 1 GiB; NVMe samples write 4 GiB (small samples on
  NVMe live entirely in cache and report bogus high numbers).
- Aggregates per-class results into a baseline via the method
  chosen by `--bench-aggregate` (default: `median`).
- Flags OSDs whose individual result is below
  `--outlier-threshold × baseline` (default `0.5×`).
- Caches everything to `~/.scrubadub/bench-<cluster_fsid>.json` for
  30 days. Use `--refresh-bench` to re-run.

Aggregation options:

| Method | When to use |
|---|---|
| `median` (default) | Robust to one bad sample; matches operator intuition. |
| `p25` | Honest for scrub-time math — scrub completes at the speed of the slowest OSDs, not the typical ones. |
| `trimmed-mean` | Drops top and bottom 10% before averaging; balances stability and detail. |
| `mean` | Simple average; vulnerable to outliers. |

What it does NOT measure:

- **Reads.** `ceph tell osd.X bench` writes data. Scrub reads data.
  For HDDs these track closely; for NVMe, read is typically faster
  than write, so the write-based baseline is **conservative** for
  scrub-time estimates — good for safety, bad if you want an
  optimistic number.
- **Cluster contention.** Bench measures the OSD under whatever
  load the cluster has at the moment. Run during low-traffic
  periods if you care about peak capacity.
- **Abort.** There is no abort facility in Ceph. If you Ctrl-C
  scrubadub mid-bench, the in-flight bench on the OSD will finish
  on its own. scrubadub stops launching new benches but can't
  interrupt the one already running.

In the analysis section, the throughput source is labelled
`source: median of N sampled, just now` (fresh run) or
`source: median of N sampled, cache <date>` (cache hit). Outliers
get a yellow warning line listing the offending OSD IDs and their
measured throughput.

### Per-host scrub concurrency

scrubadub computes `proposed_osd_max_scrubs × max(OSDs_per_host)` and
prints the result as `N simultaneous scrubs per host`. When that
product exceeds 8, scrubadub warns: many hosts can absorb a few
parallel scrubs but starve clients past that point.

In `--from-cluster` mode the OSDs-per-host count comes from
`ceph osd tree`. In prompt mode, pass `--osds-per-host N` to enable
the warning.

If you need to tighten further, Squid+ has `osd_scrub_max_concurrent_per_host`;
on older releases the practical equivalent is `osd_max_scrubs=1` plus
a tight `osd_scrub_begin_hour`/`osd_scrub_end_hour` window.

## Per-class and per-pool overrides

Beyond the global `osd_*` settings, scrubadub emits two extra kinds of
recommendation when the cluster has the right shape.

### Per-class WPQ overrides (`--from-cluster` + WPQ + mixed classes)

The global `osd_scrub_sleep` is HDD-leaning by default (HDDs need
pacing; NVMes don't). When the cluster has more than one device class
and the active scheduler is WPQ, scrubadub adds a `Per-class scheduler
overrides` section that emits class-scoped `osd/class:<class>` lines
for the faster classes:

```
ceph config set osd/class:ssd  osd_scrub_sleep 0.0
ceph config set osd/class:nvme osd_scrub_sleep 0.0
```

Under `--aggressive-scrubs`, NVMe also gets `osd_max_scrubs+1` (still
capped at 3 globally).

This section is skipped under mClock — mClock ignores
`osd_scrub_sleep` and `osd_scrub_load_threshold` per-class anyway.

### Per-pool overrides (`--from-cluster`)

Two patterns trigger pool-level recommendations:

- **`noscrub` / `nodeep-scrub` flag set on a pool.** This is a silent
  integrity killer — scrubs simply don't run on that pool, regardless
  of how the OSD scrub config looks. scrubadub flags it with the
  `ceph osd pool unset` commands needed to re-enable scrubbing.
- **Hot / index pools.** When average object size for a pool is under
  64 KB (typical of RGW index pools, RBD metadata pools, omap-heavy
  workloads), scrubadub emits a `deep_scrub_interval = 259200`
  (3-day) override via `ceph osd pool set <pool> deep_scrub_interval`.
  Index pools want frequent integrity verification because the
  consequences of bit-rot are immediate and silent.

Both per-class and per-pool sections appear only when the cluster
matches the relevant shape — they're skipped on single-class clusters
and in prompt mode (which has no pool data).

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

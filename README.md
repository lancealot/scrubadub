![scrubadub](https://raw.githubusercontent.com/lancealot/scrubadub/assets/scrubadub.png)

# Scrubadub

Scrubadub helps Ceph administrators tune their cluster's scrub settings.
You feed it your cluster's shape and it prints recommended
`ceph config set` lines for balancing data integrity against client
impact.

Ceph's defaults are sized for small clusters. On larger or busier ones
they routinely leave operators staring at `PG_NOT_DEEP_SCRUBBED_IN_TIME`
warnings. Scrubadub produces a set of starting-point settings tuned for
your cluster's media mix, PG layout, workload, and op scheduler.

## Where this project is going

Scrubadub is evolving along two strategic shifts. Both are tracked in
detail in [ROADMAP.md](ROADMAP.md):

1. **From prompt-driven to cluster-ingested.** Run scrubadub locally on
   a Ceph **monitor node** and let it read OSD inventory, PG
   distribution, pool sizes, current config, scheduler, and scrub
   backlog directly via the `ceph` CLI. Manual input stays as a
   fallback for off-cluster modeling.
2. **Scheduler-aware, WPQ + mClock equally supported.** Detect which OSD
   op scheduler is active and emit recommendations appropriate to it.
   Under mClock, classic knobs like `osd_scrub_sleep` and
   `osd_scrub_load_threshold` are silently ignored — scrubadub will say
   so out loud and recommend an mClock profile instead.

The current v1 script is prompt-driven and WPQ-shaped. Phase 0 of the
roadmap fixes correctness bugs in v1; Phase 1 introduces cluster
auto-ingest; Phase 2 adds the mClock emitter.

## What v1 does today

- Prompts for HDD / SSD / NVMe OSD counts and total PG counts per class.
- Asks for a primary workload type (Heavy Read, Heavy Write, Mixed, or
  Archival).
- Prints a `ceph config dump` backup command.
- Prints recommended `ceph config set osd ...` lines for scrub
  intervals, `osd_max_scrubs`, sleep, load threshold, and the scrub
  window.
- Prints a rough scrub-completion-time estimate.

Known v1 caveats (all tracked under [ROADMAP.md Phase 0](ROADMAP.md#phase-0--correctness-fixes)):

- The scrub-time estimate assumes 100% of cluster throughput is
  available for scrub. Realistic budget is ~10–15%. *(Phase 0.9)*
- Average PG size is hardcoded to 4 GB. Real PG size varies wildly per
  pool. *(Phase 0.5, replaced by per-pool data in Phase 1.4)*
- Output targets a WPQ scheduler. On Reef/Squid clusters running the
  default mClock scheduler, some emitted knobs are no-ops. *(Phase 0.6,
  0.7, 2.3)*
- Device throughput baselines are dated and conflate SATA/SAS SSDs and
  NVMe generations. *(Phase 0.11)*
- `osd_scrub_sleep` was previously documented in microseconds — it is
  seconds (float). *(Phase 0.1, doc fix already landed)*

See [USAGE.md](USAGE.md) for the operator-facing guide.

## Quick start

```bash
git clone https://github.com/lancealot/scrubadub.git
cd scrubadub
chmod +x scrubadub.sh
./scrubadub.sh
```

Before running, gather a few things from your cluster:

```bash
ceph osd tree --format json-pretty
ceph pg dump pools --format json-pretty
ceph config dump | grep -E 'scrub|osd_max_scrubs'
ceph config get osd osd_op_queue   # wpq or mclock_scheduler
```

Phase 1 (`--from-cluster`) will read all of this for you when run on a
monitor node.

## Requirements

- Bash (Linux, macOS, or WSL).
- No additional dependencies today.
- Future cluster-ingest mode will require `jq` and the `ceph` CLI on a
  monitor node.

## Documentation

- [USAGE.md](USAGE.md) — operator-facing usage guide.
- [ROADMAP.md](ROADMAP.md) — phased plan and per-item tracking.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Contributing

Contributions welcome. The roadmap lists itemized work; pick a checkbox
and open a PR.

## Support

File an issue on the GitHub repository.

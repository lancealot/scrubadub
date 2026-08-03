![scrubadub](https://raw.githubusercontent.com/lancealot/scrubadub/assets/scrubadub.png)

# Scrubadub

Scrubadub helps Ceph administrators tune their cluster's scrub settings.
Run it on a monitor node and it reads your cluster's real state, then
prints recommended `ceph config set` lines that balance data integrity
against client impact.

Ceph's defaults are sized for small clusters. On larger or busier ones
they routinely leave operators staring at `PG_NOT_DEEP_SCRUBBED_IN_TIME`
warnings. Scrubadub produces starting-point settings tuned for your
cluster's media mix, PG layout, pool roles, workload, and op scheduler —
and explains its reasoning.

It is a single Bash script. `jq` and the `ceph` CLI are the only
dependencies, and both already ship on every Ceph node.

## Two modes

**Cluster-ingested (`--from-cluster`)** — the default way to run it.
On a monitor node, scrubadub reads OSD inventory, per-class PG
distribution, pool sizes and roles, current scrub config, the active op
scheduler, and the scrub backlog directly via `ceph` + `jq`. No manual
input required (pass `--workload` to skip the one interactive prompt).

**Prompt-driven** — the original off-cluster what-if mode. Answer a few
questions about OSD counts and workload and it models settings without
touching a cluster. Handy for planning hardware you don't have yet.

## What it does

- **Cluster ingest.** Reads real OSD/PG/pool/config/scheduler/backlog
  state from a mon node; refuses to run off a mon unless `--force`.
- **Scheduler-aware.** Detects WPQ vs mClock and emits only the knobs
  that scheduler honors — under mClock it suppresses `osd_scrub_sleep` /
  `osd_scrub_load_threshold` and recommends an `osd_mclock_profile`
  instead, saying so out loud.
- **Honest performance model.** Estimates deep- and shallow-scrub
  completion time against a *binding* ceiling of
  `min(disk throughput, network)` — network is auto-detected via
  `ethtool` or set with `--nic-gbps`. Applies a realistic scrub budget
  (default 10%, tunable). Uses mClock's measured IOPS when present.
- **Empirical throughput (`--bench-osds`).** Optionally measures real
  per-OSD throughput via `ceph tell osd.X bench` (one OSD per host per
  class), flags slow-drive outliers, and caches results per cluster.
- **Per-class tuning.** On mixed-media WPQ clusters, emits
  `osd/class:<class>` overrides so NVMe/SSD aren't throttled like HDDs.
- **Per-pool tuning.** Detects metadata/index pools (CephFS metadata by
  role, RGW bucket index by name, or OMAP-dominant) and tightens their
  deep-scrub cadence; flags pools with `noscrub`/`nodeep-scrub` set;
  flags pools with very large per-PG data.
- **Correct arithmetic.** Real per-pool PG size and replication/EC
  overhead (EC k+m read from the authoritative profile), unique-PG vs
  OSD-assignment counts kept distinct, seconds-typed floats handled.
- **Safe by default.** Read-only. Prints a backup command and, with
  `--emit-backup-plan`, a full would-rollback plan. Nothing is applied
  to the cluster.

## Output modes

- `--dry-run` — the default; full report, no cluster changes.
- `--diff` — only the current → proposed delta (numeric-aware, so
  `86400.000000` and `86400` are not spurious changes).
- `--why` — a "Reasoning" section explaining each proposed change.
- `--emit-backup-plan FILE` — write the rollback state as a TSV, then
  exit (read-only).

See [USAGE.md](USAGE.md) for the full flag reference and worked examples.

## Quick start

On a monitor node:

```bash
git clone https://github.com/lancealot/scrubadub.git
cd scrubadub
chmod +x scrubadub.sh

# Read the cluster and print recommendations (read-only):
./scrubadub.sh --from-cluster --workload mixed

# Just the delta, with reasoning:
./scrubadub.sh --from-cluster --workload mixed --diff --why

# Override the OSD-node NIC speed if it differs from the mon's:
./scrubadub.sh --from-cluster --workload mixed --nic-gbps 50
```

Off-cluster planning (no cluster needed):

```bash
./scrubadub.sh
```

## Requirements

- **Prompt mode:** Bash (Linux, macOS, or WSL). No other dependencies.
- **`--from-cluster` mode:** run on a Ceph monitor node with `jq` and a
  working `ceph` CLI. Both ship with Ceph.

## Testing

`test/smoke.sh` exercises both modes against recorded cluster fixtures —
no live cluster required:

```bash
bash test/smoke.sh
```

Point `CEPH_FIXTURE_DIR` at a fixture directory to run `--from-cluster`
against canned `ceph` output.

## Documentation

- [USAGE.md](USAGE.md) — operator-facing usage guide and flag reference.
- [ROADMAP.md](ROADMAP.md) — completed work and what's planned next
  (measured scrub capacity, backlog-drain mode, JSON/YAML output,
  observability). scrubadub is advisory by design — it never writes to
  a cluster.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Contributing

Contributions welcome. The roadmap lists itemized work; pick an item and
open a PR.

## Support

File an issue on the GitHub repository.

# Scrubadub Roadmap

Scrubadub started as an interactive Bash tool: the operator typed in OSD
counts, PG counts, and a workload bucket, and the script printed a set of
`ceph config set` lines. This roadmap charts its evolution along two
strategic shifts:

1. **From prompt-driven to cluster-ingested.** The tool is moving toward
   being run locally on a Ceph **monitor node** so it can read the
   cluster's real state via the `ceph` CLI. Hand-typed numbers stay as a
   fallback for off-cluster what-if modeling, not the default path.
2. **Scheduler-aware, with WPQ and mClock treated equally.** Scrubadub
   will detect which OSD op scheduler is active and emit recommendations
   appropriate to it. Some classic knobs (`osd_scrub_sleep`,
   `osd_scrub_load_threshold`) are ignored under mClock; the tool should
   say so out loud and skip emitting them in that case.

Scrubadub stays a **single Bash script** (`scrubadub.sh`). `jq` is an
acceptable dependency once cluster ingestion lands — it ships with every
Ceph node anyway. No Python rewrite is planned.

---

## Status legend

| Mark | Meaning |
|------|---------|
| `[ ]` | Planned |
| `[~]` | In progress |
| `[x]` | Done |
| `[!]` | Blocked |
| `[-]` | Dropped or superseded |

---

## Current baseline (v1.6)

After Phase 0, Phase 1, Phase 2, Phase 3, Phase 3.5, and Phase 4:

Empirical throughput (Phase 3.5):
- Opt-in `--bench-osds` runs `ceph tell osd.X bench` against one
  OSD per host per device class, skipping down/backfilling OSDs.
- Aggregation configurable: `median` (default), `p25`, `trimmed-mean`,
  `mean`. P25 is appropriate for scrub-time math since the slowest
  OSDs bottleneck the round.
- Outliers flagged at `OUTLIER_THRESHOLD × baseline` (default 0.5×)
  with their measured throughput in the warning.
- Results cached to `~/.scrubadub/bench-<fsid>.json` with a 30-day
  TTL; `--refresh-bench` forces re-bench.
- Source label in the analysis section makes it clear which number
  is in play: `source: default` vs `source: median of N sampled,
  cache <date>`.

Per-class and per-pool overrides (Phase 4):
- Mixed-class clusters under WPQ get `osd/class:<class>` overrides for
  faster device classes (`osd_scrub_sleep = 0.0` for SSD/NVMe,
  optional `osd_max_scrubs+1` on NVMe under `--aggressive-scrubs`).
  Skipped under mClock (which ignores sleep/load_threshold per-class).
- `--from-cluster` now flags pools with `noscrub` or `nodeep-scrub`
  set, with the `ceph osd pool unset` commands to clear them.
- Hot pools (avg object size < 64 KB) get a tightened
  `deep_scrub_interval` (3 days) emitted as a `ceph osd pool set`
  override. Indexes / metadata pools should verify integrity more
  often than bulk RBD/EC pools.
- Pools with average per-PG data over `--large-pg-threshold-gib`
  (default 1 TiB) get an advisory sizing observation listing per-PG
  size, `pg_num`, and autoscale mode, with remediation suggestions.

Honest performance model (Phase 3):
- Network ceiling: scrub-time math now uses
  `min(disk_total, hosts × per-host NIC × 125 MB/s)` × `SCRUB_BUDGET_PERCENT`.
  Auto-detected via `ip` + `ethtool` under `--from-cluster`; in prompt
  mode, pass `--hosts N --nic-gbps N`.
- mClock self-benchmark: when `osd_mclock_max_capacity_iops_{hdd,ssd}`
  are present in `ceph config dump`, scrubadub uses those measured
  values in place of the hardcoded device IOPS. The analysis section
  labels each row's IOPS as `source: default` or `source: mClock benchmark`.
- Shallow vs deep scrub estimates are reported separately, each
  compared against its own configured interval (`osd_scrub_max_interval`
  vs `osd_deep_scrub_interval`).
- Per-host scrub concurrency: scrubadub computes
  `proposed_max_scrubs × max(OSDs_per_host)` and warns when the
  product exceeds 8 (the threshold past which most hosts can't keep
  serving clients comfortably).

Scheduler-aware output (Phase 2):
- `calculate_scrub_settings` is now a dispatcher; each scheduler has
  its own emitter (`emit_wpq_settings`, `emit_mclock_settings`). Both
  are sourceable and callable as unit functions — `test/smoke.sh`
  exercises them with a fixed value string.
- mClock profile mapping: `high_client_ops` for read-heavy or
  `--hyperconverged`, `balanced` for write/mixed/archival.
- Under `--from-cluster`, scrubadub flags suspiciously low
  `osd_mclock_max_capacity_iops_{hdd,ssd}` values and recommends
  re-running the benchmark via `osd_mclock_force_run_benchmark_on_init`.
- USAGE.md gained a "switching schedulers" section.

Cluster ingest (Phase 1):
- `--from-cluster` reads OSD inventory, per-class PG distribution
  with variance, per-pool data (sizes, replica / EC), current scrub
  config, scheduler, and the scrub backlog from a Ceph mon node via
  `ceph` + `jq`. Refuses to run off a mon unless `--force` is given.
- `--avg-pg-size-gb` and the data factor are computed from the
  cluster's real numbers instead of the 4 GB / 3× defaults.
- Output adds a `current → proposed` diff and a scrub-backlog summary.
- `--workload {read|write|mixed|archive}` allows fully non-interactive
  operation when paired with `--from-cluster`.
- Fixture-driven testing: `CEPH_FIXTURE_DIR=test/fixtures/cluster_mixed`
  + `bash test/smoke.sh` exercises both modes without a real cluster.

Carries over from Phase 0:
- Scheduler-aware: detects WPQ vs mClock and suppresses settings
  mClock ignores; recommends an `osd_mclock_profile` under mClock.
- `osd_scrub_sleep` seconds-typed (floats); `osd_max_scrubs` capped
  at 3 (4 with `--aggressive-scrubs`) — recalibrated in Phase 8 to
  match the default shipped in current Reef.
- `osd_scrub_interval_randomize_ratio = 0.5` emitted to avoid
  synchronized scrub storms.
- Replication / EC factor honored via `--replica-size` / `--ec-ratio`.
- Scrub-time estimate uses `SCRUB_BUDGET_PERCENT` (default 10%).
- Device baselines refreshed and overridable via `--device-profile`.
- Prompt mode preserved as the default for off-cluster modeling.
- Still no `--apply` / `--diff` / `--rollback`; Phase 5 adds them.

---

## Guiding principles

- **One bash script.** No Python rewrite. `jq` is fine.
- **Detect, don't assume.** Read the cluster's real state; ask the
  operator only when the cluster can't answer.
- **Both schedulers supported.** WPQ and mClock are first-class.
- **Reversible by default.** Always print a backup command; never apply
  without explicit consent and a rollback path.
- **Be honest about what we don't know.** Banners on default assumptions
  (PG size, device baselines, scrub budget fraction) — silent-wrong is
  worse than loud-uncertain.

---

## Phase 0 — Correctness fixes

Small, surgical edits to the existing bash. Most are 1–5 lines plus a
docs touch.

### `[x]` 0.1 Fix `osd_scrub_sleep` units in docs and output
**Why.** `USAGE.md:62` says microseconds. Ceph's actual unit is **seconds
(float)**. Today the script emits `10`/`15`/`20`/`30`, which tells the
OSD to sleep that many seconds between chunks — effectively halting
scrubs.
**What.** Emit floats in the `0.05`–`0.2` range. Update `USAGE.md` to say
seconds. Add an inline comment in `scrubadub.sh` citing the Ceph docs.
**Files.** `scrubadub.sh:158-181`, `USAGE.md:62`.
**Accept.** Docs read "seconds"; recommended values are floats; comment
present.

### `[x]` 0.2 Fix archival 24-hour window
**Why.** `scrubadub.sh:179-180` sets `begin=0, end=23`, which excludes
23:00–00:00. Ceph's convention for "all day" is `begin=0, end=0`.
**What.** Change archival profile to emit `begin=0, end=0`.
**Files.** `scrubadub.sh:179-180`.
**Accept.** Archival profile prints `osd_scrub_begin_hour = 0` and
`osd_scrub_end_hour = 0`.

### `[x]` 0.3 Cap `osd_max_scrubs` and warn before raising
**Why.** `scrubadub.sh:185-191` can compound `+1` and `+2` without bound.
On a 12-OSDs-per-host cluster, `osd_max_scrubs=3` means 36 simultaneous
scrubs per host — client-killer.
**What.** Clamp the final value to `max(2, current)` by default (and at
most 3 only when explicitly opted into). Print a red warning that
explains the per-host concurrency cost
(`max_scrubs × OSDs_per_host = simultaneous scrubs on that host`).
**Files.** `scrubadub.sh:132-191`.
**Accept.** Script never emits `osd_max_scrubs > 3`; warning shown when
the value is raised above the baseline.

### `[x]` 0.4 Emit `osd_scrub_interval_randomize_ratio`
**Why.** Default 0.5 spreads scrubs in time. Users who tighten intervals
without this risk a synchronized scrub storm.
**What.** Include `osd_scrub_interval_randomize_ratio = 0.5` in the
recommendations output. Add to USAGE.md "Key Parameters Explained".
**Files.** `scrubadub.sh:194-202`, `USAGE.md:56-65`.
**Accept.** Parameter appears in output and in the docs table.

### `[x]` 0.5 Make `AVG_PG_SIZE` overridable + add a notice
**Why.** Hardcoded 4 GB at `scrubadub.sh:17` is the single biggest source
of bad estimates. Real PG size varies wildly per pool (KB to tens of GB).
**What.** Accept `--avg-pg-size-gb N` (and `PG_SIZE_GB=` env var). Print
a yellow notice when the default is in use. (Phase 1.4 replaces this
with a real number from `ceph df detail`.)
**Files.** `scrubadub.sh:17` and the input/arg-parsing section.
**Accept.** Flag works; banner appears on default.

### `[x]` 0.6 Scheduler-detect banner
**Why.** mClock silently ignores sleep and load-threshold knobs. Today
the tool prints them anyway with no warning, which gives operators false
confidence on Reef/Squid clusters.
**What.** Before recommendations, prompt the user "WPQ or mClock?" (auto
in Phase 1.6). When mClock is selected, print a banner explaining the
ignored knobs and link to Ceph's mClock config reference and Clyso's
"how to disable mClock" post.
**Files.** `scrubadub.sh:205-273`.
**Accept.** Banner renders for both schedulers; links resolve.

### `[x]` 0.7 Don't emit settings the active scheduler ignores
**Why.** Companion to 0.6. If mClock ignores them, don't print them.
**What.** When the user/script declares mClock, suppress
`osd_scrub_sleep` and `osd_scrub_load_threshold` from the recommended
settings. Emit the mClock profile recommendation from Phase 2.3 in
their place.
**Files.** `scrubadub.sh:194-202`.
**Accept.** Under mClock, those two lines are absent from output.

### `[x]` 0.8 Fix `osd_scrub_load_threshold` semantics
**Why.** The threshold is `loadavg / num_cpus`, **not** raw loadavg.
Today's workload-bucket values (0.2, 0.3) effectively disable scrubs on
any busy host. Defaults aren't tied to the user's actual core count.
**What.** Document the meaning in `USAGE.md`. Add a script comment.
Don't emit values below 0.5 unless the user passes both `--scheduler wpq`
**and** `--hyperconverged` (a future flag — for now, document the gotcha
and bump the baseline values).
**Files.** `scrubadub.sh:142-181`, `USAGE.md:61`.
**Accept.** Docs and comment in place; baseline values ≥ 0.5 in
non-hyperconverged profiles.

### `[x]` 0.9 Honest scrub-time estimate
**Why.** `scrubadub.sh:122` divides total data by full cluster throughput,
implying scrubs run flat out. They don't — and shouldn't. Real scrub
budget is ~10–15% of total bandwidth.
**What.** Introduce `SCRUB_BUDGET_FRACTION` (default 0.10), multiply
effective throughput by it before time calculation. Reword the warnings
(`> 3 days` and `> 7 days` thresholds will trigger far more often, which
is actually correct).
**Files.** `scrubadub.sh:109-130`.
**Accept.** Estimate is roughly 10× current for the same inputs; warnings
fire on realistic clusters.

### `[x]` 0.10 Replication / EC factor in bytes-to-scrub
**Why.** Deep scrub on replicated×3 reads `3×` the stored bytes across
the PG set; EC `k+m` reads `(k+m)/k`×. The current model treats raw
stored bytes as the scrub workload.
**What.** Add `--replica-size N` (default 3) and `--ec-ratio k+m` flags.
Multiply data-to-scrub by the appropriate factor in
`calculate_scrub_time`. (Phase 1.4 replaces this with per-pool real
values.)
**Files.** `scrubadub.sh:109-130`, arg-parsing.
**Accept.** Estimate scales with the factor; flags documented in
USAGE.md.

### `[x]` 0.11 Refresh device baselines + make them overridable
**Why.** `scrubadub.sh:9-14` baselines are dated and conflate generations
(SATA-SSD vs SAS-SSD, NVMe Gen3 vs Gen4 vs Gen5).
**What.** Update built-in defaults — HDD 200 MB/s, SATA-SSD 500 MB/s,
SAS-SSD 1.5 GB/s, NVMe-Gen3 3 GB/s, NVMe-Gen4 6 GB/s. Accept overrides
via a `--device-profile <file>` (simple `KEY=VALUE` format) or env
vars.
**Files.** `scrubadub.sh:9-14`, USAGE.md "Performance Characteristics".
**Accept.** Profile file is honored end-to-end; built-in defaults
documented.

---

## Phase 1 — Cluster auto-ingest from a monitor node

Replace prompts with `ceph` introspection. The script becomes a
read-only consumer of the cluster's own truth.

### `[x]` 1.1 `--from-cluster` flag
**Why.** Make cluster ingestion explicit so the prompt-driven path
remains available for off-cluster modeling.
**What.** Add `--from-cluster`. When set, skip prompts and shell out to
`ceph`. Requires `ceph` and `jq` on PATH; fail with a clear error if
either is missing.
**Files.** `scrubadub.sh` (arg parsing, main flow).
**Accept.** `scrubadub.sh --from-cluster` runs without prompts on a mon
node; sensible error messages off-cluster.

### `[x]` 1.2 Read OSD inventory
**Why.** Replaces the HDD/SSD/NVMe count prompts and gives us OSDs-per-host
for the Phase 0.3 / Phase 3.4 concurrency guard.
**What.** Parse `ceph osd tree --format json` for device-class counts
and the OSD-to-host map.
**Accept.** With `--from-cluster`, counts match `ceph osd count-metadata
device_class`.

### `[x]` 1.3 Read PG distribution and variance
**Why.** Replaces the per-class PG count prompts. Variance matters: an
even distribution makes "max PGs/OSD" pessimistic; an uneven one
warrants a rebalance recommendation.
**What.** Parse `ceph osd df tree --format json` for per-OSD PG counts;
compute mean and stddev per device class. Warn when stddev/mean > 0.15.
**Accept.** PG-per-OSD numbers match `ceph osd df`; stddev warning fires
on intentionally-unbalanced test fixture.

### `[x]` 1.4 Read pool details for real PG sizes
**Why.** Replaces the `AVG_PG_SIZE=4 GB` guess with a real number,
per pool.
**What.** `ceph osd pool ls detail --format json` +
`ceph df detail --format json` → per-pool used bytes, `pg_num`,
replica size, EC profile. Compute real per-pool PG size and a
device-class-weighted cluster average.
**Accept.** Computed average matches a hand-calculated value within
5% on a test fixture; per-pool PG sizes are shown in the analysis
section.

### `[x]` 1.5 Read current scrub config for diff
**Why.** Enables current → proposed presentation, the foundation for the
Phase 5 apply/diff workflow.
**What.** Parse `ceph config dump --format json` for every scrub
parameter we touch. Render output as `param: current=X → proposed=Y`.
**Accept.** Current values match `ceph config get osd <param>`.

### `[x]` 1.6 Read Ceph version + scheduler
**Why.** Wires live detection into the Phase 0.6 banner and Phase 0.7
suppression.
**What.** Run `ceph version` and `ceph config get osd osd_op_queue`.
Detect `wpq` vs `mclock_scheduler`. Persist as a script variable used by
the emitters.
**Accept.** Banner renders the correct scheduler; mClock suppression
applies automatically without user input.

### `[x]` 1.7 Read scrub backlog as ground truth
**Why.** Best signal for "are we falling behind?" — better than the
estimated time the tool prints today.
**What.** Parse `ceph pg dump pgs_brief --format json` for
`last_scrub_stamp` and `last_deep_scrub_stamp`. Build the distribution
of PG ages and highlight PGs past their interval. Feeds Phase 6.1.
**Accept.** Backlog counts match `ceph health detail` for any
`PG_NOT_(DEEP_)SCRUBBED_IN_TIME` warnings active on the cluster.

### `[x]` 1.8 Backwards-compatible prompt mode
**Why.** What-if modeling and off-cluster use shouldn't break.
**What.** Default behavior without `--from-cluster` is the existing
prompt flow.
**Accept.** No regressions in the v1 interactive UX.

### `[x]` 1.9 Refuse to run on non-mon nodes by default
**Why.** Some `ceph` commands are slow or unauthorized off the mon;
running on an OSD host is a footgun.
**What.** Detect mon-ness via presence of `/var/lib/ceph/mon` or
`/etc/ceph/ceph.client.admin.keyring`. Bail out with a clear message
unless `--force` is passed.
**Accept.** Refuses on a non-mon host without `--force`; runs cleanly
with it.

---

## Phase 2 — Scheduler-aware output (WPQ + mClock co-equal)

### `[x]` 2.1 Scheduler dispatch in `calculate_scrub_settings`
**Why.** Clean separation makes the two emitters easy to evolve.
**What.** Route to `emit_wpq_settings` or `emit_mclock_settings` based
on the detected/declared scheduler.
**Files.** `scrubadub.sh:132-202`.
**Accept.** Each emitter is callable independently from a unit-style
test fixture.

### `[x]` 2.2 WPQ emitter (current logic, corrected)
**Why.** This is the default path for clusters following Clyso's
guidance.
**What.** Fold in every Phase 0 correction (units, archival window,
max_scrubs cap, randomize_ratio, load_threshold semantics). Emit:
`osd_scrub_sleep`, `osd_scrub_load_threshold`, intervals, `osd_max_scrubs`,
`osd_scrub_begin_hour`, `osd_scrub_end_hour`,
`osd_scrub_interval_randomize_ratio`.
**Accept.** Output is a strict superset of v1 minus the bugs.

### `[x]` 2.3 mClock emitter
**Why.** Don't emit settings mClock ignores; recommend the things it
honors.
**What.** Recommend an `osd_mclock_profile` based on the workload
bucket — `high_client_ops` for read-heavy / hyperconverged,
`balanced` for mixed/archival, `high_recovery_ops` only when the
backlog drain mode (Phase 6.1) is active. Add guidance for
`osd_mclock_force_run_benchmark_on_init` when measured IOPS look
suspiciously low. **Does not** emit `osd_scrub_sleep` or
`osd_scrub_load_threshold`.
**Accept.** mClock output contains a profile recommendation and no
sleep/load_threshold lines.

### `[x]` 2.4 Document switching schedulers
**Why.** Operators following Clyso's WPQ guidance need a pointer.
**What.** Add a `USAGE.md` section linking to Clyso's "disable
mClock" post and Ceph's mClock config reference. Make it clear that
scrubadub follows whichever scheduler is active.
**Files.** `USAGE.md`.
**Accept.** Section present, both links resolve.

---

## Phase 3 — Honest performance model

### `[x]` 3.1 Network ceiling
**Why.** Sum-of-disk-throughput is the wrong upper bound; the NIC is
usually the real one.
**What.** Detect host NIC speed via `ip -j link show` (parse
`speed` from `ethtool` where available); allow override with
`--nic-gbps`. Compute effective scrub bandwidth as
`min(sum_per_OSD, hosts × per_host_NIC_GB/s) × SCRUB_BUDGET_FRACTION`.
**Accept.** Estimates respect the NIC ceiling on a 1 GbE test fixture.

### `[x]` 3.2 Use mClock's self-benchmark when available
**Why.** The cluster has already measured itself; trust its numbers
over the script's hardcoded ones.
**What.** Pull `osd_mclock_max_capacity_iops_hdd` and
`osd_mclock_max_capacity_iops_ssd` from `ceph config dump`. When
present and non-zero, use them in place of the device constants.
**Accept.** When self-benchmark values exist, the analysis section
shows them and uses them; hardcoded fallback only when they're
missing.

### `[x]` 3.3 Distinguish shallow vs deep scrub estimates
**Why.** Shallow scrub is metadata-only; deep scrub reads object
data. Conflating them hides the real cost.
**What.** Print two estimates (shallow and deep) and align each to
its own interval (`osd_scrub_max_interval` vs `osd_deep_scrub_interval`).
**Accept.** Both estimates appear in the analysis section.

### `[x]` 3.4 Per-host concurrency cost warning
**Why.** Counterpart to Phase 0.3 — call it out even when the script
itself isn't raising `osd_max_scrubs`.
**What.** Warn when `osd_max_scrubs × max(OSDs_per_host) > 8`. Suggest
a per-host scrub cap if the cluster supports it.
**Accept.** Warning fires on a 16-OSD-per-host fixture with default
`osd_max_scrubs`.

### `[x]` 3.5 Empirical per-class throughput via `ceph tell osd.X bench`
**Why.** The hardcoded throughput baselines (200 / 500 / 3500 MB/s)
are order-of-magnitude guesses, usually wrong for real hardware.
mClock's self-benchmark only gives us IOPS, not throughput, and
on WPQ clusters the mClock values may be absent entirely.
**What.** Opt-in `--bench-osds` flag samples one OSD per host per
device class via `ceph tell osd.X bench`, aggregates per class
(median by default; p25 / trimmed-mean / mean configurable),
flags slow OSDs as outliers, and caches results to
`~/.scrubadub/bench-<fsid>.json` for 30 days. Skips OSDs in
non-clean PGs so backfilling OSDs don't drag the sample.
**Accept.** Source label in the analysis section changes from
`default` to `median of N sampled, cache <date>` when benches
have been run. Slow OSDs flagged with their measured throughput.

---

## Phase 4 — Per-pool and per-device-class recommendations

### `[x]` 4.1 Emit `ceph config set osd/class:<class>` lines
**Why.** Sleep values appropriate for HDDs should not apply to NVMe
OSDs; today the script tunes globally.
**What.** Emit class-scoped config lines for `osd_scrub_sleep`,
`osd_scrub_load_threshold`, and `osd_max_scrubs` when the cluster has
mixed classes.
**Accept.** Output shows `osd/class:hdd`, `osd/class:ssd`, etc., with
appropriate values per class.

### `[x]` 4.2 Emit `ceph osd pool set <pool> ...`
**Why.** Metadata/index pools (RGW index, CephFS metadata) and cold
bulk pools need different scrub behavior.
**What.** Identify metadata/index pools by role, in priority: (1) CephFS
metadata via `application_metadata` `{"cephfs":{"metadata":...}}` —
size-independent, since a lightly-used FS is journal-dominant (DATA)
despite being metadata; (2) RGW bucket index via the `.buckets.index`
name suffix (RGW gives all its pools the same `{"rgw":{}}` application,
no role); (3) OMAP-dominance (`stored_omap` > `stored_data`, OMAP > 1
MiB) for omap-heavy pools generally. Falls back to the average-object-
size heuristic on Ceph releases without the OMAP/DATA split. Emits a
tighter `deep_scrub_interval` per pool; also flags `noscrub` /
`nodeep-scrub`.
**Accept.** CephFS metadata (even DATA-dominant) and RGW indexes are
flagged; bulk data pools — including small-object ones and CephFS data
pools — are correctly excluded.

### `[x]` 4.3 Per-pool sizing observations (large PGs)
**Why.** Large PGs make deep-scrub and recovery take proportionally
longer, and are the usual reason a single pool falls behind on scrubs
while the rest of the cluster keeps up. Surfaced by a real 4.6 PiB
cluster where one 759 TiB pool at 256 PGs (~3 TiB/PG) accounted for
all of the late-scrub backlog.
**What.** Compute average per-PG data (`stored / pg_num`) for each
pool; flag any over `--large-pg-threshold-gib` (default 1024). List
per-PG size, `pg_num`, and autoscale mode. Advisory only — scrubadub
does not resize pools (a PG split is a heavy rebalance). Suggests
raising `mgr/pg_autoscaler/pgs_per_osd`, re-enabling autoscale, or a
manual split.
**Accept.** Section appears when a pool exceeds the threshold, silent
otherwise; shows the autoscale mode per pool.

---

## Phase 5 — Apply / diff / rollback

### `[x]` 5.1 `--dry-run` made explicit and default
**Why.** Today's behavior, but unnamed. Naming it lets `--apply` be
opt-in.
**Accept.** `scrubadub.sh --dry-run` and `scrubadub.sh` (no flag)
behave identically.

### `[x]` 5.2 `--diff`
**Why.** Show only what's changing.
**What.** Print one line per parameter where current ≠ proposed; omit
unchanged. Numeric-aware comparison so `86400.000000` == `86400`.
**Accept.** Output is exactly the delta.

### `[~]` 5.3 `--apply`
**Why.** Close the loop from "recommendation" to "applied".
**What.** Take a timestamped backup of current values (via the
existing backup recipe), prompt for confirmation, then run the
`ceph config set` lines. Print the rollback command on completion.
**Prep done.** `--emit-backup-plan FILE` writes the full would-rollback
state (global + per-class + per-pool) as a TSV, verified against a live
Reef 18.2.2 cluster. The apply/verify-after-write loop is the remaining
work.
**Accept.** Settings change; backup file exists; rollback works.

### `[ ]` 5.4 `--rollback <backup-file>`
**Why.** Two-button operation: forward and back.
**What.** Replay the backup as `ceph config set` lines.
**Accept.** After `--apply` then `--rollback`, `ceph config dump`
matches the pre-apply state.

### `[ ]` 5.5 `--yes` for non-interactive use
**Why.** Automation.
**Accept.** Pairs with `--apply` and skips the confirmation.

---

## Phase 6 — Backlog-aware tuning and re-evaluation

### `[ ]` 6.1 Backlog drain mode
**Why.** Steady-state tuning isn't what a behind-cluster needs.
**What.** When `ceph pg dump` shows PGs past their deep-scrub
interval, switch to a temporary catch-up profile: higher
`osd_max_scrubs` (within the Phase 0.3 cap), wider scrub window,
shorter randomize_ratio. Label the recommendation **temporary** and
remind the operator to re-run after the backlog drains.
**Accept.** Mode auto-engages when backlog > 5% of total PGs.

### `[ ]` 6.2 `--evaluate` mode
**Why.** Close the feedback loop. Compare the model's prediction to
reality.
**What.** Run N days after `--apply`; compare expected vs actual
scrub-age distribution; suggest refinements (`SCRUB_BUDGET_FRACTION`
adjustment, per-class tweaks).
**Accept.** Produces a delta report; suggests at least one tuning
adjustment when the model is off by >30%.

---

## Phase 7 — Output formats and observability

### `[ ]` 7.1 `--format text|json|yaml`
**Why.** Pipe-friendly output for Ansible / ceph-ansible / cephadm.
**Accept.** Each format round-trips through `jq` / `yq`.

### `[ ]` 7.2 Starter Prometheus alert rules
**Why.** Once tuned, the operator needs to know when reality drifts.
**What.** Emit a YAML file with alerts for
`pg_not_(deep_)scrubbed_in_time`, scrub-age p99 growth rate, and
scrub-correlated client latency.
**Accept.** File is `promtool check rules`-clean.

### `[ ]` 7.3 Starter Grafana panel JSON
**Why.** Visual companion to the alerts.
**What.** Dashboard with scrub-age histograms, `osd_max_scrubs`
utilization, and headroom against `osd_deep_scrub_interval`.
**Accept.** JSON imports cleanly into Grafana 10+.

---

## Phase 8 — Admission-aware scrub model

Born from a live investigation on a 4.7 PiB Reef 18.2.2 / WPQ cluster
(831 OSDs, 5216 PGs, EC 16+4 bulk pools) whose deep-scrub tail could
not be explained by bandwidth: the cluster met its 28-day cycle *on
average* while a ~5% tail of wide-EC PGs starved past the 49-day
warning threshold.

**The model.** A deep scrub must hold reservations on ALL acting-set
members simultaneously. Local and remote reservations draw from one
shared per-OSD pool (`osd_max_scrubs`); an EC k+m scrub consumes 1
local + (k+m−1) remote slots. With `f` = fraction of OSDs at their
reservation cap, per-attempt admission is roughly
`P(start) = (1−f)^width`. At the measured f=24.2%:

| Pool type | Width | P(start) | vs EC 16+4 |
|---|---|---|---|
| 3x replicated | 3 | 43.5% | 112x |
| 5x replicated | 5 | 25.0% | 64x |
| EC 8+3 | 11 | 4.7% | 12x |
| EC 16+4 | 20 | 0.39% | 1x |

Two separable penalties: linear (20 slots vs 5 = 4x) and exponential
(the conjunction = 64x). scrubadub modeled the 1.25x read
amplification from `(k+m)/k` and discarded the `(k+m)` that bites.

**Model caveats (carry into all code comments):**
- `(1−f)^width` assumes independence. Measured occupancy is ~1.7x
  more clustered than Poisson (remote grants arrive (k+m−1) at a
  time; CRUSH correlates placement). It is a diagnostic *ranking*,
  not a predictor.
- **`f` is an equilibrium property, NOT a headroom measure.** Raising
  the cap admits more PGs, occupancy rises, and `f` settles back near
  where it started — a flat `f` under a rising cap means added
  capacity is being *consumed*, not wasted. The test for whether a
  cap change helped is Δcompletions/day from `last_deep_scrub_stamp`
  histograms (8.2's machinery), never Δf. An earlier "lever exhausted"
  conclusion keyed on flat `f` was withdrawn on exactly this ground.
- Squid's reservation queuing is NOT a clean fix: it shipped with an
  mClock-specific field regression (perpetual queuing; tracker #69078)
  and an escape hatch (`osd_scrub_disable_reservation_queuing`).
  Upgrade advice must be scheduler-conditional and validate-first.

**Ground truth from the source cluster (calibration data for 8.2/8.3):**
deep-scrub durations on EC 16+4 HDD pools (n=1352): p50 3.16h,
p90 8.27h, max 19.57h — an effective 2–12 MiB/s per shard, 4–8x
slower than a bandwidth model predicts. Per-PG scrub rate is not
bandwidth-shaped. The starved tail scrubs *faster* than the healthy
population (max 1,280s vs 70,442s): those PGs are not slow, sick, or
interrupted — they lose the admission lottery.

### `[x]` 8.1 Reservation-feasibility ingest
**What.** Sample `dump_scrub_reservations` across ~30 OSDs (strided
over the id space so one unhappy host cannot dominate), compute `f`
(fraction at cap), report per-pool `P(start) = (1−f)^width` from the
pool walk's `pool_widths`. Below `ADMISSION_LIMITED_PCT` (default
10%): the pool is admission-limited and the report says plainly that
interval/cap tuning will not fix it, lists what does (demand
de-synchronisation, wider window, smaller PGs, narrower EC), and
points cap-change evaluation at completions/day. `tight` band below
`ADMISSION_TIGHT_PCT` (default 25%). All thresholds and the sample
size are env-tunable.
**Semantics.** `f` and `P(start)` are point-in-time diagnostics only.
No cap-change verdict is keyed to Δf; the code comments carry both
model caveats (independence; f-as-equilibrium) and label the
reference cluster's completions example as confounded pending the
matched-load comparison.
**Status.** Landed — patch contributed by the operator who built the
model, from live `dump_scrub_reservations` output on the reference
cluster. Down/unresponsive OSDs are skipped (they hold no
reservations and are not part of the admission population); absent
data degrades to a notice, never an error. Fixtures:
`dump_scrub_reservations_osd_<id>.json`, same missing-file contract
as the bench fixtures. Smoke tests 22–26 cover f=0, the wide-EC
starvation thesis at f=30%, no-data, partial sampling, and prompt
mode.

### `[~]` 8.9 Demand-side model — `osd_deep_scrub_randomize_ratio`
**The highest-measured-impact lever found in the whole investigation,
and Phase 8 was missing it entirely** — 8.1–8.8 are all supply-side
(admission); this is demand-side.

`osd_deep_scrub_randomize_ratio` (default 0.15) is the fraction of
*shallow*-scrub attempts randomly upgraded to deep. Total deep demand:

    attempt_cadence      = osd_scrub_min_interval x (2 + osd_scrub_interval_randomize_ratio) / 2
    shallow_attempts/day = PGs / attempt_cadence
    deep_demand/day      = PGs / osd_deep_scrub_interval                    # deadline path
                         + shallow_attempts/day x osd_deep_scrub_randomize_ratio   # random path

On the reference cluster (5216 PGs, min_interval 1d, interval ratio
7.0 → 4.5d cadence, deep interval 28d): random path 174/day + deadline
186/day = **360/day against 388/day measured capacity = 0.93x**.
**48% of deep scrubs were on PGs that did not need one**, competing
for the same 20-way reservations as PGs 65 days stale. Setting the
ratio to 0.05 drops demand to 244/day (0.63x).

**Result: 252 → 145 PGs overdue (≥49d) in 37 hours — 42% of the tail
cleared**, against a no-improvement decay baseline of 8%; net
clearance 68–80/day vs a random share of 24/day (2.8–3.3x).

**Why the tail benefits disproportionately (new mechanism).** At
P(start) ≈ 0.08% every attempt is a near-certain failure, so *which*
PG a primary selects is irrelevant — outcomes are decided by luck
across thousands of attempts. At ≈3.9% a primary that picks its
most-overdue PG actually converts. **Primary-side ordering only bites
once admission probability is high enough.** This is the causal link
between lowering demand and preferentially clearing the tail, and it
explains why the cap (throughput ↑, `f` unchanged) did not clear the
tail while the demand-side fix did. It also fits queueing intuition:
0.93x → 0.63x is a move off the saturation knee, where small load
reductions produce outsized latency improvements — which is why a
~4.6% change in total slot-hours produced a 42% tail improvement.

**Expected side effects — must ship with the recommendation, or the
fix reads as a regression:** deep-scrub concurrency fell 794 → 496
(−38%), shallow flat (371 → 388), active+clean +281. **Total
deep-scrub throughput FALLS.** The success metric is tail clearance
(p99 / max age), not completions/day.

**To implement.** (a) Compute `deep_demand/day` and report the
random-path fraction explicitly — "48% of your deep scrubs are
randomly-triggered early scrubs" is the sentence that makes the fix
obvious; the demand half needs no new ingest beyond reading the
ratio. (b) Gate the *recommendation* on `demand/capacity > ~0.8` AND
any pool admission-limited per 8.1 — the capacity denominator is
8.2's. (c) Emit the side-effects note alongside.

**Direction is counterintuitive and must be stated: for wide-EC
clusters, both randomize ratios move DOWN, and the interval one must
not move down at all** (see 8.10).

### `[x]` 8.10 Correction: never lower `osd_scrub_interval_randomize_ratio` blind
scrubadub shipped `randomize_ratio = 0.5` unconditionally, plus
`--why` text calling a high value "above the valid maximum of 1.0"
and "likely the dominant cause of scrub backlog", plus (in 8.1's own
warning) advice to lower it. **All three were wrong**, and wrong in
the direction that hurts exactly the clusters 8.1 diagnoses.

Mean attempt cadence is `min_interval x (2 + ratio)/2`, so *lowering*
the ratio *raises* the attempt rate. On the reference cluster the
achieved scrub cadence (~16.9d) was already 3.8x slower than the
scheduled attempt cadence (4.5d) — attempt rate was never the
constraint. Moving 7.0 → 0.5 would have taken deep demand from 0.93x
to **2.09x** capacity: more unservable attempts, higher `f`, lower
P(start). **On an admission-limited cluster a high ratio is
protective**, and whoever set 7.0 was likely right.

Now: the `--why` text explains the cadence relationship and the
protective case and drops the unverified "valid maximum" claim (`ceph
config set` accepted 7.0 and reports it `mon`-sourced, suggesting no
schema max — to be confirmed via `ceph config help`); 8.1's warning
names `osd_deep_scrub_randomize_ratio` as the real demand lever and
explicitly flags lowering the interval ratio as NOT a fix; and
`calculate_scrub_settings` preserves a higher current value whenever
reservation sampling shows the widest pool below
`ADMISSION_TIGHT_PCT`. Absent sampling data, prior behaviour stands.

### `[ ]` 8.2 Measured scrub model, per device class
**What.** Under `--from-cluster`, read `last_scrub_duration` and
`last_deep_scrub_stamp` from `pg dump`; compute per-class capacity as
achievable-concurrency × measured-duration percentiles, with pools
mapped to classes via CRUSH rule. Completions/day histograms from the
stamps double as the before/after instrument for any cap or interval
change. Replaces (not refines) the bandwidth estimate in cluster
mode; subsumes part of E.1.

### `[ ]` 8.3 Derive `deep_interval` from measured capacity
**What.** `max(7d, measured_cycle × ~1.3)` instead of the current
constant 604800 (assigned once, never adjusted). For the source
cluster this lands near its actual 28d policy — the honest answer.
Also emit the `mon_warn_pg_not_deep_scrubbed_ratio` implication
(warn threshold = interval × (1 + ratio)) so operators see the real
alarm line.

### `[~]` 8.4 Cap-change evaluation guidance — experiment resolved
**What.** When a cap change is contemplated, instruct measurement by
Δcompletions/day over a **matched-load** window (8.2's histograms),
with explicit warning that `f` will NOT move and is not the success
metric.
**Result (matched load, single fresh-mgr snapshot, censoring-corrected
uniformly):** cap=2 at 5.5 GiB/s → **272/day**; cap=8 at 5.4 GiB/s →
**388/day** = **+43%**. The earlier confound is closed: the fresh mgr
reproduced the cap=2 baseline within 4% of the old mgr's 251–270/day,
so staleness was not a factor. Elasticity ≈ 0.26, roughly constant
across 2→5→8, with no knee reached — elasticity ≈ 0 would mean
bandwidth-limited, ≈ 1.0 slot-limited without contention; ~0.26 is the
conjunction signature. Secondary confirmation: cap=2 completion
buckets were sub-Poisson (sd 3.1 vs 7.7 predicted) — the statistical
signature of a hard rate limit.
**The distinction that must ship with it:** raising the cap increased
aggregate throughput but did **not** clear the tail, and at cap=8 `f`
rose 24.2% → 30.3%, so per-attempt P(start) at width 20 got *worse*
(0.39% → 0.080%). Cap ↑ buys completions/day; demand ↓ buys admission
probability and tail clearance. Different levers, different symptoms —
recommending the cap for a tail problem is a category error.
**Remaining:** encode the guidance text. See 8.6 note on cap ceiling.

### `[x]` 8.5 Quick fix: emit mgr-visible intervals on `global`
`osd_deep_scrub_interval` / `osd_scrub_max_interval` are now emitted
on BOTH `osd` and `global`: the mgr evaluates
PG_NOT_(DEEP_)SCRUBBED against its own view (tracker #44959), which a
who=osd override never reaches — while emitting only `global` would
be silently overridden for OSD daemons wherever an osd-section row
already exists. The backup plan captures both sections' prior state.

### `[x]` 8.6 Quick fix: cap recalibrated to 3 (4 aggressive)
Matches the `osd_max_scrubs` default in current Reef (PR #55173);
the old cap of 2 was a downgrade there. Per-host concurrency product
demoted to an advisory — on wide-EC pools the binding constraint is
reservation admission, not spindle load.
**Open (8.4 follow-up):** measured evidence from one wide-EC cluster
supports 5–8 there (+43% completions, elasticity 0.26, no knee). Not
adopted as a blanket default: that is an n=1 result on a 831-OSD
wide-EC cluster, and a cap of 8 on a narrow-pool cluster with few
OSDs per host buys no admission benefit (P(start) is already high)
while multiplying per-host client impact. The right encoding is a
*conditional* ceiling — raise only when pools are wide AND admission
is limited AND per-host headroom exists — which needs 8.1's `f` and
8.2's completions in the same decision. Until then, `--aggressive-scrubs`
remains the operator's escape hatch.

### `[x]` 8.7 Quick fix: object-density gate on `osd_scrub_sleep`
Sleep is paid per chunk (`osd_scrub_chunk_max`, default 25 objects):
per-PG idle = (objects/25) × sleep. At ~965k objects/PG, 0.1s of
sleep = ~64 minutes of pure idling per scrub. Cluster mode now
computes real objects/PG and scales sleep so idle stays ≤ ~5 min.

### `[x]` 8.8 Quick fix: width-aware scrub window
Narrow start windows shrink the daily admission-attempt surface —
`begin/end_hour` gate scrub *starts*, so for a width-20 PG that wins
its conjunction ~0.4% of the time, attempts are the scarce resource.
Pools of width ≥ 11 now get a 24h (0-0) window recommendation with
the reasoning printed.

### `[ ]` 8.11 Cheap detectors surfaced by the investigation
Small, independent, each a thing that had to be found by hand:
- **`max` deep-scrub age as the earliest structural-blockage
  detector** — it would have fired ~7 weeks before the health warning
  on the reference cluster. Alert on it.
- **Report the effective warning threshold in days**
  (`interval x (1 + mon_warn_pg_not_deep_scrubbed_ratio)`, = 49d
  there) and label the overdue count a **lagging** indicator: inflow
  is set by the scrub pattern one threshold-period ago, so the count
  can keep rising for weeks after a successful fix.
- **Bimodality**: `p95/p50` ≈ 1.9 in a healthy regime; 5.2x means two
  populations. Report the ratio, flag > ~3x.
- **Percentile selection**: which percentile gates the warning depends
  on the overdue fraction — at 2.78% overdue the warning tracks
  p97–p98, so p99 is the gating stat, not p95. Compute
  `overdue/total` and pick accordingly.
- **Forced-scrub futility** (Phase 6 input): `ceph pg deep-scrub` sets
  `must_deep_scrub` and jumps the *primary's* queue, and requested
  scrubs get higher op priority once started (PR #14488) — but
  admission is decided by *replicas*, which never see the flag. A
  sweep of ~225 forced PGs cleared 1 PG in 38 minutes, exactly the
  random share. Forcing is not useless (flags persist and convert
  once `f` drops) but it is not a fast intervention: **force, then fix
  admission — never force to clear a backlog.** A drain mode built on
  `ceph pg deep-scrub` loops will appear to hang.
- **EC pgid shard suffix**: `pg dump` gives `29.6fd`, admin sockets
  give `29.6fds0`. Exact-match jq selects fail silently — use
  `startswith()` for admin-socket PG matching.
- **`mon_health_max_detail` (default 50) truncates the `detail` array**
  of `ceph health detail`, so any pool breakdown derived from it is a
  sample, not a census. scrubadub is **not** affected today (backlog
  reads `.checks.*.summary.count`, which is the true count) — but 8.2
  must take per-pool breakdowns from `pg dump`, never from health
  detail, and should warn if it ever parses the truncated list.

### `[ ]` 8.12 PG sizing for wide EC: per-shard, not per-PG
The current large-PG check thresholds on bytes-per-PG. For wide EC
the operative quantity is **GiB per shard** (`per-PG / k`) and the
scrub duration it implies, because **length and width multiply**: a
196.8 GiB shard takes 1.1–5.6h, so the 20-way reservation must hold
for hours rather than minutes, and any interruption restarts from
zero *without updating the stamp*. Under low P(start) such PGs have
near-zero chance of an uninterrupted run.

Evidence: on the reference cluster all three PGs older than 90 days
(147d, 126d, 116d) were in the largest-shard pool (196.8 GiB/shard,
1.67M objects/PG) despite it having the *fewest* PGs; their acting
sets showed no OSD concentration (57 distinct OSDs across 60 shard
slots, chance predicted 2.4 repeats vs 3 observed) — not hardware.
**Design rule to encode: size PGs so a deep scrub completes in well
under an hour.** This binds hard at 20 TB+ drives.

**References.**
- Clyso, *Slow Scrub and Deep Scrub* — reservation mechanics for wide EC.
- Ceph tracker #62669 — replicas rejecting scrub reserve requests.
- Ceph PR #14488 — requested scrubs get higher op priority (once started).
- Ceph docs, *Scrub internals — Scrub Reservations* (Pacific dev docs).
- Ceph tracker #44959 — deep-scrub warning evaluated against the mgr's copy.
- Ceph PR #55173 — Reef `osd_max_scrubs` default raised to 3.
- Ceph tracker #69078 — Squid `osd_scrub_disable_reservation_queuing`
  as temporary workaround for mClock reservation-queuing regression.

---

## Exploratory — not scheduled, revisit later

### `[ ]` E.1 OMAP-aware per-pool scrub-time model
**Why.** The current scrub-time estimate is bandwidth-bound (bytes to
scrub ÷ MB/s). That's right for bulk data pools, but deep-scrubbing an
OMAP-heavy metadata pool is **key-iteration-bound**, not bandwidth-
bound — the OSD walks and checksums billions of small RocksDB
key/value pairs, which is IOPS/CPU work. A pool like a busy CephFS
metadata pool (e.g. 762M objects, ~1 TiB OMAP on one observed cluster)
can take far longer to deep-scrub than its byte count implies, so the
cluster-wide bandwidth estimate understates it.
**What (sketch).** Move from a single cluster-wide estimate to a
per-pool breakdown. For OMAP-dominant pools, weight the scrub-time
contribution by object / OMAP-entry count (with a per-entry cost
constant) rather than pure bytes. Surface a per-pool scrub-time table.
Would also let per-pool `deep_scrub_interval` recommendations be
sanity-checked against each pool's own estimated completion time.
**Open questions.** What per-OMAP-entry cost constant is defensible
(needs measurement, likely via `ceph tell osd bench` variants or
observed scrub durations)? Is `ceph df detail` object count a good
enough proxy for OMAP-entry count? Worth the added model complexity
for most clusters, or only omap-heavy ones?
**Status.** Surfaced during a discussion of storing data in CephFS
metadata pools via xattrs (which push a metadata pool further toward
OMAP-dominance). Not needed now; revisit if per-pool scrub timing
becomes a real operator pain point.

---

## Out of scope (for now)

- Python rewrite or any non-bash implementation.
- ML-based tuning / parameter optimization.
- GUI or web frontend.
- Real-time monitoring daemon.
- Automated scheduled re-tuning (cron-like behavior).

---

## References

- [Ceph OSD Config Reference](https://docs.ceph.com/en/latest/rados/configuration/osd-config-ref/)
- [Ceph mClock Config Reference](https://docs.ceph.com/en/reef/rados/configuration/mclock-config-ref/)
- [Ceph mClock vs WPQ comparison study](https://docs.ceph.com/en/reef/dev/osd_internals/mclock_wpq_cmp_study/)
- [Ceph Squid release notes](https://docs.ceph.com/en/latest/releases/squid/)
- [Clyso: how to disable mClock scheduler](https://www.clyso.com/blog/ceph-how-do-disable-mclock-scheduler/)
- [Clyso: blocked requests caused by deep-scrubbing](https://docs.clyso.com/blog/ceph-blocked-requests-in-the-cluster-caused-by-deep-scrubing-operations/)
- [USAGE.md](./USAGE.md)

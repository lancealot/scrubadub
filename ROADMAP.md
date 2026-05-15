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

## Current baseline (v1)

- `scrubadub.sh` — bash-only, ~400 lines, interactive prompts.
- Emits WPQ-shaped settings (`osd_scrub_sleep`, `osd_scrub_load_threshold`,
  intervals, `osd_max_scrubs`, begin/end_hour).
- Hardcoded device throughput/IOPS constants.
- `AVG_PG_SIZE` fixed at 4 GB.
- No knowledge of replication factor, EC, network ceiling, or scheduler.
- No `--apply` / `--diff` / `--rollback`; only prints recommendations.

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

### `[ ]` 0.1 Fix `osd_scrub_sleep` units in docs and output
**Why.** `USAGE.md:62` says microseconds. Ceph's actual unit is **seconds
(float)**. Today the script emits `10`/`15`/`20`/`30`, which tells the
OSD to sleep that many seconds between chunks — effectively halting
scrubs.
**What.** Emit floats in the `0.05`–`0.2` range. Update `USAGE.md` to say
seconds. Add an inline comment in `scrubadub.sh` citing the Ceph docs.
**Files.** `scrubadub.sh:158-181`, `USAGE.md:62`.
**Accept.** Docs read "seconds"; recommended values are floats; comment
present.

### `[ ]` 0.2 Fix archival 24-hour window
**Why.** `scrubadub.sh:179-180` sets `begin=0, end=23`, which excludes
23:00–00:00. Ceph's convention for "all day" is `begin=0, end=0`.
**What.** Change archival profile to emit `begin=0, end=0`.
**Files.** `scrubadub.sh:179-180`.
**Accept.** Archival profile prints `osd_scrub_begin_hour = 0` and
`osd_scrub_end_hour = 0`.

### `[ ]` 0.3 Cap `osd_max_scrubs` and warn before raising
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

### `[ ]` 0.4 Emit `osd_scrub_interval_randomize_ratio`
**Why.** Default 0.5 spreads scrubs in time. Users who tighten intervals
without this risk a synchronized scrub storm.
**What.** Include `osd_scrub_interval_randomize_ratio = 0.5` in the
recommendations output. Add to USAGE.md "Key Parameters Explained".
**Files.** `scrubadub.sh:194-202`, `USAGE.md:56-65`.
**Accept.** Parameter appears in output and in the docs table.

### `[ ]` 0.5 Make `AVG_PG_SIZE` overridable + add a notice
**Why.** Hardcoded 4 GB at `scrubadub.sh:17` is the single biggest source
of bad estimates. Real PG size varies wildly per pool (KB to tens of GB).
**What.** Accept `--avg-pg-size-gb N` (and `PG_SIZE_GB=` env var). Print
a yellow notice when the default is in use. (Phase 1.4 replaces this
with a real number from `ceph df detail`.)
**Files.** `scrubadub.sh:17` and the input/arg-parsing section.
**Accept.** Flag works; banner appears on default.

### `[ ]` 0.6 Scheduler-detect banner
**Why.** mClock silently ignores sleep and load-threshold knobs. Today
the tool prints them anyway with no warning, which gives operators false
confidence on Reef/Squid clusters.
**What.** Before recommendations, prompt the user "WPQ or mClock?" (auto
in Phase 1.6). When mClock is selected, print a banner explaining the
ignored knobs and link to Ceph's mClock config reference and Clyso's
"how to disable mClock" post.
**Files.** `scrubadub.sh:205-273`.
**Accept.** Banner renders for both schedulers; links resolve.

### `[ ]` 0.7 Don't emit settings the active scheduler ignores
**Why.** Companion to 0.6. If mClock ignores them, don't print them.
**What.** When the user/script declares mClock, suppress
`osd_scrub_sleep` and `osd_scrub_load_threshold` from the recommended
settings. Emit the mClock profile recommendation from Phase 2.3 in
their place.
**Files.** `scrubadub.sh:194-202`.
**Accept.** Under mClock, those two lines are absent from output.

### `[ ]` 0.8 Fix `osd_scrub_load_threshold` semantics
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

### `[ ]` 0.9 Honest scrub-time estimate
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

### `[ ]` 0.10 Replication / EC factor in bytes-to-scrub
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

### `[ ]` 0.11 Refresh device baselines + make them overridable
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

### `[ ]` 1.1 `--from-cluster` flag
**Why.** Make cluster ingestion explicit so the prompt-driven path
remains available for off-cluster modeling.
**What.** Add `--from-cluster`. When set, skip prompts and shell out to
`ceph`. Requires `ceph` and `jq` on PATH; fail with a clear error if
either is missing.
**Files.** `scrubadub.sh` (arg parsing, main flow).
**Accept.** `scrubadub.sh --from-cluster` runs without prompts on a mon
node; sensible error messages off-cluster.

### `[ ]` 1.2 Read OSD inventory
**Why.** Replaces the HDD/SSD/NVMe count prompts and gives us OSDs-per-host
for the Phase 0.3 / Phase 3.4 concurrency guard.
**What.** Parse `ceph osd tree --format json` for device-class counts
and the OSD-to-host map.
**Accept.** With `--from-cluster`, counts match `ceph osd count-metadata
device_class`.

### `[ ]` 1.3 Read PG distribution and variance
**Why.** Replaces the per-class PG count prompts. Variance matters: an
even distribution makes "max PGs/OSD" pessimistic; an uneven one
warrants a rebalance recommendation.
**What.** Parse `ceph osd df tree --format json` for per-OSD PG counts;
compute mean and stddev per device class. Warn when stddev/mean > 0.15.
**Accept.** PG-per-OSD numbers match `ceph osd df`; stddev warning fires
on intentionally-unbalanced test fixture.

### `[ ]` 1.4 Read pool details for real PG sizes
**Why.** Replaces the `AVG_PG_SIZE=4 GB` guess with a real number,
per pool.
**What.** `ceph osd pool ls detail --format json` +
`ceph df detail --format json` → per-pool used bytes, `pg_num`,
replica size, EC profile. Compute real per-pool PG size and a
device-class-weighted cluster average.
**Accept.** Computed average matches a hand-calculated value within
5% on a test fixture; per-pool PG sizes are shown in the analysis
section.

### `[ ]` 1.5 Read current scrub config for diff
**Why.** Enables current → proposed presentation, the foundation for the
Phase 5 apply/diff workflow.
**What.** Parse `ceph config dump --format json` for every scrub
parameter we touch. Render output as `param: current=X → proposed=Y`.
**Accept.** Current values match `ceph config get osd <param>`.

### `[ ]` 1.6 Read Ceph version + scheduler
**Why.** Wires live detection into the Phase 0.6 banner and Phase 0.7
suppression.
**What.** Run `ceph version` and `ceph config get osd osd_op_queue`.
Detect `wpq` vs `mclock_scheduler`. Persist as a script variable used by
the emitters.
**Accept.** Banner renders the correct scheduler; mClock suppression
applies automatically without user input.

### `[ ]` 1.7 Read scrub backlog as ground truth
**Why.** Best signal for "are we falling behind?" — better than the
estimated time the tool prints today.
**What.** Parse `ceph pg dump pgs_brief --format json` for
`last_scrub_stamp` and `last_deep_scrub_stamp`. Build the distribution
of PG ages and highlight PGs past their interval. Feeds Phase 6.1.
**Accept.** Backlog counts match `ceph health detail` for any
`PG_NOT_(DEEP_)SCRUBBED_IN_TIME` warnings active on the cluster.

### `[ ]` 1.8 Backwards-compatible prompt mode
**Why.** What-if modeling and off-cluster use shouldn't break.
**What.** Default behavior without `--from-cluster` is the existing
prompt flow.
**Accept.** No regressions in the v1 interactive UX.

### `[ ]` 1.9 Refuse to run on non-mon nodes by default
**Why.** Some `ceph` commands are slow or unauthorized off the mon;
running on an OSD host is a footgun.
**What.** Detect mon-ness via presence of `/var/lib/ceph/mon` or
`/etc/ceph/ceph.client.admin.keyring`. Bail out with a clear message
unless `--force` is passed.
**Accept.** Refuses on a non-mon host without `--force`; runs cleanly
with it.

---

## Phase 2 — Scheduler-aware output (WPQ + mClock co-equal)

### `[ ]` 2.1 Scheduler dispatch in `calculate_scrub_settings`
**Why.** Clean separation makes the two emitters easy to evolve.
**What.** Route to `emit_wpq_settings` or `emit_mclock_settings` based
on the detected/declared scheduler.
**Files.** `scrubadub.sh:132-202`.
**Accept.** Each emitter is callable independently from a unit-style
test fixture.

### `[ ]` 2.2 WPQ emitter (current logic, corrected)
**Why.** This is the default path for clusters following Clyso's
guidance.
**What.** Fold in every Phase 0 correction (units, archival window,
max_scrubs cap, randomize_ratio, load_threshold semantics). Emit:
`osd_scrub_sleep`, `osd_scrub_load_threshold`, intervals, `osd_max_scrubs`,
`osd_scrub_begin_hour`, `osd_scrub_end_hour`,
`osd_scrub_interval_randomize_ratio`.
**Accept.** Output is a strict superset of v1 minus the bugs.

### `[ ]` 2.3 mClock emitter
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

### `[ ]` 2.4 Document switching schedulers
**Why.** Operators following Clyso's WPQ guidance need a pointer.
**What.** Add a `USAGE.md` section linking to Clyso's "disable
mClock" post and Ceph's mClock config reference. Make it clear that
scrubadub follows whichever scheduler is active.
**Files.** `USAGE.md`.
**Accept.** Section present, both links resolve.

---

## Phase 3 — Honest performance model

### `[ ]` 3.1 Network ceiling
**Why.** Sum-of-disk-throughput is the wrong upper bound; the NIC is
usually the real one.
**What.** Detect host NIC speed via `ip -j link show` (parse
`speed` from `ethtool` where available); allow override with
`--nic-gbps`. Compute effective scrub bandwidth as
`min(sum_per_OSD, hosts × per_host_NIC_GB/s) × SCRUB_BUDGET_FRACTION`.
**Accept.** Estimates respect the NIC ceiling on a 1 GbE test fixture.

### `[ ]` 3.2 Use mClock's self-benchmark when available
**Why.** The cluster has already measured itself; trust its numbers
over the script's hardcoded ones.
**What.** Pull `osd_mclock_max_capacity_iops_hdd` and
`osd_mclock_max_capacity_iops_ssd` from `ceph config dump`. When
present and non-zero, use them in place of the device constants.
**Accept.** When self-benchmark values exist, the analysis section
shows them and uses them; hardcoded fallback only when they're
missing.

### `[ ]` 3.3 Distinguish shallow vs deep scrub estimates
**Why.** Shallow scrub is metadata-only; deep scrub reads object
data. Conflating them hides the real cost.
**What.** Print two estimates (shallow and deep) and align each to
its own interval (`osd_scrub_max_interval` vs `osd_deep_scrub_interval`).
**Accept.** Both estimates appear in the analysis section.

### `[ ]` 3.4 Per-host concurrency cost warning
**Why.** Counterpart to Phase 0.3 — call it out even when the script
itself isn't raising `osd_max_scrubs`.
**What.** Warn when `osd_max_scrubs × max(OSDs_per_host) > 8`. Suggest
a per-host scrub cap if the cluster supports it.
**Accept.** Warning fires on a 16-OSD-per-host fixture with default
`osd_max_scrubs`.

---

## Phase 4 — Per-pool and per-device-class recommendations

### `[ ]` 4.1 Emit `ceph config set osd/class:<class>` lines
**Why.** Sleep values appropriate for HDDs should not apply to NVMe
OSDs; today the script tunes globally.
**What.** Emit class-scoped config lines for `osd_scrub_sleep`,
`osd_scrub_load_threshold`, and `osd_max_scrubs` when the cluster has
mixed classes.
**Accept.** Output shows `osd/class:hdd`, `osd/class:ssd`, etc., with
appropriate values per class.

### `[ ]` 4.2 Emit `ceph osd pool set <pool> ...`
**Why.** Hot pools (RGW index, RBD headers) and cold bulk pools
need different scrub behavior.
**What.** Identify hot vs cold pools from `ceph df detail`
(IOPS/bytes ratio). Emit `osd osd_scrub_*` overrides per pool where
appropriate.
**Accept.** Pool-scoped lines appear when the cluster has pools of
distinctly different size/IO profiles.

---

## Phase 5 — Apply / diff / rollback

### `[ ]` 5.1 `--dry-run` made explicit and default
**Why.** Today's behavior, but unnamed. Naming it lets `--apply` be
opt-in.
**Accept.** `scrubadub.sh --dry-run` and `scrubadub.sh` (no flag)
behave identically.

### `[ ]` 5.2 `--diff`
**Why.** Show only what's changing.
**What.** Print one line per parameter where current ≠ proposed; omit
unchanged.
**Accept.** Output is exactly the delta.

### `[ ]` 5.3 `--apply`
**Why.** Close the loop from "recommendation" to "applied".
**What.** Take a timestamped backup of current values (via the
existing backup recipe), prompt for confirmation, then run the
`ceph config set` lines. Print the rollback command on completion.
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

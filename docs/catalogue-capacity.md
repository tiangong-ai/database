---
docType: runbook
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "Before qualifying or releasing the Issue #25 catalogue capacity correction."
whenToUpdate: "When catalogue projection, performance gates or release evidence changes."
checkPaths: [supabase/migrations/*kb_catalogue*.sql, tests/performance/catalogue_capacity.sql, tests/sql/kb_catalogue*smoke.sql]
lastReviewedAt: 2026-10-20
lastReviewedCommit: 04e7a7a7f951f0124cbcee419cf878fd0d2f592c
---

# Catalogue capacity and release

## Scope and evidence

Issue [database #25](https://github.com/tiangong-ai/database/issues/25) corrects
both the registered document projection and literal metadata search. Deployed historical
migrations, source metadata, document identities, NAS/PDF files, roles and workers
are unchanged. The existing Next catalogue response remains version 1.

The original production ordinary-session overview failed at 8,305 ms; an isolated
1.5m-journal/60k-document reproduction failed at 8,003 ms. Separately, the original
legacy search failed at 8,008 ms locally and at 8,140 ms in main CI. A trigram-only
expression prototype fixed a selective query but still failed short searches;
it was discarded before publication. The final implementation must pass the
mixed capacity, permission, sync, upgrade, actual-session and official Preview
gates; isolated timings alone never authorize deployment.

## Maintenance preparation

Before merging a production-auto-deployed branch, recheck the exact head, official
Preview, source/production migration ledger, API exposure, private schema denial,
Supabase project binding and production deployment switch. Confirm only the four
new capacity migrations are pending and previous ledger hashes are unchanged.
Verify recent backup/PITR and available database disk space against the measured
populated rehearsal, including projection heap, GIN/PK indexes, temporary work and
WAL headroom. Preview with empty data is not a backfill-duration benchmark.

The first migration changes catalogue function bodies only. The second creates a
private projection, two source triggers, backfills normalized text, builds its
index and changes the internal legacy query. The third preserves fast transactional
source TRUNCATE by truncating the derived projection, avoiding row-by-row deletion
and its WAL/bloat costs. The fourth adds a compact short-query negative filter,
its synchronous triggers and a single shared category/metric aggregation.
Source columns, rows, policies and
ACLs are not rewritten. Creating the sync trigger acquires a source write lock
before reading the initial snapshot; it is held through commit, so no writer can
race the backfill. Ordinary reads continue, but source writes can wait. This is
**not** an online zero-write-interruption migration. Use a quiet maintenance
window and a measured duration; `lock_timeout=5s` refuses a busy lock acquisition.
Do not bypass this gate by raising role timeouts or disabling triggers.

The short-filter backfill holds `ShareRowExclusiveLock` on the text projection,
so source writers wait at their existing synchronous projection write. It builds
all single-character/adjacent-pair signatures and then a primary key. Hash
collisions or saturation cannot alter results because exact text remains the
residual predicate. They can increase query cost: include varied alphabets and
high-entropy metadata when judging capacity. Evaluate data files, temporary
files and retained WAL separately from cumulative generated WAL. An observed
local peak is not a guarantee of production WAL retention.

The 2026-10-20 comparison rejected adopting an additional large PGroonga index
as the default. It accelerated short misses, but internal Groonga files were
not reflected by `pg_relation_size(index)` and significantly increased storage.
A compact exact-pair alternative was also compared with the bit filter; its
unlimited-memory improvement alone did not establish the best production choice.
The selected forward candidate keeps the existing GIN, uses a fixed-size bit
filter, and retains the exact substring/RLS contract. Latest CI and constrained
capacity qualification remain required.

### 2026-10-20 comparison and remaining gates

All comparisons use synthetic data, not copied production rows. The shared
fixture contains 1.5m journals, 60k registered documents, 1k explicit links and
9,900 documents denied to the ordinary test user. Counts, filters, ordering and
the 8-second per-statement deadline are unchanged.

| Candidate | Additional short-query storage | Short miss `zz` | Broad short query `sy` |
| --- | ---: | ---: | ---: |
| Existing full-text projection/GIN | none | 2.32 s | 2.70 s |
| Shared aggregation only | none | 2.32 s | 2.58 s |
| Initial one-slot bit-filter prototype | 335.5 MB | 1.10 s | 2.31 s |
| Exact adjacent-pair byte prototype | 642.9 MB | 0.81 s | 2.29 s |

These four measurements used the same uncapped local runtime and are comparative
observations, not a production latency promise. The forward two-slot MD5 filter
uses 320.5 MB with bulk loading/PK construction. Its `CASE` residual prevents
evaluating/decompressing full text for definite negatives. A full forced-generic
and prepared-statement check under a 1 GB/2 CPU limit passed, with statements up
to 3.29 s. Retain the earlier AND-based 8.012-second failure; only subsequent
exact-source CI and Preview can supersede that head's failed check.

The exact-pair prototype saves about 0.3 s on this miss at an additional ~307 MB
versus the initial filter. Its build timing is not directly comparable: the
first bit prototype used serial insertion, whereas the pair prototype used
parallel CTAS. Likewise, overlapping prototype LSN deltas are contaminated;
per-statement WAL was ~511 MB versus ~651 MB. The forward MD5 CTAS measured
~356 MB generated WAL and ~84 MB cumulative PK-sort temporary writes. Do not
add cumulative generated WAL to retained WAL or confuse temporary bytes written
over time with simultaneously allocated files.

The original published backfill subsequently failed in a fresh 1 GB local
container with a confirmed cgroup OOM. A 500k-row comparison passed using the
identical text expression directly in the bulk statement and failed through the
per-row SQL wrapper. This is a separate migration blocker, not evidence for a
larger disk. The authorized correction passed the populated rehearsal below; current-head CI
and a fresh official Preview remain required before release. The observed failure alone does not establish the exact memory
behavior of a hosted Micro instance.

The first populated peak rehearsal covered only three migrations and retained
about 1 GiB WAL. Production settings are `max_wal_size=4GB` and
`min_wal_size=1GB`; those must be reflected in the complete four-migration
rehearsal. `max_wal_size` is not a hard disk cap. Preserve raw data-directory,
database, retained-WAL, temporary-file and memory samples; report the sampling
interval and account for short-lived sort files missed between samples.

The completed **corrected-backfill** rehearsal used fresh main
`e702d268`, 1 GiB/no-swap/2 CPU, 1.5m journals and 60k documents, with the WAL
settings above. Migration `20261020053109` used corrected SHA-256
`bc100bfedc2bca4294a5e5e0d1aaba1de9c98c89e878298e3318050643ceecea`;
the short-filter migration used
`d824f554a6d0995904141f7a3f6ae7ed0204de80f5740cb37760f463a2680f36`.
The operator explicitly authorized revising this one unmerged migration on
2026-10-20 after the original OOM reproduction. No deployed migration is changed.
Recreate disposable Preview state before qualifying the new bytes; an old
Preview's already-applied ledger is not proof of a clean corrected replay.

| Measured item | Bytes / observation |
| --- | ---: |
| Data directory before forward migrations | 4,440,064,000 |
| Observed peak / after checkpoint | 6,653,804,544 |
| Observed additional space | 2,213,740,544 (2.062 GiB) |
| Full-text projection including indexes/TOAST | 1,338,826,752 |
| Short-filter relation including primary key | 320,495,616 |
| Retained WAL before / peak | 1,073,741,824 / 1,627,389,952 |
| PK-sort cumulative temporary writes | 84,230,144 |
| Conservative additional-space budget | 2,297,970,688 (2.140 GiB) |
| Text backfill/index / short-filter migration | 140.23 s / 358.33 s |
| OOM kills during the complete corrected sequence | 0 |

Sampling ran approximately every 0.5 seconds. No live temporary file was caught,
but statement counters recorded the PK-sort writes, so the conservative budget
adds those bytes to the observed maximum rather than asserting zero temporary
space. Source row counts and both 1.5m-row projection counts were retained.
This is a measured synthetic budget, not a hard production upper bound: live
writes, archive lag, different text distributions and existing bloat can add
space. Keep additional operational free space beyond the migration budget.
An 8 GB volume must be assessed against its **current exact free bytes**, not
the local rehearsal's smaller starting database or a rounded dashboard label.
Neither a 12 GB requirement nor 8 GB release safety follows from this run alone.

The full local repository gate also passed (20 SQL smokes, runtime/HTTP permissions,
concurrency, actual Auth consumers, capacity and populated upgrade). Its wrapper
requested a 1 GiB cap, but observed memory exceeded it; this run counts only as
ordinary full regression, not constrained qualification. The separately owned
populated rehearsal and CASE capacity run supply the constrained evidence.

Current operator instruction is **no disk expansion, merge or deployment**.
The earlier 12 GB proposal is not an active authorization. First publish measured
candidate steady-state and peak requirements, then obtain a capacity decision.

If source writers cannot tolerate the measured pause, stop before merge and design
a separately reviewed staged online backfill. Do not improvise one in production.
`pg_trgm` must resolve to `extensions.gin_trgm_ops` on Preview and production.

## Qualification and release order

1. Run offline tests, complete local replay/upgrade and mixed 8-second capacity
   gates; inspect plans for broad and selective search. Verify all seven source
   categories and final invoker RLS. Compare the registered projection with the
   unchanged canonical permission helpers. Use synthetic records only.
2. Obtain independent review of the actual diff, private candidate composition,
   transaction sync and migration lock/recovery behavior. Resolve blockers.
3. Require latest CI and the official Supabase Preview for the exact PR head;
   verify Preview catalogue, pending migrations, actual ordinary-user sessions,
   private denial and cleanup. Do not treat a stale green check as evidence.
4. In an authorized release window, repeat maintenance preparation, merge the
   database fix, and verify only the expected forward migrations applied. Run
   bounded ordinary-user production reads for overview, categories, details,
   paging and selective/broad search. Stop on timeouts, permission or count errors.
5. Only after database acceptance resume paired Next #109 merge, exact root
   integration and 142 image/candidate/restart acceptance. Retain the previous
   image/configuration. Production workers remain off and 148 files stay intact.

## Stop and recovery

Before commit, failure rolls the search migration back atomically. The earlier
function-only migration can remain applied. Do not edit ledger history or revert
published migration files. Old 142 does not call the new catalogue API and remains
the serving recovery state until all database gates pass.

After commit, a search failure blocks Next activation. Keep source triggers and
projection together while investigating a forward fix; disabling sync creates
stale successful searches. Projection rows are disposable derived state, but a
rebuild/removal is a separately reviewed forward migration. Never remove source
rows, change UUIDs or rename PDFs as recovery. If an already activated Next fails,
restore its previous immutable image/configuration; do not start workers or revive
148 to conceal database failures.

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
lastReviewedCommit: e702d268c1d859952f196e9c759e89658a70e228
---

# Catalogue capacity and release

## Scope and evidence

Issue [database #25](https://github.com/tiangong-ai/database/issues/25) corrects
both the registered document projection and literal metadata search. Historical
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
Supabase project binding and production deployment switch. Confirm only the three
new capacity migrations are pending and previous ledger hashes are unchanged.
Verify recent backup/PITR and available database disk space against the measured
populated rehearsal, including projection heap, GIN/PK indexes, temporary work and
WAL headroom. Preview with empty data is not a backfill-duration benchmark.

The first migration changes catalogue function bodies only. The second creates a
private projection, two source triggers, backfills normalized text, builds its
index and changes the internal legacy query. The third preserves fast transactional
source TRUNCATE by truncating the derived projection, avoiding row-by-row deletion
and its WAL/bloat costs. Source columns, rows, policies and
ACLs are not rewritten. Creating the sync trigger acquires a source write lock
before reading the initial snapshot; it is held through commit, so no writer can
race the backfill. Ordinary reads continue, but source writes can wait. This is
**not** an online zero-write-interruption migration. Use a quiet maintenance
window and a measured duration; `lock_timeout=5s` refuses a busy lock acquisition.
Do not bypass this gate by raising role timeouts or disabling triggers.

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

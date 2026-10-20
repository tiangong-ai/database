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

# Catalogue browse capacity

The 2026-10-20 user-approved scope keeps navigation, visible scale, category
lists, stable pages, shared typed-key details and explicit source/document links.
Next #111 separately adds scoped identifier lookup. Next #110 defers cross-library,
abstract and arbitrary metadata substring search until usage requirements exist.

## Current implementation and migration boundary

Production main e702d268 includes 20261019154333 and 20261020032337; these bytes
remain immutable. PR #26 retains 20261020053020 registered ACL batching and narrow
page keys. The forward browse validator rejects nonempty q with 22023 and
CATALOGUE_SEARCH_UNSUPPORTED; absent/empty q retains browsing. Old Next URLs show
an explicit unsupported message and a usable browse link. No service fallback.

The unmerged search migrations 20261020053109, 20261020055621 and 20261020070732
are withdrawn from the final tree under the approved scope change. Their code,
failed broad-query experiments and resource measurements remain in Git/PR history.
Do not replay those proposals then drop their objects. No search replica, GIN,
short filter or source-write trigger is part of the browse-only candidate.
A disposable Preview containing the old proposals must be recreated from the new
chain; never repair a persistent ledger or assume it matches removed files.

## Required proof

- 1.5m synthetic metadata + 60k documents + 1k explicit links; no production rows.
- Ordinary authenticated authorization matches canonical document/collection
  helpers, with hidden collection metadata masked and legacy invoker RLS intact.
- Eight-second overview/category/detail/next/deep-page checks, exact counts and
  identity order, ten reused generic plans, rejected q with no source scan.
- Fresh replay and populated upgrade, HTTP sessions, schema/ACL/body fingerprints,
  Next browser flow, independent review, exact-head CI and official Preview.
- Compare final migration schema and source row/UUID preservation. Measure the
  remaining migration cost; previous search-replica space is not its requirement.

## Release and recovery

Current authorization is development only: no disk expansion, merge or deployment.
142 keeps its existing service, 148 files remain, production workers stay off.
A future authorized window must recheck backup/free space, pending migrations,
API exposure and ordinary-session reads, then activate the paired Next version.
If database qualification fails, do not activate Next. If Next activation fails,
restore its previous immutable image/configuration. Never change source UUIDs,
PDF filenames, permissions, or historical migration ledger as recovery.
The unchanged Edge meta_contains functions and existing indexes remain outside
this change. Main currently still exposes old q until a future authorized release;
local/Preview success does not claim a production behavior change.

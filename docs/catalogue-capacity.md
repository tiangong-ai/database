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
lastReviewedCommit: 767623f9f3d894dfe9180cdc082235d57f9a3063
---

# Catalogue browse capacity

The 2026-10-20 user-approved scope keeps navigation, visible scale, category
lists, stable pages, shared typed-key details and explicit source/document links.
Next #111 / database #27 add a separately committed scoped identifier lookup. Next #110 defers cross-library,
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

## Identifier lookup (database #27 / Next #111)

`api.kb_catalogue_identifier_v1` accepts an ordinary authenticated session and
`category=journals|standards`, `identifier` (1–512 characters, no controls),
plus the same bounded page, state and collection filters. It rejects detail keys,
other categories and nonempty q. Absent/empty identifier in Next uses browsing.
DOI uses the existing resource normalization (trim, lowercase, DOI URL/doi:
prefix removal); standard numbers use trim/lowercase only. Internal spaces,
slashes, hyphens, punctuation and leading zeroes are preserved. No stored value,
source UUID, PDF path or document link is rewritten.

All permitted duplicates remain candidates. Explicit visible legacy links resolve
to the canonical material row; hidden materials cannot suppress visible source
rows. Matching DOI alone never merges records. Legacy sources run under invoker
RLS before counts and association matches; collection/status filters cannot
resurrect suppressed legacy rows. Category means the current displayed library: a
material moved to reports is excluded from journals lookup together with its
suppressed source; it remains browsable under reports. Lookup does not silently
search across libraries or override selected state/collection filters. Detail routes keep their existing typed-key
contract, without a new alias resolver. API is user-session-only; anon and service
role execution are denied, and no private schema USAGE is granted.

A nonunique `journals_catalogue_doi_exact_idx` expression btree supports the
normalized equality predicate. Its built-in expression is checked against the
existing private normalizer, avoiding any change to historical helper grants.
Existing journal/Edge indexes are untouched. Standards initially use an exact
scan, qualified with 50,000 synthetic rows. No substring or metadata search is
added. The index is built transactionally: release planning must allow its write
lock and measure production headroom. A five-second lock-acquisition timeout and
five-minute statement cap bound the migration; failure rolls it back. It does not
claim zero write interruption.

Owned 1 GiB/no-swap, two-CPU qualification on 2026-10-20 measured 60,940,288 index
bytes on 1.5m synthetic journals, 1.26 seconds for populated index creation,
0.52–0.53 seconds for hit/miss DOI requests, and 0.54 seconds for a 50k standard
request alongside 60k registered documents. These are synthetic measurements,
not production peak-space or latency guarantees. No 12 GiB expansion is authorized.

The final three-migration populated rehearsal (1.5m journals, 60k documents,
1k links, 1 GiB/no swap and two CPUs) measured 60,940,288 index bytes,
55,453,056 total generated WAL bytes and 108,249,088 temporary bytes written
by the index build. Sampled data-directory growth was 60,956,672 bytes; the
sample interval can miss short-lived sort files, so it is not an absolute peak.
Index + all temporary bytes written + generated WAL gives a conservative
224,642,432-byte accounting allowance for this synthetic run, not a production
upper bound. Reserve at least 1 GiB free and remain below the platform's disk
threshold before release; recheck WAL/load immediately before the authorized
window. A different production DOI width/distribution may change index cost.

The capacity test times next/deep-page RPCs separately from independent expected
identity scans. Each RPC retains its 8-second statement timeout; the reference
scans use a separate 30-second test-only budget. No production timeout changes.

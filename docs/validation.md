---
docType: runbook
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "Before submitting or integrating database changes."
whenToUpdate: "When test commands, qualification scope or CI changes."
checkPaths: [scripts/**, tests/**, .github/workflows/**, .docpact/**]
lastReviewedAt: 2026-10-21
lastReviewedCommit: 37bea0613b06014badf528077e5e9479b8f7a0a6
---

# Validation

For schema tooling changes, run:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

Tests must cover offline import provenance and immutable migration bytes, schema grouping, preservation of
the changes overlay, path confinement, failure handling and non-leaking
subprocess errors. They do not require remote credentials.
Migration authoring tests include same-second different-name collisions and
concurrent attempts; dump tests reject protected paths and existing exports.

For migration, SQL test or local runtime changes, also run:

```sh
scripts/test-database.sh
```

This gate qualifies the committed KB chain on a dedicated local Supabase
runtime and executes the SQL smoke tests with SQL errors fatal. In the same
temporary stack it also exercises real CLI schema export, offline object
generation and TypeScript generation, verifying the `kb_documents` contract.
All generated qualification files stay in the temporary workdir. Imported
tests that require explicit fixtures must receive isolated, documented
fixtures; do not edit published migration history to mask a test failure.
When an imported smoke fixture is stale, record its failing assertion and make
the smallest test correction in a commit after the byte-identical import.
No passing local result establishes remote state or full legacy-schema
coverage. For changes affecting an existing deployment, also qualify the
relevant prior-schema-to-head upgrade on a disposable database.

For every PR:

```sh
scripts/docpact validate-config --root . --strict
scripts/docpact lint --root . --staged --mode enforce --format json --output .docpact/runs/latest.json
git diff --check
```

Use `--base <sha> --head <sha>` after committing. Stage all new files before
using `--staged`; `--worktree` alone excludes untracked additions. A source-only
lint probe must require review of the owning architecture/development docs.
CI runs offline tests, local SQL qualification and the PR documentation gate.

The PR records the tested commit, commands/results, source provenance,
consumer compatibility and operational limits. Root integration additionally
requires the reviewed child SHA, paired KB consumer revision, exact gitlinks,
repo graph and root governance evidence. Production application is separate.

Hosted integration changes additionally require the official Supabase Preview
check and preview catalog qualification before applying the verified pending
production migration. Follow `docs/supabase-integration.md`; local green tests
do not authorize repairing unapplied history entries.

The legacy baseline requires exact parity for 24 public tables, 72 functions
and all 11 enum definitions, plus the real consumer matrix in
`docs/legacy-schema-baseline.md`. Run `unittest discover -s tests/consumers -p
'test_*.py'` for lifecycle safety and sibling-source discovery checks. The offline
source checks cover canonical precedence, legacy fallback, missing directories and
explicit journal path overrides without opening a database connection.
Empty local and verified preview targets must independently pass catalog and
consumer qualification; no production
business-data fixture or database mocking is permitted.

`tests/schema/legacy_behaviors.sql` supplements catalog equality with real
trigger/RPC/RLS/role behavior using rollback-scoped synthetic records. It runs
in the local gate and on the verified preview, never production.

M1 resource qualification additionally runs actual concurrent psql sessions and
a prior-chain upgrade with synthetic rows using the same disposable local gate.
The pre-resource 40-file catalog uses `pre_resource_catalog.expected.json`;
head uses the current public fixture including the Jobs optimization plus
`resource_catalog.expected.json`. Every selected fixture is checked exactly.
Offline regression tests reject cross-generation function bodies and ACL drift.
`DATABASE_TEST_CATALOG_OUTPUT` may select a local output file for catalog-only
review evidence; it contains definitions, not business rows or credentials.
See [resource-contract.md](resource-contract.md) for covered cases and limits.

The resource schema boundary gate additionally starts real local PostgREST/Kong,
runs HTTP role/exposure/lifecycle checks, and tests a populated old-resource
schema upgrade. `tests/schema/resource_boundary.sql` checks exact ACL/schema
contracts; SQL statements also execute denied table operations for each API
role. Only new private/api objects enter the additive catalog; the legacy public
snapshot must not be regenerated to accept unrelated changes. Client type
qualification explicitly includes public/api and excludes private tables.
The type assertion accepts quoted and unquoted schema keys emitted by the
official generator. CLI failure handling must preserve its exit status; the
offline runtime-safety tests verify failed startup cleans only the owned stack.

## Jobs timeout regression

The local gate also runs `tests/runtime/qualify_jobs_upgrade.py`: on its owned
stack it restores only the changed Jobs function from the immutable previous
migration, checks the permission/filter/sort fixture against that definition,
and applies the new forward migration. OID, owner, ACL, parameters, return type,
security-definer/search-path and volatility must remain identical. All other
prior-schema objects are unchanged; the full smoke suite then tests the new body.

`tests/sql/kb_admin_jobs_permissions_smoke.sql` compares against the unchanged
single-document permission helper for user/group, collection/subtree/document,
owner/creator/public, revoked/expired and deleted-document cases. It covers all
sort keys and both directions (including null timestamps/ties), filters, empty
pages, normalization and service-role/anonymous execution privileges.

`tests/performance/kb_admin_jobs.sql` inserts rollback-scoped synthetic data:
20,000 documents, 60,000 jobs, 100 collections, 101 grants. Its seven calls must
finish within a transaction-local 5-second statement timeout. The fixture does
not read environment credentials or production data. It is a bounded capacity
regression, not a statement of production scale, latency or hosted remediation.
See [the investigation record](jobs-list-timeout.md). Catalog expectations update
only the intentionally changed Jobs function fingerprint.


Resource/delete concurrency qualification uses two real sessions and blocking
PID barriers. It exercises the actual resource command against actual
`request_delete`, verifies a retryable lifecycle-busy conflict (HTTP adapter SQLSTATE `PT409`)
instead of `40P01`, confirms no partial resource/receipt changes, and checks that deletion
and a retry with the identical request UUID/payload preserve cleanup ownership. Fixtures run
only in the uniquely owned disposable stack, never production.


Hosted HTTP qualification uses an actual legacy table route to prove that the
ordinary-user JWT reaches PostgREST; hosted OpenAPI introspection is restricted
to secret keys. Resource semantic conflicts must return HTTP 409 promptly on
both the pinned local runtime and hosted runtime. A rollback-scoped SQL probe
checks private/API error separation and preserves unexpected serialization
failures. This prevents a local-only HTTP 500 assertion from hiding hosted
transaction retries.


S9 adds `tests/runtime/legacy_permissions.sql` and `legacy_permissions_api.py` to fresh and populated-upgrade gates. They qualify PUBLIC inheritance, actual ordinary-role SQL/HTTP denial, custom-worker minimal grants, and seven service worker RPC effects. The current catalog accepts only the reviewed 18-function/23-table ACL delta. See [legacy-permissions.md](legacy-permissions.md) for consumer coverage and release limits.

With the Next #88 candidate, `run_web_edge.py --only next` requires exact safe
403 for all six legacy groups' POST/PATCH/DELETE, anonymous-write 401, unchanged
stored rows and no insert residue. Source hashes in its receipt bind the tested
Route Handlers and store; durable PR evidence also records both repository SHAs.
This fixes the previous consumer 500 blocker locally but does not qualify
hosted defaults, actual worker login identities or authorize release.


The local-only `tests/consumers/unstructure_role_boundary.py` adds real LOGIN qualification and explicit queue/snapshot failure boundaries; run it through the owned consumer runtime. `test_worker_role_boundary.py` rejects mismatched ports, ownership and nonlocal targets without DB access. See [S9 role evidence](s9-role-consumer-evidence.md). This is a separate consumer test, not automatically part of database-only CI.


For S9 complete local worker orchestration, use `unstructure_worker_flow.py` in
`tests/consumers/README.md`. It runs the real five Unstructure `run_once` paths
with a fresh non-superuser LOGIN and real PostgreSQL/pgmq. Run both fresh-head
and `--acl-upgrade` modes; the latter reconstructs only the precise pre-S9 ACL
delta with a queued fixture, not all old function bodies. The full database
gate independently covers prior-chain replay/upgrade. Next consumer qualification
also runs actual index/delete schedulers with real PostgREST and index ledger.
Only external provider/artifact transports are doubled. These consumers remain
separate from database-only CI and require reviewed sibling sources/dependencies.
See [the development result and deployment gates](s9-development-validation.md).

## S2 gateway gate

[S2](api-key-management.md) adds `api_key_catalog.expected.json` without changing
the existing public/resource expected definitions. The resource boundary check
now composes with the four explicitly allowed authenticated API-key functions;
its own table/helper/RPC grants remain exact. Full replay executes
`api_key_boundary.sql` and `api_key_management.py` both fresh and after upgrade.
The final upgrade step seeds the exact pre-S2 chain with active, revoked and
expired legacy keys, compares complete rows, and proves unchanged verification.
The local HTTP test injects INSERT/audit failures, verifies aborted-request retry,
and observes both rotation requests blocked by the same row-lock dependency
chain before releasing the barrier. Real Next/Edge compatibility remains a
separate sequential consumer run, not a substitute for v1 session tests.


Six-resource metadata writes use the additive [metadata management contract](metadata-management.md).
Private per-resource editor grants and receipts back three authenticated API RPCs;
no legacy table, grant, production user or worker is changed. The local full gate
checks all six real-session CRUD paths and populated upgrade preservation.

Metadata correction regressions cover invalid/valid ESG country create/update,
null clearing, no rows/audits/receipts on rejection, receipt replay after country
reference removal, and audit FK errors retaining 500/atomic rollback semantics.
The upgrade gate keeps all metadata-tail migrations after S2 and verifies a
populated initial-gateway upgrade preserves identities, grants, audit and receipts.

### Catalogue qualification

`tests/runtime/catalogue_read.py` uses owned local Auth/PostgREST sessions to
qualify seven categories, ordinary RLS versus explicit policy editor access,
collection isolation, three-source explicit-link deduplication, deterministic
pages, count/filter parity, unknown versus missing file state, status transitions,
input bounds, anonymous/service-role denial and immediate grant revocation.
`catalogue_boundary.sql` pins ownership, search paths, function execution and
absence of private schema USAGE. The additive catalogue fixture pins twelve catalogue
functions without replacing existing objects. `scripts/test-database.sh` runs
the HTTP checks on clean replay and upgrade, alongside the existing resource,
metadata, key and worker permission suites. No hosted credentials are needed.

## Catalogue capacity and body integrity

`tests/performance/catalogue_capacity.sql` retains 1,500,000 synthetic journals
with wide abstracts, 60,000 registered documents and 1,000 explicit links in a
rollback-only transaction. Mixed collection/group/subtree/direct authorization
leaves 9,900 denied documents. Overview, category, exact/missing detail, next/deep
pages and ten reused generic prepared calls keep the 8-second statement timeout.
Exact identities, counts, groups, states and source pruning are asserted.
Next/deep-page RPC results are captured in separate 8-second statements before
the independent reference scans and identity assertions, which have a bounded
30-second oracle budget. Reference-query work must not consume the product
request budget; no RPC executes under the oracle timeout.
Unsupported nonempty `q` is rejected without scanning journals, not treated as
an empty query. No search replicas or trigger-disabled bulk-load shortcuts remain.

`kb_catalogue_permissions_smoke.sql` compares batch ACL/masking with unchanged
canonical helpers and textual key ordering. `kb_catalogue_browse_smoke.sql`
retains partial restrictive source RLS before counting/paging and direct-detail
denial, plus assertions that abandoned search relations/triggers are absent.
The HTTP catalogue runner uses only the owned disposable local database and
isolates its synthetic catalogue rows from previous gates; it checks ordinary
sessions, input/error boundaries and permission revocation on replay and upgrade.

`sql_body_fingerprint.py` mutates five SQL-standard functions in rolled-back
transactions and checks exact body-hash changes. Catalog-only fixtures pin final
function attributes/ACLs and the explicitly added DOI index; existing public objects and Edge indexes remain intact. Old search-only regression
and memory/space experiments remain historical evidence, not current acceptance.
A fresh official Preview and exact-head CI are still required before release.

Identifier qualification adds `kb_catalogue_identifier_smoke.sql`: normalization
parity, duplicate candidates, punctuation preservation, visible canonical links,
hidden-source RLS, hidden-material non-suppression, state filters, invalid input,
source update and service-writer index maintenance. The ordinary Auth/PostgREST
runner exercises the new RPC with two actors and anon/service denial. Capacity
checks retain the browse assertions, then add 50k standards and exact/absent DOI
lookups, no journal sequential scan, three reused generic identifier calls and
the added btree size/build time. No production credentials or rows are used.

Issue #28 adds `kb_catalogue_hydration_smoke.sql`: rolled-back row-constructor
instrumentation proves full JSON is assembled only for selected browse/identifier
rows. The canonical-permission suite also compares complete new page bodies with
the prior projection. Capacity covers both zero entries/links and 1k links, with
60k high-entropy 8 KiB document payloads. Production acceptance remains a separate
ordinary-session gate; isolated speed alone does not prove hosted performance.

### Actual timeout correction (#30)

The Jobs capacity fixture now brackets the observed 179,080 production jobs with
60,000 synthetic documents and 180,000 jobs; its seven statements retain the
5-second local bound. The permissions oracle remains unchanged. The upgrade
probe reapplies the new final body, preserving OID/ACL/signature/settings.
`kb_journals_page_smoke.sql` compares both UUID directions, partial and empty
pages against direct RLS reads under forced generic plans, and checks invalid
inputs and anon/service denial. `catalogue_read.py` also calls the new RPC through
real local Auth/PostgREST. The existing 1.5m-row capacity fixture adds deep, last
and empty library pages under the same 8-second request budget. Uncommitted
synthetic inserts prevent an all-visible-table shortcut.
Production SELECT/EXPLAIN candidates are diagnostics only; until these migrations
are deployed and actual application requests pass, hosted recovery is unverified.

The review follow-up additionally tests single-document Jobs access against a
1000-buffer bound (red before, green after predicate pushdown), plus stage/status/
worker filtering. Upgrade qualification reapplies all three correction files.

The narrow Jobs buffer gate also forces a generic plan; both document and job
source branches must retain index probes, not merely pass on a custom first call.


The additive database #32 page/count RPC contract and ordinary/deep-page
performance bounds are documented in `docs/catalogue-capacity.md`, Split library
reads. Qualification includes caller RLS, editor grant revocation, snapshot
versions, real Auth/PostgREST, exact catalog additions and populated upgrades.


Library count qualification includes ESG editor/reader counts with restrictive
RLS and nullable title values, plus the production discrepancy: legacy/heap
60,095 versus zero-column PGroonga count 0. The new identity projection must
return the same exact count with live authorization. Synthetic tests do not
recreate the production index fault; real-data read-only parity remains a
release gate. No production index rebuild or data mutation is part of the test.

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
lastReviewedAt: 2026-10-20
lastReviewedCommit: cf137cb8a8b8105192b54cdfbe44ee96d7aede5c
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
absence of private schema USAGE. The additive catalogue fixture pins seven new
functions without replacing existing objects. `scripts/test-database.sh` runs
the HTTP checks on clean replay and upgrade, alongside the existing resource,
metadata, key and worker permission suites. No hosted credentials are needed.

## Catalogue capacity and body integrity

`tests/performance/catalogue_capacity.sql` seeds 1,500,000 synthetic journals
with 1,900-byte abstracts (10% varied high-entropy text), 60,000 registered
documents and 1,000 explicit material/source/document links, in a rollback-only
transaction. Creator, public, user collection, group subtree/manage and direct
document grants leave exactly 9,900 documents denied. Each overview, category,
existing/missing detail, next/deep page, selective/broad/one/two-character/literal
search must finish within the unchanged 8-second statement timeout. Exact counts,
identities, groups, states, deduplication and ten reused generic prepared calls
are asserted. Table statistics pin unrelated-category pruning and bounded primary
key detail access. No production rows or remote target are accepted.

`kb_catalogue_permissions_smoke.sql` compares the batch result and collection mask
against the unchanged canonical helpers across 240 synthetic documents, including
expiry, revocation, group removal, misleading subtree prefixes, owner/creator,
public and deleted states. `kb_catalogue_search_smoke.sql` compares the serialized
substring oracle, source updates/deletes/truncate and rollback on projection
failure, private access denial, partial restrictive source RLS and all four source-write
failure paths. `catalogue_projection_concurrency.py` verifies the actual
CREATE TRIGGER lock blocks a concurrent writer but permits reads, then resumes
atomic sync after commit; a busy source also exercises the 5-second migration
lock-timeout rollback. Material visibility and mixed-kind key ordering are
compared against the canonical helper/previous textual ordering. Existing real
Auth/PostgREST catalogue tests run on clean replay and populated upgrade.

The catalog collector hashes `pg_get_functiondef` for SQL-standard bodies, whose
`prosrc` is empty; older string bodies retain their historical `prosrc` hashes.
`tests/schema/sql_body_fingerprint.py` changes each of the six
SQL-standard catalogue bodies in a rolled-back local transaction and requires
exactly a body fingerprint difference. This gate runs after catalog parity, and
the final read verifies that all mutations were rolled back.

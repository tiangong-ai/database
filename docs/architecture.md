---
docType: architecture
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When deciding source ownership, schema scope or generated-path boundaries."
whenToUpdate: "When schema ownership, imported scope or consumer contracts change."
checkPaths: [supabase/**, scripts/**, tests/sql/**, docs/source-inventory.json]
lastReviewedAt: 2026-10-21
lastReviewedCommit: 890d2c9760476a2e37970b74d99e995b992fe3ac
---

# Database architecture

## Source ownership

`supabase/migrations/` is the authoritative migration chain for the AI KB
control plane. Existing migrations are immutable after publication; append
corrections with a new migration. `tests/sql/` owns database-side smoke tests.
The import manifest records the source repository, revision, original path and
SHA-256; it describes the import, not the state of a live database. The initial
byte-identical import was committed as `45198730c6217992902b6f0b203a417961c6bdee`.
Migration hashes remain enforced. Smoke tests may be corrected as the schema
evolves; their manifest hashes describe the original import, not a prohibition
on maintaining tests. Preserve the import commit through a merge commit.

KB ingestion, worker orchestration and the existing operator migration runner
remain consumers in `tiangong-ai/knowledge-base`. That runner resolves this
repository through `KB_DATABASE_DIR` or a workspace sibling named `database`.
Web and Edge clients remain in their owning repositories. Their application
types, search-index mappings and historical BigQuery queries are not database
schema sources and were not moved.

## Adopted schema

The 35 imported migrations define the KB control-plane tables, enum types,
RPCs, RLS, API-key authorization, ingestion queues, retry/reindex behavior,
partition metadata and health queries. They require PostgreSQL with `pgcrypto`,
`pgmq`, and the Supabase roles (including `service_role`). General/course
partition configuration contained in those migrations is preserved.

Hosted-integration adoption restores the already-applied May 28 hotfix and adds
two no-op receipts for cleaned-up remote benchmark versions. These additions
make 38 replay files and are separate from the immutable initial import. See
`supabase-adoption-evidence.json` for source and live catalog evidence.

The subsequent read-only legacy baseline capture supplies the missing content
schema, authorization helpers and empty legacy ledger structure. The full public
application catalog contains 24 tables, 72 functions and 11 enums. Its exact
columns, defaults, constraints, indexes, triggers, RLS/policies, ACLs and function
fingerprints are enforced by `tests/schema/public_catalog.expected.json`.
See [legacy baseline](legacy-schema-baseline.md) for capture provenance,
portable-role differences, consumer qualification and the production-read-only
boundary. Platform-managed schemas and extension internals remain owned by
Supabase; production data, identities and role memberships are never imported.

## Schema workspace

Schema export is a local inspection artifact. `remote_schema.sql`, `global/`
and `schemas/` are regenerated and ignored by Git. Splitting groups statements
by object for review; it is not a dependency-ordered database restore. Unknown
statements remain inspectable rather than being discarded.

Copy the intended object into `supabase/workspace/changes/` before editing.
The overlay survives refresh. Write explicit migration SQL and review it;
object snapshots do not imply safe `ALTER`, `DROP`, or data-conversion plans.
Generated TypeScript in `types/` is local until a consumer explicitly adopts a
reviewed contract. No fabricated production types are committed at bootstrap.

## Environments

`local` is the default tool target. `dev` and `main` are explicit operator
environment names backed by ignored local env files; they do not assert that
hosted targets through local env names. The Knowledge Base GitHub Integration
is governed by `docs/supabase-integration.md`; Git uses one `main` trunk. LCA
project refs, auth URLs, schemas and branch bindings are not part of this repo.

## Opt-in M1 resource contract

The additive resource registry and trusted-gateway RPC boundary are defined in
[resource-contract.md](resource-contract.md). Existing metadata tables remain
the fact source for legacy adapters. No collection/profile is activated by the
migration; processing and review state remain separate.

New M1 resource state lives in unexposed `private`; `api` contains only the two
invoker adapters, with privilege elevation in private implementations. This
incremental boundary does not move existing public business/control tables.
The table-by-table authority and writer matrix lives in the resource contract.

## Jobs list authorization

`20261013091317_optimize_kb_admin_jobs_authorization.sql` resolves the actor's
user/group principals and active grants once per `list_kb_admin_jobs` call,
matching the existing Documents RPC and single-document helper semantics.
Read visibility still excludes deleted documents; reindex/delete/manage grants
still expose their jobs. Revoked/expired grants and null actors remain excluded.
The six arguments, service-role-only ACL, 21 returned columns, precise count,
filters, offset pagination and timestamp/UUID tiebreaks are unchanged. Empty
pages still contain no count row, as required by existing Next consumers.
No index, role timeout or single-document helper is changed.
See [Jobs timeout evidence](jobs-list-timeout.md) for measured scope and limits.


Resource lifecycle mutations take job locks before document locks and reject
contended locks without waiting. The forward lock-conflict migration preserves
legacy worker/delete implementations and converts resource contention to an
atomic, retryable lifecycle conflict. It does not activate resource intake.

The invoker API command adapter translates only known resource business
conflicts into `PT409` / HTTP 409. Private SQL semantics stay unchanged; unrelated
serialization failures retain their original code. This transport boundary
avoids treating a permanent business conflict as a retriable database transaction.


S9 narrows only legacy public ACLs under [legacy-permissions.md](legacy-permissions.md). It keeps object locations, bodies, RLS, M1-03 and legacy-role explicit grants; deployment is separately gated.

## S2 additive API-key gateway

[API-key management v1](api-key-management.md) adds four authenticated-session
RPCs and a private receipt ledger. Caller identity comes from Auth claims;
legacy public key storage and service verifiers are unchanged. The api schema
has authenticated USAGE, while each function retains explicit EXECUTE grants;
M1 resource RPCs remain service-role-only.


Six-resource metadata writes use the additive [metadata management contract](metadata-management.md).
Private per-resource editor grants and receipts back three authenticated API RPCs;
no legacy table, grant, production user or worker is changed. The local full gate
checks all six real-session CRUD paths and populated upgrade preservation.

## Authorized catalogue (database #23 / Next #108)

`api.kb_catalogue_v1(jsonb)` is a read-only ordinary-user session API. Its
SQL-standard invoker body preserves legacy table RLS. Bound helper OIDs allow
execution without granting `private` schema USAGE. Three narrowly scoped
private definer helpers validate the actual authenticated Auth identity, read
registered materials/documents with collection/document ACLs, and retain the
existing explicit Green Deal editor read grant. There is no service-role fallback,
caller-supplied actor, table move, identifier change, file scan or queue write.

The display category is independent from collection identity and authorization.
`kb_collections.metadata_schema_json.catalogue_category` may explicitly select
journals/esg/standards/reports/education/policies/other. Absent a valid category,
registered entries use the exact legacy table mapping; unmatched collections and
internal-use metadata remain `other`. Next renders all categories with one page.

The catalogue projects journals plus the six existing editable metadata sources,
registered materials and non-deleted documents. Only explicit `legacy_ref` and
active document links consolidate records. Potential unlinked duplicates remain
separate, so `total` means visible catalogue records, not a proven global count
of unique intellectual works. Collection filtering does not invent membership
for legacy rows. Required metadata completeness, candidate/file registration,
review and processing states remain independent. A missing accessible document
has unknown processing state. File associations do not attest current NAS
availability. Ready requires completed document status and both recorded index
flags; no external index is queried. Unregistered NAS files are excluded.

Queries whitelist category and state,
collection, typed detail key, page and page_size (1..50). Nonempty legacy `q`
requests fail with SQLSTATE 22023 / CATALOGUE_SEARCH_UNSUPPORTED. Detail, list and metric
filters share the same permission-filtered snapshot. Pages sort by update time
and key; totals cover the filtered set rather than the current page. Invalid
queries fail, and unavailable results must never be presented as zeros.

The forward capacity correction uses query-aware legacy candidates: source category,
collection, state and detail-key conditions are applied before JSON projection.
Keyed and unkeyed branches are separate so prepared generic plans retain primary
key lookup. Counts and ordering use narrow typed fields; only the selected page
(at most 50) hydrates full metadata. Empty-search requests do not stringify
abstracts. Registered rows still enforce their original ACL/masking, and their
complete visible legacy-reference set suppresses source duplicates **before**
display filters. All stages remain one stable RPC snapshot.

Exact counts still scan applicable authorized identities; this is not constant-time
pagination. Page numbers remain compatible, including page 10000. The earlier
500,000-journal-only fixture missed registered authorization and broad-search
costs. Issue #25 replaces it with the mixed qualification described below.

### Catalogue capacity correction (#25)

Registered projection resolves readable collections once and materializes the
actor's direct document grants once. The unchanged canonical authorization
helpers remain the equivalence oracle. Creator/owner/public visibility and
collection/subtree/user/group read/manage grants are preserved; revoked and
expired grants never qualify. Collection metadata is masked independently from
document visibility. No cross-request permission cache is introduced.

The approved first batch does not create search replicas, trigram indexes, short
filters or source synchronization triggers. The three abandoned, unmerged search
migrations remain in PR/Git history, not in the final replay chain. Published
migration bytes are unchanged. A small forward validator rejects nonempty `q`;
empty or absent `q` remains browsing. Next exposes an explicit unsupported-link
state rather than silently ignoring an old query.

Sort/count intermediates use typed identities and hydrate at most 50 legacy rows.
Issue #28 replaces registered body materialization with narrow typed candidates
for ACL masking and explicit-link suppression. Both browse and identifier RPCs
hydrate complete registered metadata only for selected page identities. This is not constant-time pagination; real-scale browsing still has
the unchanged 8-second gate. See [capacity qualification](catalogue-capacity.md).
DOI/standard-number lookup is the separate Next #111 slice; cross-library,
abstract and arbitrary-field search stays in Next #110 Backlog. Original Edge
meta_contains functions, semantic matching and field indexes remain unchanged.

Database #27 / Next #111 adds user-session `api.kb_catalogue_identifier_v1` for
current-library normalized DOI and exact standard numbers. The sole public
schema addition is a nonunique DOI expression index; existing indexes and Edge
`meta_contains` remain unchanged. See [catalogue capacity](catalogue-capacity.md).

## Default library and Jobs scan correction (#30)

`api.kb_journals_page_v1(integer,integer,text)` is an authenticated-only stable
SECURITY INVOKER RPC. Existing journals RLS filters a materialized ID set before
both exact count and UUID pagination; only selected list fields are hydrated.
It accepts page >= 1, page size 1..100 and asc/desc, returns data/total/page/pageSize,
and preserves the exact total on an empty page. No actor, arbitrary search or
field-sort argument is accepted. Next uses it only for its default ID sort.
The forward Jobs migration materializes the original authorized document set
(id, filename and collection path) before joining jobs. Both permission branches,
including action grants on deleted documents, and every filter/order/count remain
unchanged. No existing table/index/ACL, worker or timeout setting changes.

The scan follow-up also applies an explicit Jobs document_id filter before
materialization, preserving indexed narrow requests. Other job filters remain
in their original scope; it notifies PostgREST after adding the journals RPC.

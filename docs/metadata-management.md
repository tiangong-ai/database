---
docType: contract
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When implementing or qualifying six-type metadata management."
whenToUpdate: "When metadata authorization, RPCs, lifecycle guards or release gates change."
checkPaths: [supabase/migrations/*_kb_metadata_management.sql, tests/runtime/metadata_*, tests/upgrade/metadata_*, tests/schema/metadata_catalog.expected.json]
lastReviewedAt: 2026-10-19
lastReviewedCommit: afa63dcf0e757cc527b4eaa6222846718c2bef82
---

# Six-resource metadata management v1

Tracked in database #20, paired Next #94, umbrella workspace-suite #344.
This is separate from S3. Existing public business tables and ACLs stay intact.

| Resource key | Source table | Required create field |
| --- | --- | --- |
| education | public.edu_meta | name |
| esg | public.esg_meta | report_title |
| standards | public.standards | title |
| reports | public.reports | title |
| internalUse | public.internal_use | title |
| greenDeal | public.green_deal_meta | title |

The private definition function enumerates the exact editable fields and types,
matching the existing Next form. No caller-selected identifier is interpolated
into SQL. System IDs, timestamps, source paths and processing state are not
editable. Payloads are bounded at 64 KiB; text at 10,000 characters (existing
varchar(255) at 255), chapter numbers are nonnegative 32-bit integers, dates are
finite ISO dates/timestamps, organizations are JSON objects/arrays, and languages
use the current seven Next options. A null optional field clears it; omission
preserves it. The required title cannot be blank. This gateway does not promise
all possible legacy fields are editable or impose new constraints on old rows.

## Identity and authorization

Only ordinary signed authenticated sessions can execute the three api functions.
Identity is derived from auth.uid/auth.role and an existing Auth user; there is
no actor argument. Private helpers have no API-role EXECUTE, and private tables
have RLS with no policies and no API-role table grants. No grant is seeded.

private.kb_metadata_editors maps user UUID + resource key to management rights,
with grantor, expiry and revocation. These rights cover that resource type's
rows; they are not inferred from one collection manage grant, user_roles,
self-editable claims or the user's Supabase organization membership. There is
no client grant-management RPC. A later authorized operator must configure the
chosen user's six grants explicitly. This grants neither Auth user management
nor platform, NAS or index privileges. Existing read RLS is unchanged.

## RPC protocol

- api.kb_metadata_list_v1(p_resource text,p_query jsonb default '{}') is editor-only.
  It returns records of same-snapshot values/version plus total/page/pageSize.
  Query fields: page (1..1000000), pageSize (1..100), sort (fixed source column),
  dir asc/desc, q (literal case-insensitive substring over editable fields, <=512).
  Sort ties use UUID; no wildcard/SQL injection is interpreted. Editors need this
  controlled read because Green Deal has no ordinary-user SELECT policy. Readers
  continue through existing RLS and gain no visibility from this addition.


- api.kb_metadata_context_v1(p_resource text, p_ids uuid[] default '{}') returns
  version=1, actorId, canWrite and records keyed by UUID. At most 100 IDs. Only
  editors receive row values plus a SHA-256 version, from the **same snapshot**.
  Readers receive records={}; consumers retain their existing RLS list read.
  The version includes every stored field, including worker changes. A client
  must display context values with that version, never pair it with an earlier
  list row. Missing context rows must not remain editable.
- api.kb_metadata_command_v1(p_resource text, p_operation text,
  p_request_id uuid, p_payload jsonb default '{}', p_record_id uuid default null,
  p_expected_version text default null) supports create/update/delete. Create
  prohibits an ID/version; update/delete require both, delete requires {}.
- Receipt: version=1, id, recordVersion (null after delete), replayed. Keep the
  same UUID and exact semantic input after unknown transport/5xx results.
  Receipts store no full metadata. There is no automatic expiry/cleanup policy.
- 42501 -> HTTP403; PT400 invalid input; PT404 missing row; PT409 request/version
  conflict, lifecycle required or contention; PT500 redacted unexpected failure.
  Conflict messages are stable METADATA_* codes. Only busy/unknown outcomes can
  retry unchanged; stale versions require reload and human reconciliation.

The grant row is share-locked through the mutation, serializing revocation.
Request advisory locks serialize actor+request; a reused ID with different input
fails. A replay rechecks current authorization and returns the original receipt,
not current row state. Updates lock the row and compare its full version. Audit
and receipt are in the same transaction; audit failure rolls back the write.
Existing audit events store resource/record/field names and before/after hashes,
not raw field values. ESG legacy current_user trigger labels are not the human
identity: the authenticated audit actor is authoritative for this gateway.

## Lifecycle boundary

Update/delete reject any registered M1 legacy_ref and any nonempty NAS/PDF path
or upload/parse/index marker. They acquire a NOWAIT SHARE lock on the M1 entry
table before locking the source row, excluding concurrent M1 association writes;
contention returns METADATA_BUSY. This conservative whole-registry lock is a
small-pilot tradeoff, not a scalable final lifecycle design. It may briefly
serialize unrelated intake. No long-running I/O occurs within this transaction.

Unrecorded external files/indexes cannot be proven absent from these columns.
Before production enablement, review each legacy library's evidence and scope;
do not claim isolated synthetic rows prove real rows are safe to delete. Until
Next #95/#96 implement coordinated lifecycle, linked records deliberately cannot
be edited/deleted here. Reads and unlinked draft creation remain independent.

## Qualification and release

Run metadata_management.py only against the owned disposable target through the
existing local runner; it creates ordinary Auth users, then deletes exact fixture
rows/users. It tests all six CRUD paths, base-DML denial, forbidden identities,
forged claims, typed fields, request replay, optimistic concurrency, expiry,
revocation, lifecycle protection and audit rollback. The full database gate runs
it fresh and after a populated pre-gateway upgrade, checks exact additive catalog
and ACL/RLS, and re-runs the previous resource/S9/S2 regressions.

Release is separate: review exact paired versions; official Preview and hosted
api exposure/ACL qualification; inspect pending migrations and deployment
switches; backup; explicitly approve account role correction and six grants;
use new ordinary sessions for full capability acceptance. DB first, Next second.
No personal service_role fallback. Roll back application with metadata mutations
paused; keep additive tables, receipts, audit and base-DML restrictions. Do not
undo committed edits by deleting receipts. NAS/index rights and actual provider
acceptance are later tasks. Local green does not authorize merge or deployment.

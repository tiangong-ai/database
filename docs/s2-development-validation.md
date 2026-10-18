---
docType: report
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When reviewing S2 database #14 development acceptance and S3 handoff."
whenToUpdate: "When the candidate implementation or its qualification evidence changes."
checkPaths: [docs/s2-validation-evidence.json, docs/s2-consumer-validation.json]
lastReviewedAt: 2026-10-18
lastReviewedCommit: 13065cb238205b855155f2f906cc004d3211a386
---

# S2 development validation — 2026-10-18

Development acceptance is complete for implementation
`13065cb238205b855155f2f906cc004d3211a386`, based on S9 main
`59abb9666c37ef67096de45e0b8fd103b52c9f5c`. This report is not merge,
production deployment, hosted Preview, or S3 application-adoption approval.

The [contract](api-key-management.md) and
[receipt hashes](s2-validation-evidence.json) bind the exact migration and tested
consumer revisions. [Consumer results](s2-consumer-validation.json) contain the
actual source hashes, runtime distinctions and per-scenario outcomes. Local
raw logs are retained under `/Users/jing/.codex/artifacts/s2-api-key-20261018/`;
no credential, environment file, raw API secret or Auth password is committed.

## Observed results

| Gate | Result |
| --- | --- |
| `python3.12 -m unittest discover -s tests -p 'test_*.py'` | 81 passed |
| `python3.12 -m unittest discover -s tests/consumers -p 'test_*.py'` | 33 passed |
| `SUPABASE_CLI=/tmp/kb42-tools/supabase PYTHON_BIN=python3.12 scripts/test-database.sh` | Passed on CLI 2.120.0, local PostgreSQL 17, Docker 29.8.2 |
| Full SQL and legacy gates | 17 imported SQL smoke tests, M1 resource concurrency, S9 role/worker-RPC boundary and performance/behavior tests passed |
| Catalog | Fresh and upgraded: 28 relations / 88 functions, no unexpected differences. Original 40-file prior chain: 24 / 72. Existing public and resource fixtures unchanged |
| Upgrade | Exact pre-S2 chain populated with active/revoked/expired legacy keys; all columns preserved and old verify outcomes unchanged |
| New session API | Real Auth-issued JWTs explicitly asserted `authenticated`; all four endpoints tested through PostgREST |
| Exposure/authorization | Anonymous and service-role calls denied; private profile unexposed; direct table writes denied; caller spoof/foreign target/cross-group/delete-only-as-admin denied |
| Secret and metadata | Compatible token format, full prefix+hash verification, list allowlist, no secret/hash in audit or receipts, secret returned only once |
| Idempotency/concurrency | Simultaneous create with same ID produces one secret; repeated revoke has one audit; different payload/operation conflicts. Two rotation requests observed blocked in the same row-lock dependency chain, then one success/one conflict/one successor |
| Failure/recovery | INSERT and audit trigger failures roll back old revocation/new key/receipt; aborted request retries successfully. Expired creation receipt remains recoverable without issuing a new token |
| Existing Next | 12 groups passed using exact Route Handler/store/adapter source; real local HTTP/Auth/PostgREST |
| Existing Edge | 9 groups passed using unchanged five handlers under local Deno HTTP; includes S2-created/rotated/revoked secrets through course_search |
| Governance | Strict config and explicit staged/base-to-head docpact lint passed; Git whitespace check passed |

New v1 local tests run on both fresh and populated upgraded schemas. Their
mutation/failure injection is separate from consumer execution on the same
stack. Synthetic users/rows are removed by their owning fixture harnesses.
Consumer runtime stop verifies its labeled containers and volumes are absent;
full gate cleanup removes its own disposable stack. No existing developer stack
or remote database is reused/reset.

## Review and fixes

Claude Code App independently assessed the design in the same workspace using
DeepSeek-V4.1-Flash 1M / Max / Bypass permissions. Its identity, scoped manage,
expiry, atomicity and cache-boundary findings informed the contract. Two
assessment assumptions were corrected against source: the catalog already
covers private/api, and S3 is not authorization to move tables. Authenticated
schema USAGE is now explicit, without broadening M1 function EXECUTE.

Implementation self-review and actual tests found and fixed the following:

- The initial real-HTTP regression failed because the new RPC did not exist on
  the unchanged baseline; the implemented gateway passed the same scenario.
- The old resource boundary test prohibited authenticated USAGE for the entire
  API schema. It now composes exact resource grants with the four explicit new
  function grants; no resource implementation/ACL was altered.
- An expiry predicate originally prevented retrieving a successful creation
  receipt after expiry. A real timed Auth/PostgREST regression reproduced
  HTTP 400, then passed after restricting expiry validation to fresh minting.
- The lock-barrier test follows recursive blocking dependencies, because the
  second waiter can wait behind the first waiter rather than directly on the
  owner session. Both actual requests must be blocked before release.

A final artifact-review request through the local Claude UI could not be
confirmed as delivered after input/window errors. No independent final code
approval is claimed here; ordinary PR review remains outstanding. This does
not substitute an earlier design assessment for a review of the final diff.

## Remaining release/adoption gates

1. Review the exact PR head and its hosted CI results; this task does not merge.
2. Before a later authorized database release, verify official Supabase Preview,
   current exposed schemas, effective default/object grants and auto-deployment
   behavior for that head. Local green is not hosted evidence.
3. S3 must adopt user-session RPCs, explicit finite scopes, idempotency IDs,
   timestamp/error mapping and lost-secret recovery. Current Next remains on its
   compatible service path, including its old rotation behavior until S3.
4. Verify real login roles and consumer/proxy logging. A human service_role
   session is not a valid v1 session; do not expand grants to bypass this gate.
5. Preserve the existing course_search 900-second cache limit in user-facing
   revocation expectations; provider doubles do not prove hosted cache invalidation.
6. Keep direct CRUD retirement and any later table relocation independently
   gated. Preserve keys/audits/receipts on rollback; exact source references and
   forward-disable procedure are in the contract.

No operations were performed on 142, 148, production workers, production Auth,
NAS, production search providers or hosted Supabase branches in this task.
Root integration remains pending because the child change is intentionally
unmerged; the root database gitlink is not committed to an unmerged revision.

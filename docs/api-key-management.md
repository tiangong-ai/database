---
docType: contract
scope: repo
status: current
authoritative: true
owner: database
language: en
whenToUse: "When implementing, reviewing or adopting the S2 API-key management gateway."
whenToUpdate: "When S2 identity, permissions, idempotency, compatibility or release gates change."
checkPaths: [supabase/migrations/*_kb_api_key_management.sql, tests/runtime/api_key_*, tests/upgrade/api_key_*, tests/schema/api_key_catalog.expected.json]
lastReviewedAt: 2026-10-21
lastReviewedCommit: 5fd64c0e8aadcd3bd48086ac4a95f586176ea237
---

# S2 API-key management v1

Scope: database #14. The migration is additive: `public.kb_api_keys`, all its
columns/constraints/ACL/RLS, and both public verifier functions remain unchanged.
No production worker, NAS, host service or search index participates. Application
adoption belongs to web-app #78 (S3). Physical relocation remains a separate S6
decision, not part of S2 or S3.

## Identity and authorization

Only `authenticated` may execute the four new `api` functions. The database gets
the caller from the signed Auth session (`auth.uid()` and `auth.role()`), verifies
that the Auth user still exists, and accepts no caller actor argument. Anonymous
requests, service-role keys, and sessions whose JWT role is `service_role` cannot
use v1. `actor_user_id` in creation is the **target key identity**, never caller
identity. Next must use its authenticated session client when adopting v1;
forwarding a client-supplied actor with a service key is not this contract.

The `api` wrappers are SECURITY DEFINER owned by postgres with fixed
`search_path=pg_catalog`. They call fully qualified private SECURITY INVOKER
helpers with no API-role EXECUTE grants. The private schema is not exposed.
`authenticated` receives schema USAGE, but only the four selected function
EXECUTE grants; existing M1 resource RPCs remain service-role-only. The new
private receipt table has RLS, no policies, and no direct API-role privileges.
No new global default grants or table policies are introduced.

Authorization uses existing `can_collection_action` and its user/group,
collection/subtree, expiry and revocation semantics. It does not interpret
`user_roles`, or treat the existing console label `admin` (which includes any
delete grant) as global authority.

- A personal key targets the caller and requires the target to have every
  requested action on every selected collection.
- Delegation additionally requires the caller to have `manage` on every selected
  collection. `kb:admin` requires target `manage`; other scopes map explicitly
  to read/upload/delete/reindex. A delete-only grant is not management authority.
- Listing, revocation and rotation allow the owner, or a delegate with `manage`
  on **all** of a key's nonempty collection scope. Other keys are omitted from
  lists and return 404 on mutation. A manager of one group cannot manage keys
  covering another group's collection.
- Create/rotate require 1–100 bounded collections. Legacy unbounded keys remain
  valid with the old verifiers; only their owner can list/revoke them through
  v1, and v1 refuses to rotate them. Explicit bounded replacement is an S3 UX
  decision. A key's owner may revoke it even after losing collection grants.
- Rotation rechecks the target's current actions and the caller's delegation
  rights. Expired keys cannot rotate; unexpired expiry is copied unchanged.
  Scope is not silently expanded. A rotation does not extend validity.

Authorization reflects the transaction's database snapshot. A concurrent grant
revocation does not cancel an already executing statement. Existing verifier
and authorization behavior is unchanged; no stronger revocation guarantee is
claimed by this additive gateway.

## Interface

All endpoints are POST `/rest/v1/rpc/<name>` with `Content-Profile: api` and a
valid user bearer session. List can also use GET with `Accept-Profile: api`.
Do not log response bodies or tokens in consumers/proxies. Use UUID request IDs
for mutations and retain them while retrying the same operation.

| Function | Input |
| --- | --- |
| `kb_api_key_list_v1` | `p_limit` integer 1–100 (default 100), `p_offset` 0–10000 (default 0) |
| `kb_api_key_create_v1` | `p_request_id` UUID, `p_payload` object described below |
| `kb_api_key_revoke_v1` | `p_key_id` UUID, `p_request_id` UUID, optional `p_reason` text/null (max 1000) |
| `kb_api_key_rotate_v1` | Same as revoke |

Create payload allowlist: `name` and `client_id` strings trimmed to 1–120
characters; `scopes` array of 1–5 values from `kb:read`, `kb:upload`, `kb:delete`,
`kb:reindex`, `kb:admin`; `collection_scope` array of 1–100 paths, each at most
512 characters; optional `actor_user_id` UUID/null (self by default); optional
`expires_at` finite future timestamp/null. Null array items, wrong JSON types,
unknown fields and invalid selectors fail. Paths use the existing normalizer;
written scopes and paths are deduplicated/sorted. Payloads are limited to 64 KiB.

List returns `{version:1,data:[metadata],limit,offset}`, sorted by created_at and
id descending. Offset pagination may shift during writes; it is a console list,
not a stable export cursor. Metadata is an explicit allowlist:
`id,name,clientId,actorUserId,tokenPrefix,scopes,collectionScope,expiresAt,revokedAt,
lastUsedAt,createdBy,createdAt,updatedAt`. Neither token_hash nor raw token is
returned in metadata. Timestamp strings are PostgreSQL ISO timestamps; S3 must
normalize them as the current Next mapper does before applying its Zod schema.

Mutation returns `{version:1,apiKey:metadata,token,replayed,changed}` on the first
successful request. `token` is populated only for first create/rotate; revoke
returns null. Replays return `{version:1,apiKey:currentMetadata,token:null,
replayed:true}`; `changed` is absent. A new revoke request on an already revoked
key returns `changed:false` and adds no audit event. Rotation on a revoked key
with a different request ID returns 409.

### Idempotency and recovery

`private.kb_api_key_requests` uses `(actor_id,request_id)` as the primary key and
stores operation, SHA-256 of JSONB input, resulting key ID, and creation time.
JSON object property order is irrelevant; all other input values (including
array order, whitespace inside strings and omitted versus explicit null) must
remain identical for a retry. This deliberately strict identity is distinct
from the normalization used for persisted key fields. Different operation or
payload with the same request ID returns 409, without mutation.

A transaction advisory lock serializes an actor/request pair. Rotation locks
the old key row; revocation, new-key insert, audit and receipt commit together.
Insert/audit failures roll back the entire operation and leave the request ID
available for retry. Concurrent rotations of the same old key produce one
successor; a later distinct request conflicts. No old table index is added.
This guarantee covers the new gateway, not arbitrary privileged SQL writes.

Raw tokens are generated in the database with 32 cryptographically random bytes,
encoded using the unchanged `tgkb_live_` + base64url format. Only the 18-character
prefix and complete SHA-256 are stored in the old table. No raw token is stored
in the receipt or audit; no raw token is accepted as a management input.

The secret is returned in the first successful response only, not guaranteed
delivered exactly once across network failures. After an uncertain commit,
repeat the **same request** to learn its key ID without minting another secret.
If the first secret was lost, revoke that resulting key and create a replacement,
or rotate the resulting key with a new request ID. Never blindly retry with a
new request ID. A missing resulting key in a creation/rotation receipt yields
`API_KEY_RECEIPT_UNAVAILABLE` rather
than recreating a key. Replays recheck authorization before revealing metadata.
An expired creation can still return its receipt (without a token); creation
expiry validation applies only when minting, not when recovering an old result.

Receipts are intentionally retained without automatic expiry: deleting one
would allow a previously used creation request to mint another key. They contain
no raw secret, key hash or input body. Before high-volume adoption, S3 operations
must size this small control-plane ledger; any later retention policy needs an
explicit bounded idempotency contract or durable tombstones. No cleanup job is
introduced here.

### Errors and audit

| HTTP | SQLSTATE / fixed message | Meaning |
| --- | --- | --- |
| 401/403 | 42501 | Function ACL rejection before execution |
| 403 | 42501 / `API_KEY_AUTH_REQUIRED`, `API_KEY_FORBIDDEN` | Session or current grant boundary |
| 400 | PT400 / `API_KEY_INVALID_REQUEST`, `API_KEY_INVALID_FIELDS`, `API_KEY_INVALID_SCOPES`, `API_KEY_INVALID_TARGET`, `API_KEY_INVALID_COLLECTION`, `API_KEY_INVALID_EXPIRY`, `API_KEY_INVALID_PAGE`, `API_KEY_BOUNDED_COLLECTIONS_REQUIRED` | Validation failure |
| 404 | PT404 / `API_KEY_NOT_FOUND` | Missing or inaccessible key |
| 409 | PT409 / `API_KEY_REQUEST_CONFLICT`, `API_KEY_RECEIPT_UNAVAILABLE`, `API_KEY_ALREADY_REVOKED`, `API_KEY_EXPIRED` | Conflict requiring recovery |
| 500 | PT500 / `API_KEY_OPERATION_FAILED` | Transaction aborted; generic diagnostic, no input/secret echo |

PostgREST can reject malformed typed UUID/integer arguments before function entry
with its own 400 code; unknown named arguments can yield PGRST202/404. Consumers
must handle HTTP class as well as the fixed domain messages, and must not expose
raw upstream diagnostics.

Successful state changes append `kb.api_key_create_v1`, `kb.api_key_revoke_v1`
or `kb.api_key_rotate_v1` through existing `write_kb_audit_event` in the same
transaction. Payload contains only key_id, previous_key_id and target_actor_id;
caller and request ID occupy the existing audit columns. Freeform name, client
ID, reason, prefix, hash and raw secret are excluded from audit. Authorization
failures and no-change replays do not write a mutation audit record. Existing
verify behavior remains last_used_at update, not one audit row per lookup;
adding high-volume verification logs requires a separate privacy/retention plan.

## Compatibility and S3 handoff

| Consumer | Pre-S2 database `59abb966` | S2 additive database |
| --- | --- | --- |
| Existing Next `95a033e21c1cd3615bd133aac93c7e1eb0059e0c` service-role CRUD | Existing behavior | Unchanged; old non-atomic rotation remains until S3 adoption |
| Existing Edge course_search service verify RPC | Supported | Same signature, role, result, hash/prefix contract |
| S3 user-session v1 client | RPC absent: must not deploy first | Supported after schema/API configuration and role checks |
| Legacy scoped/unbounded keys | Existing verifier behavior | Preserved; v1 creation/rotation restrictions do not rewrite them |

The old verifier and `authorize_kb_api_key_collection_action` still require the
full token hash plus prefix; prefix alone never authenticates. Database checks
observe revocation after commit. Existing course_search Redis auth cache may
continue accepting a cached context for up to 900 seconds (bounded by token
expiry), plus an already in-flight request. S2 neither flushes nor changes the
cache. The local compatibility harness uses cache-miss doubles for external
Redis; it does not prove hosted cache behavior or an immediate revocation SLA.

S3 must replace the four Next table operations with these four session RPCs,
map metadata/timestamps and fixed errors, preserve request IDs across retries,
handle lost-secret recovery, and retain authentication/CSRF protections. Its
collection picker can keep current read RPCs but must align UI authority with
scoped manage, finite scope and target actions. It must test ordinary
`authenticated` sessions, not a human account carrying a service_role claim.
Review account-role anomalies separately; do not regrant v1 to service_role as
a workaround. S3 must not move tables, change Edge caching, or retire old
verifiers without separately tracked owner changes.

Before retiring direct CRUD: inventory consumers, deploy S3 after database v1,
verify real sessions and no credential-bearing logs, qualify existing key types,
observe errors and cache-window behavior, and obtain deployment approval.
Neither this PR nor an Issue completion authorizes production deployment.

## Validation and rollback

Run `scripts/test-database.sh` with the pinned Supabase CLI 2.120.0. It tests
fresh replay, all old SQL/resource/permission gates, exact catalog parity,
Auth/PostgREST v1, injected INSERT/audit failure, real overlapping row-lock
rotation, duplicate revoke, and populated pre-S2 active/revoked/expired keys.
`tests/runtime/api_key_boundary.sql` pins ACL/owner/search-path/RLS expectations.
`api_key_catalog.expected.json` is additive; legacy and M1 catalogs are unchanged.
Run the existing `run_web_edge.py` consumer harness separately against an owned
local stack. Receipts must identify actual Next/Edge source hashes and distinguish
external provider doubles from real Auth/PostgREST. This is local development
qualification, not hosted Preview or production acceptance.

Exact pre-S2 database rollback reference:
`59abb9666c37ef67096de45e0b8fd103b52c9f5c`. Existing Next rollback/reference is
`95a033e21c1cd3615bd133aac93c7e1eb0059e0c`. A Git revert alone does not undo applied
SQL or restore revoked keys. For a separately authorized future rollback, stop
S3 adoption, return to the compatible Next revision, then use a reviewed forward
migration to revoke authenticated EXECUTE on these four v1 signatures. Preserve
all key rows, revocations, audits and receipts. Do not resurrect revoked secrets,
drop the public key table, or restore pre-S9 broad grants. Remove additive
objects only after consumer retirement and explicit receipt-retention approval.
142/148 and production workers are outside this development task.


The separate six-resource metadata gateway (database #20) adds three authenticated
RPCs with private per-type grants; existing S2 contracts, legacy tables and ACLs
remain unchanged. See [metadata management](metadata-management.md).

The catalogue read API added by database #23 is included in the global API
allowlist test; it does not change the four S2 functions or their permissions.

Catalogue identifier RPC exposure (database #27) is explicitly allowlisted by the
S2 boundary regression. It does not change the four key-management RPCs, grants,
receipts, verifier behavior or public key storage.

Database #30 adds the authenticated invoker journals page RPC to the global API
allowlist assertion. All four S2 RPC attributes, ACLs and behavior remain pinned
by the existing boundary checks.

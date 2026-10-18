-- Run after the exact pre-S2 chain, before applying the additive gateway.
create schema s2_upgrade_test;
insert into public.kb_api_keys(id,name,client_id,actor_user_id,token_prefix,token_hash,scopes,created_by,expires_at,revoked_at)
select ('a2140000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
  'S2 populated upgrade','s2-upgrade-fixture','a2140000-0000-4000-8000-000000000099',
  's2-upgrade-'||n,repeat(n::text,64),array['kb:read'],
  'a2140000-0000-4000-8000-000000000099',
  case when n=3 then '2020-01-01'::timestamptz end,
  case when n=2 then '2020-01-01'::timestamptz end
from generate_series(1,3) n;
create table s2_upgrade_test.key_snapshot as
select * from public.kb_api_keys where client_id='s2-upgrade-fixture';

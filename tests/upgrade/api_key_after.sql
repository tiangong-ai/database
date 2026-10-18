do $$
begin
  if exists ((select * from s2_upgrade_test.key_snapshot except select * from public.kb_api_keys)
     union all (select * from public.kb_api_keys where client_id='s2-upgrade-fixture' except select * from s2_upgrade_test.key_snapshot)) then
    raise exception 'S2 changed populated legacy key rows';
  end if;
  if (select code from public.verify_kb_api_key('s2-upgrade-1',repeat('1',64))) <> 'ok'
     or (select code from public.verify_kb_api_key('s2-upgrade-2',repeat('2',64))) <> 'revoked_token'
     or (select code from public.verify_kb_api_key('s2-upgrade-3',repeat('3',64))) <> 'expired_token' then
    raise exception 'S2 changed populated legacy verifier behavior';
  end if;
end $$;
delete from public.kb_api_keys where client_id='s2-upgrade-fixture';
drop table s2_upgrade_test.key_snapshot;
drop schema s2_upgrade_test;

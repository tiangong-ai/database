#!/usr/bin/env python3
"""Owned-local concurrency and no-source-scan proof for overview snapshots."""
import re
import subprocess
import sys
import time

container = sys.argv[1]
assert re.fullmatch(r'supabase_db_tiangong-ai-(?:database-test-\d+-\d+|consumers-[a-f0-9]+)', container)
base = ['docker', 'exec', '-i', container, 'psql', '-XAtq', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres']

def sql(query, success=True):
    result = subprocess.run(base, input=query, text=True, capture_output=True, timeout=15)
    assert (result.returncode == 0) == success, 'SQL outcome mismatch: ' + result.stderr
    return result

lock = subprocess.Popen(base, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    lock.stdin.write("begin; select pg_advisory_xact_lock(1684836901,122);\n\\echo overview-lock-ready\n")
    lock.stdin.flush()
    while lock.stdout.readline().strip() != 'overview-lock-ready':
        assert lock.poll() is None, 'lock session ended'
    denied = sql('select private.kb_refresh_library_overview_v1();', success=False)
    assert 'OVERVIEW_REFRESH_BUSY' in denied.stderr
    lock.stdin.write('rollback;\n\\echo source-lock-ready\n')
    lock.stdin.flush()
    while lock.stdout.readline().strip() != 'source-lock-ready':
        assert lock.poll() is None, 'lock session ended'
    start = time.monotonic()
    sql("""begin;
    insert into auth.users(id,role) values(md5('overview-concurrency')::uuid,'authenticated');
    insert into auth.sessions(id,user_id) values(md5('overview-concurrency-session')::uuid,md5('overview-concurrency')::uuid);
    select set_config('request.jwt.claims',jsonb_build_object('sub',md5('overview-concurrency')::uuid,'role','authenticated','session_id',md5('overview-concurrency-session')::uuid)::text,true);
    set local role authenticated; set local statement_timeout='1s';
    select api.kb_library_overview_v1();
    do $$ begin
      if exists(select from pg_stat_xact_user_tables
        where schemaname='public' and relname in
          ('journals','edu_meta','esg_meta','standards','reports','internal_use','green_deal_meta')
        and (seq_scan<>0 or idx_scan<>0)) then
        raise exception 'overview read scanned source rows';
      end if;
    end $$;
    rollback;""")
    print('Overview single-flight and snapshot read with zero source table/index scans passed; client ms=' + str(round((time.monotonic()-start)*1000)))
finally:
    if lock.poll() is None:
        lock.communicate('rollback;\n', timeout=10)
    assert lock.returncode == 0, 'lock cleanup failed'

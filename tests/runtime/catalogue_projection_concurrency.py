"""Prove CREATE TRIGGER's migration lock blocks writers, permits reads and times out.

Only the full gate's owned local stack is accepted. No credentials/environment
files, production rows or server-side files are read.
"""
import re
import select
import subprocess
import sys
import time
import uuid

container = sys.argv[1]
assert re.fullmatch(r'supabase_db_tiangong-ai-database-test-\d+-\d+', container), 'Owned local gate only'
base = ['docker', 'exec', '-i', container, 'psql', '-XAtq', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=sqlstate', '-U', 'postgres', '-d', 'postgres']
marker = 'catalogue_lock_' + uuid.uuid4().hex
row = str(uuid.uuid4())
processes = []

def sql(query):
    r = subprocess.run(base, input=query, text=True, capture_output=True, timeout=15)
    assert r.returncode == 0, 'Owned concurrency SQL failed (diagnostics withheld)'
    return r.stdout.strip()

def start(query):
    p = subprocess.Popen(base, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    processes.append(p)
    p.stdin.write(query + '\n'); p.stdin.flush()
    return p

def ready(p):
    assert select.select([p.stdout], [], [], 15)[0], 'Lock barrier did not open'
    assert p.stdout.readline().strip() == 'LOCKED', 'Unexpected lock barrier result'

def finish(p, command='commit;'):
    out, err = p.communicate(command + '\n', timeout=15)
    assert p.returncode == 0, 'Owned barrier connection failed'
    return out.strip()

try:
    definition = sql("select pg_get_triggerdef(oid) from pg_trigger where tgrelid='public.journals'::regclass and tgname='kb_catalogue_journal_search_sync';")
    assert definition.startswith('CREATE TRIGGER kb_catalogue_journal_search_sync ')
    create = definition.replace('CREATE TRIGGER kb_catalogue_journal_search_sync ', 'CREATE TRIGGER ' + marker + ' ', 1)
    a = start("begin;set application_name='"+marker+"_migration';" + create + ";select 'LOCKED';")
    ready(a)
    assert sql("select exists(select from pg_locks l join pg_stat_activity a on a.pid=l.pid where a.application_name='"+marker+"_migration' and l.relation='public.journals'::regclass and l.mode='ShareRowExclusiveLock' and l.granted);") == 't'
    assert sql('select count(*)>=0 from public.journals;') == 't', 'Source reads continue during migration lock'
    b = start("set application_name='"+marker+"_writer';set lock_timeout='10s';set role service_role;insert into public.journals(id,doi,title) values('"+row+"','10.000/"+marker+"','"+marker+"');select 'WRITTEN';")
    deadline = time.monotonic() + 5
    waiting = False
    while time.monotonic() < deadline:
        waiting = sql("select exists(select from pg_locks l join pg_stat_activity a on a.pid=l.pid where a.application_name='"+marker+"_writer' and l.relation='public.journals'::regclass and not l.granted);") == 't'
        if waiting: break
        time.sleep(.05)
    assert waiting, 'Concurrent source writer must wait behind CREATE TRIGGER/backfill transaction'
    assert sql("select not exists(select from public.journals where id='"+row+"');") == 't'
    # Rehearse the locked backfill statement using the real source encoder. The
    # large populated migration rehearsal separately measures the initial build.
    finish(a, "insert into private.kb_catalogue_journal_search(id,search_text) select id,private.kb_catalogue_journal_text_v1(title,doi,journal,authors,date,abstract) from public.journals on conflict(id) do update set search_text=excluded.search_text;commit;")
    assert finish(b, '') == 'WRITTEN'
    assert sql("select exists(select from public.journals j join private.kb_catalogue_journal_search s using(id) where j.id='"+row+"' and s.search_text=private.kb_catalogue_journal_text_v1(j.title,j.doi,j.journal,j.authors,j.date,j.abstract));") == 't', 'Unblocked writer updates source and projection'
    sql('drop trigger '+marker+' on public.journals;')

    a = start("begin;lock table public.journals in row exclusive mode;select 'LOCKED';")
    ready(a)
    rejected = subprocess.run(base, input="begin;set local lock_timeout='5s';"+create+";commit;", text=True, capture_output=True, timeout=10)
    assert rejected.returncode != 0 and '55P03' in rejected.stderr, 'Busy source aborts migration lock acquisition after 5s'
    finish(a, 'rollback;')
    assert sql("select not exists(select from pg_trigger where tgrelid='public.journals'::regclass and tgname='"+marker+"');") == 't', 'Failed migration leaves no trigger'

    # The short-filter migration freezes the derived text relation. A source
    # writer can lock journals first, but must wait at its existing sync trigger;
    # the migration never needs a source-table write lock in the opposite order.
    a = start("begin;set application_name='"+marker+"_short_migration';lock table private.kb_catalogue_journal_search in share row exclusive mode;select 'LOCKED';")
    ready(a)
    assert sql('select count(*)>=0 from public.journals;') == 't'
    b = start("set application_name='"+marker+"_short_writer';set lock_timeout='10s';set role service_role;update public.journals set title='short-filter-updated' where id='"+row+"';select 'WRITTEN';")
    deadline = time.monotonic() + 5
    waiting = False
    while time.monotonic() < deadline:
        waiting = sql("select exists(select from pg_locks l join pg_stat_activity a on a.pid=l.pid where a.application_name='"+marker+"_short_writer' and l.relation='private.kb_catalogue_journal_search'::regclass and not l.granted);") == 't'
        if waiting: break
        time.sleep(.05)
    assert waiting, 'Source writer waits behind the short-filter backfill lock'
    finish(a, "insert into private.kb_catalogue_journal_short_filter select id,private.kb_catalogue_short_signature_v1(search_text) from private.kb_catalogue_journal_search on conflict(id) do update set signature=excluded.signature;commit;")
    assert finish(b, '') == 'WRITTEN'
    assert sql("select exists(select from public.journals j join private.kb_catalogue_journal_search s using(id) join private.kb_catalogue_journal_short_filter f using(id) where j.id='"+row+"' and j.title='short-filter-updated' and f.signature=private.kb_catalogue_short_signature_v1(s.search_text));") == 't', 'Resumed source writer synchronizes the latest signature'
    a = start("begin;lock table private.kb_catalogue_journal_search in row exclusive mode;select 'LOCKED';")
    ready(a)
    rejected = subprocess.run(base, input="begin;set local lock_timeout='5s';lock table private.kb_catalogue_journal_search in share row exclusive mode;commit;", text=True, capture_output=True, timeout=10)
    assert rejected.returncode != 0 and '55P03' in rejected.stderr, 'Busy derived source refuses the short-filter migration lock'
    finish(a, 'rollback;')
finally:
    for p in processes:
        if p.poll() is None:
            try: p.communicate('rollback;\n', timeout=2)
            except subprocess.TimeoutExpired: p.kill(); p.communicate()
    sql('drop trigger if exists '+marker+' on public.journals;delete from public.journals where id=\''+row+"';")
print('Catalogue projection/filter: actual migration locks, concurrent writers, read continuity and 5s lock-timeout rollback passed.')

"""Real SQL-standard-body mutations must change catalog fingerprints.

Invoked only by the owned local Docker gate. Every mutation is rolled back in
its own connection, preserving attributes/signatures and all application data.
"""
import json
from pathlib import Path
import subprocess
import sys

collector = Path(__file__).with_name('public_catalog.sql').read_text()
container = sys.argv[1]
if not container.startswith('supabase_db_tiangong-ai-database-test-'):
    raise SystemExit('Owned local test stack required')

def sql(text):
    result = subprocess.run(['docker', 'exec', '-i', container, 'psql', '-XAtq', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres'], input=text, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('Local SQL fingerprint probe failed')
    return result.stdout.strip()

baseline = json.loads(sql(collector))
for signature, body in [
    ('private.kb_catalogue_category_v1(text,text)', "RETURN 'fingerprint probe'::text;"),
    ('private.kb_catalogue_row_v1(text,uuid,text,text,jsonb,timestamptz,jsonb)', "RETURN '{\"probe\":true}'::jsonb;"),
    ('private.kb_catalogue_rows_v1()', "BEGIN ATOMIC SELECT '{\"probe\":true}'::jsonb; END;"),
    ('private.kb_catalogue_legacy_v1(jsonb,boolean)', "BEGIN ATOMIC SELECT 'probe'::text,NULL::uuid,'other'::text,NULL::timestamptz,'probe'::text,'{}'::jsonb; END;"),
    ('api.kb_catalogue_v1(jsonb)', "BEGIN ATOMIC SELECT '{\"probe\":true}'::jsonb; END;"),
]:
    definition = sql("select pg_get_functiondef('" + signature + "'::regprocedure);")
    # Deparser uses a newline before the SQL-standard body; retain every header
    # attribute, including default arguments, security, volatility and config.
    import re
    mutated, count = re.subn(r'\n(?:RETURN|BEGIN ATOMIC)\b[\s\S]*', '\n' + body, definition)
    assert count == 1, signature
    observed = json.loads(sql('begin;\n' + mutated + '\n' + collector + '\nrollback;'))
    before = {f['name']: f for f in baseline['functions']}
    after = {f['name']: f for f in observed['functions']}
    changed = {name: [k for k in before[name] if before[name][k] != after[name][k]] for name in before if before[name] != after[name]}
    assert changed == {signature.split('(')[0]: ['body_md5']}, changed
assert json.loads(sql(collector)) == baseline, 'Probe must leave catalog unchanged'
print('Five SQL-standard body mutations detected; all changes rolled back.')

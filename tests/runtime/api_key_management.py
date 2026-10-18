#!/usr/bin/env python3
"""S2 real Auth/PostgREST, transaction failures and concurrent sessions; owned local only."""
import base64
import concurrent.futures
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
if len(sys.argv) == 2:
    sys.path.insert(0, str(ROOT / 'tests/consumers'))
    from runtime import load_private, validate_target
    target = load_private(Path(sys.argv[1])); validate_target(target)
    assert target['mode'] == 'local', 'Local only'
    container='supabase_db_'+target['project_ref']; workdir=target['workdir']
    url,anon,service=(target[k] for k in ('api_url','publishable_key','service_role_key'))
else:
    container,workdir=sys.argv[1:]
    assert re.fullmatch(r'supabase_db_tiangong-ai-database-test-\d+-\d+',container)
    status=json.loads(subprocess.check_output([os.environ['SUPABASE_CLI'],'status','--workdir',workdir,'-o','json'],stderr=subprocess.DEVNULL))
    url,anon,service=status['API_URL'],status['ANON_KEY'],status['SERVICE_ROLE_KEY']
assert urllib.parse.urlsplit(url).hostname in ('localhost','127.0.0.1') and url.startswith('http://')
labels=json.loads(subprocess.check_output(['docker','inspect','--format','{{json .Config.Labels}}',container]))
assert Path(labels['com.supabase.cli.workdir']).resolve()==Path(workdir).resolve()

def sql(query):
    r=subprocess.run(['docker','exec','-i',container,'psql','-XAtq','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres'],input=query,text=True,capture_output=True)
    assert r.returncode==0, 'Synthetic SQL failed (diagnostics withheld)'
    return r.stdout.strip()

def request(path,body=None,token=None,schema=None,method=None):
    token=token or service
    headers={'apikey':service if token==service else anon,'Content-Type':'application/json'}
    if token.startswith('eyJ'): headers['Authorization']='Bearer '+token
    method=method or ('POST' if body is not None else 'GET')
    if schema: headers['Accept-Profile' if method=='GET' else 'Content-Profile']=schema
    req=urllib.request.Request(url+path,headers=headers,data=json.dumps(body).encode() if body is not None else None,method=method)
    try:
        with urllib.request.urlopen(req,timeout=20) as r:
            raw=r.read(); return r.status,json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        return e.code,json.loads(e.read())

def expect(result,status,label):
    code,data=result
    assert code==status, (label,'expected',status,'observed',code,data.get('code') if isinstance(data,dict) else None)
    return data

def rpc(name,args,token,schema='api'):
    return request('/rest/v1/rpc/'+name,args,token,schema)

def uid():return str(uuid.uuid4())
def key_args(key,request_id=None):return {'p_key_id':key,'p_request_id':request_id or uid()}
users=[]; grants=[]; collections=[]; groups=[]; token_values=[]
marker='s2-'+uuid.uuid4().hex
checks=[]
def passed(label):checks.append(label)
try:
    sessions=[]
    for _ in range(4):
        email=marker+'-'+uid()+'@example.test'; password=uid()+uid()
        identity=expect(request('/auth/v1/admin/users',{'email':email,'password':password,'email_confirm':True}),200,'create synthetic user')
        users.append(identity['id'])
        sessions.append(expect(request('/auth/v1/token?grant_type=password',{'email':email,'password':password},anon),200,'real login')['access_token'])
    for session in sessions:
        encoded=session.split('.')[1];claims=json.loads(base64.urlsafe_b64decode(encoded+'='*(-len(encoded)%4)))
        assert claims['role']=='authenticated','Must test ordinary signed sessions'
    owner,other,manager,delete_only=users; user,outsider,admin,deleter=sessions
    for _ in range(2):
        cid=uid(); collections.append(cid)
        sql(f"insert into public.kb_collections(id,name,path) values('{cid}','{marker}','/{marker}/{cid}');")
    c1,c2=collections; path1=f'/{marker}/{c1}'; path2=f'/{marker}/{c2}'
    group=uid(); groups.append(group)
    sql(f"insert into public.kb_groups(id,name,created_by) values('{group}','{marker}','{manager}'); insert into public.kb_group_members(group_id,user_id) values('{group}','{owner}');")
    for principal,pid,cid,actions in [('group',group,c1,'read'),('user',other,c2,'manage'),('user',manager,c1,'manage'),('user',delete_only,c1,'delete')]:
        gid=uid();grants.append(gid)
        sql(f"insert into public.kb_grants(id,resource_type,resource_id,principal_type,principal_id,actions,created_by) values('{gid}','collection','{cid}','{principal}','{pid}',array['{actions}']::public.kb_grant_action[],'{manager}');")
    # Readiness checks only; never retry writes.
    for _ in range(30):
        code,doc=request('/rest/v1/',token=user,schema='api')
        if code==200 and '/rpc/kb_api_key_create_v1' in doc.get('paths',{}):break
        time.sleep(.2)
    else:raise AssertionError('S2 authenticated RPC missing from real PostgREST')
    base={'name':'Synthetic key','client_id':marker,'scopes':['kb:read'],'collection_scope':[path1]}
    def create(payload=None,token=user,request_id=None):
        return rpc('kb_api_key_create_v1',{'p_request_id':request_id or uid(),'p_payload':payload or base},token)
    for token in (anon,service):
        for name,args in [('list',{}),('create',{'p_request_id':uid(),'p_payload':base}),('revoke',key_args(uid())),('rotate',key_args(uid()))]:
            code,data=rpc('kb_api_key_'+name+'_v1',args,token)
            assert code in (401,403) and data['code']=='42501', ('execution ACL',name,code)
    for token in (anon,user,service):
        assert request('/rest/v1/kb_api_key_requests',token=token,schema='private')[0]==406
    assert expect(request('/rest/v1/kb_api_keys?select=id',token=user),200,'direct RLS')==[]
    expect(request('/rest/v1/kb_api_keys',{},user,method='POST'),403,'direct writes denied')
    expect(rpc('kb_api_key_list_v1',{'p_actor_id':other},user),404,'forged caller signature')
    expect(create({**base,'created_by':other}),400,'forged creator')
    expect(create({**base,'actor_user_id':other}),403,'forged target')
    expect(create({**base,'collection_scope':[path2]}),403,'cross group')
    expect(create({**base,'scopes':['kb:admin']},token=deleter),403,'delete is not admin')
    for bad in ({**base,'scopes':['bad']},{**base,'scopes':None},{**base,'collection_scope':[]},{**base,'name':123},{**base,'expires_at':'infinity'},{**base,'expires_at':'bad'}, {**base,'actor_user_id':'bad'}):
        expect(create(bad),400,'input validation')
    passed('real Auth / ACL / actor spoof / cross-group / strict input')
    rid=uid(); created=expect(create(request_id=rid),200,'create')
    key=created['apiKey']['id']; token=created['token']; token_values.append(token)
    assert re.fullmatch(r'tgkb_live_[A-Za-z0-9_-]{43}',token)
    assert created['apiKey']['createdBy']==owner and created['apiKey']['actorUserId']==owner
    assert created['apiKey']['tokenPrefix']==token[:18]
    def verify(value):
        return expect(rpc('verify_kb_api_key',{'p_token_prefix':value[:18],'p_token_hash':hashlib.sha256(value.encode()).hexdigest(),'p_required_scopes':['kb:read']},service,'public'),200,'legacy verifier')[0]
    assert verify(token)['ok'] and not verify(token+'x')['ok']
    authz=expect(rpc('authorize_kb_api_key_collection_action',{'p_token_prefix':token[:18],'p_token_hash':hashlib.sha256(token.encode()).hexdigest(),'p_collection_selector':{'collection_id':c1},'p_action':'read'},service,'public'),200,'legacy authorize')[0]
    assert authz['ok']
    rows=expect(rpc('kb_api_key_list_v1',{},user),200,'list')['data']
    assert key in [r['id'] for r in rows] and 'token_hash' not in json.dumps(rows) and token not in json.dumps(rows)
    assert key not in [r['id'] for r in expect(rpc('kb_api_key_list_v1',{},outsider),200,'isolated list')['data']]
    for name in ('revoke','rotate'):
        expect(rpc('kb_api_key_'+name+'_v1',key_args(key),outsider),404,'cross-key denial')
    replay=expect(create(request_id=rid),200,'create replay')
    assert replay['replayed'] and replay['token'] is None and replay['apiKey']['id']==key
    expect(create({**base,'name':'changed'},request_id=rid),409,'semantic idempotency conflict')
    delegated=expect(create({**base,'actor_user_id':owner},token=admin),200,'scoped manager delegation')
    token_values.append(delegated['token'])
    expect(create({**base,'actor_user_id':other,'collection_scope':[path2]},token=admin),403,'manager cannot cross collection')
    concurrent_id=uid()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        creations=list(pool.map(lambda _:create(request_id=concurrent_id),range(2)))
    assert all(r[0]==200 for r in creations) and sum(r[1]['token'] is not None for r in creations)==1
    assert len({r[1]['apiKey']['id'] for r in creations})==1
    token_values.extend(r[1]['token'] for r in creations if r[1]['token'])
    expect(rpc('kb_api_key_revoke_v1',key_args(key,rid),user),409,'request reused for other operation')
    # Domain expiry behavior, independently of the imported verifier fixture.
    expiring=expect(create(),200,'expiry fixture');token_values.append(expiring['token'])
    expiring_id=expiring['apiKey']['id']
    sql(f"update public.kb_api_keys set expires_at='2020-01-01' where id='{expiring_id}';")
    expect(rpc('kb_api_key_rotate_v1',key_args(expiring_id),user),409,'expired rotation')
    assert verify(expiring['token'])['code']=='expired_token'
    expiring_request=uid()
    short_lived={**base,'expires_at':(datetime.now(timezone.utc)+timedelta(seconds=2)).isoformat()}
    first_expiry=expect(create(short_lived,request_id=expiring_request),200,'short-lived creation')
    token_values.append(first_expiry['token'])
    time.sleep(2.1)
    replay_expiry=expect(create(short_lived,request_id=expiring_request),200,'expired creation receipt remains recoverable')
    assert replay_expiry['replayed'] and replay_expiry['token'] is None and replay_expiry['apiKey']['id']==first_expiry['apiKey']['id']
    passed('token format / legacy verify+authorize / metadata / scoped delegation / concurrent create replay / expiry')
    # Inject actual INSERT and audit failures after revoke; transaction must undo all effects.
    for table in ('kb_api_keys','kb_audit_events'):
        sql(f"create function pg_temp_placeholder() returns trigger language plpgsql as $$ begin raise exception 'S2_SYNTHETIC_FAILURE'; end $$; create trigger s2_failure before insert on public.{table} for each row execute function pg_temp_placeholder();")
        retry_id=uid()
        try:
            expect(rpc('kb_api_key_rotate_v1',key_args(key,retry_id),user),500,'injected transaction error')
            assert verify(token)['ok'],'failed rotate revoked old key'
            assert sql(f"select count(*) from private.kb_api_key_requests where actor_id='{owner}' and request_id='{retry_id}';")=='0'
            assert sql(f"select count(*) from public.kb_api_keys where rotated_from_key_id='{key}';")=='0'
        finally:sql(f"drop trigger s2_failure on public.{table}; drop function pg_temp_placeholder();")
    passed('insert and audit failures roll back revoke/new key/receipt')
    # Prove retries after an aborted transaction remain usable.
    repaired=expect(rpc('kb_api_key_rotate_v1',key_args(key,retry_id),user),200,'retry aborted rotation')
    token_values.append(repaired['token']); key=repaired['apiKey']['id']; token=repaired['token']
    # Hold the real old-row lock until BOTH independent HTTP transactions are blocked.
    locker=subprocess.Popen(['docker','exec','-i',container,'psql','-XAtq','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    locker.stdin.write(f"begin; select id from public.kb_api_keys where id='{key}' for update; select pg_backend_pid();\n"); locker.stdin.flush()
    import selectors
    ready=selectors.DefaultSelector(); ready.register(locker.stdout,selectors.EVENT_READ)
    lock_output=b'';deadline=time.monotonic()+10
    while len(lock_output.splitlines())<2:
        assert time.monotonic()<deadline,'row lock barrier timeout'
        if ready.select(.1): lock_output+=os.read(locker.stdout.fileno(),4096)
    ready.close(); lock_pid=int(lock_output.splitlines()[1])
    # Both requests start together; independent HTTP transactions serialize on the old key.
    import threading
    barrier=threading.Barrier(2)
    rotation_ids=[uid(),uid()]
    def rotate(index):
        barrier.wait(timeout=10)
        return rpc('kb_api_key_rotate_v1',key_args(key,rotation_ids[index]),user)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures=[pool.submit(rotate,i) for i in range(2)]
            try:
                deadline=time.monotonic()+10
                while int(sql(f"with recursive blocked(pid) as (select pid from pg_stat_activity where {lock_pid}=any(pg_blocking_pids(pid)) union select a.pid from pg_stat_activity a join blocked b on b.pid=any(pg_blocking_pids(a.pid))) select count(*) from blocked;"))<2:
                    assert time.monotonic()<deadline,'HTTP rotations did not overlap at the row lock'
                    time.sleep(.05)
            finally:
                locker.stdin.write('commit;\n');locker.stdin.flush()
            results=[f.result(timeout=20) for f in futures]
    finally:
        locker.communicate(timeout=10)
        assert locker.returncode==0,'lock session failed'
    assert sorted(r[0] for r in results)==[200,409],('parallel rotations', [r[0] for r in results])
    winner=next(i for i,r in enumerate(results) if r[0]==200); rotated=results[winner][1]
    token_values.append(rotated['token']); new_key=rotated['apiKey']['id']
    assert verify(token)['code']=='revoked_token' and verify(rotated['token'])['ok']
    assert sql(f"select count(*) from public.kb_api_keys where rotated_from_key_id='{key}';")=='1'
    replay=expect(rpc('kb_api_key_rotate_v1',key_args(key,rotation_ids[winner]),user),200,'rotation replay')
    assert replay['token'] is None and replay['replayed'] and replay['apiKey']['id']==new_key
    revoke_id=uid()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        revokes=list(pool.map(lambda _:rpc('kb_api_key_revoke_v1',key_args(new_key,revoke_id),user),range(2)))
    assert all(r[0]==200 for r in revokes) and sum(r[1]['replayed'] for r in revokes)==1
    assert sql(f"select count(*) from public.kb_audit_events where request_id='{revoke_id}';")=='1'
    assert verify(rotated['token'])['code']=='revoked_token'
    passed('concurrent rotation and repeated revoke / single successor and audit / secret once')
    # Authorization is evaluated on replay too, after group membership removal.
    sql(f"delete from public.kb_group_members where group_id='{group}' and user_id='{owner}';")
    expect(create(request_id=rid),403,'revoked grant cannot replay')
    # Revocation remains possible even when the issuing collection grant was lost.
    expect(rpc('kb_api_key_revoke_v1',key_args(delegated['apiKey']['id']),user),200,'owner can always revoke')
    # Legacy unbounded keys remain readable/verifiable/revocable; v1 cannot clone them.
    legacy=uid(); legacy_token='tgkb_live_'+('x'*43);token_values.append(legacy_token)
    sql(f"insert into public.kb_api_keys(id,name,client_id,actor_user_id,token_prefix,token_hash,scopes,created_by) values('{legacy}','Legacy','{marker}','{owner}','{legacy_token[:18]}','{hashlib.sha256(legacy_token.encode()).hexdigest()}',array['kb:read'],'{owner}');")
    assert verify(legacy_token)['ok']
    expect(rpc('kb_api_key_rotate_v1',key_args(legacy),user),400,'unbounded legacy rotate')
    expect(rpc('kb_api_key_revoke_v1',key_args(legacy),user),200,'legacy revoke')
    audit=sql(f"select coalesce(jsonb_agg(to_jsonb(e)),'[]') from public.kb_audit_events e where actor_id in ('{owner}','{manager}');")
    receipts=sql(f"select coalesce(jsonb_agg(to_jsonb(r)),'[]') from private.kb_api_key_requests r where actor_id in ('{owner}','{manager}');")
    assert all(t not in audit+receipts and hashlib.sha256(t.encode()).hexdigest() not in audit+receipts for t in token_values)
    passed('grant loss / legacy unbounded compatibility / no audit or receipt secrets')
finally:
    # Exact owned fixture IDs only; private ledger has no FK to legacy mutable rows.
    if users:
        literals=','.join("'"+u+"'" for u in users)
        sql(f"delete from public.kb_api_keys where client_id='{marker}'; delete from public.kb_audit_events where actor_id in ({literals}); delete from private.kb_api_key_requests where actor_id in ({literals});" if sql("select to_regclass('private.kb_api_key_requests') is not null;")=='t' else f"delete from public.kb_api_keys where client_id='{marker}';")
    for g in grants:sql(f"delete from public.kb_grants where id='{g}';")
    for g in groups:sql(f"delete from public.kb_group_members where group_id='{g}'; delete from public.kb_groups where id='{g}';")
    for c in collections:sql(f"delete from public.kb_collections where id='{c}';")
    for u in users:expect(request('/auth/v1/admin/users/'+u,token=service,method='DELETE'),200,'cleanup Auth')
print(json.dumps({'schema_version':1,'passed':True,'runtime':'owned local Auth + PostgREST + PostgreSQL','checks':checks,'fixtures_cleaned':True}))

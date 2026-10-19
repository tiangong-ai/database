#!/usr/bin/env python3
"""Metadata real Auth/PostgREST, transaction failures and concurrent sessions; owned local only."""
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
users=[]; rows=[]; checks=[]; marker='metadata-'+uuid.uuid4().hex
resources={'education':('edu_meta','name'), 'esg':('esg_meta','report_title'), 'standards':('standards','title'), 'reports':('reports','title'), 'internalUse':('internal_use','title'), 'greenDeal':('green_deal_meta','title')}
def command(resource,operation='create',payload=None,record=None,version=None,token=None,rid=None):
    return rpc('kb_metadata_command_v1',{'p_resource':resource,'p_operation':operation,'p_request_id':rid or uid(),'p_payload':payload if payload is not None else {resources[resource][1]:marker},'p_record_id':record,'p_expected_version':version},token or editor)
def context(resource,ids=None,token=None):
    return expect(rpc('kb_metadata_context_v1',{'p_resource':resource,'p_ids':ids or []},token or editor),200,'context')
def snapshot(resource,row):return context(resource,[row])['records'][row]
try:
    sessions=[]
    for _ in range(3):
        email=marker+'-'+uid()+'@example.test'; password=uid()+uid()
        identity=expect(request('/auth/v1/admin/users',{'email':email,'password':password,'email_confirm':True}),200,'synthetic identity')
        users.append(identity['id'])
        sessions.append(expect(request('/auth/v1/token?grant_type=password',{'email':email,'password':password},anon),200,'ordinary login')['access_token'])
    owner,reader,other=users; editor,read_session,other_session=sessions
    for session in sessions:
        encoded=session.split('.')[1]; claims=json.loads(base64.urlsafe_b64decode(encoded+'='*(-len(encoded)%4)))
        assert claims['role']=='authenticated'
    for resource in resources:
        sql(f"insert into private.kb_metadata_editors(actor_id,resource,granted_by) values('{owner}','{resource}','{owner}');")
    sql(f"insert into private.kb_metadata_editors(actor_id,resource,granted_by) values('{other}','esg','{owner}');")
    for _ in range(30):
        code,doc=request('/rest/v1/',token=editor,schema='api')
        if code==200 and '/rpc/kb_metadata_command_v1' in doc.get('paths',{}):break
        time.sleep(.2)
    else:raise AssertionError('metadata gateway absent')
    for token in (anon,service):
        assert command('reports',token=token)[0] in (401,403)
        assert rpc('kb_metadata_context_v1',{'p_resource':'reports'},token)[0] in (401,403)
    for token in (anon,editor,service):
        assert request('/rest/v1/kb_metadata_editors',token=token,schema='private')[0]==406
    expect(command('reports',token=read_session),403,'ungranted reader')
    expect(command('reports',token=other_session),403,'cross resource')
    assert not context('reports',token=read_session)['canWrite']
    assert context('reports',token=read_session)['records']=={}
    expect(rpc('kb_metadata_command_v1',{'p_resource':'reports','p_operation':'create','p_request_id':uid(),'p_payload':{'title':marker},'p_actor_id':owner},editor),404,'forged actor')
    expect(request('/auth/v1/user',{'data':{'role':'admin','metadata_resources':list(resources)}},read_session,method='PUT'),200,'editable claims fixture')
    expect(command('reports',token=read_session),403,'editable claims grant nothing')
    for resource,(table,title) in resources.items():
        expect(request('/rest/v1/'+table,{title:marker},editor,method='POST'),403,'legacy DML remains denied')
        rid=uid(); create=expect(command(resource,rid=rid),200,'create '+resource); row=create['id']; rows.append((table,row))
        assert context(resource)['canWrite']
        listed=expect(rpc('kb_metadata_list_v1',{'p_resource':resource,'p_query':{'q':marker}},editor),200,'editor list '+resource)
        assert row in [r['values']['id'] for r in listed['records']]
        expect(rpc('kb_metadata_list_v1',{'p_resource':resource},read_session),403,'reader cannot elevate list')
        data=snapshot(resource,row); assert data['values'][title]==marker and data['version']==create['recordVersion']
        assert expect(command(resource,rid=rid),200,'replay')['id']==row
        expect(command(resource,payload={title:marker+'x'},rid=rid),409,'id reuse')
        for payload in ({title:marker,'id':uid()},{title:marker,'nas_path':'/unsafe'}, {title:marker,'created_by':reader},{title:''},{title:None},{title:123},{title:'x'*10001}):
            expect(command(resource,payload=payload),400,'invalid fields')
        updated=expect(command(resource,'update',{title:marker+' updated'},row,data['version']),200,'update '+resource)
        assert snapshot(resource,row)['values'][title]==marker+' updated'
        expect(command(resource,'update',{title:'stale'},row,data['version']),409,'stale update')
        expect(command(resource,'delete',{},row,data['version']),409,'stale delete')
        delete_id=uid()
        expect(command(resource,'delete',{},row,updated['recordVersion'],rid=delete_id),200,'delete '+resource)
        assert expect(command(resource,'delete',{},row,updated['recordVersion'],rid=delete_id),200,'delete replay')['replayed']
        assert row not in context(resource,[row])['records']
        expect(command(resource,'delete',{},row,updated['recordVersion']),404,'missing row')
    checks.append('six resources CRUD, ordinary Auth, explicit grants, forbidden roles/claims/cross-resource, base DML, strict fields, versions and replay')
    for resource,payload in [('education',{'name':marker,'chapter_number':-1}),('education',{'name':marker,'chapter_number':1.5}),('education',{'name':marker,'course':'x'*256}),('reports',{'title':marker,'release_date':'infinity'}),('reports',{'title':marker,'release_date':'2026-99-99'}),('reports',{'title':marker,'language':'bogus'}),('reports',{'title':marker,'issuing_organization':123})]:
        expect(command(resource,payload=payload),400,'typed field validation')
    # Known ESG business FK is invalid input, not an unknown committed outcome.
    country='ZZ'
    assert sql("select count(*) from public.esg_country where code='ZZ';")=='0'
    bad_id=uid()
    expect(command('esg',payload={'report_title':marker,'country':country},rid=bad_id),400,'invalid country create')
    assert sql(f"select count(*) from public.esg_meta where report_title='{marker}';")=='0'
    assert sql(f"select count(*) from private.kb_metadata_requests where actor_id='{owner}' and request_id='{bad_id}';")=='0'
    assert sql(f"select count(*) from public.kb_audit_events where actor_id='{owner}' and request_id='{bad_id}';")=='0'
    sql("insert into public.esg_country(code) values('ZZ');")
    try:
        created=expect(command('esg',payload={'report_title':marker,'country':country},rid=bad_id),200,'retry after country correction')
        esg_row=created['id'];rows.append(('esg_meta',esg_row))
        before=snapshot('esg',esg_row);bad_update=uid()
        expect(command('esg','update',{'country':'invalid-country'},esg_row,before['version'],rid=bad_update),400,'invalid country update')
        assert snapshot('esg',esg_row)==before
        assert sql(f"select count(*) from private.kb_metadata_requests where actor_id='{owner}' and request_id='{bad_update}';")=='0'
        assert sql(f"select count(*) from public.kb_audit_events where actor_id='{owner}' and request_id='{bad_update}';")=='0'
        valid_update=expect(command('esg','update',{'country':country},esg_row,before['version']),200,'valid country update')
        cleared=expect(command('esg','update',{'country':None},esg_row,valid_update['recordVersion']),200,'clear optional country')
        assert snapshot('esg',esg_row)['values']['country'] is None
        sql("delete from public.esg_country where code='ZZ';")
        replay=expect(command('esg',payload={'report_title':marker,'country':country},rid=bad_id),200,'receipt before mutable reference lookup')
        assert replay['id']==esg_row and replay['replayed']
        # Even a diagnostic with the same constraint name in the audit phase is internal.
        sql("create function public.metadata_test_fk() returns trigger language plpgsql as $$ begin raise foreign_key_violation using schema='public',table='esg_meta',constraint='fk_country'; end $$; create trigger metadata_test_fk before insert on public.kb_audit_events for each row execute function public.metadata_test_fk();")
        failed=uid();before=snapshot('esg',esg_row)
        try:
            expect(command('esg','update',{'report_title':marker+' audit'},esg_row,cleared['recordVersion'],rid=failed),500,'audit FK remains internal')
            assert snapshot('esg',esg_row)==before
            assert sql(f"select count(*) from private.kb_metadata_requests where actor_id='{owner}' and request_id='{failed}';")=='0'
        finally:sql('drop trigger metadata_test_fk on public.kb_audit_events; drop function public.metadata_test_fk();')
        expect(command('esg','update',{'report_title':marker+' audit'},esg_row,cleared['recordVersion'],rid=failed),200,'audit FK retry')
    finally:
        sql("delete from public.esg_country where code='ZZ';")
    checks.append('ESG country create/update errors, null, exact retry, replay after reference removal, audit FK isolation')
    for query in ({'sort':'title; drop table public.reports'}, {'pageSize':101}, {'page':0}, {'dir':'bad'}, {'q':{}}, {'page':1.5}, {'x':'bad'}, {'sort':None}):
        expect(rpc('kb_metadata_list_v1',{'p_resource':'reports','p_query':query},editor),400,'list input validation')
    valid=expect(command('reports',payload={'title':marker,'release_date':'2026-10-19','issuing_organization':[{'name':'example'}],'language':'eng'}),200,'typed valid')
    row=valid['id']; rows.append(('reports',row))
    for sort in ('title','issuing_organization','release_date'):
        expect(rpc('kb_metadata_list_v1',{'p_resource':'reports','p_query':{'sort':sort,'dir':'asc','page':1,'pageSize':1}},editor),200,'typed list sort')
    # Real independent HTTP transactions contend on one source row/version.
    import threading
    barrier=threading.Barrier(2)
    def update(i):
        barrier.wait(timeout=10)
        return command('reports','update',{'title':marker+str(i)},row,valid['recordVersion'])
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(update,range(2)))
    assert sorted(r[0] for r in results)==[200,409],('concurrent versions',[r[0] for r in results])
    rid=uid()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(lambda _:command('reports',rid=rid),range(2)))
    assert all(r[0]==200 for r in results) and len({r[1]['id'] for r in results})==1 and sum(r[1]['replayed'] for r in results)==1
    rows.append(('reports',results[0][1]['id']))
    assert sql(f"select count(*) from public.kb_audit_events where request_id='{rid}';")=='1'
    sql(f"update private.kb_metadata_editors set expires_at=now()-interval '1 minute' where actor_id='{owner}' and resource='reports';")
    expect(command('reports',rid=rid),403,'expired cannot replay')
    sql(f"update private.kb_metadata_editors set expires_at=null,revoked_at=now() where actor_id='{owner}' and resource='reports';")
    expect(command('reports',rid=rid),403,'revoked cannot replay')
    sql(f"update private.kb_metadata_editors set revoked_at=null where actor_id='{owner}' and resource='reports';")
    # Linked-file markers protect both mutation modes; retain the exact fixture only.
    for field in ('uploaded_time','embedded_time','fulltext_time'):
        sql(f"update public.reports set {field}=now() where id='{row}';")
        v=snapshot('reports',row)['version']
        expect(command('reports','update',{'title':'must not change'},row,v),409,'processed update')
        expect(command('reports','delete',{},row,v),409,'processed delete')
        sql(f"update public.reports set {field}=null where id='{row}';")
    # Resource association, including a concurrent M1 writer, must block legacy mutation.
    cid=uid(); entry=uid()
    sql(f"insert into public.kb_collections(id,name,path) values('{cid}','{marker}','/{marker}');")
    try:
        sql(f"insert into private.kb_resource_entries(id,collection_id,primary_source_binding_id,external_key,profile_json,metadata_mode,legacy_ref) values('{entry}','{cid}','test','{row}','{{}}','legacy_ref','{{\"table\":\"reports\",\"id\":\"{row}\"}}');")
        expect(command('reports','delete',{},row,snapshot('reports',row)['version']),409,'M1 link protected')
    finally:
        sql(f"delete from private.kb_resource_entries where id='{entry}'; delete from public.kb_collections where id='{cid}';")
    locker=subprocess.Popen(['docker','exec','-i',container,'psql','-XAtq','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        locker.stdin.write('begin; lock table private.kb_resource_entries in row exclusive mode; select 1;\n');locker.stdin.flush()
        import selectors
        ready=selectors.DefaultSelector(); ready.register(locker.stdout,selectors.EVENT_READ)
        assert ready.select(10), 'M1 lock barrier failed'
        assert locker.stdout.readline().strip()=='1'; ready.close()
        blocked=command('reports','delete',{},row,snapshot('reports',row)['version'])
        assert blocked[0]==409 and blocked[1]['message']=='METADATA_BUSY'
    finally:
        locker.communicate('rollback;\n',timeout=10)
        assert locker.returncode==0
    checks.append('typed fields, simultaneous update/create, expiry and revocation on replay, processing and M1 guards')
    # Inject audit failure, prove row AND receipt are rolled back; retry the same request succeeds.
    sql("create function public.metadata_test_fail() returns trigger language plpgsql as $$ begin raise exception 'synthetic'; end $$; create trigger metadata_test_fail before insert on public.kb_audit_events for each row execute function public.metadata_test_fail();")
    fail_id=uid(); before=snapshot('reports',row)
    try:
        expect(command('reports','update',{'title':'must rollback'},row,before['version'],rid=fail_id),500,'audit failure')
        assert snapshot('reports',row)==before
        assert sql(f"select count(*) from private.kb_metadata_requests where actor_id='{owner}' and request_id='{fail_id}';")=='0'
    finally:sql('drop trigger metadata_test_fail on public.kb_audit_events; drop function public.metadata_test_fail();')
    expect(command('reports','update',{'title':'must rollback'},row,before['version'],rid=fail_id),200,'retry rollback')
    audit=sql(f"select jsonb_agg(payload_json) from public.kb_audit_events where actor_id='{owner}';")
    assert marker not in audit and 'must rollback' not in audit
    checks.append('audit failure atomic rollback/retry; audit contains no raw metadata')
finally:
    for table,row in rows:sql(f"delete from public.{table} where id='{row}';")
    if users:
        literals=','.join("'"+u+"'" for u in users)
        sql(f"delete from public.kb_audit_events where actor_id in ({literals}); delete from private.kb_metadata_requests where actor_id in ({literals}); delete from private.kb_metadata_editors where actor_id in ({literals});")
    for user in users:expect(request('/auth/v1/admin/users/'+user,token=service,method='DELETE'),200,'cleanup identity')
print(json.dumps({'metadata_management':'passed','checks':checks,'synthetic_users_deleted':len(users)}))

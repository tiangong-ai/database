#!/usr/bin/env python3
"""Catalogue real ordinary Auth/PostgREST authorization and count qualification; owned local only."""
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
users=[]; records=[]; checks=[]; marker='catalogue-'+uuid.uuid4().hex
cid,did,eid,hidden_cid,hidden_doc=[uid() for _ in range(5)]
def catalogue(query=None,session=None):
    return expect(rpc('kb_catalogue_v1',{'p_query':query or {}},session or sessions[0]),200,'catalogue')
try:
    # This runner owns a disposable local stack; isolate catalogue fixtures from prior gates.
    sql('truncate public.journals,public.edu_meta,public.esg_meta,public.standards,public.reports,public.internal_use,public.green_deal_meta,private.kb_resource_entries,public.kb_documents cascade;')
    sessions=[]
    for _ in range(2):
        email=marker+'-'+uid()+'@example.test'; password=uid()+uid()
        user=expect(request('/auth/v1/admin/users',{'email':email,'password':password,'email_confirm':True}),200,'identity')
        users.append(user['id']);sessions.append(expect(request('/auth/v1/token?grant_type=password',{'email':email,'password':password},anon),200,'login')['access_token'])
    actor,other=users
    resources={'journals':('title','journals'), 'edu_meta':('name','education'), 'esg_meta':('report_title','esg'), 'standards':('title','standards'), 'reports':('title','reports'), 'internal_use':('title','other'), 'green_deal_meta':('title','policies')}
    for table,(field,category) in resources.items():
        row=uid();records.append((table,row))
        extra=",doi" if table=='journals' else ''
        value=",'10.000/"+row+"'" if table=='journals' else ''
        sql(f"insert into public.{table}(id,{field}{extra}) values('{row}','{marker} {table}'{value});")
    sql(f"insert into private.kb_metadata_editors(actor_id,resource,granted_by) values('{actor}','greenDeal','{actor}');")
    rows=catalogue({'page_size':50})
    assert rows['total']==7 and len(rows['groups'])==7, 'all source categories'
    assert rows['metrics']=={'associated':0,'ready':0,'missing':0,'unknown':7}, 'unknown is not missing'
    assert catalogue({},sessions[1])['total']==6, 'Green Deal editor read stays explicit'
    for table,(_,category) in resources.items():
        assert catalogue({'category':category})['total']==1
    a=catalogue({'page_size':2}); b=catalogue({'page_size':2,'page':2})
    assert a['total']==b['total']==7 and len(a['rows'])==len(b['rows'])==2
    assert not ({x['key'] for x in a['rows']}&{x['key'] for x in b['rows']}), 'stable server pages'
    assert catalogue({'page':100})['rows']==[]
    journal=records[0][1]
    for session in sessions:
        page=expect(rpc('kb_journals_page_v1',{'p_page':1,'p_page_size':10,'p_dir':'desc'},session),200,'journals session page')
        assert page['total']==1 and page['data'][0]['id']==journal
        empty=expect(rpc('kb_journals_page_v1',{'p_page':2},session),200,'journals empty page')
        assert empty['total']==1 and empty['data']==[]
    expect(rpc('kb_journals_page_v1',{},anon),401,'journals anonymous denied')
    expect(rpc('kb_journals_page_v1',{},service),403,'journals service denied')
    expect(rpc('kb_journals_page_v1',{'p_page':0},sessions[0]),400,'journals invalid page')
    checks.append('journals ordinary HTTP/RLS pagination, exact empty-page total, anon/service denial')
    sql(f"""insert into public.kb_collections(id,name,path,metadata_schema_json) values
      ('{cid}','{marker}','/{marker}','{{"catalogue_category":"journals"}}'),
      ('{hidden_cid}','Hidden','/{hidden_cid}','{{}}');
      insert into public.kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by)
      values('collection','{cid}','user','{actor}',array['read']::public.kb_grant_action[],'{actor}');
      insert into private.kb_resource_entries(id,collection_id,primary_source_binding_id,external_key,profile_json,metadata_mode,legacy_ref,source_metadata,candidates)
      values('{eid}','{cid}','catalog','{eid}','{{"required_fields":["title"]}}','legacy_ref','{{"table":"journals","id":"{journal}"}}','{{"title":"{marker} linked"}}','{{"synthetic":{{}}}}');
      insert into public.kb_documents(id,primary_collection_id,dedupe_scope,original_filename,sha256,status,created_by,owner_user_id,opensearch_indexed,pinecone_indexed)
      values('{did}','{cid}','{cid}','{marker}.pdf','a','completed','{actor}','{actor}',true,true),
      ('{hidden_doc}','{hidden_cid}','{hidden_cid}','{marker} hidden.pdf','b','failed','{other}','{other}',false,false);
      insert into private.kb_resource_document_links(entry_id,document_id,content_revision,active,publish_state,approved_revision,candidate_json,metadata_snapshot,effective_metadata_revision)
      values('{eid}','{did}',1,true,'published',1,'{{}}','{{}}',1);""")
    result=catalogue({'page_size':50})
    assert result['total']==7 and result['metrics']['ready']==1 and result['metrics']['associated']==1, 'explicit links dedupe three projections'
    assert not any(x['id'] in (journal,did,hidden_doc) for x in result['rows'])
    linked=catalogue({'key':'material:'+eid})['rows'][0]
    assert linked['document_id']==did and linked['metadata_state']=='complete'
    assert catalogue({'key':'material:'+eid},sessions[1])['total']==0
    assert catalogue({'collection':cid})['total']==1
    assert catalogue({'key':'journals:'+journal})['total']==0, 'source detail stays suppressed'
    sql(f"update public.kb_collections set metadata_schema_json='{{\"catalogue_category\":\"reports\"}}' where id='{cid}';")
    assert catalogue({'category':'journals'})['total']==0, 'category filter cannot resurrect a suppressed source'
    assert catalogue({'category':'reports','key':'material:'+eid})['total']==1
    sql(f"update public.kb_collections set metadata_schema_json='{{\"catalogue_category\":\"journals\"}}' where id='{cid}';")
    assert catalogue({'state':'ready'})['total']==1
    assert catalogue({'state':'associated'})['total']==1
    assert catalogue({'state':'missing'})['total']==0
    assert catalogue({'state':'review'})['total']==1
    sql(f"update public.kb_documents set status='failed' where id='{did}'; update private.kb_resource_entries set candidates='{{}}',source_metadata='{{"""+'"title":null'+f"""}}' where id='{eid}';""")
    assert catalogue({'state':'failed','collection':cid})['total']==1
    assert catalogue({'state':'pending','collection':cid})['total']==1
    assert catalogue({'state':'missing','collection':cid})['total']==0, 'active document remains a file registration'
    sql(f"update private.kb_resource_document_links set active=false,publish_state='superseded' where entry_id='{eid}';")
    assert catalogue({'state':'missing','collection':cid})['total']==1
    assert catalogue({'state':'unknown'})['total']==6
    assert catalogue({'state':'ready'})['total']==0
    sql(f"insert into public.kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by) values('document','{hidden_doc}','user','{actor}',array['read']::public.kb_grant_action[],'{actor}');")
    hidden=catalogue({'key':'document:'+hidden_doc})['rows'][0]
    assert hidden['collection_id'] is None and hidden['collection_name'] is None and hidden['category']=='other', 'document access does not expose hidden collection'
    assert catalogue({'collection':hidden_cid})['total']==0
    sql(f"delete from public.kb_grants where resource_id='{hidden_doc}';")
    checks.append('seven types; Green Deal explicit read grant; cross-collection isolation; explicit-link dedupe; stable pages and count parity; independent metadata/file/processing states')
    for term in ('a','synthetic abstract','%','测试',' '):
        denied=expect(rpc('kb_catalogue_v1',{'p_query':{'q':term}},sessions[0]),400,'unsupported search')
        assert denied['code']=='22023' and denied['message']=='CATALOGUE_SEARCH_UNSUPPORTED'
    for query in ({'page_size':51},{'page':0},{'page':1.2},{'page':10**20},{'category':'invented'},{'state':'invented'},{'q':'x'*201},{'key':'invalid'},{'key':'journals:'+'-'*36},{'collection':'invalid'},{'actor_id':actor},[],None):
        expect(rpc('kb_catalogue_v1',{'p_query':query},sessions[0]),400,'invalid query')
    lookup={'category':'journals','identifier':'https://doi.org/10.000/'+journal.upper()}
    found=expect(rpc('kb_catalogue_identifier_v1',{'p_query':lookup},sessions[0]),200,'identifier ordinary session')
    assert found['total']==1 and found['rows'][0]['id']==eid, 'Canonical material via source DOI'
    found=expect(rpc('kb_catalogue_identifier_v1',{'p_query':lookup},sessions[1]),200,'identifier other session')
    assert found['total']==1 and found['rows'][0]['id']==journal, 'Inaccessible material does not suppress source'
    expect(rpc('kb_catalogue_identifier_v1',{'p_query':lookup},anon),401,'identifier anonymous denied')
    expect(rpc('kb_catalogue_identifier_v1',{'p_query':lookup},service),403,'identifier service denied')
    expect(rpc('kb_catalogue_identifier_v1',{'p_query':{'category':'all','identifier':'a'}},sessions[0]),400,'identifier current-library bound')
    checks.append('identifier exact source match and canonical material; ordinary sessions; anon/service denial')
    expect(rpc('kb_catalogue_v1',{},anon),401,'anonymous denied')
    expect(rpc('kb_catalogue_v1',{},service),403,'service role denied')
    assert sql("select has_schema_privilege('authenticated','private','usage');")=='f'
    expect(request('/rest/v1/kb_resource_entries',token=sessions[0],schema='private'),406,'private not exposed')
    sql(f"delete from public.kb_grants where resource_id='{cid}'; delete from private.kb_metadata_editors where actor_id='{actor}';")
    # Owner may still see document; entry requires a collection grant.
    assert catalogue({'key':'material:'+eid})['total']==0
    assert catalogue({'category':'policies'})['total']==0
    checks.append('ordinary HTTP sessions; invalid query bounds; anon/service denial; private schema unexposed; immediate grant revocation')
finally:
    sql(f"delete from private.kb_resource_document_links where entry_id='{eid}'; delete from private.kb_resource_entries where id='{eid}'; delete from public.kb_documents where id in ('{did}','{hidden_doc}'); delete from public.kb_grants where resource_id in ('{cid}','{hidden_cid}','{hidden_doc}'); delete from public.kb_collections where id in ('{cid}','{hidden_cid}');")
    for table,row in records:sql(f"delete from public.{table} where id='{row}';")
    for user in users:
        sql(f"delete from private.kb_metadata_editors where actor_id='{user}';")
        expect(request('/auth/v1/admin/users/'+user,token=service,method='DELETE'),200,'identity cleanup')
print(json.dumps({'catalogue_read':'passed','checks':checks,'synthetic_users_deleted':len(users)}))

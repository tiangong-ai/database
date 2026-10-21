#!/usr/bin/env python3
"""Library live-account/session guard through real Auth/PostgREST; owned local only."""
import base64
import hashlib
import hmac
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
status=json.loads(subprocess.check_output([os.environ['SUPABASE_CLI'],'status','--workdir',workdir,'-o','json'],stderr=subprocess.DEVNULL))
local_jwt_secret=status['JWT_SECRET']

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
users=[]; checks=[]; marker='library-session-'+uuid.uuid4().hex
try:
    sessions=[]
    for _ in range(2):
        email=marker+'-'+uid()+'@example.test'; password=uid()+uid()
        user=expect(request('/auth/v1/admin/users',{'email':email,'password':password,'email_confirm':True}),200,'create isolated user')
        users.append(user['id'])
        sessions.append(expect(request('/auth/v1/token?grant_type=password',{'email':email,'password':password},anon),200,'login'))
    def claims(token):
        encoded=token.split('.')[1]; return json.loads(base64.urlsafe_b64decode(encoded+'='*(-len(encoded)%4)))
    actor=users[0]; token=sessions[0]['access_token']; sid=claims(token)['session_id']
    def check(allowed,label):
        auth=request('/auth/v1/user',token=token)[0]
        assert (auth==200)==allowed,(label,'Auth',auth)
        for count in (False,True):
            result=rpc('kb_library_read_v1',{'p_resource':'journals','p_query':{'page':1,'pageSize':10},'p_count_only':count},token)
            assert (result[0]==200)==allowed,(label,'RPC',result[0])
            if not allowed:assert result[0] in (401,403)
        checks.append(label)
    check(True,'live session page/count agree with Auth')
    if 'local_jwt_secret' in globals():
        def signed_claims(payload):
            encode=lambda value: base64.urlsafe_b64encode(json.dumps(value,separators=(',',':')).encode()).decode().rstrip('=')
            message=encode({'alg':'HS256','typ':'JWT'})+'.'+encode(payload)
            signature=base64.urlsafe_b64encode(hmac.new(local_jwt_secret.encode(),message.encode(),hashlib.sha256).digest()).decode().rstrip('=')
            return message+'.'+signature
        valid_token=token
        expired={**claims(token),'exp':int(time.time())-120,'iat':int(time.time())-3600}
        token=signed_claims(expired);check(False,'expired signed JWT rejected')
        for session_claim in (None,'invalid',uid()):
            payload=claims(valid_token)
            if session_claim is None:payload.pop('session_id')
            else:payload['session_id']=session_claim
            for count in (False,True):
                assert rpc('kb_library_read_v1',{'p_resource':'journals','p_count_only':count},signed_claims(payload))[0] in (401,403)
        checks.append('signed missing, malformed and absent session IDs denied')
        token=valid_token
    sql(f"update auth.users set banned_until=now()+interval '1 hour' where id='{actor}';")
    check(False,'banned account rejected with unexpired JWT')
    sql(f"update auth.users set banned_until=now()-interval '1 hour' where id='{actor}';")
    check(True,'expired ban restores permitted reads')
    sql(f"update auth.sessions set user_id='{users[1]}' where id='{sid}';")
    for count in (False,True):expect(rpc('kb_library_read_v1',{'p_resource':'journals','p_count_only':count},token),403,'session ownership mismatch')
    checks.append('session ownership mismatch rejected')
    sql(f"update auth.sessions set user_id='{actor}' where id='{sid}';")
    refreshed=expect(request('/auth/v1/token?grant_type=refresh_token',{'refresh_token':sessions[0]['refresh_token']},anon),200,'refresh')
    token=refreshed['access_token'];check(True,'refreshed ordinary session')
    expect(request('/auth/v1/logout?scope=local',{},token),204,'local signout')
    check(False,'signout rejects still-unexpired JWT')
    token=sessions[1]['access_token'];user=users.pop()
    expect(request('/auth/v1/admin/users/'+user,token=service,method='DELETE'),200,'delete isolated account')
    check(False,'deleted account rejected')
    for forbidden in (anon,service,token[:-12]+'invalidxxxxx'):
        for count in (False,True):assert rpc('kb_library_read_v1',{'p_resource':'journals','p_count_only':count},forbidden)[0] in (401,403)
    checks.append('anonymous, service role and forged signature denied')
finally:
    for user in users:expect(request('/auth/v1/admin/users/'+user,token=service,method='DELETE'),200,'isolated user cleanup')
print(json.dumps({'library_session':'passed','checks':checks,'production_touched':False}))

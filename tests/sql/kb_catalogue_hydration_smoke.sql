-- Regression for #28: a one-row page must not serialize every document.
-- Instrument the existing row constructor inside a rollback-only transaction.
begin;
truncate public.journals,public.edu_meta,public.esg_meta,public.standards,
 public.reports,public.internal_use,public.green_deal_meta,
 private.kb_resource_entries,public.kb_documents cascade;
insert into auth.users(id,role) values(md5('hydration-actor')::uuid,'authenticated');
insert into public.kb_collections(id,name,path,metadata_schema_json)
 values(md5('hydration-collection')::uuid,'hydration','/hydration','{"catalogue_category":"journals"}');
insert into public.kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by)
 values('collection',md5('hydration-collection')::uuid,'user',md5('hydration-actor')::uuid,array['read']::public.kb_grant_action[],md5('hydration-actor')::uuid);
insert into public.kb_documents(id,primary_collection_id,dedupe_scope,original_filename,sha256,created_by,owner_user_id,metadata_json)
 select md5('hydration-document-'||i)::uuid,md5('hydration-collection')::uuid,'hydration','fixture.pdf',i::text,md5('hydration-actor')::uuid,md5('hydration-actor')::uuid,
 jsonb_build_object('doi','10.000/hydration','description',repeat(md5(i::text),1000)) from generate_series(1,120)i;
create temporary sequence catalogue_hydrations;
grant usage,select on sequence pg_temp.catalogue_hydrations to authenticated;
do $$ declare definition text; begin
 select pg_get_functiondef('private.kb_catalogue_row_v1(text,uuid,text,text,jsonb,timestamptz,jsonb)'::regprocedure) into definition;
 -- Wrap the original expression, retaining its exact output and ACL.
 definition:=replace(definition,'LANGUAGE sql','LANGUAGE plpgsql');
 definition:=replace(definition,'IMMUTABLE','VOLATILE');
 definition:=replace(definition,'RETURN ',E'AS $body$ BEGIN PERFORM nextval(''pg_temp.catalogue_hydrations''); RETURN ');
 definition:=regexp_replace(definition,';?\s*$', '')||'; END $body$;';
 execute definition;
end $$;
select set_config('request.jwt.claims',jsonb_build_object('sub',md5('hydration-actor')::uuid,'role','authenticated')::text,true);
set local role authenticated;
do $$ declare r jsonb; begin
 assert (api.kb_catalogue_v1(jsonb_build_object('collection',repeat('-',36)))->>'total')::int=0,'Malformed collection retains empty-match behavior, never UUID cast failure';
 r:=api.kb_catalogue_v1('{"page_size":1}');
 assert (r->>'total')::int=120 and jsonb_array_length(r->'rows')=1,'All candidates counted, one body returned';
 assert (select last_value from pg_temp.catalogue_hydrations)=1,'Browse must hydrate only its selected page';
 assert length(r->'rows'->0->'metadata'->>'description')=32000,'Selected wide metadata remains intact';
end $$;
reset role;
alter sequence pg_temp.catalogue_hydrations restart;
set local role authenticated;
do $$ declare r jsonb; begin
 assert (api.kb_catalogue_identifier_v1(jsonb_build_object('category','journals','identifier','10.000/hydration','collection',repeat('-',36)))->>'total')::int=0,'Identifier malformed collection retains empty match';
 r:=api.kb_catalogue_identifier_v1('{"category":"journals","identifier":"10.000/hydration","page_size":1}');
 assert (r->>'total')::int=120 and jsonb_array_length(r->'rows')=1,'Identifier duplicate counts remain exact';
 assert (select last_value from pg_temp.catalogue_hydrations)=1,'Identifier must hydrate only its selected page';
end $$;
reset role;
-- The same bound applies to material pages and explicit legacy/document links.
insert into public.journals(id,doi,title)
 select md5('hydration-legacy-'||i)::uuid,'10.000/hydration','fixture' from generate_series(1,120)i;
insert into private.kb_resource_entries(id,collection_id,primary_source_binding_id,external_key,profile_json,metadata_mode,legacy_ref,source_metadata)
 select md5('hydration-entry-'||i)::uuid,md5('hydration-collection')::uuid,'hydration',i::text,
 '{"required_fields":["title"]}','legacy_ref',jsonb_build_object('table','journals','id',md5('hydration-legacy-'||i)::uuid),
 '{"title":"fixture","doi":"10.000/hydration"}' from generate_series(1,120)i;
insert into private.kb_resource_document_links(entry_id,document_id,content_revision,active,publish_state,approved_revision,candidate_json,metadata_snapshot,effective_metadata_revision)
 select md5('hydration-entry-'||i)::uuid,md5('hydration-document-'||i)::uuid,1,true,'published',1,'{}','{}',1 from generate_series(1,120)i;
alter sequence pg_temp.catalogue_hydrations restart;
set local role authenticated;
do $$ declare r jsonb; begin
 r:=api.kb_catalogue_v1('{"page_size":20,"category":"journals","state":"associated"}');
 assert (r->>'total')::int=120 and jsonb_array_length(r->'rows')=20 and r->'rows'->0->>'kind'='material','Material pages suppress explicit legacy/document duplicates';
 assert (select last_value from pg_temp.catalogue_hydrations)=20,'20-row material page hydrates exactly 20 bodies';
end $$;
reset role;
alter sequence pg_temp.catalogue_hydrations restart;
set local role authenticated;
do $$ declare r jsonb; begin
 r:=api.kb_catalogue_identifier_v1('{"page_size":50,"category":"journals","identifier":"10.000/hydration"}');
 assert (r->>'total')::int=120 and jsonb_array_length(r->'rows')=50,'Material identifier pages preserve duplicate counts';
 assert (select last_value from pg_temp.catalogue_hydrations)=50,'50-row identifier page hydrates exactly 50 bodies';
end $$;
reset role;
rollback;

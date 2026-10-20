-- Preserve fast privileged source TRUNCATE without per-row projection deletion/WAL.
-- Both source and derived TRUNCATE remain transactional and roll back together.
begin;
create or replace function private.kb_catalogue_journal_sync_v1() returns trigger
language plpgsql security definer set search_path=pg_catalog as $$
begin
 if tg_op='TRUNCATE' then
   truncate table private.kb_catalogue_journal_search;
   return null;
 end if;
 if tg_op='DELETE' then
   delete from private.kb_catalogue_journal_search where id=old.id;
   return old;
 end if;
 if tg_op='UPDATE' and old.id<>new.id then
   delete from private.kb_catalogue_journal_search where id=old.id;
 end if;
 insert into private.kb_catalogue_journal_search(id,search_text)
 values(new.id,private.kb_catalogue_journal_text_v1(new.title,new.doi,new.journal,new.authors,new.date,new.abstract))
 on conflict(id) do update set search_text=excluded.search_text;
 return new;
end $$;
commit;

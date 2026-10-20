-- Populated prior-chain upgrade: derived search text must cover exactly the
-- retained source identities, without rewriting their metadata or identities.
do $$ begin
 assert not exists(
  select 1 from public.journals j full join private.kb_catalogue_journal_search s on s.id=j.id
  where j.id is null or s.id is null or s.search_text is distinct from
   private.kb_catalogue_journal_text_v1(j.title,j.doi,j.journal,j.authors,j.date,j.abstract)
 ), 'Search backfill exactly matches populated source rows';
end $$;

-- Populated prior-chain upgrade: derived search text must cover exactly the
-- retained source identities, without rewriting their metadata or identities.
do $$ begin
 assert not exists(
  select 1 from public.journals j full join private.kb_catalogue_journal_search s on s.id=j.id
  where j.id is null or s.id is null or s.search_text is distinct from
   private.kb_catalogue_journal_text_v1(j.title,j.doi,j.journal,j.authors,j.date,j.abstract)
 ), 'Search backfill exactly matches populated source rows';
end $$;
do $$ begin
 assert not exists(
  select 1 from private.kb_catalogue_journal_search s
   full join private.kb_catalogue_journal_short_filter f using(id)
  where s.id is null or f.id is null
   or f.signature is distinct from private.kb_catalogue_short_signature_v1(s.search_text)
 ), 'Short-filter backfill exactly covers retained projection rows';
end $$;

begin;

create table public.briefing_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  countries text[] not null check (cardinality(countries) > 0),
  topics text[] not null default '{}',
  industries text[] not null default '{}',
  people text[] not null default '{}',
  language text not null,
  perspective text not null,
  timezone text not null,
  delivery_time time not null default '07:00'
);
alter table public.briefing_preferences enable row level security;
revoke all on public.briefing_preferences from public, anon, authenticated;
grant select, insert, update on public.briefing_preferences to authenticated;
create policy own_preferences on public.briefing_preferences to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create function public.validate_briefing_timezone() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception 'Invalid time zone';
  end if;
  return new;
end $$;
create trigger validate_timezone before insert or update on public.briefing_preferences
for each row execute function public.validate_briefing_timezone();

-- An operator adds a row only after reviewing the source and the country/topic pair.
create table public.verified_coverage (
  country text not null, topic text not null, source_name text not null,
  evidence_url text not null check (evidence_url ~ '^https?://'),
  primary key(country, topic, source_name)
);
alter table public.verified_coverage enable row level security;
revoke all on public.verified_coverage from public, anon, authenticated;
grant select on public.verified_coverage to authenticated;
create policy read_coverage on public.verified_coverage for select to authenticated using (true);

create schema if not exists private;
-- One classification per article/country/topic, independent of industries and people.
create table private.article_classifications (
  article_id bigint references public.articles(id) on delete cascade,
  country text, topic text, industries text[] not null default '{}', people text[] not null default '{}',
  primary key(article_id,country,topic)
);
-- Each row is an editorially verified language/perspective variant.
create table private.reviewed_briefing_copy (
  article_id bigint references public.articles(id) on delete cascade,
  language text, perspective text, priority integer not null default 0,
  kind text not null check (kind in ('뉴스','정책 변경','통계','연구','기업 발표','인물 동향')),
  evidence_kind text not null check (evidence_kind in ('일반','연구 결과','확립된 지침','논란')),
  headline text not null check (btrim(headline) <> ''),
  facts text not null check (btrim(facts) <> ''),
  analysis text, claim text, claim_source text,
  check (claim is null or length(btrim(coalesce(claim_source,''))) > 0),
  primary key(article_id,language,perspective)
);
revoke all on private.reviewed_briefing_copy, private.article_classifications from public, anon, authenticated;
grant all on private.reviewed_briefing_copy, private.article_classifications, public.verified_coverage to service_role;

create table public.personalized_editions (
  user_id uuid references auth.users(id) on delete cascade,
  briefing_date date, items jsonb not null,
  primary key(user_id,briefing_date)
);
alter table public.personalized_editions enable row level security;
revoke all on public.personalized_editions from public, anon, authenticated;
grant select on public.personalized_editions to authenticated;
create policy own_editions on public.personalized_editions for select to authenticated
using (user_id = (select auth.uid()));

create function public.generate_personalized_edition() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p public.briefing_preferences;
  local_day date;
  result jsonb;
begin
  select * into strict p from public.briefing_preferences where user_id = auth.uid() for update;
  local_day := (now() at time zone p.timezone)::date;
  select coalesce(jsonb_agg(to_jsonb(candidate) order by priority desc, published_at desc, article_id), '[]')
  into result from (
    select a.id as article_id, a.published_at, a.source_name, a.source_url,
           r.headline,r.facts,r.analysis,r.claim,r.claim_source,r.kind,r.evidence_kind,r.priority
    from public.articles a join private.reviewed_briefing_copy r on r.article_id = a.id
    where r.language = p.language and r.perspective = p.perspective
      and a.published_at between now() - interval '24 hours' and now()
      and exists (
        select 1 from private.article_classifications c
        join public.verified_coverage v on (v.country,v.topic,v.source_name) = (c.country,c.topic,a.source_name)
        where c.article_id = a.id and c.country = any(p.countries)
          and (c.topic = any(p.topics) or c.industries && p.industries or c.people && p.people
               or cardinality(p.topics)+cardinality(p.industries)+cardinality(p.people)=0)
      )
    order by r.priority desc,a.published_at desc,a.id limit 30
  ) candidate;
  insert into public.personalized_editions values (p.user_id,local_day,result)
  on conflict (user_id,briefing_date) do update set items = excluded.items;
  return result;
end $$;
revoke all on function public.generate_personalized_edition() from public, anon;
grant execute on function public.generate_personalized_edition() to authenticated;
commit;

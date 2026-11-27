begin;

-- Preserve the title, Korean summary and source as shown in each dated edition.
create table public.briefing_news (
  briefing_id uuid not null references public.briefings(id) on delete cascade,
  position integer not null check (position > 0),
  title text not null check (length(trim(title)) > 0),
  summary_ko text not null check (length(trim(summary_ko)) > 0),
  source_url text not null check (source_url ~* '^https?://[^[:space:]]+$'),
  primary key (briefing_id, position)
);

alter table public.briefing_news enable row level security;
revoke all on table public.briefing_news from public, anon, authenticated;
grant select on table public.briefing_news to authenticated;
create policy "Read news in own briefings" on public.briefing_news
for select to authenticated using (
  exists (
    select 1 from public.briefings b
    where b.id = briefing_news.briefing_id and b.user_id = (select auth.uid())
  )
);
commit;

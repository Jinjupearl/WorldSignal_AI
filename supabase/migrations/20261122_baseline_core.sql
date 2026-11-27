-- =====================================================================
-- 20261122_baseline_core.sql — 기본 스키마 (저장소에 없던 부분)
-- 2026-11-27 운영 DB(WorldSignal_AI)에서 읽기 전용으로 조회한 구조를 그대로 옮김.
-- 차이: (1) 칠레 제목 키워드 필터 제거 (운영에도 2026-11-27 적용됨)
--       (2) anon·authenticated의 articles TRUNCATE/TRIGGER/REFERENCES 권한 제거
--       (3) save_daily_briefing 은 PR #2 방식(p_user_id 인자)으로, 이메일 고정 제거
-- 기사 130건 데이터와 cron 등록은 포함하지 않음 (cron은 supabase/cron/ 참고).
-- 빈 DB(DEV·로컬)에서 20261123 이전에 실행되는 파일입니다.
-- =====================================================================

begin;

create schema if not exists private;
create extension if not exists http with schema extensions;

-- 기사
create table public.articles (
  id                 bigint generated always as identity primary key,
  title              text not null,
  source_name        text not null,
  source_url         text not null unique,
  country_code       text not null check (country_code = any (array['KR', 'CL'])),
  published_at       timestamptz not null,
  collected_at       timestamptz not null default now(),
  source_description text
);
alter table public.articles enable row level security;
revoke all on public.articles from public, anon, authenticated;

-- 사용자별 브리핑 (기존 구조. 공통 발행본은 20261127의 daily_editions)
create table public.briefings (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id),
  briefing_date date not null,
  status        text not null default 'draft',
  generated_at  timestamptz,
  unique (user_id, briefing_date)
);
alter table public.briefings enable row level security;
revoke all on public.briefings from public, anon, authenticated;
grant select on public.briefings to authenticated;
create policy "Users can read their own briefings" on public.briefings
  for select to authenticated using (user_id = (select auth.uid()));

-- RSS 설명문 → 평문
create or replace function private.rss_plain_text(raw_text text)
returns text
language sql
immutable strict
set search_path = ''
as $$
  with decoded as (
    select replace(replace(replace(replace(replace(
             raw_text, '&amp;', '&'), '&lt;', '<'), '&gt;', '>'),
             '&quot;', '"'), '&#39;', '''') as body
  ),
  spaced as (
    select regexp_replace(body, '</?(p|div|br|li|td|h[1-6])\M[^>]*>', ' ', 'gi') as body
    from decoded
  ),
  stripped as (
    select regexp_replace(body, '</?[[:alpha:]][^>]*>', '', 'g') as body
    from spaced
  )
  select nullif(trim(regexp_replace(
           replace(replace(replace(body, '&nbsp;', ' '), '&#160;', ' '), chr(160), ' '),
           '[[:space:]]+', ' ', 'g')), '')
  from stripped;
$$;

-- 기존 국가별 수집기 (20261127 이후에는 private.collect_source 가 대체)
create or replace function private.collect_worldsignal_rss(p_country text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  feed_url text;
  publisher text;
  response_status integer;
  response_body text;
  feed_xml xml;
begin
  case p_country
    when 'KR' then
      publisher := '한국은행';
      feed_url := 'https://www.bok.or.kr/portal/bbs/B0000552/news.rss?menuNo=200690';
    when 'CL' then
      publisher := 'Diario Financiero';
      feed_url := 'https://www.df.cl/noticias/site/list/port/rss.xml';
    else
      raise exception '지원하지 않는 국가: %', p_country;
  end case;

  select status, content into response_status, response_body
  from extensions.http_get(feed_url);
  if response_status is distinct from 200 then
    raise exception '% RSS 응답 오류: HTTP %', publisher, response_status;
  end if;

  feed_xml := xmlparse(document response_body);
  if not coalesce(xpath_exists('/rss/channel/item', feed_xml), false) then
    raise exception '% RSS에서 기사 항목을 찾지 못했습니다', publisher;
  end if;

  insert into public.articles as a
    (title, source_name, source_url, country_code, published_at, source_description)
  select distinct on (trim(x.link))
         trim(x.title), publisher, trim(x.link), p_country,
         trim(x.pub_date)::timestamptz, nullif(trim(x.description), '')
  from xmltable('/rss/channel/item' passing feed_xml
         columns title       text path 'title',
                 link        text path 'link',
                 pub_date    text path 'pubDate',
                 description text path 'description') as x
  where trim(x.title) <> ''
    and trim(x.link) <> ''
    and trim(x.pub_date) <> ''
  order by trim(x.link), length(trim(x.description)) desc nulls last
  on conflict (source_url) do update
    set source_description = excluded.source_description
    where excluded.source_description is not null
      and a.source_description is distinct from excluded.source_description;
end;
$$;

-- 기존 후보 선정 (국가당 1건, 최근 24시간). 공통 발행본은 get_edition_candidates 사용
create or replace function public.get_briefing_candidates()
returns table (article_id bigint, country_code text, source_name text, title text,
               source_url text, published_at timestamptz, summary_input text)
language sql
stable
set search_path = ''
as $$
  with candidates as (
    select a.id, a.country_code, a.source_name, a.title, a.source_url, a.published_at,
           private.rss_plain_text(a.source_description) as summary_input
    from public.articles a
    where a.country_code in ('KR', 'CL')
      and a.published_at between now() - interval '24 hours' and now()
  )
  select distinct on (c.country_code)
         c.id, c.country_code, c.source_name, c.title, c.source_url, c.published_at, c.summary_input
  from candidates c
  where nullif(trim(c.summary_input), '') is not null
  order by c.country_code, c.published_at desc, c.id desc;
$$;

grant usage on schema private to service_role;
revoke execute on function private.rss_plain_text(text), private.collect_worldsignal_rss(text)
  from public, anon, authenticated;
grant execute on function private.rss_plain_text(text) to service_role;

commit;

-- save_daily_briefing 은 briefing_news 가 필요하므로 20261123 다음 파일에서 만듭니다:
-- supabase/migrations/20261123b_save_daily_briefing.sql

-- =====================================================================
-- 06_mvp_phase2.sql — WorldSignal AI Phase 2 (MVP: 공통 브리핑 + 07:00 이메일)
-- PR #2 스키마 위에 "추가만" 합니다. 기존 테이블(articles, briefings, 개인화 등)은 건드리지 않습니다.
--
-- 추가되는 것
--   sources            출처 목록·활성 여부·이용 조건 확인일 (수집기가 여기서 읽음)
--   job_runs           단계별 실행 기록 + 수집 건수 (성공했지만 0건인 상황을 드러냄)
--   daily_editions     날짜별 공통 발행본 1개 (draft → approved → published / withheld)
--   edition_items      발행본 항목 최대 8개, 핵심 최대 3개, URL은 기사에서 가져옴
--   subscriptions      수신 동의·확인·해지
--   email_deliveries   (발행본, 수신자)당 1건 → 중복 발송 방지, unknown 상태 보존
--
-- 실행 대상: 로컬 샌드박스 먼저. DEV 적용은 별도 승인 후.
-- 실행: docker exec -i supabase_db_worldsignal-sandbox psql -X -U postgres -d postgres \
--         -v ON_ERROR_STOP=1 < validation/06_mvp_phase2.sql
-- =====================================================================

begin;

-- 0. 실행 대상 확인: 사용자가 있는 DB(운영)에서는 중단 / PR #2 스키마가 아니면 중단
do $$ begin
  if (select count(*) from auth.users) > 0 then
    raise exception '중단: 사용자가 있는 DB입니다(운영 DB 보호). 로컬 샌드박스 또는 빈 DEV에서만 실행하세요';
  end if;
  if to_regprocedure('public.save_daily_briefing(uuid,jsonb)') is null then
    raise exception '중단: PR #2 기반 스키마가 아닙니다';
  end if;
  if to_regclass('public.daily_editions') is not null then
    raise exception '중단: 이미 적용된 DB입니다';
  end if;
end $$;

create extension if not exists http with schema extensions;
grant usage on schema private to service_role;

-- =====================================================================
-- 1. sources — 출처 관리
-- =====================================================================
create table public.sources (
  id               smallint generated always as identity primary key,
  code             text not null unique check (code ~ '^[a-z0-9_]+$'),
  name             text not null unique,      -- articles.source_name 과 같은 값
  country_code     text not null check (country_code in ('KR', 'CL')),
  language         text not null check (language in ('ko', 'es', 'en')),
  kind             text not null default 'rss' check (kind = 'rss'),
  feed_url         text check (feed_url ~* '^https://[^[:space:]]+$'),
  title_filter     text,                      -- 선택: 이 정규식에 맞는 제목만 저장. null이면 전부 저장
  active           boolean not null default false,
  terms_checked_on date,                      -- 이용 조건(수집·저장·AI 입력·재배포) 확인일
  terms_note       text,
  created_at       timestamptz not null default now(),
  check (not active or feed_url is not null)
);

insert into public.sources (name, code, country_code, language, feed_url, active, terms_note) values
  ('한국은행',          'bok',       'KR', 'ko', 'https://www.bok.or.kr/portal/bbs/B0000552/news.rss?menuNo=200690', true, '운영 중. 이용 조건 확인일 기록 필요'),
  ('Diario Financiero', 'df',        'CL', 'es', 'https://www.df.cl/noticias/site/list/port/rss.xml',               true, '운영 중. 이용 조건 확인일 기록 필요'),
  ('연합뉴스',          'yonhap',    'KR', 'ko', null, false, '피드 주소·이용 조건 확인 전'),
  ('한국경제',          'hankyung',  'KR', 'ko', null, false, '피드 주소·이용 조건 확인 전'),
  ('La Tercera',        'latercera', 'CL', 'es', null, false, '피드 주소·이용 조건 확인 전'),
  ('BioBioChile',       'biobio',    'CL', 'es', null, false, '피드 주소·이용 조건 확인 전'),
  ('칠레 중앙은행',     'bcentral',  'CL', 'es', null, false, '피드 주소·이용 조건 확인 전');

-- =====================================================================
-- 2. job_runs — 실행 기록 (운영자 전용)
-- =====================================================================
create table public.job_runs (
  id             bigint generated always as identity primary key,
  job            text not null check (job in ('collect', 'summarize', 'publish', 'send')),
  source_id      smallint references public.sources(id),
  edition_date   date,
  status         text not null default 'running'
                 check (status in ('running', 'succeeded', 'failed', 'skipped')),
  items_found    integer,
  items_inserted integer,
  error          text,
  meta           jsonb not null default '{}'::jsonb,
  started_at     timestamptz not null default now(),
  finished_at    timestamptz
);
create index job_runs_job_started_idx on public.job_runs (job, started_at desc);

-- =====================================================================
-- 3. 수집기 — sources 기반 + job_runs 기록
--    실패해도 예외를 밖으로 던지지 않고 job_runs에 failed로 남김 (cron "성공"에 가려지지 않게)
-- =====================================================================
create or replace function private.collect_source(p_source_id smallint)
returns void
language plpgsql
set search_path = ''
as $$
declare
  s               public.sources%rowtype;
  run_id          bigint;
  response_status integer;
  response_body   text;
  feed_xml        xml;
  n_found         integer;
  n_inserted      integer;
begin
  select * into strict s from public.sources where id = p_source_id;
  insert into public.job_runs (job, source_id) values ('collect', s.id) returning id into run_id;

  begin
    if not s.active then
      raise exception '비활성 출처: %', s.code;
    end if;

    select status, content into response_status, response_body
    from extensions.http_get(s.feed_url);
    if response_status is distinct from 200 then
      raise exception '% RSS 응답 오류: HTTP %', s.name, response_status;
    end if;

    feed_xml := xmlparse(document response_body);
    select count(*) into n_found
    from xmltable('/rss/channel/item' passing feed_xml columns t text path 'title') x;
    if n_found = 0 then
      raise exception '% RSS 항목 0건', s.name;
    end if;

    with ins as (
      insert into public.articles as a
        (title, source_name, source_url, country_code, published_at, source_description)
      select distinct on (trim(x.link))
             trim(x.title), s.name, trim(x.link), s.country_code,
             trim(x.pub_date)::timestamptz, nullif(trim(x.description), '')
      from xmltable('/rss/channel/item' passing feed_xml
             columns title       text path 'title',
                     link        text path 'link',
                     pub_date    text path 'pubDate',
                     description text path 'description') x
      where trim(x.title) <> ''
        and trim(x.link) <> ''
        and trim(x.pub_date) <> ''
        and (s.title_filter is null or x.title ~* s.title_filter)
      order by trim(x.link), length(trim(x.description)) desc nulls last
      on conflict (source_url) do update
        set source_description = excluded.source_description
        where excluded.source_description is not null
          and a.source_description is distinct from excluded.source_description
      returning (a.xmax = 0) as inserted
    )
    select count(*) filter (where inserted) into n_inserted from ins;

    update public.job_runs
       set status = 'succeeded', items_found = n_found, items_inserted = n_inserted, finished_at = now()
     where id = run_id;
  exception when others then
    update public.job_runs
       set status = 'failed', items_found = n_found, error = sqlerrm, finished_at = now()
     where id = run_id;
  end;
end;
$$;

create or replace function private.collect_all_sources()
returns void
language plpgsql
set search_path = ''
as $$
declare r record;
begin
  for r in select id from public.sources where active order by id loop
    perform private.collect_source(r.id);
  end loop;
end;
$$;

-- =====================================================================
-- 4. 공통 발행본
-- =====================================================================
-- 자료 구간: 전날 06:30 ~ 당일 06:30 (America/Santiago). 서머타임 날은 23/25시간.
create or replace function private.edition_window(
  p_date date, out window_start timestamptz, out window_end timestamptz)
language sql
stable
set search_path = ''
as $$
  select ((p_date - 1) + time '06:30') at time zone 'America/Santiago',
         (p_date + time '06:30') at time zone 'America/Santiago';
$$;

create table public.daily_editions (
  id           uuid primary key default gen_random_uuid(),
  edition_date date not null unique,
  window_start timestamptz not null,
  window_end   timestamptz not null,
  status       text not null default 'draft'
               check (status in ('draft', 'approved', 'published', 'withheld')),
  approved_at  timestamptz,
  published_at timestamptz,
  note         text,
  created_at   timestamptz not null default now(),
  check (window_end > window_start)
);

create table public.edition_items (
  edition_id     uuid not null references public.daily_editions(id),
  position       smallint not null check (position between 1 and 8),
  article_id     bigint not null references public.articles(id),
  country_code   text not null check (country_code in ('KR', 'CL')),
  title          text not null check (length(trim(title)) > 0),
  summary_ko     text not null check (length(trim(summary_ko)) > 0),
  why_it_matters text,
  importance     text not null default 'normal' check (importance in ('high', 'normal', 'low')),
  is_top         boolean not null default false,
  source_url     text not null check (source_url ~* '^https?://[^[:space:]]+$'),
  primary key (edition_id, position),
  unique (edition_id, article_id)
);

-- 발행 후 보존: 발행본은 되돌리거나 지울 수 없고, 초안이 아닌 발행본의 항목은 바꿀 수 없음
create or replace function private.protect_edition()
returns trigger
language plpgsql
set search_path = ''
as $$
declare eid uuid;
begin
  if tg_table_name = 'daily_editions' then
    if tg_op = 'DELETE' then
      if old.status = 'published' then
        raise exception '발행된 브리핑은 삭제할 수 없습니다';
      end if;
      return old;
    end if;
    if old.status = 'published' and (new.status <> 'published'
        or new.edition_date <> old.edition_date
        or new.window_start <> old.window_start
        or new.window_end <> old.window_end) then
      raise exception '발행된 브리핑은 바꿀 수 없습니다 (정정은 새 버전으로)';
    end if;
    return new;
  end if;

  -- edition_items
  if tg_op = 'INSERT' then eid := new.edition_id; else eid := old.edition_id; end if;
  if exists (select 1 from public.daily_editions e where e.id = eid and e.status <> 'draft') then
    raise exception '초안이 아닌 브리핑의 항목은 바꿀 수 없습니다';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger protect_daily_editions
  before update or delete on public.daily_editions
  for each row execute function private.protect_edition();
create trigger protect_edition_items
  before insert or update or delete on public.edition_items
  for each row execute function private.protect_edition();

-- 후보 기사: 자료 구간 안, 본문 요약 입력이 있는 기사만, 국가별로 번갈아 정렬
create or replace function public.get_edition_candidates(p_date date default null, p_limit integer default 30)
returns table (article_id bigint, country_code text, source_name text, title text,
               source_url text, published_at timestamptz, summary_input text)
language sql
stable
set search_path = ''
as $$
  with w as (
    select * from private.edition_window(coalesce(p_date, (now() at time zone 'America/Santiago')::date))
  ), c as (
    select a.id, a.country_code, a.source_name, a.title, a.source_url, a.published_at,
           private.rss_plain_text(a.source_description) as summary_input
      from public.articles a, w
     where a.published_at >= w.window_start
       and a.published_at <  w.window_end
  ), r as (
    select c.*, row_number() over (partition by c.country_code order by c.published_at desc, c.id desc) as rn
      from c
     where nullif(trim(c.summary_input), '') is not null
  )
  select r.id, r.country_code, r.source_name, r.title, r.source_url, r.published_at, r.summary_input
    from r
   order by r.rn, r.country_code, r.published_at desc
   limit least(greatest(coalesce(p_limit, 30), 1), 200);
$$;

-- 초안 저장: 같은 날짜 초안을 통째로 교체 (재시도해도 결과 동일)
create or replace function public.save_edition(p_date date, p_items jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  e    public.daily_editions%rowtype;
  w    record;
  item jsonb;
  pos  integer := 0;
  url  text;
  cc   text;
begin
  if p_date is null then
    raise exception '발행 날짜가 필요합니다';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception '항목은 배열이어야 합니다';
  end if;
  if jsonb_array_length(p_items) > 8 then
    raise exception '하루 최대 8개 이슈입니다 (%개 요청)', jsonb_array_length(p_items);
  end if;

  select * into w from private.edition_window(p_date);
  insert into public.daily_editions (edition_date, window_start, window_end)
  values (p_date, w.window_start, w.window_end)
  on conflict (edition_date) do nothing;

  select * into strict e from public.daily_editions where edition_date = p_date for update;
  if e.status <> 'draft' then
    raise exception '초안 상태에서만 저장할 수 있습니다 (현재 %)', e.status;
  end if;

  delete from public.edition_items where edition_id = e.id;

  for item in select value from jsonb_array_elements(p_items) loop
    pos := pos + 1;
    select a.source_url, a.country_code into url, cc
      from public.articles a
     where a.id = (item->>'article_id')::bigint
       and a.published_at >= e.window_start
       and a.published_at <  e.window_end;
    if not found then
      raise exception '자료 구간 밖이거나 없는 기사입니다: %', item->>'article_id';
    end if;

    insert into public.edition_items
      (edition_id, position, article_id, country_code, title, summary_ko,
       why_it_matters, importance, is_top, source_url)
    values
      (e.id, pos, (item->>'article_id')::bigint, cc, trim(item->>'title'), trim(item->>'summary_ko'),
       nullif(trim(item->>'why_it_matters'), ''), coalesce(item->>'importance', 'normal'),
       coalesce((item->>'is_top')::boolean, false), url);
  end loop;

  if (select count(*) from public.edition_items where edition_id = e.id and is_top) > 3 then
    raise exception '핵심 이슈는 최대 3개입니다';
  end if;

  return jsonb_build_object('edition_id', e.id, 'date', p_date, 'items', pos);
end;
$$;

-- 운영자 검토 후 승인 (06:30~06:50)
create or replace function public.approve_edition(p_date date)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update public.daily_editions d
     set status = 'approved', approved_at = now()
   where d.edition_date = p_date
     and d.status = 'draft'
     and exists (select 1 from public.edition_items i where i.edition_id = d.id);
  if not found then
    raise exception '% 승인 불가: 초안이 아니거나 항목이 0개입니다', p_date;
  end if;
end;
$$;

-- 발행 고정 (06:50)
create or replace function public.publish_edition(p_date date)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update public.daily_editions
     set status = 'published', published_at = now()
   where edition_date = p_date and status = 'approved';
  if not found then
    raise exception '% 발행 불가: 승인된 브리핑만 발행할 수 있습니다', p_date;
  end if;
end;
$$;

-- 보류 (검토 미완료·근거 부족). 과거 내용을 오늘 뉴스로 대체하지 않음
create or replace function public.withhold_edition(p_date date, p_note text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update public.daily_editions
     set status = 'withheld', note = p_note
   where edition_date = p_date and status in ('draft', 'approved');
  if not found then
    raise exception '% 보류 불가: 초안 또는 승인 상태가 아닙니다', p_date;
  end if;
end;
$$;

-- =====================================================================
-- 5. 구독 · 발송 기록
-- =====================================================================
create table public.subscriptions (
  user_id           uuid primary key references auth.users(id) on delete cascade,
  email             text not null check (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  opted_in          boolean not null default false,
  confirmed_at      timestamptz,
  unsubscribed_at   timestamptz,
  unsubscribe_token uuid not null default gen_random_uuid() unique,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create or replace function private.track_subscription_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  if new.opted_in is distinct from old.opted_in then
    new.unsubscribed_at := case when new.opted_in then null else now() end;
  end if;
  return new;
end;
$$;
create trigger track_subscription_change
  before update on public.subscriptions
  for each row execute function private.track_subscription_change();

create table public.email_deliveries (
  id                  uuid primary key default gen_random_uuid(),
  edition_id          uuid not null references public.daily_editions(id),
  user_id             uuid not null references auth.users(id),
  email               text not null,
  idempotency_key     text not null unique,     -- Resend Idempotency-Key 로 그대로 사용
  status              text not null default 'queued'
                      check (status in ('queued', 'sending', 'sent', 'unknown', 'failed', 'bounced', 'skipped')),
  provider_message_id text,
  attempts            smallint not null default 0,
  last_error          text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  sent_at             timestamptz,
  unique (edition_id, user_id)
);
create index email_deliveries_edition_status_idx on public.email_deliveries (edition_id, status);

-- 발행된 브리핑의 수신 대상 고정 (여러 번 호출해도 수신자당 1건)
create or replace function public.queue_edition_deliveries(p_date date)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  e public.daily_editions%rowtype;
  n integer;
begin
  select * into e from public.daily_editions where edition_date = p_date;
  if not found then
    raise exception '% 발행본이 없습니다', p_date;
  end if;
  if e.status <> 'published' then
    raise exception '발행된 브리핑만 발송할 수 있습니다 (현재 %)', e.status;
  end if;

  insert into public.email_deliveries (edition_id, user_id, email, idempotency_key)
  select e.id, s.user_id, s.email, 'worldsignal-' || to_char(p_date, 'YYYYMMDD') || '-' || s.user_id
    from public.subscriptions s
   where s.opted_in and s.confirmed_at is not null and s.unsubscribed_at is null
  on conflict (edition_id, user_id) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- 발송 직전: 수신 상태를 다시 확인하고(해지자는 skipped), 보낼 건만 sending으로 가져감
create or replace function public.claim_deliveries(p_edition_id uuid, p_limit integer default 50)
returns table (delivery_id uuid, to_email text, idem_key text)
language plpgsql
set search_path = ''
as $$
begin
  update public.email_deliveries d
     set status = 'skipped', last_error = '발송 직전 확인: 수신 해지 또는 미확인', updated_at = now()
   where d.edition_id = p_edition_id
     and d.status = 'queued'
     and not exists (select 1 from public.subscriptions s
                      where s.user_id = d.user_id and s.opted_in
                        and s.confirmed_at is not null and s.unsubscribed_at is null);

  return query
  with c as (
    select d.id from public.email_deliveries d
     where d.edition_id = p_edition_id and d.status = 'queued'
     order by d.created_at
     limit greatest(coalesce(p_limit, 50), 1)
     for update skip locked
  )
  update public.email_deliveries d
     set status = 'sending', attempts = d.attempts + 1, updated_at = now()
    from c
   where d.id = c.id
  returning d.id, d.email, d.idempotency_key;
end;
$$;

-- 발송 결과 기록. unknown(응답 불명확)은 자동 재발송 대상이 아님
create or replace function public.record_delivery_result(
  p_delivery_id uuid, p_status text, p_provider_message_id text default null, p_error text default null)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_status not in ('sent', 'unknown', 'failed', 'bounced') then
    raise exception '허용되지 않는 발송 결과: %', p_status;
  end if;
  update public.email_deliveries d
     set status = p_status,
         provider_message_id = coalesce(p_provider_message_id, d.provider_message_id),
         last_error = p_error,
         sent_at = case when p_status = 'sent' then now() else d.sent_at end,
         updated_at = now()
   where d.id = p_delivery_id
     and (d.status = 'sending' or (p_status = 'bounced' and d.status = 'sent'));
  if not found then
    raise exception '결과를 기록할 수 없는 상태입니다: %', p_delivery_id;
  end if;
end;
$$;

-- 명확히 실패(failed)한 건만 다시 대기열로. unknown은 공급자 확인 후 사람이 판단
create or replace function public.requeue_failed_deliveries(p_edition_id uuid, p_max_attempts integer default 3)
returns integer
language plpgsql
set search_path = ''
as $$
declare n integer;
begin
  update public.email_deliveries
     set status = 'queued', updated_at = now()
   where edition_id = p_edition_id and status = 'failed' and attempts < p_max_attempts;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- =====================================================================
-- 6. 권한 — Supabase 기본값(anon·authenticated 전체 허용)을 먼저 모두 회수하고 필요한 것만 허용
-- =====================================================================
alter table public.sources          enable row level security;
alter table public.job_runs         enable row level security;
alter table public.daily_editions   enable row level security;
alter table public.edition_items    enable row level security;
alter table public.subscriptions    enable row level security;
alter table public.email_deliveries enable row level security;

revoke all on public.sources, public.job_runs, public.daily_editions, public.edition_items,
              public.subscriptions, public.email_deliveries
  from public, anon, authenticated;
grant all on public.sources, public.job_runs, public.daily_editions, public.edition_items,
             public.subscriptions, public.email_deliveries
  to service_role;
grant usage, select on sequence public.job_runs_id_seq, public.sources_id_seq to service_role;

-- 로그인 사용자: 발행된 브리핑만 읽기
grant select on public.daily_editions, public.edition_items to authenticated;
create policy read_published_editions on public.daily_editions
  for select to authenticated using (status = 'published');
create policy read_published_items on public.edition_items
  for select to authenticated using (exists (
    select 1 from public.daily_editions e
     where e.id = edition_items.edition_id and e.status = 'published'));

-- 로그인 사용자: 본인 구독 정보 읽기 + 수신 동의(opted_in)만 변경
grant select on public.subscriptions to authenticated;
grant update (opted_in) on public.subscriptions to authenticated;
create policy read_own_subscription on public.subscriptions
  for select to authenticated using (user_id = (select auth.uid()));
create policy update_own_subscription on public.subscriptions
  for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- 함수: 서버(service_role)만 실행. 트리거 함수는 직접 호출 불가
revoke execute on function
  private.collect_source(smallint), private.collect_all_sources(),
  private.edition_window(date), private.protect_edition(), private.track_subscription_change(),
  public.get_edition_candidates(date, integer), public.save_edition(date, jsonb),
  public.approve_edition(date), public.publish_edition(date), public.withhold_edition(date, text),
  public.queue_edition_deliveries(date), public.claim_deliveries(uuid, integer),
  public.record_delivery_result(uuid, text, text, text), public.requeue_failed_deliveries(uuid, integer)
  from public, anon, authenticated;
grant execute on function
  private.collect_source(smallint), private.collect_all_sources(), private.edition_window(date),
  public.get_edition_candidates(date, integer), public.save_edition(date, jsonb),
  public.approve_edition(date), public.publish_edition(date), public.withhold_edition(date, text),
  public.queue_edition_deliveries(date), public.claim_deliveries(uuid, integer),
  public.record_delivery_result(uuid, text, text, text), public.requeue_failed_deliveries(uuid, integer)
  to service_role;

commit;

-- =====================================================================
-- (DEV 적용 때만) 예약 수집 — 샌드박스에서는 실행하지 않음
-- 기존 운영 DB의 cron 2개(collect-bank-of-korea-rss, collect-diario-financiero-rss)를 대체
-- =====================================================================
-- create extension if not exists pg_cron;
-- select cron.schedule('collect-all-sources', '0 * * * *', $c$select private.collect_all_sources()$c$);

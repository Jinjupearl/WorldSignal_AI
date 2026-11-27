-- 사용자별 브리핑에 기사 추가 (기존 구조). 운영 DB 버전에서 이메일 고정을 p_user_id 인자로 바꿈.
-- 서버(service_role)만 실행. 같은 기사는 같은 브리핑에 한 번만 저장.
begin;

-- 운영 DB에 있는 고유 제약 (같은 브리핑에 같은 URL 한 번만)
alter table public.briefing_news
  add constraint briefing_news_briefing_id_source_url_key unique (briefing_id, source_url);

create or replace function public.save_daily_briefing(p_user_id uuid, p_articles jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  daily_id uuid;
  daily_status text;
  local_day date := (now() at time zone 'America/Santiago')::date;
  item jsonb;
  article_url text;
  next_position integer;
  added integer := 0;
begin
  if p_user_id is null then
    raise exception '사용자가 필요합니다';
  end if;
  if jsonb_typeof(p_articles) is distinct from 'array' then
    raise exception '기사 목록은 배열이어야 합니다';
  end if;
  if jsonb_array_length(p_articles) = 0 then
    return jsonb_build_object('date', local_day, 'added', 0);
  end if;

  insert into public.briefings (id, user_id, briefing_date, status, generated_at)
  values (gen_random_uuid(), p_user_id, local_day, 'draft', now())
  on conflict (user_id, briefing_date) do nothing;

  select id, status into strict daily_id, daily_status
  from public.briefings
  where user_id = p_user_id and briefing_date = local_day
  for update;

  if daily_status is distinct from 'draft' then
    raise exception '초안 상태인 브리핑에만 기사를 추가할 수 있습니다';
  end if;

  select coalesce(max(position), 0) + 1 into next_position
  from public.briefing_news where briefing_id = daily_id;

  for item in select value from jsonb_array_elements(p_articles) loop
    select a.source_url into strict article_url
    from public.articles a where a.id = (item->>'article_id')::bigint;

    if nullif(trim(item->>'title'), '') is null or nullif(trim(item->>'summary_ko'), '') is null then
      raise exception '기사 제목 또는 한국어 요약이 비어 있습니다';
    end if;

    insert into public.briefing_news (briefing_id, position, title, summary_ko, source_url)
    values (daily_id, next_position, trim(item->>'title'), trim(item->>'summary_ko'), article_url)
    on conflict (briefing_id, source_url) do nothing;

    if found then
      added := added + 1;
      next_position := next_position + 1;
    end if;
  end loop;

  return jsonb_build_object('date', local_day, 'briefing_id', daily_id, 'added', added);
end;
$$;

revoke execute on function public.save_daily_briefing(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.save_daily_briefing(uuid, jsonb) to service_role;
revoke execute on function public.get_briefing_candidates() from public, anon, authenticated;
grant execute on function public.get_briefing_candidates() to service_role;

commit;

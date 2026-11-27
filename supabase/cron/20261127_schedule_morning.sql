-- =====================================================================
-- 아침 예약 실행 (DEV → 검증 후 운영). Phase 2 마이그레이션 적용 후 실행.
-- Vercel Hobby cron은 하루 1회·±59분이라 07:00 정시 발송에 쓸 수 없어서,
-- Supabase pg_cron이 5분마다 /api/jobs/tick 을 호출하고 앱이 칠레 현지 시각으로 할 일을 정합니다.
-- (서머타임 UTC-3/UTC-4 모두 덮도록 UTC 09:00~12:55 사이에 실행)
-- =====================================================================

-- 1) 비밀값을 Vault에 저장 (한 번만. <> 부분을 실제 값으로 바꿔서 실행)
-- select vault.create_secret('https://<your-app>.vercel.app/api/jobs/tick', 'worldsignal_tick_url');
-- select vault.create_secret('<JOB_SECRET 값>', 'worldsignal_job_secret');

-- 2) 호출 함수
create or replace function private.call_morning_tick()
returns void
language plpgsql
set search_path = ''
as $$
declare
  tick_url text;
  job_secret text;
  resp_status integer;
  resp_body text;
begin
  select decrypted_secret into tick_url from vault.decrypted_secrets where name = 'worldsignal_tick_url';
  select decrypted_secret into job_secret from vault.decrypted_secrets where name = 'worldsignal_job_secret';
  if tick_url is null or job_secret is null then
    raise exception 'Vault 비밀값(worldsignal_tick_url / worldsignal_job_secret)이 없습니다';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '115');
  select status, content into resp_status, resp_body
  from extensions.http((
    'POST', tick_url,
    array[extensions.http_header('x-job-secret', job_secret)],
    'application/json', '{}'
  )::extensions.http_request);

  if resp_status is distinct from 200 then
    -- cron.job_run_details 에 실패로 남음
    raise exception 'tick 실패 HTTP %: %', resp_status, left(resp_body, 500);
  end if;
end;
$$;
revoke execute on function private.call_morning_tick() from public, anon, authenticated;

-- 3) 예약 등록
--    기존 06시 한정 수집 2개는 매시간 전체 출처 수집으로 교체
select cron.unschedule('collect-bank-of-korea-rss')     where exists (select 1 from cron.job where jobname = 'collect-bank-of-korea-rss');
select cron.unschedule('collect-diario-financiero-rss') where exists (select 1 from cron.job where jobname = 'collect-diario-financiero-rss');
select cron.schedule('collect-all-sources', '0 * * * *',    $c$select private.collect_all_sources()$c$);
select cron.schedule('morning-tick',        '*/5 9-12 * * *', $c$select private.call_morning_tick()$c$);

-- 확인
-- select jobname, schedule, active from cron.job;
-- select j.jobname, d.status, d.start_time, d.return_message
--   from cron.job_run_details d join cron.job j using (jobid) order by d.start_time desc limit 20;

-- =====================================================================
-- 07_phase2_tests.sql — Phase 2 (공통 브리핑 + 이메일) 테스트
-- LOCAL SANDBOX ONLY. 06_mvp_phase2.sql 적용 후 실행. 모든 테스트 데이터는 ROLLBACK.
--
-- 실행: docker exec -i supabase_db_worldsignal-sandbox psql -X -U postgres -d postgres \
--         -v ON_ERROR_STOP=1 < validation/07_phase2_tests.sql
-- 테스트 날짜: 2030-01-15 (실제 데이터와 겹치지 않는 날짜)
-- 사용자 A=...0001(수신 동의) B=...0002(미동의) C=...0003(수신 동의 → 발송 직전 해지)
-- =====================================================================

BEGIN;
SET LOCAL TIME ZONE 'UTC';

DO $$ BEGIN
  IF (SELECT count(*) FROM auth.users) <> 0 THEN
    RAISE EXCEPTION 'P0 중단: 사용자가 있는 DB입니다 — 로컬 샌드박스에서만 실행';
  END IF;
  IF to_regclass('public.daily_editions') IS NULL THEN
    RAISE EXCEPTION 'P0 중단: 06_mvp_phase2.sql을 먼저 적용하세요';
  END IF;
  RAISE NOTICE 'OK   P0 로컬 샌드박스 + Phase 2 스키마 확인';
END $$;

-- ---------------------------------------------------------------------
-- P1 출처 목록 + 06:30 마감 구간 (서머타임 포함)
-- ---------------------------------------------------------------------
DO $$
DECLARE w record; hrs numeric;
BEGIN
  IF (SELECT count(*) FROM public.sources) <> 7 OR (SELECT count(*) FROM public.sources WHERE active) <> 2 THEN
    RAISE EXCEPTION 'FAIL P1 출처 목록: 전체 7개, 활성 2개여야 함';
  END IF;

  SELECT * INTO w FROM private.edition_window('2026-11-27');
  IF w.window_start <> '2026-11-26 09:30+00' OR w.window_end <> '2026-11-27 09:30+00' THEN
    RAISE EXCEPTION 'FAIL P1 2026-11-27 자료 구간이 다름: % ~ %', w.window_start, w.window_end;
  END IF;

  SELECT * INTO w FROM private.edition_window('2026-04-05');
  hrs := extract(epoch FROM w.window_end - w.window_start) / 3600;
  IF hrs <> 25 THEN RAISE EXCEPTION 'FAIL P1 서머타임 종료일(2026-04-05) 구간 %시간 (25시간이어야 함)', hrs; END IF;

  SELECT * INTO w FROM private.edition_window('2026-09-06');
  hrs := extract(epoch FROM w.window_end - w.window_start) / 3600;
  IF hrs <> 23 THEN RAISE EXCEPTION 'FAIL P1 서머타임 시작일(2026-09-06) 구간 %시간 (23시간이어야 함)', hrs; END IF;

  RAISE NOTICE 'PASS P1 출처 7개(활성 2) + 06:30 마감 구간, 서머타임 23·25시간';
END $$;

-- ---------------------------------------------------------------------
-- 테스트 데이터
-- ---------------------------------------------------------------------
INSERT INTO auth.users(id) VALUES
  ('00000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-000000000003');

-- 2030-01-15 자료 구간 = 2030-01-14 09:30Z ~ 2030-01-15 09:30Z
INSERT INTO public.articles(title, source_name, source_url, country_code, published_at, source_description) VALUES
  ('kr1',    'fixture', 'https://example.invalid/kr1',    'KR', '2030-01-15 01:00+00', '한국 기사 설명'),
  ('cl1',    'fixture', 'https://example.invalid/cl1',    'CL', '2030-01-15 02:00+00', 'descripcion cl1'),
  ('cl2',    'fixture', 'https://example.invalid/cl2',    'CL', '2030-01-15 03:00+00', 'descripcion cl2'),
  ('cl3',    'fixture', 'https://example.invalid/cl3',    'CL', '2030-01-15 04:00+00', 'descripcion cl3'),
  ('late',   'fixture', 'https://example.invalid/late',   'CL', '2030-01-15 10:00+00', '마감 이후 기사'),
  ('notext', 'fixture', 'https://example.invalid/notext', 'KR', '2030-01-15 05:00+00', null);

INSERT INTO public.subscriptions(user_id, email, opted_in, confirmed_at) VALUES
  ('00000000-0000-0000-0000-000000000001', 'a@example.invalid', true,  now()),
  ('00000000-0000-0000-0000-000000000002', 'b@example.invalid', false, null),
  ('00000000-0000-0000-0000-000000000003', 'c@example.invalid', true,  now());

-- ---------------------------------------------------------------------
-- P2 후보 기사 · P3 초안 저장 (서버 = service_role)
-- ---------------------------------------------------------------------
SET LOCAL ROLE service_role;

DO $$
DECLARE got text[]; first2 text[];
BEGIN
  SELECT array_agg(c.title ORDER BY c.ord), (array_agg(c.title ORDER BY c.ord))[1:2]
    INTO got, first2
    FROM public.get_edition_candidates('2030-01-15', 30)
         WITH ORDINALITY AS c(article_id, country_code, source_name, title, source_url, published_at, summary_input, ord);
  IF got IS NULL OR NOT (got @> ARRAY['kr1','cl1','cl2','cl3'] AND cardinality(got) = 4) THEN
    RAISE EXCEPTION 'FAIL P2 후보가 다름: % (kr1·cl1·cl2·cl3만 있어야 함)', got;
  END IF;
  IF NOT (first2 @> ARRAY['kr1','cl3']) THEN
    RAISE EXCEPTION 'FAIL P2 국가별 번갈아 정렬 실패: 앞 2개 %', first2;
  END IF;
  RAISE NOTICE 'PASS P2 후보: 구간 밖·본문 없는 기사 제외, 한국·칠레 번갈아 정렬';
END $$;

DO $$
DECLARE r jsonb; kr bigint; cl1 bigint; cl2 bigint; cl3 bigint; late bigint; two jsonb;
BEGIN
  SELECT id INTO kr   FROM public.articles WHERE source_url = 'https://example.invalid/kr1';
  SELECT id INTO cl1  FROM public.articles WHERE source_url = 'https://example.invalid/cl1';
  SELECT id INTO cl2  FROM public.articles WHERE source_url = 'https://example.invalid/cl2';
  SELECT id INTO cl3  FROM public.articles WHERE source_url = 'https://example.invalid/cl3';
  SELECT id INTO late FROM public.articles WHERE source_url = 'https://example.invalid/late';

  two := jsonb_build_array(
    jsonb_build_object('article_id', kr,  'title', '한국 이슈', 'summary_ko', '요약 1', 'importance', 'high', 'is_top', true),
    jsonb_build_object('article_id', cl1, 'title', '칠레 이슈', 'summary_ko', '요약 2', 'why_it_matters', '의미'));

  r := public.save_edition('2030-01-15', two);
  IF (r->>'items')::int <> 2 THEN RAISE EXCEPTION 'FAIL P3 저장 결과: %', r; END IF;
  r := public.save_edition('2030-01-15', two);   -- 재시도
  IF (SELECT count(*) FROM public.edition_items i JOIN public.daily_editions e ON e.id = i.edition_id
       WHERE e.edition_date = '2030-01-15') <> 2 THEN
    RAISE EXCEPTION 'FAIL P3 재시도 후 항목 수가 2가 아님';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.edition_items WHERE source_url = 'https://example.invalid/kr1' AND country_code = 'KR') THEN
    RAISE EXCEPTION 'FAIL P3 원문 URL·국가가 기사에서 채워지지 않음';
  END IF;

  BEGIN
    PERFORM public.save_edition('2030-01-15',
      (SELECT jsonb_agg(jsonb_build_object('article_id', kr, 'title', 'x', 'summary_ko', 'x')) FROM generate_series(1, 9)));
    RAISE EXCEPTION 'FAIL P3 9개 이슈가 허용됨' USING ERRCODE = 'XX000';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;

  BEGIN
    PERFORM public.save_edition('2030-01-15',
      jsonb_build_array(jsonb_build_object('article_id', late, 'title', 'x', 'summary_ko', 'x')));
    RAISE EXCEPTION 'FAIL P3 마감 이후 기사가 허용됨' USING ERRCODE = 'XX000';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;

  BEGIN
    PERFORM public.save_edition('2030-01-15', jsonb_build_array(
      jsonb_build_object('article_id', kr,  'title', 'x', 'summary_ko', 'x', 'is_top', true),
      jsonb_build_object('article_id', cl1, 'title', 'x', 'summary_ko', 'x', 'is_top', true),
      jsonb_build_object('article_id', cl2, 'title', 'x', 'summary_ko', 'x', 'is_top', true),
      jsonb_build_object('article_id', cl3, 'title', 'x', 'summary_ko', 'x', 'is_top', true)));
    RAISE EXCEPTION 'FAIL P3 핵심 이슈 4개가 허용됨' USING ERRCODE = 'XX000';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;

  IF (SELECT count(*) FROM public.edition_items i JOIN public.daily_editions e ON e.id = i.edition_id
       WHERE e.edition_date = '2030-01-15') <> 2 THEN
    RAISE EXCEPTION 'FAIL P3 거부된 저장 시도가 기존 초안을 바꿈';
  END IF;
  RAISE NOTICE 'PASS P3 초안 저장·재시도 동일, 9개·마감 이후·핵심 4개 거부';
END $$;

-- ---------------------------------------------------------------------
-- P4 초안은 사용자에게 안 보임 + 사용자는 운영 함수 실행 불가
-- ---------------------------------------------------------------------
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.daily_editions) OR EXISTS (SELECT 1 FROM public.edition_items) THEN
    RAISE EXCEPTION 'FAIL P4 초안이 로그인 사용자에게 보임';
  END IF;
  BEGIN
    PERFORM public.save_edition('2030-01-15', '[]'::jsonb);
    RAISE EXCEPTION 'FAIL P4 사용자가 save_edition 실행' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.approve_edition('2030-01-15');
    RAISE EXCEPTION 'FAIL P4 사용자가 approve_edition 실행' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM public.get_edition_candidates('2030-01-15', 5);
    RAISE EXCEPTION 'FAIL P4 사용자가 후보 기사 조회' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'PASS P4 초안 비공개, 사용자 운영 함수 실행 차단';
END $$;

-- ---------------------------------------------------------------------
-- P5 승인 → 발행 순서, 발행 후 보존
-- ---------------------------------------------------------------------
RESET ROLE;
SET LOCAL ROLE service_role;

DO $$ BEGIN
  BEGIN
    PERFORM public.queue_edition_deliveries('2030-01-15');
    RAISE EXCEPTION 'FAIL P5 발행 전 발송 대기열 생성됨' USING ERRCODE = 'XX000';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  BEGIN
    PERFORM public.publish_edition('2030-01-15');
    RAISE EXCEPTION 'FAIL P5 승인 없이 발행됨' USING ERRCODE = 'XX000';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;

  PERFORM public.approve_edition('2030-01-15');
  PERFORM public.publish_edition('2030-01-15');

  BEGIN
    UPDATE public.edition_items SET title = '몰래 변경'
     WHERE edition_id = (SELECT id FROM public.daily_editions WHERE edition_date = '2030-01-15');
    RAISE EXCEPTION 'FAIL P5 발행 후 항목 수정됨' USING ERRCODE = 'XX000';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  BEGIN
    UPDATE public.daily_editions SET status = 'draft' WHERE edition_date = '2030-01-15';
    RAISE EXCEPTION 'FAIL P5 발행본이 초안으로 되돌아감' USING ERRCODE = 'XX000';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  BEGIN
    DELETE FROM public.daily_editions WHERE edition_date = '2030-01-15';
    RAISE EXCEPTION 'FAIL P5 발행본이 삭제됨' USING ERRCODE = 'XX000';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  BEGIN
    PERFORM public.save_edition('2030-01-15', '[]'::jsonb);
    RAISE EXCEPTION 'FAIL P5 발행 후 초안 저장 허용' USING ERRCODE = 'XX000';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  RAISE NOTICE 'PASS P5 승인 → 발행 순서 강제, 발행본 수정·되돌리기·삭제 차단';
END $$;

-- 발행 후: 로그인 사용자는 보임, 비로그인은 안 보임
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
DO $$ BEGIN
  IF (SELECT count(*) FROM public.daily_editions WHERE edition_date = '2030-01-15') <> 1
     OR (SELECT count(*) FROM public.edition_items) <> 2 THEN
    RAISE EXCEPTION 'FAIL P5 발행본이 로그인 사용자에게 보이지 않음';
  END IF;
END $$;

RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
DO $$
DECLARE n integer;
BEGIN
  BEGIN
    SELECT count(*) INTO n FROM public.edition_items;
    IF n <> 0 THEN RAISE EXCEPTION 'FAIL P5 비로그인 사용자가 발행본 조회' USING ERRCODE = 'XX000'; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'PASS P5b 발행본: 로그인 사용자만 조회';
END $$;

-- ---------------------------------------------------------------------
-- P6 발송 대기열 · 중복 발송 방지 · 발송 직전 해지 · unknown 보존
-- ---------------------------------------------------------------------
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
DECLARE n integer;
BEGIN
  n := public.queue_edition_deliveries('2030-01-15');
  IF n <> 2 THEN RAISE EXCEPTION 'FAIL P6 대기열 %건 (수신 동의 A·C 2건이어야 함)', n; END IF;
  n := public.queue_edition_deliveries('2030-01-15');
  IF n <> 0 OR (SELECT count(*) FROM public.email_deliveries) <> 2 THEN
    RAISE EXCEPTION 'FAIL P6 대기열 재실행 시 중복 생성';
  END IF;
  RAISE NOTICE 'PASS P6a 수신 동의자만 대기열, 재실행해도 수신자당 1건';
END $$;

-- C가 웹에서 수신 해지 (본인 opted_in만 변경 가능)
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
DO $$
DECLARE n integer;
BEGIN
  IF (SELECT count(*) FROM public.subscriptions) <> 1 THEN
    RAISE EXCEPTION 'FAIL P7 다른 사용자의 구독 정보가 보임';
  END IF;
  UPDATE public.subscriptions SET opted_in = false WHERE user_id = auth.uid();
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'FAIL P7 본인 수신 해지 실패'; END IF;

  BEGIN
    UPDATE public.subscriptions SET email = 'evil@example.invalid' WHERE user_id = auth.uid();
    RAISE EXCEPTION 'FAIL P7 사용자가 이메일 주소를 직접 변경' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  UPDATE public.subscriptions SET opted_in = false WHERE user_id = '00000000-0000-0000-0000-000000000001';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 0 THEN RAISE EXCEPTION 'FAIL P7 다른 사용자의 수신 상태 변경'; END IF;

  BEGIN
    PERFORM 1 FROM public.email_deliveries;
    RAISE EXCEPTION 'FAIL P7 사용자가 발송 기록 조회' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.job_runs;
    RAISE EXCEPTION 'FAIL P7 사용자가 운영 로그 조회' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.sources;
    RAISE EXCEPTION 'FAIL P7 사용자가 출처 설정 조회' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'PASS P7 본인 수신 해지만 가능, 이메일·타인 변경 차단, 발송 기록·로그·출처 비공개';
END $$;

RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
DECLARE eid uuid; n integer; did uuid;
BEGIN
  SELECT id INTO eid FROM public.daily_editions WHERE edition_date = '2030-01-15';

  IF (SELECT unsubscribed_at FROM public.subscriptions WHERE user_id = '00000000-0000-0000-0000-000000000003') IS NULL THEN
    RAISE EXCEPTION 'FAIL P6 해지 시각이 기록되지 않음';
  END IF;

  SELECT count(*), min(c.delivery_id::text)::uuid INTO n, did FROM public.claim_deliveries(eid, 50) c;
  IF n <> 1 THEN RAISE EXCEPTION 'FAIL P6 발송 대상 %건 (해지한 C 제외 1건이어야 함)', n; END IF;
  IF (SELECT status FROM public.email_deliveries WHERE user_id = '00000000-0000-0000-0000-000000000003') <> 'skipped' THEN
    RAISE EXCEPTION 'FAIL P6 발송 직전 해지자가 skipped 처리되지 않음';
  END IF;

  PERFORM public.record_delivery_result(did, 'unknown', null, 'timeout');
  SELECT count(*) INTO n FROM public.claim_deliveries(eid, 50);
  IF n <> 0 THEN RAISE EXCEPTION 'FAIL P6 unknown 건이 다시 발송 대상으로 잡힘'; END IF;
  n := public.requeue_failed_deliveries(eid);
  IF n <> 0 THEN RAISE EXCEPTION 'FAIL P6 unknown 건이 재발송 대기열로 돌아감'; END IF;

  BEGIN
    PERFORM public.record_delivery_result(did, 'sent', 'msg_1', null);
    RAISE EXCEPTION 'FAIL P6 sending이 아닌 건에 결과 기록됨' USING ERRCODE = 'XX000';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  RAISE NOTICE 'PASS P6b 발송 직전 해지자 제외, unknown은 자동 재발송 안 함, 잘못된 상태 전이 차단';
END $$;

-- ---------------------------------------------------------------------
-- P8 수집 실패가 job_runs에 남는지 (네트워크 없이)
-- P8b 실제 피드 수집 (네트워크가 되면 확인, 안 되면 참고만)
-- ---------------------------------------------------------------------
RESET ROLE;
DO $$
DECLARE j record;
BEGIN
  PERFORM private.collect_source((SELECT id FROM public.sources WHERE code = 'yonhap'));
  SELECT * INTO j FROM public.job_runs ORDER BY id DESC LIMIT 1;
  IF j.status <> 'failed' OR j.error NOT LIKE '%비활성%' OR j.finished_at IS NULL THEN
    RAISE EXCEPTION 'FAIL P8 수집 실패가 기록되지 않음: % / %', j.status, j.error;
  END IF;
  RAISE NOTICE 'PASS P8 수집 실패 → 예외 없이 job_runs에 failed + 사유 기록';

  PERFORM private.collect_source((SELECT id FROM public.sources WHERE code = 'df'));
  SELECT * INTO j FROM public.job_runs ORDER BY id DESC LIMIT 1;
  IF j.status = 'succeeded' THEN
    RAISE NOTICE 'PASS P8b Diario Financiero 실제 수집: 피드 %건, 신규 저장 %건', j.items_found, j.items_inserted;
  ELSE
    RAISE NOTICE '참고 P8b 실제 수집 실패(네트워크일 수 있음): %', j.error;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- P9 새 함수 실행 권한: anon·authenticated 모두 불가
-- ---------------------------------------------------------------------
DO $$
DECLARE f text; ro text; bad text := '';
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'private.collect_source(smallint)', 'private.collect_all_sources()', 'private.edition_window(date)',
    'public.get_edition_candidates(date,integer)', 'public.save_edition(date,jsonb)',
    'public.approve_edition(date)', 'public.publish_edition(date)', 'public.withhold_edition(date,text)',
    'public.queue_edition_deliveries(date)', 'public.claim_deliveries(uuid,integer)',
    'public.record_delivery_result(uuid,text,text,text)', 'public.requeue_failed_deliveries(uuid,integer)']
  LOOP
    FOREACH ro IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF has_function_privilege(ro, f, 'EXECUTE') THEN
        bad := bad || format(E'\n   %s → %s', ro, f);
      END IF;
    END LOOP;
    IF NOT has_function_privilege('service_role', f, 'EXECUTE') THEN
      bad := bad || format(E'\n   service_role 실행 불가 → %s', f);
    END IF;
  END LOOP;
  IF bad <> '' THEN RAISE EXCEPTION 'FAIL P9 함수 권한 문제:%', bad; END IF;
  RAISE NOTICE 'PASS P9 운영 함수는 service_role만 실행';
  RAISE NOTICE '=== Phase 2 테스트 모두 통과 — 이제 ROLLBACK ===';
END $$;

ROLLBACK;

-- 원상 복구 확인. 기대값: auth_users 0 / editions 0 / deliveries 0 / subscriptions 0 / job_runs 0 / sources 7 / checksum_ok t
SELECT
  (SELECT count(*) FROM auth.users) AS auth_users,
  (SELECT count(*) FROM public.daily_editions) AS editions,
  (SELECT count(*) FROM public.email_deliveries) AS deliveries,
  (SELECT count(*) FROM public.subscriptions) AS subscriptions,
  (SELECT count(*) FROM public.job_runs) AS job_runs,
  (SELECT count(*) FROM public.sources) AS sources,
  (SELECT md5(string_agg(to_jsonb(a)::text, chr(10) ORDER BY id)) FROM public.articles a)
    = 'dc0b82aaabe67384d1df6acff6ace4bc' AS checksum_ok;

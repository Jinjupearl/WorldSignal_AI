-- =====================================================================
-- 05_core_tests.sql — WorldSignal AI 핵심 보안·무결성 테스트 9개
-- LOCAL SANDBOX ONLY. 모든 테스트 데이터는 마지막 ROLLBACK으로 제거됩니다.
--
-- 실행:
--   docker exec -i supabase_db_worldsignal-sandbox psql -X -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 < validation/05_core_tests.sql
--
-- 결과 읽는 법: 'PASS Tn' 줄이 차례로 나오고 마지막에 '9개 테스트 모두 통과'가 나오면 성공.
--             'FAIL Tn ...' 이 나오면 그 지점에서 멈추고 자동으로 전부 취소됩니다.
-- 사용자 A = 00000000-0000-0000-0000-000000000001
-- 사용자 B = 00000000-0000-0000-0000-000000000002
-- =====================================================================

BEGIN;
SET LOCAL TIME ZONE 'UTC';

-- T0 실행 대상 확인 — 로컬 샌드박스(사용자 0명 + 기사 130건 체크섬 일치)가 아니면 중단
DO $$ BEGIN
  IF (SELECT count(*) FROM auth.users) <> 0 THEN
    RAISE EXCEPTION 'T0 중단: auth.users가 비어 있지 않음 — 로컬 샌드박스가 아닐 수 있습니다';
  END IF;
  IF (SELECT md5(string_agg(to_jsonb(a)::text, chr(10) ORDER BY id)) FROM public.articles a)
     IS DISTINCT FROM 'dc0b82aaabe67384d1df6acff6ace4bc' THEN
    RAISE EXCEPTION 'T0 중단: 기사 체크섬 불일치';
  END IF;
  RAISE NOTICE 'OK   T0 로컬 샌드박스 확인';
END $$;

-- ---------------------------------------------------------------------
-- 테스트 데이터 (04 테스트와 같은 구성)
-- ---------------------------------------------------------------------
INSERT INTO auth.users(id) VALUES
  ('00000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000002');
INSERT INTO public.articles(title, source_name, source_url, country_code, published_at)
  VALUES ('fixture', 'fixture', 'https://example.invalid/fixture', 'KR', now());
INSERT INTO public.verified_coverage VALUES ('KR', 'economy', 'fixture', 'https://example.invalid');
INSERT INTO private.article_classifications(article_id, country, topic)
  SELECT id, 'KR', 'economy' FROM public.articles WHERE source_name = 'fixture';
INSERT INTO private.reviewed_briefing_copy(article_id, language, perspective, kind, evidence_kind, headline, facts)
  SELECT id, 'ko', 'neutral', '뉴스', '일반', 'fixture', 'fixture' FROM public.articles WHERE source_name = 'fixture';
INSERT INTO public.briefings(user_id, briefing_date) VALUES
  ('00000000-0000-0000-0000-000000000001', current_date),
  ('00000000-0000-0000-0000-000000000002', current_date);
INSERT INTO public.briefing_news(briefing_id, position, title, summary_ko, source_url)
  SELECT id, 1, user_id::text, 'fixture', 'https://example.invalid' FROM public.briefings;

-- ---------------------------------------------------------------------
-- 사용자 A 로그인 → T3 RPC 호출, T6a 개인화 브리핑 중복 방지
-- ---------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
INSERT INTO public.briefing_preferences(user_id, countries, language, perspective, timezone)
  VALUES (auth.uid(), ARRAY['KR'], 'ko', 'neutral', 'UTC');

DO $$ BEGIN
  IF auth.uid() IS DISTINCT FROM '00000000-0000-0000-0000-000000000001'::uuid THEN
    RAISE EXCEPTION '준비 실패: A 로그인 설정이 적용되지 않음';
  END IF;

  -- T3 공개·내부 RPC 정상 호출
  IF jsonb_array_length(public.generate_personalized_edition()) <> 1 THEN
    RAISE EXCEPTION 'FAIL T3 공개 RPC 결과가 1건이 아님';
  END IF;
  -- 내부 함수는 ZIP 부트스트랩 구조에만 있음 (저장소 PR #2는 public 함수 하나가 DEFINER)
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'private' AND p.proname = 'generate_personalized_edition_internal') THEN
    IF jsonb_array_length(private.generate_personalized_edition_internal()) <> 1 THEN
      RAISE EXCEPTION 'FAIL T3 내부 RPC 결과가 1건이 아님';
    END IF;
  ELSE
    PERFORM public.generate_personalized_edition();
    RAISE NOTICE '참고 T3 내부 함수 없음(저장소 구조) — 공개 RPC만 확인';
  END IF;
  RAISE NOTICE 'PASS T3 공개·내부 RPC 정상 호출';

  -- T6a 같은 날짜 개인화 브리핑 재생성 → 1건 유지
  PERFORM public.generate_personalized_edition();
  IF (SELECT count(*) FROM public.personalized_editions) <> 1 THEN
    RAISE EXCEPTION 'FAIL T6 같은 날짜 개인화 브리핑이 중복 생성됨';
  END IF;
  RAISE NOTICE 'PASS T6a 같은 날짜 3회 생성 → 1건 유지';
END $$;

-- ---------------------------------------------------------------------
-- 사용자 B 로그인 → T1(B→A 조회 차단), B 데이터 생성
-- ---------------------------------------------------------------------
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}', true);

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.briefing_preferences)
     OR EXISTS (SELECT 1 FROM public.personalized_editions) THEN
    RAISE EXCEPTION 'FAIL T1 B가 A의 관심사·개인화 브리핑을 조회함';
  END IF;
  IF (SELECT count(*) FROM public.briefings) <> 1
     OR EXISTS (SELECT 1 FROM public.briefings WHERE user_id <> auth.uid()) THEN
    RAISE EXCEPTION 'FAIL T1 B가 A의 briefings를 조회함';
  END IF;
  IF (SELECT count(*) FROM public.briefing_news) <> 1 THEN
    RAISE EXCEPTION 'FAIL T1 B가 A의 briefing_news를 조회함';
  END IF;
END $$;

INSERT INTO public.briefing_preferences(user_id, countries, language, perspective, timezone)
  VALUES (auth.uid(), ARRAY['CL'], 'ko', 'neutral', 'UTC');
DO $$ BEGIN PERFORM public.generate_personalized_edition(); END $$;

-- ---------------------------------------------------------------------
-- 다시 사용자 A → T1(A→B 조회 차단), T2(타인 명의 쓰기 차단), T7(시간대), T5, T8a
-- ---------------------------------------------------------------------
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}', true);

DO $$
DECLARE n integer;
BEGIN
  -- T1 A→B 조회 차단
  IF (SELECT count(*) FROM public.briefing_preferences) <> 1
     OR EXISTS (SELECT 1 FROM public.briefing_preferences WHERE user_id <> auth.uid()) THEN
    RAISE EXCEPTION 'FAIL T1 A가 B의 관심사를 조회함';
  END IF;
  IF (SELECT count(*) FROM public.personalized_editions) <> 1
     OR EXISTS (SELECT 1 FROM public.personalized_editions WHERE user_id <> auth.uid()) THEN
    RAISE EXCEPTION 'FAIL T1 A가 B의 개인화 브리핑을 조회함';
  END IF;
  IF (SELECT count(*) FROM public.briefings) <> 1
     OR (SELECT count(*) FROM public.briefing_news) <> 1 THEN
    RAISE EXCEPTION 'FAIL T1 A가 B의 briefings 또는 briefing_news를 조회함';
  END IF;
  RAISE NOTICE 'PASS T1 A↔B 양방향 조회 차단';

  -- T2 타인 user_id로 쓰기 차단
  BEGIN
    INSERT INTO public.briefing_preferences(user_id, countries, language, perspective, timezone)
      VALUES ('00000000-0000-0000-0000-000000000002', ARRAY['KR'], 'ko', 'neutral', 'UTC');
    RAISE EXCEPTION 'FAIL T2 A가 B 명의로 관심사를 등록함' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  UPDATE public.briefing_preferences SET language = 'en'
   WHERE user_id = '00000000-0000-0000-0000-000000000002';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 0 THEN RAISE EXCEPTION 'FAIL T2 A가 B의 관심사를 수정함 (%건)', n; END IF;

  -- 삭제는 권한 자체가 없거나(권한 거부), 있더라도 RLS로 0건이어야 통과
  BEGIN
    DELETE FROM public.briefing_preferences
     WHERE user_id = '00000000-0000-0000-0000-000000000002';
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n <> 0 THEN
      RAISE EXCEPTION 'FAIL T2 A가 B의 관심사를 삭제함 (%건)', n USING ERRCODE = 'XX000';
    END IF;
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE '참고 T2 authenticated에는 briefing_preferences DELETE 권한 자체가 없음 (차단으로 인정)';
  END;

  BEGIN
    UPDATE public.briefing_preferences SET user_id = '00000000-0000-0000-0000-000000000002'
     WHERE user_id = auth.uid();
    RAISE EXCEPTION 'FAIL T2 A가 자기 관심사의 소유자를 B로 바꿈' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    INSERT INTO public.personalized_editions(user_id, briefing_date, items)
      VALUES ('00000000-0000-0000-0000-000000000002', current_date + 1, '[]');
    RAISE EXCEPTION 'FAIL T2 A가 personalized_editions에 직접 쓰기 가능' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    INSERT INTO public.briefings(user_id, briefing_date)
      VALUES ('00000000-0000-0000-0000-000000000002', current_date + 1);
    RAISE EXCEPTION 'FAIL T2 A가 briefings에 직접 쓰기 가능' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    INSERT INTO public.briefing_news(briefing_id, position, title, summary_ko, source_url)
      SELECT id, 9, 'x', 'x', 'https://example.invalid/x' FROM public.briefings LIMIT 1;
    RAISE EXCEPTION 'FAIL T2 A가 briefing_news에 직접 쓰기 가능' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'PASS T2 타인 명의 등록·수정·삭제·소유자 변경, 발행 테이블 직접 쓰기 차단';

  -- T7 잘못된 시간대 차단 / 정상 시간대 허용
  BEGIN
    UPDATE public.briefing_preferences SET timezone = 'Invalid/Zone' WHERE user_id = auth.uid();
    RAISE EXCEPTION 'FAIL T7 잘못된 시간대가 저장됨' USING ERRCODE = 'XX000';
  EXCEPTION WHEN raise_exception OR invalid_parameter_value OR check_violation THEN NULL;
  END;
  UPDATE public.briefing_preferences SET timezone = 'America/Santiago' WHERE user_id = auth.uid();
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'FAIL T7 정상 시간대(America/Santiago)가 거부됨'; END IF;
  RAISE NOTICE 'PASS T7 잘못된 시간대 차단, 정상 시간대 허용';

  -- T5 로그인 사용자의 private 테이블 접근 차단
  BEGIN
    PERFORM 1 FROM private.reviewed_briefing_copy;
    RAISE EXCEPTION 'FAIL T5 로그인 사용자가 private.reviewed_briefing_copy 조회' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM private.article_classifications;
    RAISE EXCEPTION 'FAIL T5 로그인 사용자가 private.article_classifications 조회' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- T8a 일반 사용자는 save_daily_briefing 실행 불가
  BEGIN
    PERFORM public.save_daily_briefing(auth.uid(), '[]'::jsonb);
    RAISE EXCEPTION 'FAIL T8 로그인 사용자가 save_daily_briefing 실행' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

-- ---------------------------------------------------------------------
-- 비로그인(anon) → T4 RPC 차단, T5 private 차단, 직접 조회 차단
-- ---------------------------------------------------------------------
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);

DO $$
DECLARE n integer;
BEGIN
  BEGIN
    PERFORM public.generate_personalized_edition();
    RAISE EXCEPTION 'FAIL T4 비로그인 사용자가 공개 RPC 실행' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  IF EXISTS (SELECT 1 FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'private' AND p.proname = 'generate_personalized_edition_internal') THEN
    BEGIN
      PERFORM private.generate_personalized_edition_internal();
      RAISE EXCEPTION 'FAIL T4 비로그인 사용자가 내부 RPC 실행' USING ERRCODE = 'XX000';
    EXCEPTION
      WHEN insufficient_privilege THEN NULL;
      WHEN raise_exception THEN
        RAISE NOTICE '참고 T4 anon이 내부 함수까지 도달했지만 함수 안에서 차단됨 → EXECUTE 권한 회수 권장';
    END;
  END IF;

  BEGIN
    PERFORM public.save_daily_briefing('00000000-0000-0000-0000-000000000001', '[]'::jsonb);
    RAISE EXCEPTION 'FAIL T4 비로그인 사용자가 save_daily_briefing 실행' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- 직접 조회: 권한 거부 또는 0건이어야 함
  BEGIN
    SELECT (SELECT count(*) FROM public.briefings) + (SELECT count(*) FROM public.briefing_news) INTO n;
    IF n <> 0 THEN RAISE EXCEPTION 'FAIL T4 비로그인 사용자가 브리핑 %건 조회', n USING ERRCODE = 'XX000'; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    SELECT (SELECT count(*) FROM public.briefing_preferences) + (SELECT count(*) FROM public.personalized_editions) INTO n;
    IF n <> 0 THEN RAISE EXCEPTION 'FAIL T4 비로그인 사용자가 개인 데이터 %건 조회', n USING ERRCODE = 'XX000'; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'PASS T4 비로그인 RPC·직접 조회 차단';

  BEGIN
    PERFORM 1 FROM private.reviewed_briefing_copy;
    RAISE EXCEPTION 'FAIL T5 비로그인 사용자가 private 테이블 조회' USING ERRCODE = 'XX000';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'PASS T5 private 테이블 접근 차단 (로그인·비로그인 모두)';
END $$;

-- ---------------------------------------------------------------------
-- service_role → T8 save_daily_briefing 저장·URL 확인, T6b 같은 기사 중복 저장 방지
-- ---------------------------------------------------------------------
RESET ROLE;
SET LOCAL ROLE service_role;

DO $$
DECLARE r jsonb; aid bigint; items jsonb;
BEGIN
  SELECT id INTO STRICT aid FROM public.articles WHERE source_name = 'fixture';
  items := jsonb_build_array(jsonb_build_object(
    'article_id', aid, 'title', 'fixture headline', 'summary_ko', '픽스처 한국어 요약'));

  r := public.save_daily_briefing('00000000-0000-0000-0000-000000000001', items);
  IF coalesce((r->>'added')::int, -1) <> 1 THEN
    RAISE EXCEPTION 'FAIL T8 service_role 저장 결과가 예상과 다름: %', r;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.briefing_news bn JOIN public.briefings b ON b.id = bn.briefing_id
     WHERE b.user_id = '00000000-0000-0000-0000-000000000001'
       AND bn.source_url = 'https://example.invalid/fixture'
       AND bn.title = 'fixture headline') THEN
    RAISE EXCEPTION 'FAIL T8 기사 URL(article_url)이 briefing_news에 저장되지 않음';
  END IF;
  RAISE NOTICE 'PASS T8 service_role 실행 성공 + URL 저장 확인 (일반·비로그인 사용자 차단은 위에서 확인)';

  r := public.save_daily_briefing('00000000-0000-0000-0000-000000000001', items);
  IF coalesce((r->>'added')::int, -1) <> 0 THEN
    RAISE EXCEPTION 'FAIL T6 같은 기사가 같은 브리핑에 다시 저장됨: %', r;
  END IF;
  IF (SELECT count(*) FROM public.briefing_news bn JOIN public.briefings b ON b.id = bn.briefing_id
       WHERE b.user_id = '00000000-0000-0000-0000-000000000001'
         AND bn.source_url = 'https://example.invalid/fixture') <> 1 THEN
    RAISE EXCEPTION 'FAIL T6 briefing_news에 같은 URL이 2건 이상';
  END IF;
  RAISE NOTICE 'PASS T6b 같은 기사 재저장 → 추가 0건';
END $$;

-- ---------------------------------------------------------------------
-- 관리자(postgres) → B 데이터 무손상 확인, T9 테이블 권한 점검
-- ---------------------------------------------------------------------
RESET ROLE;

DO $$
DECLARE r record; bad text := '';
BEGIN
  -- T2 보강: A의 시도 이후에도 B 데이터가 그대로인지
  IF (SELECT count(*) FROM public.briefing_preferences
       WHERE user_id = '00000000-0000-0000-0000-000000000002'
         AND language = 'ko' AND countries = ARRAY['CL']) <> 1 THEN
    RAISE EXCEPTION 'FAIL T2 B의 관심사가 변경 또는 삭제됨';
  END IF;

  -- T9 anon·authenticated에 불필요한 권한이 없는지 (운영 DB에서 TRUNCATE 권한 발견)
  FOR r IN
    SELECT format('%I.%I', n.nspname, c.relname) AS tbl, ro.role, pv.priv
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     CROSS JOIN unnest(ARRAY['anon', 'authenticated']) AS ro(role)
     CROSS JOIN unnest(ARRAY['TRUNCATE', 'TRIGGER', 'REFERENCES']) AS pv(priv)
     WHERE n.nspname IN ('public', 'private') AND c.relkind = 'r'
  LOOP
    IF has_table_privilege(r.role, r.tbl, r.priv) THEN
      bad := bad || format(E'\n   %s → %s %s', r.role, r.tbl, r.priv);
    END IF;
  END LOOP;

  -- 사용자가 직접 쓰면 안 되는 테이블 (briefing_preferences만 본인 쓰기 허용)
  FOR r IN
    SELECT t.tbl, ro.role, pv.priv
      FROM unnest(ARRAY['public.articles', 'public.briefings', 'public.briefing_news',
                        'public.personalized_editions', 'public.verified_coverage',
                        'private.article_classifications', 'private.reviewed_briefing_copy']) AS t(tbl)
     CROSS JOIN unnest(ARRAY['anon', 'authenticated']) AS ro(role)
     CROSS JOIN unnest(ARRAY['INSERT', 'UPDATE', 'DELETE']) AS pv(priv)
  LOOP
    IF has_table_privilege(r.role, r.tbl, r.priv) THEN
      bad := bad || format(E'\n   %s → %s %s', r.role, r.tbl, r.priv);
    END IF;
  END LOOP;

  -- 비로그인 사용자는 개인 데이터 테이블에 어떤 권한도 없어야 함
  IF has_table_privilege('anon', 'public.briefing_preferences', 'SELECT,INSERT,UPDATE,DELETE') THEN
    bad := bad || E'\n   anon → public.briefing_preferences (읽기 또는 쓰기)';
  END IF;

  IF bad <> '' THEN
    RAISE EXCEPTION 'FAIL T9 불필요한 테이블 권한 발견:%', bad;
  END IF;
  RAISE NOTICE 'PASS T9 anon·authenticated 테이블 권한 최소화 확인';
  RAISE NOTICE '=== 9개 테스트 모두 통과 — 이제 ROLLBACK으로 테스트 데이터를 지웁니다 ===';
END $$;

ROLLBACK;

-- ---------------------------------------------------------------------
-- T9 원상 복구 확인 (ROLLBACK 이후)
-- 기대값: auth_users 0 / articles 130 / checksum_ok t / test_rows 0
-- 참고: 기사 ID 시퀀스는 ROLLBACK해도 되돌아가지 않아 다음 ID가 1 늘어납니다(로컬 전용이라 무해).
-- ---------------------------------------------------------------------
SELECT
  (SELECT count(*) FROM auth.users) AS auth_users,
  (SELECT count(*) FROM public.articles) AS articles,
  (SELECT md5(string_agg(to_jsonb(a)::text, chr(10) ORDER BY id)) FROM public.articles a)
    = 'dc0b82aaabe67384d1df6acff6ace4bc' AS checksum_ok,
  (SELECT count(*) FROM public.briefings)
  + (SELECT count(*) FROM public.briefing_news)
  + (SELECT count(*) FROM public.briefing_preferences)
  + (SELECT count(*) FROM public.personalized_editions)
  + (SELECT count(*) FROM public.verified_coverage)
  + (SELECT count(*) FROM private.article_classifications)
  + (SELECT count(*) FROM private.reviewed_briefing_copy) AS test_rows;

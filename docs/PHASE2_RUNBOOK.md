# WorldSignal AI — Phase 2 실행 안내 (공통 브리핑 + 07:00 이메일)

## 하루 흐름 (America/Santiago)

| 시각 | 하는 일 | 담당 |
|---|---|---|
| 매시 정각 | 활성 출처 전체 수집 → `job_runs`에 건수 기록 | pg_cron `collect-all-sources` |
| 06:30 | 후보(전날 06:30~당일 06:30) → AI 요약 → 초안 저장 → 운영자에게 검토 메일 | `/api/jobs/tick` |
| 06:30~06:50 | 운영자가 원문과 대조 후 메일의 링크에서 **승인하고 발행** | 운영자 |
| 07:00~ | 발행본이 있으면 수신 동의자에게 발송 (수신자당 1건, 발송 직전 해지 확인) | `/api/jobs/tick` |

- pg_cron이 UTC 09:00~12:55 사이 5분마다 tick을 호출하고, 앱이 칠레 시각을 보고 할 일을 정합니다 (서머타임 자동 대응).
- 모든 단계는 여러 번 호출돼도 결과가 같습니다 (초안은 날짜당 1개, 발송은 수신자당 1건).
- 승인이 07:00을 넘기면 승인 직후 다음 tick(최대 5분 뒤)에 발송됩니다. 12:00 이후에는 아무것도 하지 않습니다.
- 응답이 불명확한 발송은 `unknown`으로 남고 자동 재발송하지 않습니다. Resend 대시보드에서 확인 후 판단합니다.

## 처음 설정 순서

1. **Resend**: 발신 도메인 추가 → DNS(SPF·DKIM) 등록 → Verified 확인 → API 키 발급
2. **OpenAI**: API 키 발급, 사용 한도 설정, 사용할 모델 이름 결정 (`OPENAI_MODEL`)
3. **Supabase (DEV 먼저)**
   - PR #2 부트스트랩 → `supabase/migrations/20261127_phase2_common_edition.sql`
   - 샌드박스 테스트: `supabase/tests/05_core_tests.sql`, `07_phase2_tests.sql`
4. **Vercel 환경 변수**: `.env.example`의 서버 전용 값 입력 (`SUPABASE_SERVICE_ROLE_KEY`는 절대 `NEXT_PUBLIC_` 금지)
5. **구독 등록** (본인): Supabase SQL Editor에서
   ```sql
   insert into public.subscriptions (user_id, email, opted_in, confirmed_at)
   select id, email, true, now() from auth.users where email = '<본인 이메일>';
   ```
6. **수동 시험** (예약 전에 먼저):
   ```bash
   curl -X POST "$SITE_URL/api/jobs/tick" -H "x-job-secret: $JOB_SECRET" \
     -H 'Content-Type: application/json' -d '{"action":"build","date":"YYYY-MM-DD"}'
   # 검토 메일의 링크로 승인 후
   curl -X POST "$SITE_URL/api/jobs/tick" -H "x-job-secret: $JOB_SECRET" \
     -H 'Content-Type: application/json' -d '{"action":"send","date":"YYYY-MM-DD"}'
   ```
7. **예약 등록**: `supabase/cron/20261127_schedule_morning.sql` (Vault에 tick 주소·JOB_SECRET 저장 후)

## 데모 모드
`AUTO_APPROVE=true`면 06:30 초안을 검토 없이 바로 발행합니다. 본인 수신 확인용으로만 쓰고, 초대 사용자에게 보내기 전에는 `false`로 되돌립니다.

## 확인할 곳
```sql
select job, edition_date, status, items_found, items_inserted, error, started_at
  from public.job_runs order by id desc limit 20;
select edition_date, status, approved_at, published_at from public.daily_editions order by edition_date desc;
select status, count(*) from public.email_deliveries group by 1;
```

## 마이그레이션 순서 (빈 DEV 기준)
1. `20261122_baseline_core.sql` — articles·briefings·수집기 (운영 DB 구조를 옮김, 칠레 필터·TRUNCATE 권한 정리)
2. `20261123_briefing_news.sql`
3. `20261123b_save_daily_briefing.sql` — URL 고유 제약 + 사용자 인자 방식
4. `20261124_personalization.sql` (PR #2)
5. `20261127_phase2_common_edition.sql`
6. 테스트: `supabase/tests/05_core_tests.sql`, `07_phase2_tests.sql`
   (05의 T0는 기사 130건 체크섬을 확인하므로, 기사를 옮기지 않은 DB에서는 그 검사만 빼고 실행)

## 알려진 한계 (다음 단계)
- **ZIP 부트스트랩과 저장소 PR #2가 다릅니다.** ZIP은 개인화 함수를 public 래퍼(INVOKER) + `private.generate_personalized_edition_internal`(DEFINER)로 나눴고,
  저장소는 `public.generate_personalized_edition` 하나가 DEFINER입니다. DEV에는 한쪽만 기준으로 적용해야 합니다 (권장: 저장소).
  테스트 05는 두 구조 모두에서 동작합니다.
- 기사 130건 데이터는 마이그레이션에 포함하지 않았습니다. DEV에 필요하면 ZIP의 데이터 부분만 따로 넣습니다.
- Phase 2 마이그레이션의 첫 검사(사용자가 있는 DB면 중단)는 운영 DB 보호용입니다. 운영 적용 때는 별도 승인 후 대상 확인 방식으로 바꿉니다.
- 사건 묶기(issues)·주장 근거(summary_claims)는 Phase 4 범위입니다.

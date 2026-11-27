import 'server-only'
import { adminDb } from './supabase'
import { env } from './env'
import { summarize, type Candidate } from './summarize'
import { renderBriefing, sendEmail, type EmailItem } from './email'
import { approvalUrl } from './approval'
import { at, santiagoNow } from './time'

type Result = Record<string, unknown>

async function rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await adminDb().rpc(fn, args)
  if (error) throw new Error(`${fn}: ${error.message}`)
  return data as T
}

async function getEdition(date: string) {
  const { data, error } = await adminDb().from('daily_editions')
    .select('id, edition_date, status').eq('edition_date', date).maybeSingle()
  if (error) throw new Error(`daily_editions 조회: ${error.message}`)
  return data as { id: string; edition_date: string; status: string } | null
}

async function getItems(editionId: string): Promise<EmailItem[]> {
  const { data, error } = await adminDb().from('edition_items')
    .select('position, country_code, title, summary_ko, why_it_matters, importance, is_top, source_url')
    .eq('edition_id', editionId).order('position')
  if (error) throw new Error(`edition_items 조회: ${error.message}`)
  return data as EmailItem[]
}

// ---------------------------------------------------------------------------
// 06:30 초안 만들기: 후보 → AI 요약 → save_edition → (데모) 자동 승인 또는 운영자 검토 메일
// ---------------------------------------------------------------------------
export async function buildEdition(date: string): Promise<Result> {
  const db = adminDb()
  if (await getEdition(date)) return { build: 'exists' }

  // 동시 실행 방지: 같은 날짜 요약이 이미 성공했거나 5분 안에 시작된 게 있으면 건너뜀
  const since = new Date(Date.now() - 5 * 60_000).toISOString()
  const { data: recent, error: recentError } = await db.from('job_runs').select('status, started_at')
    .eq('job', 'summarize').eq('edition_date', date).in('status', ['succeeded', 'running'])
  if (recentError) throw new Error(`job_runs 조회: ${recentError.message}`)
  if (recent?.some(r => r.status === 'succeeded' || r.started_at >= since)) return { build: 'in-progress-or-done' }

  const { data: run, error: runError } = await db.from('job_runs')
    .insert({ job: 'summarize', edition_date: date }).select('id').single()
  if (runError) throw new Error(`job_runs 시작 기록: ${runError.message}`)
  const finish = (status: string, fields: Result = {}) =>
    db.from('job_runs').update({ status, finished_at: new Date().toISOString(), ...fields }).eq('id', run.id)

  try {
    const candidates = await rpc<Candidate[]>('get_edition_candidates', { p_date: date, p_limit: 30 })
    if (!candidates?.length) {
      await finish('skipped', { items_found: 0, error: '자료 구간에 후보 기사가 없습니다' })
      return { build: 'no-candidates' }
    }
    const { items, usage, model } = await summarize(candidates)
    if (!items.length) {
      await finish('skipped', { items_found: candidates.length, items_inserted: 0, error: 'AI가 선택한 이슈가 없습니다', meta: { model, usage } })
      return { build: 'no-items', candidates: candidates.length }
    }
    await rpc('save_edition', { p_date: date, p_items: items })
    await finish('succeeded', { items_found: candidates.length, items_inserted: items.length, meta: { model, usage } })

    if (env.autoApprove()) {
      await rpc('approve_edition', { p_date: date })
      await rpc('publish_edition', { p_date: date })
      await db.from('job_runs').insert({ job: 'publish', edition_date: date, status: 'succeeded',
        finished_at: new Date().toISOString(), meta: { mode: 'auto_approve' } })
      return { build: 'published-auto', items: items.length }
    }

    const edition = await getEdition(date)
    const draft = await getItems(edition!.id)
    const link = approvalUrl(date)
    const { html, text } = renderBriefing(date, draft,
      `<b>검토용 초안입니다.</b> 원문과 대조한 뒤 <a href="${link}">여기서 승인·발행</a>하세요. 06:50까지 승인하지 않으면 발송되지 않습니다.`,
      `검토용 초안입니다. 승인·발행: ${link}`)
    const review = await sendEmail({ to: env.operatorEmail(), subject: `[검토] ${date} WorldSignal 초안 ${draft.length}건`,
      html, text, idempotencyKey: `worldsignal-review-${date}` })
    return { build: 'draft', items: items.length, reviewEmail: review.status }
  } catch (e) {
    await finish('failed', { error: (e as Error).message.slice(0, 1000) })
    throw e
  }
}

// ---------------------------------------------------------------------------
// 07:00 발송: 발행본 확인 → 대기열 → (발송 직전 수신 상태 재확인) → Resend → 결과 기록
// ---------------------------------------------------------------------------
export async function sendEdition(date: string): Promise<Result> {
  const db = adminDb()
  const edition = await getEdition(date)
  if (!edition) return { send: 'no-edition' }
  if (edition.status !== 'published') return { send: `not-published (${edition.status})` }

  const queued = await rpc<number>('queue_edition_deliveries', { p_date: date })
  const items = await getItems(edition.id)
  const counts = { sent: 0, failed: 0, unknown: 0 }

  for (let round = 0; round < 20; round++) {
    const batch = await rpc<{ delivery_id: string; to_email: string; idem_key: string }[]>(
      'claim_deliveries', { p_edition_id: edition.id, p_limit: 20 })
    if (!batch?.length) break

    const { data: rows } = await db.from('email_deliveries').select('id, user_id').in('id', batch.map(b => b.delivery_id))
    const { data: subs } = await db.from('subscriptions').select('user_id, unsubscribe_token')
      .in('user_id', (rows ?? []).map(r => r.user_id))
    const tokenByDelivery = new Map((rows ?? []).map(r => [r.id, subs?.find(s => s.user_id === r.user_id)?.unsubscribe_token]))

    for (const d of batch) {
      const unsubscribeUrl = `${env.siteUrl()}/unsubscribe?token=${tokenByDelivery.get(d.delivery_id) ?? ''}`
      const { html, text } = renderBriefing(date, items,
        `수신을 원하지 않으면 <a href="${unsubscribeUrl}">수신 해지</a>하세요.`, `수신 해지: ${unsubscribeUrl}`)
      const result = await sendEmail({ to: d.to_email, subject: `${date} WorldSignal 아침 브리핑`,
        html, text, idempotencyKey: d.idem_key, unsubscribeUrl })
      counts[result.status]++
      await rpc('record_delivery_result', {
        p_delivery_id: d.delivery_id, p_status: result.status,
        p_provider_message_id: result.status === 'sent' ? result.id : null,
        p_error: result.status === 'sent' ? null : result.error,
      })
    }
  }

  const total = counts.sent + counts.failed + counts.unknown
  if (queued || total) {
    await db.from('job_runs').insert({ job: 'send', edition_date: date,
      status: counts.failed || counts.unknown ? 'failed' : 'succeeded',
      items_found: queued, items_inserted: counts.sent, finished_at: new Date().toISOString(), meta: counts })
  }
  return { send: 'done', queued, ...counts }
}

// ---------------------------------------------------------------------------
// pg_cron이 아침 시간대에 5분마다 호출. 칠레 현지 시각을 보고 할 일을 결정 (서머타임 자동 대응)
// 모든 단계가 여러 번 호출돼도 같은 결과가 나오도록 설계됨
// ---------------------------------------------------------------------------
export async function tick(now = new Date()): Promise<Result> {
  const { date, minutes } = santiagoNow(now)
  const out: Result = { date, local: `${String(Math.floor(minutes / 60)).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}` }
  if (minutes < at(6, 30) || minutes >= at(12, 0)) return { ...out, action: 'outside-window' }
  out.build = (await buildEdition(date)).build
  if (minutes >= at(7, 0)) Object.assign(out, await sendEdition(date))
  return out
}

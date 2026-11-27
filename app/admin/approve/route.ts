import { verifyApproval } from '@/lib/server/approval'
import { adminDb } from '@/lib/server/supabase'
import { isIsoDate } from '@/lib/server/time'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const page = (title: string, body: string, status = 200) => new Response(
  `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
  <meta name="robots" content="noindex"><title>${title}</title></head>
  <body style="font-family:system-ui;max-width:34rem;margin:10vh auto;padding:1rem;color:#19372f">
  <h1 style="font-size:1.4rem">${title}</h1>${body}</body></html>`,
  { status, headers: { 'Content-Type': 'text/html; charset=utf-8' } })

const esc = (s: string) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!))

// GET: 확인 화면만 보여줌 (메일 보안 스캐너가 링크를 미리 열어도 승인되지 않도록)
export async function GET(req: Request) {
  const url = new URL(req.url)
  const date = url.searchParams.get('date') ?? ''
  const sig = url.searchParams.get('sig') ?? ''
  if (!isIsoDate(date) || !verifyApproval(date, sig)) return page('링크가 올바르지 않습니다', '<p>검토 메일의 링크를 다시 확인하세요.</p>', 403)
  const { data } = await adminDb().from('daily_editions').select('status').eq('edition_date', date).maybeSingle()
  if (!data) return page('초안이 없습니다', `<p>${date} 초안을 찾지 못했습니다.</p>`, 404)
  if (data.status !== 'draft') return page('이미 처리되었습니다', `<p>${date} 브리핑 상태: <b>${esc(data.status)}</b></p>`)
  return page(`${date} 브리핑 승인`, `<p>검토 메일의 내용을 원문과 대조했다면 승인하세요. 승인하면 바로 발행되고 07:00 이후 발송됩니다.</p>
    <form method="post"><input type="hidden" name="date" value="${date}"><input type="hidden" name="sig" value="${esc(sig)}">
    <button style="padding:.8rem 1.2rem;background:#16503e;color:#fff;border:0;border-radius:.3rem">승인하고 발행</button></form>`)
}

export async function POST(req: Request) {
  const form = await req.formData()
  const date = String(form.get('date') ?? '')
  const sig = String(form.get('sig') ?? '')
  if (!isIsoDate(date) || !verifyApproval(date, sig)) return page('링크가 올바르지 않습니다', '', 403)
  const db = adminDb()
  const approve = await db.rpc('approve_edition', { p_date: date })
  if (approve.error) return page('승인하지 못했습니다', `<p>${esc(approve.error.message)}</p>`, 409)
  const publish = await db.rpc('publish_edition', { p_date: date })
  if (publish.error) return page('발행하지 못했습니다', `<p>${esc(publish.error.message)}</p>`, 409)
  await db.from('job_runs').insert({ job: 'publish', edition_date: date, status: 'succeeded',
    finished_at: new Date().toISOString(), meta: { mode: 'operator_approval' } })
  return page('발행했습니다', `<p>${date} 브리핑을 발행했습니다. 07:00 이후 다음 예약 실행 때 발송됩니다.</p>`)
}

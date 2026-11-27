import { adminDb } from '@/lib/server/supabase'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const page = (title: string, body: string, status = 200) => new Response(
  `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
  <meta name="robots" content="noindex"><title>${title}</title></head>
  <body style="font-family:system-ui;max-width:34rem;margin:10vh auto;padding:1rem;color:#19372f">
  <h1 style="font-size:1.4rem">${title}</h1>${body}</body></html>`,
  { status, headers: { 'Content-Type': 'text/html; charset=utf-8' } })

// GET: 확인 버튼만 보여줌 (링크 미리보기로 해지되지 않도록)
export async function GET(req: Request) {
  const token = new URL(req.url).searchParams.get('token') ?? ''
  if (!UUID.test(token)) return page('링크가 올바르지 않습니다', '', 400)
  return page('WorldSignal 브리핑 수신 해지', `<form method="post"><input type="hidden" name="token" value="${token}">
    <button style="padding:.8rem 1.2rem;background:#16503e;color:#fff;border:0;border-radius:.3rem">수신 해지</button></form>`)
}

// POST: 버튼 클릭 또는 메일 앱의 원클릭 해지(List-Unsubscribe-Post)
export async function POST(req: Request) {
  const url = new URL(req.url)
  const form = await req.formData().catch(() => null)
  const token = String(form?.get('token') ?? url.searchParams.get('token') ?? '')
  if (!UUID.test(token)) return page('링크가 올바르지 않습니다', '', 400)
  const { error } = await adminDb().from('subscriptions').update({ opted_in: false }).eq('unsubscribe_token', token)
  if (error) return page('처리하지 못했습니다', '<p>잠시 후 다시 시도하세요.</p>', 500)
  return page('수신을 해지했습니다', '<p>더 이상 아침 브리핑 메일을 보내지 않습니다. 웹에서는 계속 볼 수 있습니다.</p>')
}

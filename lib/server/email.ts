import 'server-only'
import { env } from './env'

export type EmailItem = {
  position: number; country_code: string; title: string; summary_ko: string
  why_it_matters: string | null; importance: string; is_top: boolean; source_url: string
}

const esc = (s: string) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!))
const flag = (cc: string) => (cc === 'KR' ? '한국' : cc === 'CL' ? '칠레' : cc)
const level = (v: string) => (v === 'high' ? '중요도 높음' : v === 'low' ? '중요도 낮음' : '중요도 보통')

export function renderBriefing(date: string, items: EmailItem[], footerHtml: string, footerText: string) {
  const tops = items.filter(i => i.is_top)
  const rest = items.filter(i => !i.is_top)
  const block = (i: EmailItem) => `
    <tr><td style="padding:16px 0;border-top:1px solid #d3ddd7">
      <div style="font-size:12px;color:#5b6f66">${flag(i.country_code)} · ${level(i.importance)}</div>
      <h3 style="margin:4px 0 8px;font-size:17px;color:#19372f">${esc(i.title)}</h3>
      <p style="margin:0 0 8px;line-height:1.6">${esc(i.summary_ko)}</p>
      ${i.why_it_matters ? `<p style="margin:0 0 8px;line-height:1.6;color:#36544a"><b>왜 중요한가</b> · ${esc(i.why_it_matters)}</p>` : ''}
      <a href="${esc(i.source_url)}" style="color:#16503e">원문 보기 ↗</a>
    </td></tr>`
  const html = `<!doctype html><html lang="ko"><body style="margin:0;background:#f7f6f1;font-family:system-ui,sans-serif;color:#19372f">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center">
  <table role="presentation" width="100%" style="max-width:600px;background:#fff;padding:24px;border-top:4px solid #21624a">
    <tr><td><div style="font:bold 20px Georgia,serif">WorldSignal AI</div>
      <div style="color:#5b6f66;font-size:13px">${date} 아침 브리핑 · 자료 마감 06:30 (칠레 시간)</div></td></tr>
    ${tops.length ? `<tr><td style="padding-top:16px;font-weight:700">오늘의 핵심 ${tops.length}</td></tr>${tops.map(block).join('')}` : ''}
    ${rest.length ? `<tr><td style="padding-top:16px;font-weight:700">그 밖의 이슈</td></tr>${rest.map(block).join('')}` : ''}
    <tr><td style="padding-top:24px;font-size:12px;color:#5b6f66;line-height:1.6">
      요약은 AI가 원문을 바탕으로 작성하고 운영자가 확인했습니다. 분석은 가능성으로 표현했으며, 정확한 내용은 원문을 확인하세요.<br>${footerHtml}
    </td></tr>
  </table></td></tr></table></body></html>`
  const text = [`WorldSignal AI ${date} 아침 브리핑`, '',
    ...items.map(i => `[${flag(i.country_code)}${i.is_top ? ' · 핵심' : ''}] ${i.title}\n${i.summary_ko}${i.why_it_matters ? `\n왜 중요한가: ${i.why_it_matters}` : ''}\n원문: ${i.source_url}\n`),
    footerText].join('\n')
  return { html, text }
}

type SendResult =
  | { status: 'sent'; id: string }
  | { status: 'failed'; error: string }   // 공급자가 명확히 거절 (주소 오류 등)
  | { status: 'unknown'; error: string }  // 응답 불명확: 자동 재발송하지 않음

export async function sendEmail(msg: { to: string; subject: string; html: string; text: string;
  idempotencyKey: string; unsubscribeUrl?: string }): Promise<SendResult> {
  const headers: Record<string, string> = {}
  if (msg.unsubscribeUrl) {
    headers['List-Unsubscribe'] = `<${msg.unsubscribeUrl}>`
    headers['List-Unsubscribe-Post'] = 'List-Unsubscribe=One-Click'
  }
  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.resendKey()}`, 'Content-Type': 'application/json',
        'Idempotency-Key': msg.idempotencyKey },
      body: JSON.stringify({ from: env.emailFrom(), to: [msg.to], subject: msg.subject,
        html: msg.html, text: msg.text, headers }),
      signal: AbortSignal.timeout(15_000),
    })
    const body = await res.text()
    if (res.ok) {
      const id = (() => { try { return JSON.parse(body).id as string } catch { return '' } })()
      return id ? { status: 'sent', id } : { status: 'unknown', error: `200이지만 id 없음: ${body.slice(0, 200)}` }
    }
    if (res.status === 429 || res.status >= 500) return { status: 'unknown', error: `HTTP ${res.status}: ${body.slice(0, 200)}` }
    return { status: 'failed', error: `HTTP ${res.status}: ${body.slice(0, 200)}` }
  } catch (e) {
    return { status: 'unknown', error: `요청 실패/시간 초과: ${(e as Error).message}` }
  }
}

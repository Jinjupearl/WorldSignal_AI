import 'server-only'
import { env } from './env'

export type Candidate = {
  article_id: number; country_code: 'KR' | 'CL'; source_name: string; title: string
  source_url: string; published_at: string; summary_input: string
}
export type EditionItem = {
  article_id: number; title: string; summary_ko: string; why_it_matters: string
  importance: 'high' | 'normal' | 'low'; is_top: boolean
}

const SYSTEM_PROMPT = `당신은 한국과 칠레의 정치·경제 뉴스를 한국어 아침 브리핑으로 정리하는 편집자입니다.
규칙:
- 제공된 기사 본문(summary_input)에 있는 사실만 사용합니다. 본문에 없는 인물·수치·배경·전망을 추가하지 않습니다.
- 정치·경제와 관련 없거나 한국·칠레와 관련 없는 기사는 고르지 않습니다. 개수를 억지로 채우지 않습니다 (최대 8개).
- 같은 사건을 다룬 기사가 여러 개면 가장 정보가 많은 1개만 고릅니다.
- title: 한국어 제목, 사실 그대로.
- summary_ko: 기사로 확인되는 사실을 한국어 3~5문장 이내로.
- why_it_matters: 정책·경제적 의미 1~2문장. 추론이면 "~일 수 있다"처럼 가능성으로 표현합니다. 근거가 부족하면 빈 문자열.
- importance: 영향 범위·긴급성·한국·칠레 관련성을 각각 0~2점으로 매겨 합계 5~6 high, 3~4 normal, 0~2 low.
- is_top: 오늘 가장 중요한 이슈 최대 3개만 true.
- 수치는 통화·단위·기준 시점을 원문 그대로 유지합니다.`

const SCHEMA = {
  type: 'object', additionalProperties: false, required: ['items'],
  properties: {
    items: {
      type: 'array', maxItems: 8,
      items: {
        type: 'object', additionalProperties: false,
        required: ['article_id', 'title', 'summary_ko', 'why_it_matters', 'importance', 'is_top'],
        properties: {
          article_id: { type: 'integer' },
          title: { type: 'string' },
          summary_ko: { type: 'string' },
          why_it_matters: { type: 'string' },
          importance: { type: 'string', enum: ['high', 'normal', 'low'] },
          is_top: { type: 'boolean' },
        },
      },
    },
  },
}

export async function summarize(candidates: Candidate[]): Promise<{ items: EditionItem[]; usage: unknown; model: string }> {
  const model = env.openaiModel()
  const input = candidates.map(c => ({
    article_id: c.article_id, country: c.country_code, source: c.source_name,
    published_at: c.published_at, title: c.title, summary_input: c.summary_input.slice(0, 1500),
  }))
  const res = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.openaiKey()}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model,
      messages: [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user', content: `오늘 후보 기사 ${input.length}건입니다. 규칙에 따라 고르고 정리하세요.\n${JSON.stringify(input)}` },
      ],
      response_format: { type: 'json_schema', json_schema: { name: 'edition', strict: true, schema: SCHEMA } },
    }),
    signal: AbortSignal.timeout(90_000),
  })
  if (!res.ok) throw new Error(`OpenAI 오류 HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`)
  const body = await res.json()
  const content = body?.choices?.[0]?.message?.content
  if (!content) throw new Error('OpenAI 응답이 비어 있습니다')
  const parsed = JSON.parse(content) as { items: EditionItem[] }
  return { items: sanitize(parsed.items, candidates), usage: body.usage, model }
}

// 서버 검사: 후보에 없는 기사·중복·빈 문장 제거, 최대 8개, 핵심 최대 3개 (DB도 한 번 더 검사)
export function sanitize(items: EditionItem[], candidates: Candidate[]): EditionItem[] {
  const allowed = new Set(candidates.map(c => c.article_id))
  const seen = new Set<number>()
  let tops = 0
  const out: EditionItem[] = []
  for (const item of items ?? []) {
    if (!allowed.has(item.article_id) || seen.has(item.article_id)) continue
    if (!item.title?.trim() || !item.summary_ko?.trim()) continue
    seen.add(item.article_id)
    const isTop = item.is_top && tops < 3
    if (isTop) tops++
    out.push({ ...item, title: item.title.trim(), summary_ko: item.summary_ko.trim(),
      why_it_matters: item.why_it_matters?.trim() ?? '', is_top: isTop })
    if (out.length === 8) break
  }
  return out
}

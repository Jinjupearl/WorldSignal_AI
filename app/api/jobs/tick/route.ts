import { timingSafeEqual } from 'node:crypto'
import { NextResponse } from 'next/server'
import { env } from '@/lib/server/env'
import { buildEdition, sendEdition, tick } from '@/lib/server/jobs'
import { isIsoDate } from '@/lib/server/time'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'
export const maxDuration = 120

function authorized(req: Request) {
  const given = Buffer.from(req.headers.get('x-job-secret') ?? '')
  const expected = Buffer.from(env.jobSecret())
  return given.length === expected.length && timingSafeEqual(given, expected)
}

// POST /api/jobs/tick                         → 현재 칠레 시각 기준으로 할 일 수행 (pg_cron이 호출)
// POST /api/jobs/tick {"action":"build","date":"2026-11-30"} → 수동 실행 (운영자 테스트용)
export async function POST(req: Request) {
  if (!authorized(req)) return NextResponse.json({ error: 'unauthorized' }, { status: 401 })
  const body = await req.json().catch(() => ({})) as { action?: string; date?: string }
  try {
    if (body.action) {
      if (!isIsoDate(body.date)) return NextResponse.json({ error: 'date 형식은 YYYY-MM-DD' }, { status: 400 })
      if (body.action === 'build') return NextResponse.json(await buildEdition(body.date))
      if (body.action === 'send') return NextResponse.json(await sendEdition(body.date))
      return NextResponse.json({ error: 'action은 build 또는 send' }, { status: 400 })
    }
    return NextResponse.json(await tick())
  } catch (e) {
    console.error('tick 실패', e)
    return NextResponse.json({ error: (e as Error).message }, { status: 500 })
  }
}

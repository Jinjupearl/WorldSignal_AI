import 'server-only'
import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { env } from './env'

// service_role 클라이언트: RLS를 우회하므로 서버 코드에서만 사용합니다.
let client: SupabaseClient | null = null
export function adminDb(): SupabaseClient {
  if (!client) {
    client = createClient(env.supabaseUrl(), env.supabaseServiceKey(), {
      auth: { persistSession: false, autoRefreshToken: false },
    })
  }
  return client
}

type JobName = 'collect' | 'summarize' | 'publish' | 'send'
type JobStatus = 'running' | 'succeeded' | 'failed' | 'skipped'

// job_runs 기록. 기록 자체가 실패해도 본 작업을 막지 않습니다.
export async function logJob(job: JobName, editionDate: string, status: JobStatus,
  fields: { items_found?: number; items_inserted?: number; error?: string; meta?: Record<string, unknown> } = {}) {
  const { error } = await adminDb().from('job_runs').insert({
    job, edition_date: editionDate, status, finished_at: new Date().toISOString(), ...fields,
  })
  if (error) console.error('job_runs 기록 실패', error.message)
}

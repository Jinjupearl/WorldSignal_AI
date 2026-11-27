'use client'
import { useEffect, useState, type FormEvent } from 'react'
import { createClient, type Session } from '@supabase/supabase-js'

const url = process.env.NEXT_PUBLIC_SUPABASE_URL
const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
const db = url && key ? createClient(url, key) : null
type Briefing = { id: string; briefing_date: string; status: string }

type NewsItem = { position: number; title: string; summary_ko: string; source_url: string }

function BriefingDetail({row, onBack}: {row: Briefing; onBack: () => void}) {
  const [items, setItems] = useState<NewsItem[] | null>(null)
  const [error, setError] = useState(false)
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    const controller = new AbortController()
    async function load() {
      setError(false)
      try {
        const {data, error} = await db!.from('briefing_news')
          .select('position, title, summary_ko, source_url')
          .eq('briefing_id', row.id).order('position').abortSignal(controller.signal)
        if (error) throw error
        if (!controller.signal.aborted) setItems(data)
      } catch {
        if (!controller.signal.aborted) setError(true)
      }
    }
    void load()
    return () => controller.abort()
  }, [row.id, attempt])
  return <section aria-label="브리핑 상세">
    <button type="button" onClick={onBack}>목록으로</button>
    <h2>{row.briefing_date} 브리핑</h2>
    {error ? <p role="alert">뉴스를 불러오지 못했습니다. <button onClick={() => setAttempt(n => n + 1)}>다시 조회</button></p>
      : items === null ? <p role="status">뉴스를 불러오는 중입니다.</p>
      : items.length === 0 ? <p>아직 이 브리핑에 등록된 뉴스가 없습니다.</p>
      : items.map(item => <article key={item.position}>
          <h3>{item.title}</h3><p>{item.summary_ko}</p>
          {/^https?:\/\//i.test(item.source_url) && <a href={item.source_url} target="_blank" rel="noopener noreferrer" aria-label={item.title + ' 원문 보기 (새 탭)'}>원문 보기 ↗</a>}
        </article>)}
  </section>
}

function Briefings({userId}: {userId: string}) {
  const [selected, setSelected] = useState<Briefing | null>(null)
  const [rows, setRows] = useState<Briefing[] | null>(null)
  const [error, setError] = useState(false)
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    let active = true
    async function load() {
      setError(false)
      setRows(null)
      try {
        const {data, error} = await db!.from('briefings').select('id, briefing_date, status')
          .eq('user_id', userId).order('briefing_date', {ascending: false}).limit(30)
        if (error) throw error
        if (active) setRows(data)
      } catch {
        if (active) setError(true)
      }
    }
    void load()
    return () => { active = false }
  }, [userId, attempt])
  if (error) return <p role="alert">브리핑을 불러오지 못했습니다. <button onClick={() => setAttempt(n => n + 1)}>다시 조회</button></p>
  if (!rows) return <p role="status">브리핑을 불러오는 중입니다.</p>
  if (selected) return <BriefingDetail row={selected} onBack={() => setSelected(null)} />
  if (!rows.length) return <p>이 계정에 저장된 브리핑이 없습니다.</p>
  return <ul>{rows.map(row => <li key={row.id}><button className="date-link" onClick={() => setSelected(row)}><time dateTime={row.briefing_date}>{row.briefing_date}</time></button><span>{row.status === 'draft' ? '초안' : row.status}</span></li>)}</ul>
}

export default function Page() {
  const [session, setSession] = useState<Session | null | undefined>(undefined)
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    const subscription = db?.auth.onAuthStateChange((_event, next) => setSession(next)).data.subscription
    return () => subscription?.unsubscribe()
  }, [])
  async function login(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const fields = new FormData(event.currentTarget)
    setBusy(true)
    setMessage('')
    try {
      const {error} = await db!.auth.signInWithPassword({email: String(fields.get('email')).trim(), password: String(fields.get('password'))})
      if (error) throw error
    } catch {
      setMessage('로그인하지 못했습니다. 이메일, 비밀번호와 네트워크 연결을 확인하세요.')
    } finally { setBusy(false) }
  }
  async function logout() {
    setMessage('')
    setBusy(true)
    try {
      const {error} = await db!.auth.signOut({scope:'local'})
      if (error) throw error
    } catch { setMessage('로그아웃하지 못했습니다. 다시 시도하세요.') }
    finally { setBusy(false) }
  }
  if (!db) return <p role="alert">Supabase 연결 설정이 필요합니다.</p>
  if (session === undefined) return <p role="status">로그인 상태를 확인하는 중입니다.</p>
  return <><h1>{session ? '내 브리핑' : '로그인'}</h1>
    {session ? <><p>{session.user.email}</p><Briefings key={session.user.id} userId={session.user.id}/><button disabled={busy} onClick={logout}>로그아웃</button></>
      : <form onSubmit={login}><label>이메일<input name="email" type="email" autoComplete="username" required/></label>
        <label>비밀번호<input name="password" type="password" autoComplete="current-password" required/></label>
        <button disabled={busy}>{busy ? '로그인 중…' : '로그인'}</button></form>}
    {message && <p role="alert">{message}</p>}</>
}

'use client'
import { useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

type Edition = { id: string; edition_date: string; published_at: string | null }
type Item = { position: number; country_code: string; title: string; summary_ko: string
  why_it_matters: string | null; importance: string; is_top: boolean; source_url: string }

const country = (cc: string) => (cc === 'KR' ? '한국' : cc === 'CL' ? '칠레' : cc)
const level = (v: string) => (v === 'high' ? '높음' : v === 'low' ? '낮음' : '보통')

// 공통 아침 브리핑 (발행본만 조회 가능 — RLS가 초안을 숨김)
export function Editions({ db }: { db: SupabaseClient }) {
  const [editions, setEditions] = useState<Edition[] | null>(null)
  const [selected, setSelected] = useState<Edition | null>(null)
  const [items, setItems] = useState<Item[] | null>(null)
  const [error, setError] = useState(false)

  useEffect(() => {
    let active = true
    db.from('daily_editions').select('id, edition_date, published_at')
      .order('edition_date', { ascending: false }).limit(30)
      .then(({ data, error }) => {
        if (!active) return
        if (error) setError(true)
        else { setEditions(data); setSelected(data[0] ?? null) }
      })
    return () => { active = false }
  }, [db])

  useEffect(() => {
    if (!selected) return
    let active = true
    setItems(null)
    db.from('edition_items')
      .select('position, country_code, title, summary_ko, why_it_matters, importance, is_top, source_url')
      .eq('edition_id', selected.id).order('position')
      .then(({ data, error }) => { if (active) error ? setError(true) : setItems(data) })
    return () => { active = false }
  }, [db, selected])

  if (error) return <p role="alert">아침 브리핑을 불러오지 못했습니다.</p>
  if (!editions) return <p role="status">아침 브리핑을 불러오는 중입니다.</p>
  if (!editions.length) return <p>아직 발행된 아침 브리핑이 없습니다.</p>

  const tops = items?.filter(i => i.is_top) ?? []
  const rest = items?.filter(i => !i.is_top) ?? []
  const card = (i: Item) => <article key={i.position}>
    <small>{country(i.country_code)} · 중요도 {level(i.importance)}</small>
    <h3>{i.title}</h3><p>{i.summary_ko}</p>
    {i.why_it_matters && <p><b>왜 중요한가</b> · {i.why_it_matters}</p>}
    {/^https?:\/\//i.test(i.source_url) && <a href={i.source_url} target="_blank" rel="noopener noreferrer">원문 보기 ↗</a>}
  </article>

  return <section aria-label="아침 브리핑">
    <label>날짜
      <select value={selected?.id} onChange={e => setSelected(editions.find(x => x.id === e.target.value) ?? null)}>
        {editions.map(e => <option key={e.id} value={e.id}>{e.edition_date}</option>)}
      </select>
    </label>
    <p><small>자료 마감 06:30 (칠레 시간) · AI 요약, 운영자 확인</small></p>
    {items === null ? <p role="status">불러오는 중…</p> : <>
      {tops.length > 0 && <><h2>오늘의 핵심 {tops.length}</h2>{tops.map(card)}</>}
      {rest.length > 0 && <><h2>그 밖의 이슈</h2>{rest.map(card)}</>}
    </>}
  </section>
}

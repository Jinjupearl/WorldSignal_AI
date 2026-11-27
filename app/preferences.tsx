'use client'
import {useEffect, useState} from 'react'
import type {SupabaseClient} from '@supabase/supabase-js'

const topics = {
  '정치·공공': '정치 선거 외교 안보 행정 정책 규제',
  '경제·금융': '거시경제 무역 고용 금융시장 은행 보험 세금',
  '교육': '영유아 초중고 대학 입시 직업교육 교육정책',
  '의료·건강': '보건정책 의료서비스 질병·예방 정신건강 의학연구',
  '기술·과학': 'AI 소프트웨어 반도체 통신 사이버보안 우주',
  '산업·기업': '제조 자동차 에너지 광업 건설 물류 농수산업',
  '소비·생활': '유통 식품 주거 교통 여행 육아 생활비',
  '사회·환경': '인권 노동 이민 기후 환경 재난 치안',
  '문화·스포츠': '예술 콘텐츠 엔터테인먼트 패션 스포츠',
  '인물·화제': '주요인물SNS 인터뷰 공식입장 화제·논란'
}
const initial = {countries:['CL','KR'], topics:[] as string[], industries:[] as string[], people:[] as string[],
  language:'ko', perspective:'해외 거주자', timezone:'America/Santiago', delivery_time:'07:00'}
type Profile = typeof initial
type Item = {article_id:number, source_url:string, headline:string, facts:string, analysis?:string,
  claim?:string, claim_source?:string, kind:string,evidence_kind:string,source_name:string}
type Coverage = {country:string,topic:string,source_name:string}
const split = (s:string) => Array.from(new Set(s.split(',').map(x => x.trim()).filter(Boolean)))

export function Personalization({db,userId}:{db:SupabaseClient,userId:string}) {
  const [profile,setProfile] = useState<Profile>(initial)
  const [coverage,setCoverage] = useState<Coverage[]>([])
  const [items,setItems] = useState<Item[]>([])
  const [date,setDate] = useState('')
  const [ready,setReady] = useState(false)
  const [busy,setBusy] = useState(false)
  const [message,setMessage] = useState('')
  useEffect(() => {
    let active = true
    async function load() {
      const [pref,cov,edition] = await Promise.all([
        db.from('briefing_preferences').select('*').eq('user_id',userId).maybeSingle(),
        db.from('verified_coverage').select('country,topic,source_name'),
        db.from('personalized_editions').select('briefing_date,items').eq('user_id',userId).order('briefing_date',{ascending:false}).limit(1).maybeSingle()
      ])
      if (!active) return
      if (pref.error || cov.error || edition.error) {setMessage('개인화 설정을 불러오지 못했습니다.');return}
      if (pref.data) setProfile(pref.data as Profile)
      setCoverage(cov.data || [])
      if (edition.data) {setItems(edition.data.items);setDate(edition.data.briefing_date)}
      setReady(true)
    }
    void load()
    return () => {active=false}
  },[db,userId])

  async function submit(form:HTMLFormElement,generate:boolean) {
    const fields = new FormData(form)
    const read = (name:string) => String(fields.get(name) || '').trim()
    const next = {...profile,countries:split(read('countries').toUpperCase()),industries:split(read('industries')),
      people:split(read('people')),language:read('language'),perspective:read('perspective'),
      timezone:read('timezone'),delivery_time:read('delivery_time')}
    if (!next.countries.length || next.countries.some(x=>!(/^[A-Z]{2}$/).test(x))) {setMessage('국가는 두 글자 코드로 입력하세요.');return}
    setBusy(true)
    try {
      const stored = await db.from('briefing_preferences').upsert({...next,user_id:userId})
      if (stored.error) throw stored.error
      if (!generate) {setMessage('관심사를 저장했습니다.');return}
      const edition = await db.rpc('generate_personalized_edition')
      if (edition.error) throw edition.error
      setItems(edition.data)
      setDate(new Intl.DateTimeFormat('sv-SE',{timeZone:next.timezone}).format(new Date()))
      setMessage(edition.data.length ? '개인 브리핑을 저장했습니다.' : '최근 24시간에 조건과 일치하는 검증 기사가 없습니다.')
    } catch {setMessage('요청을 완료하지 못했습니다. 시간대와 연결을 확인하세요.')}
    finally {setBusy(false)}
  }
  return <details><summary>개인 브리핑 및 관심사</summary>
    {ready && <form onSubmit={e=>{e.preventDefault();const button=(e.nativeEvent as SubmitEvent).submitter as HTMLButtonElement;void submit(e.currentTarget,button?.value==='generate')}}>
      <label>국가 코드 (쉼표로 구분)<input name="countries" defaultValue={profile.countries.join(', ')} required/></label>
      <fieldset><legend>관심 분야</legend>{Object.entries(topics).map(([group,children])=>{
        const keys=children.split(' ')
        function toggle(values:string[],on:boolean) {
          setProfile(p=>({...p,topics:on?Array.from(new Set([...p.topics,...values])):p.topics.filter(x=>!values.includes(x))}))
        }
        return <details key={group}><summary>{group}</summary>
          <label className="choice"><input type="checkbox" checked={keys.every(k=>profile.topics.includes(k))} onChange={e=>toggle(keys,e.target.checked)}/>전체 선택</label>
          {keys.map(k=><label key={k} className="choice"><input type="checkbox" checked={profile.topics.includes(k)} onChange={e=>toggle([k],e.target.checked)}/>{k}</label>)}</details>
      })}</fieldset>
      <label>관심 산업 (쉼표로 구분)<input name="industries" placeholder="의료기기, 반도체" defaultValue={profile.industries.join(', ')}/></label>
      <label>관심 인물 (쉼표로 구분)<input name="people" defaultValue={profile.people.join(', ')}/></label>
      <label>브리핑 언어<select name="language" defaultValue={profile.language}><option value="ko">한국어</option><option value="es">Español</option><option value="en">English</option></select></label>
      <label>관점<select name="perspective" defaultValue={profile.perspective}>{['해외 거주자','수출기업','연구자','일반'].map(v=><option key={v}>{v}</option>)}</select></label>
      <label>수신 시간대<input name="timezone" required defaultValue={profile.timezone}/></label>
      <label>희망 수신 시각<input type="time" name="delivery_time" required defaultValue={profile.delivery_time.slice(0,5)}/></label>
      <p>개인별 예약 발송은 준비 중입니다.</p>
      <h3>검증된 국가·분야</h3>
      {coverage.length ? <ul>{coverage.map(c=><li key={JSON.stringify(c)}>{c.country} · {c.topic} · {c.source_name}</li>)}</ul> : <p>현재 검증을 마친 조합이 없습니다.</p>}
      <button disabled={busy}>관심사 저장</button><button value="generate" disabled={busy}>저장하고 오늘 브리핑 생성</button>
    </form>}
    <p role="status">{message || (!ready && '불러오는 중…')}</p>
    {date && <section><h2>{date} 개인 브리핑</h2>{!items.length && <p>선별된 기사가 없습니다.</p>}
      {items.map(x=><article key={x.article_id}><small>{x.kind} · {x.evidence_kind}</small><h3>{x.headline}</h3>
        <p>{x.facts}</p>{x.claim && <p>주장 ({x.claim_source}) · {x.claim}</p>}
        {x.analysis && <p>관점별 해설 · {x.analysis}</p>}
        {/^https?:\/\//i.test(x.source_url) && <a href={x.source_url} target="_blank" rel="noreferrer">{x.source_name} 원문 ↗</a>}
      </article>)}</section>}
  </details>
}

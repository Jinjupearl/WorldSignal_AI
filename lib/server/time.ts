// 모든 일정은 America/Santiago 기준. DB에는 UTC로 저장됩니다.
export const TIME_ZONE = 'America/Santiago'

export function santiagoNow(now = new Date()) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-CA', {
    timeZone: TIME_ZONE, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(now).map(p => [p.type, p.value]))
  return {
    date: `${parts.year}-${parts.month}-${parts.day}`,   // YYYY-MM-DD
    minutes: Number(parts.hour) * 60 + Number(parts.minute), // 자정부터 분
  }
}

export const at = (hour: number, minute = 0) => hour * 60 + minute

export function isIsoDate(value: unknown): value is string {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)
}

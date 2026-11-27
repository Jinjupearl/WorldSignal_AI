import 'server-only'
import { createHmac, timingSafeEqual } from 'node:crypto'
import { env } from './env'

// 승인 링크 서명: 날짜별 HMAC. 링크만 있으면 승인 "화면"이 열리고, 실제 승인은 버튼(POST)으로만 됩니다.
export function approvalSignature(date: string) {
  return createHmac('sha256', env.approvalSecret()).update(`approve:${date}`).digest('hex')
}

export function verifyApproval(date: string, sig: string) {
  const expected = Buffer.from(approvalSignature(date))
  const given = Buffer.from(sig ?? '')
  return given.length === expected.length && timingSafeEqual(given, expected)
}

export function approvalUrl(date: string) {
  return `${env.siteUrl()}/admin/approve?date=${date}&sig=${approvalSignature(date)}`
}

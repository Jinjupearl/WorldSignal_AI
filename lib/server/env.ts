// 서버 전용 환경 변수. 브라우저 번들에 포함되면 안 되는 값만 여기서 읽습니다.
import 'server-only'

function required(name: string): string {
  const value = process.env[name]
  if (!value) throw new Error(`환경 변수 ${name} 가 설정되지 않았습니다`)
  return value
}

export const env = {
  supabaseUrl: () => required('NEXT_PUBLIC_SUPABASE_URL'),
  supabaseServiceKey: () => required('SUPABASE_SERVICE_ROLE_KEY'),
  openaiKey: () => required('OPENAI_API_KEY'),
  openaiModel: () => required('OPENAI_MODEL'),
  resendKey: () => required('RESEND_API_KEY'),
  emailFrom: () => required('EMAIL_FROM'),            // 예: WorldSignal AI <briefing@your-domain.com>
  operatorEmail: () => required('OPERATOR_EMAIL'),    // 06:30 검토 메일을 받을 운영자
  siteUrl: () => required('SITE_URL').replace(/\/$/, ''), // 예: https://worldsignal.vercel.app
  jobSecret: () => required('JOB_SECRET'),            // pg_cron → /api/jobs/tick 호출 인증
  approvalSecret: () => required('APPROVAL_SECRET'),  // 승인 링크 서명
  autoApprove: () => process.env.AUTO_APPROVE === 'true', // 데모용. 기본은 사람이 승인
}

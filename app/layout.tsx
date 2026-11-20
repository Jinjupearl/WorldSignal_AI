import './style.css'
import type { ReactNode } from 'react'
export const metadata = { title: '내 브리핑 | WorldSignal AI' }
export default function Layout({children}: {children: ReactNode}) {
  return <html lang="ko"><body><header>WorldSignal AI</header><main>{children}</main></body></html>
}

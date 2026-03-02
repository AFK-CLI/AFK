import type { ReactNode } from 'react'

export function CardGrid({ children }: { children: ReactNode }) {
  return <div className="cards">{children}</div>
}

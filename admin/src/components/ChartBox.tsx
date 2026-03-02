import type { ReactNode } from 'react'

interface ChartBoxProps {
  title: string
  children: ReactNode
}

export function ChartBox({ title, children }: ChartBoxProps) {
  return (
    <div className="chart-box">
      <h3>{title}</h3>
      {children}
    </div>
  )
}

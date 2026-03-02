import type { ReactNode } from 'react'

interface Tab {
  key: string
  label: string
  content: ReactNode
}

interface TabGroupProps {
  tabs: Tab[]
  activeTab: string
  onTabChange: (key: string) => void
}

export function TabGroup({ tabs, activeTab, onTabChange }: TabGroupProps) {
  return (
    <>
      <div className="tabs">
        {tabs.map((tab) => (
          <div
            key={tab.key}
            className={`tab ${activeTab === tab.key ? 'active' : ''}`}
            onClick={() => onTabChange(tab.key)}
          >
            {tab.label}
          </div>
        ))}
      </div>
      {tabs.map((tab) =>
        tab.key === activeTab ? (
          <div key={tab.key}>{tab.content}</div>
        ) : null,
      )}
    </>
  )
}

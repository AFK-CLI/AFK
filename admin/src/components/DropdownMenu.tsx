import { useState, useRef, useEffect } from 'react'

interface Option {
  label: string
  value: string
}

interface Props {
  options: Option[]
  onSelect: (value: string) => void
  label: string
}

export function DropdownMenu({ options, onSelect, label }: Props) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [open])

  return (
    <div className="dropdown-wrap" ref={ref} onClick={(e) => e.stopPropagation()}>
      <button
        className="action-btn action-btn-primary"
        onClick={() => setOpen(!open)}
      >
        {label}
      </button>
      {open && (
        <div className="dropdown-menu">
          {options.map((o) => (
            <div
              key={o.value}
              className="dropdown-item"
              onClick={() => {
                onSelect(o.value)
                setOpen(false)
              }}
            >
              {o.label}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

interface Props {
  label: string
  variant?: 'danger' | 'primary' | 'default'
  loading?: boolean
  onClick: () => void
}

export function ActionButton({ label, variant = 'default', loading = false, onClick }: Props) {
  return (
    <button
      className={`action-btn action-btn-${variant}`}
      onClick={(e) => {
        e.stopPropagation()
        onClick()
      }}
      disabled={loading}
    >
      {loading ? '...' : label}
    </button>
  )
}

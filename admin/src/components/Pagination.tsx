interface PaginationProps {
  start: number
  end: number
  total: number
  hasPrev: boolean
  hasNext: boolean
  onPrev: () => void
  onNext: () => void
}

export function Pagination({ start, end, total, hasPrev, hasNext, onPrev, onNext }: PaginationProps) {
  return (
    <div className="pagination">
      <span>
        {start}&ndash;{end} of {total}
      </span>
      <div>
        <button className="btn-sm" disabled={!hasPrev} onClick={onPrev}>
          Prev
        </button>
        <button className="btn-sm" disabled={!hasNext} onClick={onNext}>
          Next
        </button>
      </div>
    </div>
  )
}

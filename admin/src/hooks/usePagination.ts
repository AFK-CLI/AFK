import { useState, useCallback } from 'react'

const PAGE_SIZE = 50

export function usePagination() {
  const [offset, setOffset] = useState(0)
  const [total, setTotal] = useState(0)

  const nextPage = useCallback(() => {
    setOffset((o) => Math.min(o + PAGE_SIZE, total - 1))
  }, [total])

  const prevPage = useCallback(() => {
    setOffset((o) => Math.max(0, o - PAGE_SIZE))
  }, [])

  const reset = useCallback(() => {
    setOffset(0)
  }, [])

  return {
    offset,
    total,
    pageSize: PAGE_SIZE,
    setTotal,
    nextPage,
    prevPage,
    reset,
    hasPrev: offset > 0,
    hasNext: offset + PAGE_SIZE < total,
    start: total > 0 ? offset + 1 : 0,
    end: Math.min(offset + PAGE_SIZE, total),
  }
}

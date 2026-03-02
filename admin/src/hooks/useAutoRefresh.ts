import { useEffect, useRef } from 'react'

export function useAutoRefresh(callback: () => void, intervalMs = 30_000) {
  const callbackRef = useRef(callback)
  callbackRef.current = callback

  useEffect(() => {
    const id = setInterval(() => callbackRef.current(), intervalMs)
    return () => clearInterval(id)
  }, [intervalMs])
}

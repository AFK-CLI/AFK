import type { ReactNode } from 'react'

interface Column<T> {
  header: string
  render: (row: T) => ReactNode
  style?: React.CSSProperties
}

interface DataTableProps<T> {
  columns: Column<T>[]
  data: T[]
  emptyText?: string
  onRowClick?: (row: T) => void
}

export function DataTable<T>({ columns, data, emptyText = 'No data', onRowClick }: DataTableProps<T>) {
  return (
    <table>
      <thead>
        <tr>
          {columns.map((col, i) => (
            <th key={i}>{col.header}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {data.length === 0 ? (
          <tr>
            <td colSpan={columns.length} style={{ color: 'var(--text-dim)' }}>
              {emptyText}
            </td>
          </tr>
        ) : (
          data.map((row, ri) => (
            <tr
              key={ri}
              onClick={onRowClick ? () => onRowClick(row) : undefined}
              className={onRowClick ? 'clickable-row' : undefined}
            >
              {columns.map((col, ci) => (
                <td key={ci} style={col.style}>
                  {col.render(row)}
                </td>
              ))}
            </tr>
          ))
        )}
      </tbody>
    </table>
  )
}

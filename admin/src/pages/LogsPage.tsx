import { PageHeader } from '../components/PageHeader'
import { EmptyState } from '../components/EmptyState'

export function LogsPage() {
  return (
    <div>
      <PageHeader title="Logs" />
      <EmptyState
        title="Coming Soon"
        message="Real-time log streaming will be available here."
      />
    </div>
  )
}

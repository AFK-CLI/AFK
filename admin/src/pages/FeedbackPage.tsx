import { PageHeader } from '../components/PageHeader'
import { EmptyState } from '../components/EmptyState'

export function FeedbackPage() {
  return (
    <div>
      <PageHeader title="Feedback" />
      <EmptyState
        title="Coming Soon"
        message="User feedback and feature requests will be available here."
      />
    </div>
  )
}

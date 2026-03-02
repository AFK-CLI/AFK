type BadgeVariant = 'green' | 'red' | 'blue' | 'yellow'

interface BadgeProps {
  text: string
  variant: BadgeVariant
}

export function Badge({ text, variant }: BadgeProps) {
  return <span className={`badge badge-${variant}`}>{text}</span>
}

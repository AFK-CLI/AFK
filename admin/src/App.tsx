import { createBrowserRouter, RouterProvider, Outlet } from 'react-router-dom'
import { AuthProvider, useAuth } from './contexts/AuthContext'
import { ToastProvider } from './contexts/ToastContext'
import { AppLayout } from './components/AppLayout'
import { LoginPage } from './pages/LoginPage'
import { OverviewPage } from './pages/OverviewPage'
import { UsersPage } from './pages/UsersPage'
import { UserDetailPage } from './pages/UserDetailPage'
import { DevicesPage } from './pages/DevicesPage'
import { SessionsPage } from './pages/SessionsPage'
import { SessionDetailPage } from './pages/SessionDetailPage'
import { CommandsPage } from './pages/CommandsPage'
import { SecurityPage } from './pages/SecurityPage'
import { ServerPage } from './pages/ServerPage'
import { LogsPage } from './pages/LogsPage'
import { FeedbackPage } from './pages/FeedbackPage'

function AuthGate() {
  const { loggedIn } = useAuth()
  if (loggedIn === null) return null
  if (!loggedIn) return <LoginPage />
  return <Outlet />
}

function RootLayout() {
  return (
    <AuthProvider>
      <ToastProvider>
        <AuthGate />
      </ToastProvider>
    </AuthProvider>
  )
}

const router = createBrowserRouter(
  [
    {
      path: '/',
      element: <RootLayout />,
      children: [
        {
          element: <AppLayout />,
          children: [
            { index: true, element: <OverviewPage /> },
            { path: 'users', element: <UsersPage /> },
            { path: 'users/:id', element: <UserDetailPage /> },
            { path: 'devices', element: <DevicesPage /> },
            { path: 'sessions', element: <SessionsPage /> },
            { path: 'sessions/:id', element: <SessionDetailPage /> },
            { path: 'commands', element: <CommandsPage /> },
            { path: 'security', element: <SecurityPage /> },
            { path: 'server', element: <ServerPage /> },
            { path: 'logs', element: <LogsPage /> },
            { path: 'feedback', element: <FeedbackPage /> },
          ],
        },
      ],
    },
  ],
  { basename: '/admin' },
)

export default function App() {
  return <RouterProvider router={router} />
}

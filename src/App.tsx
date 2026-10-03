import { useSyncExternalStore } from 'react'
import SignIn from './screens/SignIn.tsx'
import WorkspaceCreated from './screens/WorkspaceCreated.tsx'

// ponytail: hash router, swap for a real router once routes need params or nesting
const subscribe = (cb: () => void) => {
  addEventListener('hashchange', cb)
  return () => removeEventListener('hashchange', cb)
}

export default function App() {
  const hash = useSyncExternalStore(subscribe, () => location.hash)
  return hash === '#/workspace' ? <WorkspaceCreated /> : <SignIn />
}

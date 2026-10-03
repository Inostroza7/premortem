import { useSyncExternalStore, type ComponentType } from 'react'
import SignIn from './screens/SignIn.tsx'
import WorkspaceCreated from './screens/WorkspaceCreated.tsx'
import Projects from './screens/Projects.tsx'
import NewProject from './screens/NewProject.tsx'
import Catalog from './screens/Catalog.tsx'
import { PackDetail, PackTools } from './screens/Pack.tsx'

const ROUTES: Record<string, ComponentType> = {
  '#/workspace': WorkspaceCreated,
  '#/projects': Projects,
  '#/project/new': NewProject,
  '#/catalog': Catalog,
  '#/packs/refunds': PackDetail,
  '#/packs/refunds/tools': PackTools,
}

// ponytail: hash router, swap for a real router once routes need params or nesting
const subscribe = (cb: () => void) => {
  addEventListener('hashchange', cb)
  return () => removeEventListener('hashchange', cb)
}

export default function App() {
  const hash = useSyncExternalStore(subscribe, () => location.hash)
  const Screen = ROUTES[hash] ?? SignIn
  return <Screen />
}

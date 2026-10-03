import type { ReactNode } from 'react'
import {
  Cpu,
  Folders,
  GitCompare,
  Package,
  Play,
  ShieldAlert,
  Terminal,
  Wallet,
  type LucideIcon,
} from 'lucide-react'
import './AppShell.css'

// ponytail: mock data until Supabase lands — replace with the workspace row + credit_entries balance
export const WORKSPACE = { name: 'Wingsoft Labs', initials: 'WL', units: 8, granted: 8, reserved: 0 }

// href undefined = screen not built yet
const NAV: { label: string; icon: LucideIcon; href?: string; section?: Section }[] = [
  { label: 'Projects', icon: Folders, href: '#/projects', section: 'projects' },
  { label: 'Domain packs', icon: Package, href: '#/catalog', section: 'packs' },
  { label: 'Agents', icon: Cpu },
  { label: 'Runs', icon: Play },
  { label: 'Compare', icon: GitCompare },
  { label: 'Wallet', icon: Wallet },
  { label: 'MCP', icon: Terminal },
]

type Section = 'projects' | 'packs'

export default function AppShell({
  section,
  header,
  children,
}: {
  section: Section
  header: ReactNode
  children: ReactNode
}) {
  const pct = (WORKSPACE.units / WORKSPACE.granted) * 100
  return (
    <div className="shell">
      <aside className="sidebar">
        <a href="#/projects" className="brand">
          <span className="brand-mark">
            <ShieldAlert size={16} />
          </span>
          PREMORTEM
        </a>
        <nav className="nav">
          {NAV.map(({ label, icon: Icon, href, section: s }) => (
            <a
              key={label}
              href={href}
              aria-current={s === section ? 'page' : undefined}
              aria-disabled={href ? undefined : true}
              title={href ? undefined : 'Coming soon'}
            >
              <Icon size={16} />
              {label}
            </a>
          ))}
        </nav>
        <div className="sidebar-foot">
          <div className="units">
            <div>
              <span>Units available</span>
              <b>
                {WORKSPACE.units} / {WORKSPACE.granted}
              </b>
            </div>
            <div
              className="progress progress-sm"
              role="progressbar"
              aria-label="Units available"
              aria-valuemin={0}
              aria-valuemax={WORKSPACE.granted}
              aria-valuenow={WORKSPACE.units}
            >
              <div style={{ width: `${pct}%` }} />
            </div>
            <small>trial grant · {WORKSPACE.reserved} reserved</small>
          </div>
          <div className="member">
            <span className="avatar">{WORKSPACE.initials}</span>
            <div className="member-who">
              <span>{WORKSPACE.name}</span>
              <small>owner · 1 member</small>
            </div>
          </div>
        </div>
      </aside>

      <main className="shell-main">
        <header className="shell-header">{header}</header>
        <div className="shell-body">{children}</div>
      </main>
    </div>
  )
}

export function Stat({ value, label }: { value: ReactNode; label: string }) {
  return (
    <div className="stat">
      <b>{value}</b>
      <span>{label}</span>
    </div>
  )
}

export function Table<T extends Record<string, string>>({
  cols,
  rows,
  selected,
}: {
  cols: { key: keyof T & string; label: string }[]
  rows: T[]
  selected?: number
}) {
  return (
    <div className="table-wrap">
      <table className="table">
        <thead>
          <tr>
            {cols.map((c) => (
              <th key={c.key}>{c.label}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} aria-selected={i === selected || undefined}>
              {cols.map((c) => (
                <td key={c.key}>{r[c.key]}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

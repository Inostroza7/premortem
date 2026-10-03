import { useState } from 'react'
import { Cpu, CreditCard, Globe, Package, Play, Plus, Rocket, Wallet } from 'lucide-react'
import AppShell, { Table, WORKSPACE } from './AppShell.tsx'

// ponytail: mock data until the projects/runs tables exist
const PROJECT_COLS = [
  { key: 'name', label: 'Project' },
  { key: 'cases', label: 'Cases' },
  { key: 'runs', label: 'Runs' },
  { key: 'last', label: 'Last run' },
  { key: 'updated', label: 'Updated' },
] as const
const PROJECTS = [
  { name: 'Support agent — refunds', cases: '1 · refunds@1.0.0', runs: '2', last: 'r_7f3a · running', updated: '2 min ago' },
  { name: 'Scheduling assistant', cases: '1 · calendar@1.0.0', runs: '1', last: 'r_5b90 · 3 failed', updated: '2 days ago' },
  { name: 'Sandbox', cases: '0', runs: '0', last: '—', updated: 'Oct 1' },
]
const RUNS = [
  { id: 'r_7f3a', what: 'refunds@1.0.0 · reference_naive v1 · 4 scenarios × 2', status: 'running · 5/8', tone: 'warn', when: '2 min ago' },
  { id: 'r_6c21', what: 'refunds@1.0.0 · reference_corrected v1 · 4 scenarios × 2', status: '6 passed · 2 safe_stop', tone: 'ok', when: 'yesterday' },
  { id: 'r_5b90', what: 'calendar@1.0.0 · reference_naive v1 · 4 scenarios × 1', status: '1 passed · 3 failed', tone: 'bad', when: '2 days ago' },
]

export default function Projects() {
  const [filter, setFilter] = useState('')
  const rows = PROJECTS.filter((p) => p.name.toLowerCase().includes(filter.toLowerCase()))

  return (
    <AppShell
      section="projects"
      header={
        <>
          <div className="page-title">
            <h1>Projects</h1>
            <span className="muted">
              Workspace created today · {WORKSPACE.granted} trial units granted once
            </span>
          </div>
          <span className="chip">
            <Globe size={12} />
            Environment: simulated
          </span>
          <span className="chip">
            <CreditCard size={12} />
            Billing: Stripe sandbox
          </span>
          <a href="#/project/new" className="btn btn-sm">
            <Plus size={16} />
            New project
          </a>
        </>
      }
    >
      <section className="card banner">
        <span className="icon-tile icon-tile-primary">
          <Rocket size={20} />
        </span>
        <div className="banner-text">
          <b>Welcome to your workspace</b>
          <span className="fg-muted">
            Three steps to a first verdict: pick a domain pack, register an agent version, quote
            and run four worlds. Your {WORKSPACE.granted} trial units cover one full suite × 2
            repetitions.
          </span>
        </div>
        <div className="row">
          <a href="#/catalog" className="btn btn-outline btn-sm">
            <Package size={16} />
            Browse packs
          </a>
          <a className="btn btn-sm" aria-disabled="true" title="Coming soon">
            <Play size={16} />
            Start first run
          </a>
        </div>
      </section>

      <div className="grid">
        <div className="card kpi">
          <span>
            <Wallet size={12} />
            Units available
          </span>
          <b>{WORKSPACE.units}</b>
          <span className="muted">trial grant · {WORKSPACE.reserved} reserved</span>
        </div>
        <div className="card kpi">
          <span>
            <Play size={12} />
            Runs this week
          </span>
          <b>3</b>
          <span className="muted">1 running · 2 finished</span>
        </div>
        <a href="#/catalog" className="card kpi">
          <span>
            <Package size={12} />
            Domain packs
          </span>
          <b>2</b>
          <span className="muted">refunds@1.0.0 · calendar@1.0.0</span>
        </a>
        <div className="card kpi">
          <span>
            <Cpu size={12} />
            Agent versions
          </span>
          <b>3</b>
          <span className="muted">2 reference · 1 model (pending key)</span>
        </div>
      </div>

      <section className="card section">
        <div className="section-head">
          <h2>Your projects</h2>
          <input
            className="input input-sm"
            style={{ width: 240 }}
            placeholder="Filter projects"
            aria-label="Filter projects"
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
          />
        </div>
        <Table cols={[...PROJECT_COLS]} rows={rows} />
      </section>

      <section className="card section">
        <h2>Recent runs</h2>
        <div className="runs">
          {RUNS.map((r) => (
            <div key={r.id} className="run">
              <span className="mono-sm muted">{r.id}</span>
              <span>{r.what}</span>
              <span className={`pill pill-${r.tone}`}>{r.status}</span>
              <span className="muted">{r.when}</span>
            </div>
          ))}
        </div>
      </section>
    </AppShell>
  )
}

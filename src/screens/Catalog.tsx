import { useState, type CSSProperties } from 'react'
import {
  Banknote,
  Calendar,
  ExternalLink,
  FileJson,
  Globe,
  Play,
  PlusCircle,
  ShieldCheck,
  X,
} from 'lucide-react'
import AppShell, { Stat, Table } from './AppShell.tsx'

// ponytail: mirrors GET /api/domain-packs and GET /api/cases until the API exists
const PACKS = [
  {
    id: 'refunds',
    icon: Banknote,
    ref: 'refunds@1.0.0 · sha256 9b1e…4c7a',
    href: '#/packs/refunds',
    desc: 'Partial refunds on paid orders. Models duplicate customers, lost write responses and revoked permissions; effect ',
    effect: 'refund.created',
    stats: [6, 4, 6, 2],
    renderer: 'renderer: ledger (optional)',
  },
  {
    id: 'calendar',
    icon: Calendar,
    ref: 'calendar@1.0.0 · sha256 e07d…21f9',
    href: undefined, // ponytail: only the refunds detail screen is designed so far
    desc: '30-minute meetings with one invitee. Duplicate contacts, lost create responses, revoked permissions; overlapping events are allowed on purpose; effect ',
    effect: 'calendar.event_created',
    stats: [5, 4, 5, 2],
    renderer: 'renderer: none → generic viewer',
  },
]
const STAT_LABELS = ['tools', 'scenarios', 'required rules', 'reference policies']

const SUITE = 'base · duplicate_identity · lost_response · revoked_permission'
const CASE_COLS = [
  { key: 'name', label: 'Case version' },
  { key: 'pack', label: 'Pack' },
  { key: 'task', label: 'Task' },
  { key: 'fixture', label: 'Fixture' },
  { key: 'suite', label: 'Compatible suite' },
] as const
const CASES = [
  { name: 'alex-rivera-headphones · v3', pack: 'refunds@1.0.0', task: 'Refund 2500 USD cents of order PM-1042 (paid 10000)', fixture: 'synthetic · 48 KiB', suite: SUITE },
  { name: 'alex-rivera-30min · v1', pack: 'calendar@1.0.0', task: 'Create 30-min meeting, 2026-11-03T14:00Z → 14:30Z', fixture: 'synthetic · 21 KiB', suite: SUITE },
]

export default function Catalog() {
  const [onboarding, setOnboarding] = useState(true)

  return (
    <AppShell
      section="packs"
      header={
        <>
          <div className="page-title">
            <h1>Domain packs</h1>
            <span className="muted">
              GET /api/domain-packs · trusted packages shipped in the repository · one contract,
              any domain
            </span>
          </div>
          <span className="chip">
            <Globe size={12} />
            Environment: simulated
          </span>
        </>
      }
    >
      {onboarding && (
        <section className="card banner">
          <span className="step-dot step-dot-on">4</span>
          <p>
            <span>
              <b>Onboarding · last step.</b>{' '}
              <span className="fg-muted">
                Project "Support agent — refunds" is ready. Pick a pack to read its tools,
                scenarios and rules, then start your first run: a full suite costs 4 units per
                repetition.
              </span>
            </span>
          </p>
          <button
            className="btn btn-ghost btn-sm btn-icon"
            aria-label="Dismiss"
            onClick={() => setOnboarding(false)}
          >
            <X size={16} />
          </button>
        </section>
      )}

      <div className="grid" style={{ '--min': '420px' } as CSSProperties}>
        {PACKS.map((p) => (
          <article key={p.id} className="card section pack">
            <div className="row row-between">
              <div className="row" style={{ gap: 12 }}>
                <span className="icon-tile">
                  <p.icon size={20} />
                </span>
                <div className="pack-name">
                  <b>{p.id}</b>
                  <span className="mono-sm muted">{p.ref}</span>
                </div>
              </div>
              <span className="chip">
                <ShieldCheck size={12} />
                trusted · in repo
              </span>
            </div>
            <p className="secondary">
              {p.desc}
              <span className="mono-sm">{p.effect}</span>.
            </p>
            <div className="stats-4">
              {p.stats.map((n, i) => (
                <Stat key={i} value={n} label={STAT_LABELS[i]} />
              ))}
            </div>
            <div className="row">
              <a
                href={p.href}
                className="btn btn-outline btn-sm"
                aria-disabled={p.href ? undefined : true}
              >
                <FileJson size={16} />
                View pack
              </a>
              <a className="btn btn-sm" aria-disabled="true" title="Coming soon">
                <Play size={16} />
                New run
              </a>
              <span className="muted" style={{ marginLeft: 'auto' }}>
                {p.renderer}
              </span>
            </div>
          </article>
        ))}
      </div>

      <section className="card section">
        <div className="section-head">
          <h2>Cases in this project</h2>
          <span className="muted">
            GET /api/cases?project_id=… · fixture, visible context and oracle are stored apart; the
            oracle is never served
          </span>
        </div>
        <Table cols={[...CASE_COLS]} rows={CASES} />
      </section>

      <section className="dashed banner">
        <PlusCircle size={18} />
        <p className="secondary">
          <span>
            Adding a third domain is a package plus its conformance tests — no change to the
            runner, queue, billing, event store or this screen.{' '}
            <span className="fg-muted">
              Client-authored packs and OpenAPI/MCP import arrive in P1.
            </span>
          </span>
        </p>
        <a className="btn btn-ghost btn-sm" aria-disabled="true">
          DOMAIN_PACK_SDK.md
          <ExternalLink size={16} />
        </a>
      </section>
    </AppShell>
  )
}

import { useState, type FormEvent } from 'react'
import {
  ArrowLeft,
  ArrowRight,
  Check,
  ChevronRight,
  CircleCheck,
  Coins,
  CreditCard,
  Lock,
  ShieldAlert,
} from 'lucide-react'
import './WorkspaceCreated.css'

// ponytail: mock data until Supabase Auth lands — replace with the session user + workspace row
const USER = { email: 'gus@wingsoft.com', initials: 'GI' }
const TRIAL_UNITS = 8

const STEPS = ['Sign in', 'Workspace', 'First project', 'Catalog']
const CURRENT_STEP = 1

const toSlug = (s: string) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')

export default function WorkspaceCreated() {
  const [name, setName] = useState('Wingsoft Labs')
  const [slug, setSlug] = useState(toSlug('Wingsoft Labs'))

  function onInvite(e: FormEvent) {
    e.preventDefault()
    // ponytail: no invitations backend yet
  }

  return (
    <div className="ws">
      <header className="ws-header">
        <div className="brand">
          <span className="brand-mark">
            <ShieldAlert size={16} />
          </span>
          PREMORTEM
        </div>

        <ol className="steps">
          {STEPS.map((label, i) => (
            <li key={label} aria-current={i === CURRENT_STEP ? 'step' : undefined}>
              {i > 0 && <ChevronRight size={12} aria-hidden="true" />}
              <span className={i <= CURRENT_STEP ? 'step-dot step-dot-on' : 'step-dot'}>
                {i < CURRENT_STEP ? <Check size={12} /> : i + 1}
              </span>
              {label}
            </li>
          ))}
        </ol>

        <span className="chip">
          <CreditCard size={12} />
          Billing: Stripe sandbox
        </span>
      </header>

      <main className="ws-main">
        <div className="ws-grid">
          <section className="card ws-card">
            <div className="ws-title">
              <span className="ws-ok">
                <CircleCheck size={22} />
              </span>
              <div>
                <h1>Workspace created</h1>
                <span>You are its owner. Roles are modelled; P0 ships owner only.</span>
              </div>
            </div>

            <label className="field">
              Workspace name
              <input
                className="input"
                value={name}
                onChange={(e) => setName(e.target.value)}
              />
              <span className="helper">Shown on runs, exports and Stripe receipts.</span>
            </label>
            <label className="field">
              Slug
              <input
                className="input"
                value={slug}
                onChange={(e) => setSlug(toSlug(e.target.value))}
              />
              <span className="helper">premortem.app/w/{slug}</span>
            </label>

            <div className="members">
              <div className="member">
                <span className="avatar">{USER.initials}</span>
                <div className="member-who">
                  <span>{USER.email}</span>
                  <small>owner · workspace_members</small>
                </div>
                <span className="badge">owner</span>
              </div>
              <form className="field" onSubmit={onInvite}>
                <div className="invite">
                  <input
                    className="input input-sm"
                    type="email"
                    placeholder="Invite a teammate by email"
                    aria-label="Invite a teammate by email"
                    required
                  />
                  <button type="submit" className="btn btn-sm">
                    Invite
                  </button>
                </div>
                <span className="helper">
                  Invitations join this workspace; they never create a second trial grant.
                </span>
              </form>
            </div>

            <div className="ws-actions">
              <a href="#/" className="btn btn-ghost btn-sm">
                <ArrowLeft size={16} />
                Back
              </a>
              <a href="#/project/new" className="btn btn-auto">
                Create your first project
                <ArrowRight size={16} />
              </a>
            </div>
          </section>

          <aside className="ws-aside">
            <div className="card trial">
              <span className="trial-label">
                <Coins size={12} />
                Trial grant
              </span>
              <div className="trial-units">
                <span>{TRIAL_UNITS}</span>
                evaluation units
              </div>
              <div
                className="progress"
                role="progressbar"
                aria-label="Trial units available"
                aria-valuemin={0}
                aria-valuemax={TRIAL_UNITS}
                aria-valuenow={TRIAL_UNITS}
              >
                <div style={{ width: '100%' }} />
              </div>
              <p>
                Granted once per workspace. One unit is one simulated world (a{' '}
                <span className="mono">world_job</span>), not a tool call or a report page. A
                full suite — 4 scenarios × 2 repetitions — costs exactly 8.
              </p>
              <dl className="ledger">
                <div>
                  <dt>credit_entries</dt>
                  <dd className="mono">trial_grant +{TRIAL_UNITS}</dd>
                </div>
                <div>
                  <dt>reserved · consumed</dt>
                  <dd className="mono">0 · 0</dd>
                </div>
              </dl>
            </div>

            <div className="never">
              <span>
                <Lock size={14} />
                What the browser never gets
              </span>
              service_role, database keys, provider tokens. Reads go through RLS by membership;
              writes through enumerated SQL functions.
            </div>
          </aside>
        </div>
      </main>
    </div>
  )
}

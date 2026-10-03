import type { FormEvent } from 'react'
import {
  ArrowRight,
  Coins,
  CreditCard,
  FileCheck,
  Globe,
  Package,
  ShieldAlert,
} from 'lucide-react'
import './SignIn.css'

// lucide-react dropped brand icons
function GithubIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12" />
    </svg>
  )
}

export default function SignIn() {
  function onSubmit(e: FormEvent) {
    e.preventDefault()
    // ponytail: no auth yet — wire Supabase Auth + S01b (workspace created) when its ref lands
  }

  return (
    <div className="signin">
      <section className="signin-pitch">
        <div className="brand">
          <span className="brand-mark">
            <ShieldAlert size={16} />
          </span>
          PREMORTEM
        </div>

        <div className="pitch">
          <h1>Test your agent against the world that breaks it.</h1>
          <p>
            Run an agent version in simulated worlds, change the conditions, and get back
            failures backed by evidence — before it touches a real system.
          </p>
          <ul>
            <li>
              <Package size={16} />
              <span>
                Two synthetic domain packs today: <b>refunds@1.0.0</b> and{' '}
                <b>calendar@1.0.0</b>.
              </span>
            </li>
            <li>
              <FileCheck size={16} />
              <span>
                Every verdict is derived from committed effects and rule results, never from
                what the agent says.
              </span>
            </li>
            <li>
              <Coins size={16} />
              <span>
                A new workspace gets <b>8 trial units</b>, once. One unit = one simulated
                world.
              </span>
            </li>
          </ul>
        </div>

        <div className="chips">
          <span className="chip">
            <Globe size={12} />
            Environment: simulated
          </span>
          <span className="chip">
            <CreditCard size={12} />
            Billing: Stripe sandbox
          </span>
        </div>
      </section>

      <section className="signin-form">
        <form onSubmit={onSubmit}>
          <div className="form-head">
            <h2>Sign in</h2>
            <p>Supabase Auth · your workspace is created on first sign-in.</p>
          </div>

          <label className="field">
            Work email
            <input
              className="input"
              type="email"
              name="email"
              placeholder="you@company.com"
              autoComplete="email"
              required
            />
          </label>
          <label className="field">
            Password
            <input
              className="input"
              type="password"
              name="password"
              placeholder="••••••••"
              autoComplete="current-password"
              required
            />
          </label>

          <button type="submit" className="btn">
            Continue
            <ArrowRight size={16} />
          </button>

          <div className="or">
            <span className="separator" />
            or
            <span className="separator" />
          </div>

          <button type="button" className="btn btn-outline">
            <GithubIcon />
            Continue with GitHub
          </button>

          <label className="check">
            <input type="checkbox" name="createWorkspace" />
            <span>
              Create a new workspace for me
              <small>Skip this if you were invited to an existing workspace.</small>
            </span>
          </label>

          <p className="fine">
            No credentials, provider keys or service roles ever reach the browser.
          </p>
        </form>
      </section>
    </div>
  )
}

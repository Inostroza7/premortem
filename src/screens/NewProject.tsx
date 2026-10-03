import { useEffect, useRef, type FormEvent } from 'react'
import { FolderPlus, Globe, Plus, X } from 'lucide-react'
import AppShell from './AppShell.tsx'
import './NewProject.css'

const PACKS = [
  { value: '', label: 'Pick later from the catalog' },
  { value: 'refunds', label: 'refunds@1.0.0 — Alex Rivera headphones refund' },
  { value: 'calendar', label: 'calendar@1.0.0 — 30-minute meeting with Alex Rivera' },
]

const cancel = () => (location.hash = '#/workspace')

export default function NewProject() {
  const dialog = useRef<HTMLDialogElement>(null)
  const open = () => {
    if (!dialog.current?.open) dialog.current?.showModal()
  }
  useEffect(open, [])

  function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    // ponytail: no projects table yet — insert the row (+ demo case version if a pack is picked) here
    const openCatalog = new FormData(e.currentTarget).get('openCatalog')
    location.hash = openCatalog ? '#/catalog' : '#/projects'
  }

  return (
    <AppShell
      section="projects"
      header={
        <>
          <div className="page-title">
            <h1>Projects</h1>
            <span className="muted">
              No projects yet · a project groups cases and runs inside the workspace
            </span>
          </div>
          <span className="chip">
            <Globe size={12} />
            Environment: simulated
          </span>
          <button className="btn btn-sm" onClick={open}>
            <Plus size={16} />
            New project
          </button>
        </>
      }
    >
      <section className="dashed empty">
        <span className="icon-tile">
          <FolderPlus size={22} />
        </span>
        <b>Create your first project</b>
        <span>
          A project holds case versions and runs. You can add cases from both domain packs to the
          same project.
        </span>
      </section>

      <dialog ref={dialog} className="np" aria-labelledby="np-title" onCancel={cancel}>
        <form onSubmit={onSubmit}>
          <div className="np-head">
            <div>
              <h2 id="np-title">New project</h2>
              <p>
                Step 3 of 4 · Projects group cases and runs; the workspace stays the billing
                boundary.
              </p>
            </div>
            <button type="button" className="btn btn-ghost btn-sm btn-icon" aria-label="Close" onClick={cancel}>
              <X size={16} />
            </button>
          </div>

          <label className="field">
            Project name
            <input
              className="input"
              name="name"
              defaultValue="Support agent — refunds"
              placeholder="Support agent — refunds"
              required
            />
          </label>
          <label className="field">
            Description
            <textarea
              className="input textarea"
              name="description"
              rows={3}
              placeholder="What this agent is supposed to do, for your teammates"
            />
          </label>
          <label className="field">
            Start from a domain pack (optional)
            <select className="input" name="pack" defaultValue="refunds">
              {PACKS.map((p) => (
                <option key={p.value} value={p.value}>
                  {p.label}
                </option>
              ))}
            </select>
            <span className="helper">
              Adds the pack's demo case version to the project. Nothing is reserved or run.
            </span>
          </label>
          <label className="check">
            <input type="checkbox" name="openCatalog" />
            <span>
              Open the catalog after creating
              <small>Continues to step 4.</small>
            </span>
          </label>

          <div className="np-actions">
            <button type="button" className="btn btn-outline btn-sm" onClick={cancel}>
              Cancel
            </button>
            <button type="submit" className="btn btn-sm">
              <FolderPlus size={16} />
              Create project
            </button>
          </div>
        </form>
      </dialog>
    </AppShell>
  )
}

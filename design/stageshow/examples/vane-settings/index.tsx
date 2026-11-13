import {
  Paintbrush, LayoutGrid, ShieldCheck, Search, KeyRound, Puzzle, ArrowDownToLine, Info, Plus, GripVertical, Lock,
} from 'lucide-react'
import { Bar, Segmented, Stage, Toggle, Window, type Act } from '../../kit'
import './settings.css'

// Vane Settings dashboard, design check for the native SwiftUI build.
// Sidebar nav in a floating panel; each page is a grid of cards. Two states:
// Appearance (live preview card + controls) and Spaces (list + gradient editor).

type S = { page: 'appearance' | 'spaces' }
const initial: S = { page: 'appearance' }

async function script(a: Act<S>) {
  a.mark('appearance')
  await a.wait(2500)
  await a.set({ page: 'spaces' })
  a.mark('spaces')
  await a.wait(2500)
  await a.set({ page: 'appearance' })
}

const NAV = [
  ['appearance', 'Appearance', Paintbrush], ['spaces', 'Spaces', LayoutGrid], ['privacy', 'Privacy & Security', ShieldCheck],
  ['search', 'Search & Tabs', Search], ['pw', 'Passwords', KeyRound], ['ext', 'Extensions', Puzzle],
  ['dl', 'Downloads', ArrowDownToLine], ['about', 'About', Info],
] as const

const PRESETS: [string, string, string][] = [
  ['Lagoon', '#9ee0d6', '#5cb3c7'], ['Dusk', '#fabd9e', '#cc85bd'], ['Grape', '#c7b3fa', '#8575e0'], ['Meadow', '#cceb9e', '#7ac280'],
  ['Ember', '#ffcc75', '#f07557'], ['Ocean', '#99c7ff', '#4d75db'], ['Rose', '#ffc7d6', '#e6809e'], ['Graphite', '#ccced6', '#8f94a1'],
  ['Midnight', '#333857', '#171729'], ['Forest', '#2e5747', '#122921'],
]

export default function VaneSettings({ theme }: { theme?: 'light' | 'dark' }) {
  return (
    <Stage<S> width={1040} height={660} initial={initial} poster={initial} script={script}
      accent="#0e8a7e" greys="cool" theme={theme} ground={['#bfe3dc', '#c9d8f2', '#e6dcf0']} className="as-stage">
      {(s) => (
        <Window className="as-window" sidebarWidth={210} sidebarStyle="floating" lightsSize="large"
          sidebar={<Side page={s.page} />} body={{ className: 'as-body' }}>
          {s.page === 'appearance' ? <Appearance /> : <Spaces />}
        </Window>
      )}
    </Stage>
  )
}

function Side({ page }: { page: string }) {
  return (
    <div className="as-side">
      {NAV.map(([id, label, I]) => (
        <div key={id} className="as-nav" data-on={id === page || undefined}>
          <span className="as-nav__ic"><I size={14} strokeWidth={1.9} /></span>{label}
        </div>
      ))}
    </div>
  )
}

function Card({ title, help, children, className }: { title: string; help?: string; children: React.ReactNode; className?: string }) {
  return (
    <section className={'as-card ' + (className ?? '')}>
      <h3>{title}</h3>
      {help && <p className="as-help">{help}</p>}
      {children}
    </section>
  )
}

function Slider({ label, value, pct }: { label: string; value: string; pct: number }) {
  return (
    <div className="as-row">
      <span>{label}</span>
      <div className="as-slider"><i style={{ width: `${pct}%` }} /><b style={{ left: `${pct}%` }} /></div>
      <span className="as-val">{value}</span>
    </div>
  )
}

function Preview({ a, b }: { a: string; b: string }) {
  return (
    <div className="as-prev" style={{ background: `linear-gradient(${a}, ${b})` }}>
      <div className="as-prev__side">
        <span className="as-prev__lights"><i /><i /><i /></span>
        <span className="as-prev__url" />
        {[70, 52, 84, 60, 44].map((w, i) => <span key={i} className="as-prev__tab" data-on={i === 1 || undefined}><Bar w={w} h={5} tone={3} /></span>)}
      </div>
      <div className="as-prev__page">
        <Bar w={140} h={9} tone={4} />
        {[92, 100, 84, 96, 60].map((p, i) => <Bar key={i} w={`${p}%` as never} h={5} tone={2} />)}
      </div>
    </div>
  )
}

function Appearance() {
  return (
    <div className="as-page">
      <header><h1>Appearance</h1><p>How Vane looks across every window.</p></header>
      <div className="as-grid as-grid--app">
        <Card title="Preview" className="as-span2">
          <Preview a="#9ee0d6" b="#5cb3c7" />
        </Card>
        <Card title="Theme" help="Follow macOS, or keep Vane light or dark.">
          <Segmented items={['System', 'Light', 'Dark']} value={0} />
          <div className="as-row as-row--toggle"><span>Tint window with space color</span><Toggle on /></div>
        </Card>
        <Card title="Layout" help="Sizes of the sidebar and page card.">
          <div className="as-row"><span>Density</span><Segmented items={['Compact', 'Comfortable', 'Spacious']} value={1} /></div>
          <Slider label="Corner radius" value="12 pt" pct={50} />
          <Slider label="Text size" value="13 pt" pct={40} />
          <Slider label="Card inset" value="8 pt" pct={33} />
        </Card>
      </div>
    </div>
  )
}

function Spaces() {
  const list: [string, string, string, number][] = [['Personal', '#9ee0d6', '#5cb3c7', 14], ['Work', '#c7b3fa', '#8575e0', 9], ['Research', '#fabd9e', '#cc85bd', 4]]
  return (
    <div className="as-page">
      <header><h1>Spaces</h1><p>Each space has its own tabs, gradient and, optionally, its own cookies.</p></header>
      <div className="as-grid as-grid--spaces">
        <Card title="Your spaces" className="as-list">
          {list.map(([n, a, b, c], i) => (
            <div key={n} className="as-space" data-on={i === 1 || undefined}>
              <GripVertical size={12} className="as-grip" />
              <span className="as-dot" style={{ background: `linear-gradient(${a}, ${b})` }} />
              <span className="as-space__name">{n}</span><span className="as-val">{c}</span>
            </div>
          ))}
          <div className="as-add"><Plus size={13} /> New Space</div>
        </Card>
        <div className="as-col">
          <Card title="Work">
            <div className="as-hero" style={{ background: 'linear-gradient(#c7b3fa, #8575e0)' }}><span>Work</span></div>
            <div className="as-row"><span>Name</span><span className="as-field">Work</span></div>
            <div className="as-row"><span><Lock size={11} /> Separate cookies & logins</span><span className="as-val">Own profile · 9 tabs</span></div>
          </Card>
          <Card title="Gradient" help="Pick a preset or set the top and bottom colors.">
            <div className="as-swatches">
              {PRESETS.map(([n, a, b]) => <span key={n} className="as-sw" data-on={n === 'Grape' || undefined} style={{ background: `linear-gradient(${a}, ${b})` }} />)}
            </div>
            <div className="as-row"><span>Top</span><span className="as-well" style={{ background: '#c7b3fa' }} /><span>Bottom</span><span className="as-well" style={{ background: '#8575e0' }} /></div>
            <Slider label="Intensity" value="70%" pct={70} />
            <div className="as-row as-row--toggle"><span>Film grain</span><Toggle on /></div>
          </Card>
        </div>
      </div>
    </div>
  )
}

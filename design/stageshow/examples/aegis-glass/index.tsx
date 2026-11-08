import { type ReactNode } from 'react'
import {
  ArrowDownToLine,
  ArrowLeft,
  ArrowRight,
  BookOpen,
  CalendarDays,
  Clock,
  Inbox,
  MessageSquare,
  Music2,
  Plus,
  RotateCw,
  Search,
  ShieldCheck,
} from 'lucide-react'
import { Bar, Field, Popover, Stage, Text, Window, type Act, type Layout } from '../../kit'
import './aegis.css'

// Aegis, direction A ("Glass"): an original sidebar browser for macOS 26.
// A floating glass sidebar holds the address pill, a favorites grid, pinned
// tabs and today's tabs; the page sits in an opaque inset card. The story is
// the command palette: ⌘K, type "own", and the open tab, a history match and
// Reader Mode are one list, ranked together.
//
// Structure copied from examples/linear (sidebar window, inset panel, command
// menu over a scrim); the floating sidebar from examples/finder-glass.

type S = { open: boolean; query: string }
const initial: S = { open: false, query: '' }
const poster: S = { open: true, query: 'own' }

async function script(a: Act<S>) {
  await a.wait(900)
  a.mark('open')
  await a.key('cmd+k')
  await a.set({ open: true })
  await a.wait(500)
  await a.type('query', 'own', { interval: 110 })
  await a.wait(3200)
  a.mark('close')
  await a.key('escape')
  await a.set({ open: false, query: '' })
  await a.wait(1200)
}

type Result = { section?: string; icon: ReactNode; title: string; meta?: string; key?: string }
const ic = { size: 15, strokeWidth: 1.7 }
const RESULTS: Result[] = [
  { section: 'Switch to tab', icon: <span className="ab-fav ab-fav--book" />, title: 'Understanding Ownership', meta: 'Today' , key: '↵' },
  { section: 'History', icon: <Clock {...ic} />, title: 'Ownership and borrowing in practice', meta: 'Tuesday' },
  { section: 'Actions', icon: <BookOpen {...ic} />, title: 'Open in Reader', key: '⇧⌘R' },
]

export default function AegisGlass({ theme }: { theme?: 'light' | 'dark' }) {
  return (
    <Stage<S>
      width={960}
      height={520}
      compact={{ below: 620, width: 400, height: 380 }}
      initial={initial}
      poster={poster}
      script={script}
      accent="#0e8a7e"
      greys="cool"
      theme={theme}
      ground={['#bfe3dc', '#c9d8f2', '#e6dcf0']}
      className="ab-stage"
    >
      {(s, _rect, layout) => <Scene s={s} layout={layout} />}
    </Stage>
  )
}

export function Scene({ s, layout }: { s: S; layout: Layout }) {
  const compact = layout === 'compact'
  const q = s.query
  return (
    <>
      <Window
        className="ab-window"
        sidebar={compact ? undefined : <Sidebar />}
        sidebarWidth={236}
        sidebarStyle="floating"
        lightsSize="large"
        body={{ className: 'ab-body', 'data-crop': true }}
      >
        <Page compact={compact} />
      </Window>

      <div className="ab-scrim" data-show={s.open || undefined} />
      <Popover show={s.open} origin="top center" className="ab-cmd">
        <div className="ab-cmd__head">
          <Search size={16} strokeWidth={1.8} className="ab-cmd__glass" />
          <Field value={q} placeholder="Search tabs, history, or type a command" focused={s.open} className="ab-cmd__field" />
          <span className="ab-cmd__scope">All</span>
        </div>
        <div className="ab-cmd__list">
          {RESULTS.map((r, i) => (
            <div key={r.title}>
              {r.section && <div className="ab-cmd__section">{r.section}</div>}
              <div className="ab-cmd__item" data-active={i === 0 || undefined}>
                <span className="ab-cmd__icon">{r.icon}</span>
                <span className="ab-cmd__title"><Hl text={r.title} q={q} /></span>
                {r.meta && <span className="ab-cmd__meta">{r.meta}</span>}
                {r.key && <span className="ab-cmd__key">{r.key}</span>}
              </div>
            </div>
          ))}
        </div>
        <div className="ab-cmd__foot">
          <ShieldCheck size={13} strokeWidth={1.8} />
          <span>Results stay on this Mac</span>
        </div>
      </Popover>
    </>
  )
}

function Sidebar() {
  const nav = { size: 15, strokeWidth: 1.8 }
  return (
    <div className="ab-side">
      <div className="ab-nav">
        <ArrowLeft {...nav} />
        <ArrowRight {...nav} className="ab-off" />
        <RotateCw {...nav} />
      </div>

      <div className="ab-url">
        <ShieldCheck size={13} strokeWidth={1.9} className="ab-url__shield" />
        <span className="ab-url__host">doc.rust-lang.org</span>
        <span className="ab-url__count">14</span>
      </div>

      <div className="ab-favs">
        {[<Inbox {...nav} />, <CalendarDays {...nav} />, <MessageSquare {...nav} />, <Music2 {...nav} />].map((g, i) => (
          <span key={i} className="ab-favs__tile">{g}</span>
        ))}
      </div>

      <div className="ab-group">
        <Tab w={92} pinned />
        <Tab w={70} pinned />
      </div>

      <div className="ab-rule">
        <span className="ab-rule__label">Today</span>
        <span className="ab-rule__line" />
      </div>

      <div className="ab-group">
        <div className="ab-tab ab-tab--new">
          <Plus size={14} strokeWidth={1.8} />
          <span>New Tab</span>
        </div>
        <div className="ab-tab" data-active>
          <span className="ab-fav ab-fav--book" />
          <Text className="ab-tab__title">Understanding Ownership</Text>
        </div>
        <Tab w={104} />
        <Tab w={78} />
        <Tab w={118} />
        <Tab w={86} sleeping />
        <Tab w={98} sleeping />
        <Tab w={64} sleeping />
        <Tab w={110} sleeping />
      </div>

      <div className="ab-foot">
        <span className="ab-spaces">
          <span className="ab-spaces__dot" data-on />
          <span className="ab-spaces__dot" />
          <span className="ab-spaces__dot" />
        </span>
        <ArrowDownToLine size={15} strokeWidth={1.8} className="ab-foot__icon" />
      </div>
    </div>
  )
}

function Tab({ w, pinned, sleeping }: { w: number; pinned?: boolean; sleeping?: boolean }) {
  return (
    <div className="ab-tab" data-pinned={pinned || undefined} data-sleeping={sleeping || undefined}>
      <span className="ab-fav" />
      <Bar w={w} h={6} tone={3} />
    </div>
  )
}

/** The page: a documentation article, all filler; the palette is the subject. */
function Page({ compact }: { compact: boolean }) {
  return (
    <div className="ab-page">
      <div className="ab-page__col">
        <Bar w={compact ? 180 : 320} h={14} tone={4} className="ab-page__h1" />
        {[96, 100, 88, 94, 60].map((p, i) => (
          <Bar key={i} w={`${p}%` as never} h={7} tone={2} />
        ))}
        <div className="ab-page__code">
          {[62, 48, 74, 40].map((p, i) => (
            <Bar key={i} w={`${p}%` as never} h={6} tone={3} />
          ))}
        </div>
        {[100, 92, 97, 70].map((p, i) => (
          <Bar key={i} w={`${p}%` as never} h={7} tone={2} />
        ))}
      </div>
    </div>
  )
}

/** Bolds the first match of the query, the way the ranking found it. */
function Hl({ text, q }: { text: string; q: string }) {
  const i = q ? text.toLowerCase().indexOf(q.toLowerCase()) : -1
  if (i < 0) return <>{text}</>
  return (
    <>
      {text.slice(0, i)}
      <b>{text.slice(i, i + q.length)}</b>
      {text.slice(i + q.length)}
    </>
  )
}

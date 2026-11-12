import { ArrowLeft, ArrowRight, RotateCw, Plus, ShieldCheck, PanelLeft, Columns2, Home, Briefcase, FlaskConical } from 'lucide-react'
import { Bar, Stage, Text, Window, type Act } from '../../kit'
import '../aegis-glass/aegis.css'
import '../aegis-themed/themed.css'
import '../aegis-arc-plus/plus.css'
import './split.css'

// Split view + sidebar collapse, before building it natively.
// Beats: two panes, left focused → click the right pane (ring moves, sidebar segment follows)
// → click the sidebar button by the lights (sidebar folds, panes go edge to edge)
// → pointer to the left edge: the sidebar peeks in over the page.
type S = { focus: 0 | 1; collapsed: boolean; peek: boolean }
const initial: S = { focus: 0, collapsed: false, peek: false }

async function script(a: Act<S>) {
  await a.wait(1400)
  await a.move('right-pane', { duration: 700 })
  await a.click()
  a.set({ focus: 1 })
  await a.wait(1600)
  await a.move('collapse', { duration: 800 })
  await a.click()
  a.set({ collapsed: true })
  await a.wait(1600)
  await a.move('edge', { duration: 700 })
  a.set({ peek: true })
  await a.wait(2200)
  await a.move('right-pane', { duration: 700 })
  a.set({ peek: false })
  await a.wait(900)
  await a.move('reopen', { duration: 700 })
  await a.click()
  a.set({ collapsed: false, focus: 0 })
  await a.wait(1200)
}

const fav = (c: string, l: string) => <span className="ap-fav" style={{ background: c }}>{l}</span>

export default function AegisSplit({ theme }: { theme?: 'light' | 'dark' }) {
  return (
    <Stage<S> width={1040} height={620} initial={initial} poster={{ focus: 0, collapsed: false, peek: false }} script={script}
      accent="#0e8a7e" greys="cool" theme={theme} cursor={{ at: 'left-pane' }} className="ab-stage at-stage ap-stage as-stage">
      {(s) => <Scene s={s} />}
    </Stage>
  )
}

function Panes({ s }: { s: S }) {
  return (
    <div className="as-panes">
      <div className="as-pane" data-focus={s.focus === 0 || undefined} data-target="left-pane">
        <div className="as-pane__page">
          <div className="as-doc__h"><Text>Q4 planning notes</Text></div>
          {[92, 100, 84, 96, 70].map((p, i) => <Bar key={i} w={`${p}%` as never} h={7} tone={2} />)}
          <div className="as-doc__gap" />
          {[88, 94, 60].map((p, i) => <Bar key={i} w={`${p}%` as never} h={7} tone={2} />)}
        </div>
      </div>
      <div className="as-pane" data-focus={s.focus === 1 || undefined} data-target="right-pane">
        <div className="as-pane__page as-pane__page--video">
          <div className="as-video" />
          <div className="as-doc__h"><Text>Design review — recording</Text></div>
          {[72, 50].map((p, i) => <Bar key={i} w={`${p}%` as never} h={7} tone={2} />)}
        </div>
      </div>
    </div>
  )
}

function Scene({ s }: { s: S }) {
  return (
    <div className="as-root" data-collapsed={s.collapsed || undefined}>
      <Window className="ab-window as-window" sidebar={<Side s={s} />} sidebarWidth={s.collapsed ? 0 : 236} sidebarStyle="floating" lightsSize="large" body={{ className: 'ab-body as-body', 'data-crop': true }}>
        <Panes s={s} />
      </Window>
      <span className="as-reopen" data-target="reopen" data-show={s.collapsed && !s.peek || undefined}><PanelLeft size={15} strokeWidth={1.8} /></span>
      <span className="as-edge" data-target="edge" />
      <div className="as-peek" data-show={s.collapsed && s.peek || undefined}><Side s={s} peek /></div>
    </div>
  )
}

function Side({ s, peek }: { s: S; peek?: boolean }) {
  const nav = { size: 15, strokeWidth: 1.8 }
  return (
    <div className="ab-side as-side">
      <div className="as-top">
        {peek && <span className="as-lights"><i /><i /><i /></span>}
        <span className="as-toggle" data-target={peek ? undefined : 'collapse'}><PanelLeft size={15} strokeWidth={1.8} /></span>
        <span className="as-top__nav"><ArrowLeft {...nav} /><ArrowRight {...nav} className="ab-off" /><RotateCw {...nav} /></span>
      </div>
      <div className="ab-url"><ShieldCheck size={13} strokeWidth={1.9} className="ab-url__shield" /><span className="ab-url__host">{s.focus === 0 ? 'docs.example.com' : 'video.example.com'}</span></div>
      <div className="ab-group">
        <div className="ab-tab"><span className="ab-fav" /><Bar w={92} h={6} tone={3} /></div>
        <div className="ab-tab"><span className="ab-fav" /><Bar w={70} h={6} tone={3} /></div>
      </div>
      <div className="ab-rule"><span className="ab-rule__label">Today</span><span className="ab-rule__line" /><span className="ap-clear">Clear</span></div>
      <div className="ab-group">
        <div className="ab-tab ab-tab--new"><Plus size={14} strokeWidth={1.8} /><span>New Tab</span></div>
        <div className="as-splitrow" data-active>
          <span className="as-seg" data-focus={s.focus === 0 || undefined}>{fav('#1a73e8', 'D')}<Text className="as-seg__t">Q4 planning</Text></span>
          <span className="as-seg" data-focus={s.focus === 1 || undefined}>{fav('#e5484d', '▶')}<Text className="as-seg__t">Design review</Text></span>
        </div>
        <div className="ab-tab"><span className="ab-fav" /><Bar w={104} h={6} tone={3} /></div>
        <div className="ab-tab"><span className="ab-fav" /><Bar w={78} h={6} tone={3} /></div>
      </div>
      <div className="ab-foot ap-foot as-foot">
        <span className="ap-spaces">
          <span className="ap-space" data-on style={{ background: 'linear-gradient(#9fe0d6,#5cb3c7)' }}><Home size={11} strokeWidth={2.2} /></span>
          <span className="ap-space" style={{ background: 'linear-gradient(#c7b3fa,#8575e0)' }}><Briefcase size={11} strokeWidth={2.2} /></span>
          <span className="ap-space" style={{ background: 'linear-gradient(#fbbc9e,#cc85bd)' }}><FlaskConical size={11} strokeWidth={2.2} /></span>
        </span>
        <span style={{ flex: 1 }} />
        <Columns2 size={15} strokeWidth={1.8} className="ab-foot__icon" />
      </div>
    </div>
  )
}

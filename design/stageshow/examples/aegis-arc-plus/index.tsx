import { ArrowLeft, ArrowRight, RotateCw, Plus, ShieldCheck, Search, Pause, PictureInPicture2, ArrowDownToLine, Clock, Briefcase, Home, FlaskConical, Download } from 'lucide-react'
import { Bar, Stage, Text, Window, type Act, type Layout } from '../../kit'
import '../aegis-glass/aegis.css'
import '../aegis-themed/themed.css'
import './plus.css'

// Taste-review mockup of proposed fixes over the shipped themed window:
// 1. footer space switcher = coloured, iconed chips (not grey dots),
// 2. favorites 4-up with real favicons and a "playing" dot,
// 3. a quiet "Pinned" boundary,
// 4. now-playing strip with artwork + progress hairline,
// 5. ⌘T zero state: an "Import from Arc" card and favicon rows, palette sprung in.
type S = { open: boolean }
const initial: S = { open: true }
async function script(a: Act<S>) { await a.wait(4000) }

const fav = (c: string, l: string) => <span className="ap-fav" style={{ background: c }}>{l}</span>

export default function AegisArcPlus({ theme }: { theme?: 'light' | 'dark' }) {
  return (
    <Stage<S> width={1040} height={620} initial={initial} poster={initial} script={script}
      accent="#0e8a7e" greys="cool" theme={theme} className="ab-stage at-stage ap-stage">
      {(s, _r, layout) => <Scene s={s} layout={layout} />}
    </Stage>
  )
}

function Scene({ s }: { s: S; layout: Layout }) {
  return (
    <>
      <Window className="ab-window" sidebar={<Side />} sidebarWidth={236} sidebarStyle="floating" lightsSize="large" body={{ className: 'ab-body', 'data-crop': true }}>
        <div className="ab-page"><div className="ab-page__col">
          <Bar w={300} h={14} tone={4} />
          {[96, 100, 88, 94, 60, 92, 80].map((p, i) => <Bar key={i} w={`${p}%` as never} h={7} tone={2} />)}
        </div></div>
      </Window>
      <div className="ab-scrim ap-scrim" data-show={s.open || undefined} />
      <div className="ab-cmd ap-cmd" data-show={s.open || undefined}>
        <div className="ab-cmd__head">
          <Search size={16} strokeWidth={1.8} className="ab-cmd__glass" />
          <span className="ap-ph">Search or enter address</span>
        </div>
        <div className="ap-arc">
          <div className="ap-arc__mark"><Download size={15} strokeWidth={2} /></div>
          <div className="ap-arc__copy"><b>Coming from Arc?</b><span>Bring 4 spaces, 12 favorites and your pinned tabs.</span></div>
          <span className="ap-arc__btn">Import</span>
        </div>
        <div className="ab-cmd__list">
          <div className="ab-cmd__section">Jump back in</div>
          <div className="ab-cmd__item" data-active><span className="ab-cmd__icon">{fav('#ff6600', 'Y')}</span><span className="ab-cmd__title">Hacker News</span><span className="ab-cmd__meta">news.ycombinator.com</span><span className="ab-cmd__key">↵</span></div>
          <div className="ab-cmd__item"><span className="ab-cmd__icon">{fav('#24292f', 'G')}</span><span className="ab-cmd__title">aegis-browser · Pull requests</span><span className="ab-cmd__meta">github.com</span></div>
          <div className="ab-cmd__item"><span className="ab-cmd__icon"><Clock size={15} strokeWidth={1.7} /></span><span className="ab-cmd__title">Understanding Ownership</span><span className="ab-cmd__meta">Yesterday</span></div>
        </div>
        <div className="ab-cmd__foot"><ShieldCheck size={13} strokeWidth={1.8} /><span>Results stay on this Mac</span></div>
      </div>
    </>
  )
}

function Side() {
  const nav = { size: 15, strokeWidth: 1.8 }
  return (
    <div className="ab-side">
      <div className="ab-nav"><ArrowLeft {...nav} /><ArrowRight {...nav} className="ab-off" /><RotateCw {...nav} /></div>
      <div className="ab-url"><ShieldCheck size={13} strokeWidth={1.9} className="ab-url__shield" /><span className="ab-url__host">news.ycombinator.com</span></div>
      <div className="ap-favs">
        {[fav('#ea4335', 'M'), fav('#1a73e8', '31'), fav('#4a154b', 'S'), fav('#1db954', '♫')].map((g, i) => (
          <span key={i} className="ap-tile" data-live={i === 3 || undefined}>{g}</span>
        ))}
      </div>
      <div className="ab-group">
        <div className="ab-tab"><span className="ab-fav" /><Bar w={92} h={6} tone={3} /></div>
        <div className="ab-tab"><span className="ab-fav" /><Bar w={70} h={6} tone={3} /></div>
      </div>
      <div className="ab-rule"><span className="ab-rule__label">Today</span><span className="ab-rule__line" /><span className="ap-clear">Clear</span></div>
      <div className="ab-group">
        <div className="ab-tab ab-tab--new"><Plus size={14} strokeWidth={1.8} /><span>New Tab</span></div>
        <div className="ab-tab" data-active>{fav('#ff6600', 'Y')}<Text className="ab-tab__title">Hacker News</Text></div>
        <div className="ab-tab"><span className="ab-fav" /><Bar w={104} h={6} tone={3} /></div>
        <div className="ab-tab"><span className="ab-fav" /><Bar w={78} h={6} tone={3} /></div>
        
      </div>
      <div className="ap-np">
        <span className="ap-np__art" />
        <div className="ap-np__txt"><b>Lofi Girl</b><span>beats to relax/study to</span></div>
        <PictureInPicture2 size={14} strokeWidth={1.8} /><Pause size={14} strokeWidth={2.2} />
        <span className="ap-np__bar"><i /></span>
      </div>
      <div className="ab-foot ap-foot">
        <span className="ap-spaces">
          <span className="ap-space" data-on style={{ background: 'linear-gradient(#9fe0d6,#5cb3c7)' }}><Home size={11} strokeWidth={2.2} /></span>
          <span className="ap-space" style={{ background: 'linear-gradient(#c7b3fa,#8575e0)' }}><Briefcase size={11} strokeWidth={2.2} /></span>
          <span className="ap-space" style={{ background: 'linear-gradient(#fbbc9e,#cc85bd)' }}><FlaskConical size={11} strokeWidth={2.2} /></span>
        </span>
        <span className="ap-foot__name">Personal</span>
        <ArrowDownToLine size={15} strokeWidth={1.8} className="ab-foot__icon" /><Plus size={15} strokeWidth={1.8} className="ab-foot__icon" />
      </div>
    </div>
  )
}

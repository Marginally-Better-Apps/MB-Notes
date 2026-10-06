import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type PointerEvent } from 'react';
import QRCode from 'qrcode';
import { runtime } from './runtime';
import { native } from './network';
import { newID, type Content, type Point } from '../../Packages/NoteEngine/Collaboration/session';
import './style.css';

type Tool = 'pen' | 'text' | 'laser';
function Icon({ name }: { name: Tool | 'share' }) {
  const paths = { pen: 'M4 20l4-1 12-12-3-3L5 16z M14 6l4 4', text: 'M4 5h16 M12 5v15 M8 20h8', laser: 'M12 3v4 M12 17v4 M3 12h4 M17 12h4 M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6', share: 'M12 15V3 M7 8l5-5 5 5 M5 13v8h14v-8' };
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d={paths[name]} /></svg>;
}
export function App() {
  useSyncExternalStore(runtime.subscribe, runtime.snapshot);
  const [invite, setInvite] = useState('');
  const [tool, setTool] = useState<Tool>('pen');
  const [points, setPoints] = useState<Point[]>([]);
  const [draft, setDraft] = useState<{ x: number; y: number; text: string }>();
  const [sharing, setSharing] = useState(false);
  const [qr, setQR] = useState('');
  const [forceRelay, setForceRelay] = useState(localStorage.getItem('mb-force-relay') === 'yes');
  const [settings, setSettings] = useState(false);
  const [ice, setICE] = useState(localStorage.getItem('mb-ice-servers') || '');
  const [iceError, setICEError] = useState('');
  const workspace = useRef<HTMLElement>(null);
  const [paperSize, setPaperSize] = useState({ width: 0, height: 0 });
  const stage = useRef<SVGSVGElement>(null);
  const pointer = useRef<number | undefined>(undefined);
  const lastLaser = useRef(0);
  const ownHistory = useRef<string[]>([]);
  const doc = runtime.document;
  const page = doc?.pages.find(p => p.id === runtime.pageID) ?? doc?.pages[0];
  const objects = doc?.objects.filter(o => o.pageID === page?.id) ?? [];
  useEffect(() => {
    const hash = new URLSearchParams(location.hash.slice(1)).get('mb');
    if (hash && !window.webkit?.messageHandlers?.collaboration) runtime.join(location.href);
    native({ type: 'ready' });
  }, []);
  useEffect(() => {
    if (sharing) void QRCode.toDataURL(runtime.link(runtime.publicURL || location.href), { width: 280, margin: 2, color: { dark: '#4C3AD6', light: '#FFFFFF' } }).then(setQR);
  }, [sharing]);
  useEffect(() => { setPoints([]); closeDraft(); pointer.current = undefined; }, [runtime.connected, page?.id]);
  useLayoutEffect(() => {
    if (!workspace.current || !page) return;
    const element = workspace.current;
    const measure = () => {
      const style = getComputedStyle(element);
      const width = element.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
      const height = element.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
      const scale = Math.min(width / page.width, height / page.height);
      setPaperSize({ width: page.width * scale, height: page.height * scale });
    };
    measure();
    const observer = new ResizeObserver(measure); observer.observe(element);
    return () => observer.disconnect();
  }, [doc?.id, page?.id, page?.width, page?.height]);
  function point(event: PointerEvent): Point {
    const local = new DOMPoint(event.clientX, event.clientY).matrixTransform(stage.current!.getScreenCTM()!.inverse());
    return { x: Math.max(0, Math.min(page!.width, local.x)), y: Math.max(0, Math.min(page!.height, local.y)) };
  }
  function down(event: PointerEvent<SVGSVGElement>) {
    if (!runtime.connected || !page || pointer.current !== undefined) return;
    const p = point(event);
    if (tool === 'text') { setDraft({ ...p, text: '' }); return; }
    pointer.current = event.pointerId;
    event.currentTarget.setPointerCapture(event.pointerId);
    if (tool === 'pen') setPoints([p]);
    else laser(p);
  }
  function laser(p: Point) {
    if (Date.now() - lastLaser.current < 65) return;
    lastLaser.current = Date.now();
    runtime.presence({ ...p, pageID: page!.id, laser: true, name: runtime.name });
  }
  function move(event: PointerEvent) {
    if (event.pointerId !== pointer.current || !runtime.connected) return;
    if (tool === 'laser') laser(point(event));
    else if (points.length < 4096) setPoints(previous => [...previous, point(event)]);
  }
  function up(event: PointerEvent) {
    if (event.pointerId !== pointer.current) return;
    pointer.current = undefined;
    if (tool === 'pen' && points.length >= 1 && runtime.connected) {
      const id = newID();
      const path = [...points.slice(0, 4095), point(event)];
      runtime.edit({ id, kind: 'add', object: { id, kind: 'stroke', author: runtime.client, pageID: page!.id, points: path, color: '#4C3AD6', width: 3 } });
      ownHistory.current.push(id);
    }
    setPoints([]);
  }
  function closeDraft() {
    const focused = window.document.activeElement;
    if (focused instanceof HTMLElement) focused.blur();
    setDraft(undefined);
  }
  function addText() {
    if (!draft?.text.trim() || !page || !runtime.connected) return;
    const id = newID();
    runtime.edit({ id, kind: 'add', object: { id, kind: 'text', author: runtime.client, pageID: page.id, text: draft.text.trim(), x: draft.x, y: draft.y,
                                          width: Math.max(24, Math.min(320, page.width - draft.x)), fontSize: 18, color: '#29243D' } });
    ownHistory.current.push(id); closeDraft();
  }
  function undo() {
    const id = ownHistory.current.pop();
    if (id && runtime.connected && doc?.objects.some(o => o.id === id)) runtime.edit({ id: newID(), kind: 'remove', objectID: id });
  }
  function stop() { runtime.stop(); ownHistory.current = []; setSharing(false); native({ type: 'stop' }); }
  function draw(object: Content) {
    if (object.kind === 'stroke') return <polyline key={object.id} data-object-id={object.id} points={object.points.map(p => `${p.x},${p.y}`).join(' ')} fill="none" stroke={object.color} strokeWidth={object.width} strokeLinecap="round" strokeLinejoin="round"/>;
    return <foreignObject key={object.id} data-object-id={object.id} x={object.x} y={object.y} width={object.width} height={page!.height - object.y}>
      <div className="note-text" style={{ color: object.color, fontSize: object.fontSize }}>{object.text}</div>
    </foreignObject>;
  }
  return <main>
    <header><div className="brand"><span className="brand-mark">m<span>•</span>b</span><div>MB Notes<small>Collaboration lab</small></div></div>
      <div className={`connection ${runtime.connected ? 'connected' : ''}`} role="status"><i/>{runtime.status}</div>
      <button className="quiet" onClick={() => setSettings(!settings)} aria-label="Connection options">•••</button>
    </header>
    {!doc && (runtime.replica || window.webkit?.messageHandlers?.collaboration) ? <section className="welcome"><h1>{runtime.replica ? 'Joining the note…' : 'Session ended'}</h1><p>{runtime.status}</p>{runtime.replica && <button onClick={stop}>Leave</button>}</section> : !doc ? <section className="welcome">
      <span className="eyebrow">Write together</span><h1>A shared place<br/>for the class.</h1>
      <p>One person hosts. Everyone else joins their live note.</p>
      <button className="primary" onClick={() => runtime.startHost()}>Host a demo board</button>
      <div className="join"><label htmlFor="invite">Have an invitation?</label><input id="invite" value={invite} onChange={e => setInvite(e.target.value)} placeholder="Paste the session link"/>
        <button disabled={!invite.trim()} onClick={() => runtime.join(invite)}>Join session</button>
      </div>
    </section> : <>
      <section className="note-bar"><div><span className="eyebrow">{runtime.host ? 'Your live session' : 'Joined session'}</span><h1>{doc.title}</h1></div>
        <div className="session-actions">{!window.webkit?.messageHandlers?.collaboration && runtime.invite && !runtime.host && <a className="app-link" href={"mbnotes://collaboration?" + new URLSearchParams({ invitation: JSON.stringify(runtime.invite) })}>Open in MB Notes</a>}<span className="people">{runtime.participants} / 10</span>
          {runtime.host && <button onClick={() => setSharing(true)}><Icon name="share"/>Invite</button>}
          <button className="quiet" onClick={stop}>{runtime.host ? 'End session' : 'Leave'}</button></div>
      </section>
      <section ref={workspace} className="workspace">
        <div className="tools" role="toolbar" aria-label="Drawing tools">{(['pen', 'text', 'laser'] as Tool[]).map(item =>
          <button key={item} aria-label={item === 'pen' ? 'Pen' : item === 'text' ? 'Add text' : 'Laser pointer'} aria-pressed={tool === item} disabled={!runtime.connected} className={tool === item ? 'selected' : ''} onClick={() => { setTool(item); closeDraft(); }}><Icon name={item}/></button>)}
          <span className="divider"/><button disabled={!runtime.connected || !ownHistory.current.length} onClick={undo} aria-label="Undo my last addition">↶</button>
        </div>
        {page && <svg ref={stage} className="paper" aria-label="Shared canvas" role="img" viewBox={`0 0 ${page.width} ${page.height}`} style={{ width: paperSize.width, height: paperSize.height }}
          onContextMenu={event => event.preventDefault()} onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={() => { pointer.current = undefined; setPoints([]); }}>
          <rect width={page.width} height={page.height} fill="white"/>
          {runtime.backgrounds.has(page.id) && <image pointerEvents="none" href={runtime.backgrounds.get(page.id)} width={page.width} height={page.height}/>}
          {objects.map(draw)}
          {points.length > 0 && <polyline points={points.map(p => `${p.x},${p.y}`).join(' ')} stroke="#4C3AD6" strokeWidth="3" fill="none" strokeLinecap="round"/>}
          {[...runtime.presences].filter(([, entry]) => entry.value.pageID === page.id && entry.value.laser).map(([id, entry]) => <g key={id} data-laser={id}><circle cx={entry.value.x} cy={entry.value.y} r="9" fill="#F76CA0" opacity=".2"/><circle cx={entry.value.x} cy={entry.value.y} r="4" fill="#F76CA0"/></g>)}
        </svg>}
        {draft && <div className="text-composer" role="dialog" aria-label="New text box"><textarea autoFocus aria-label="Text to add" value={draft.text} onChange={e => setDraft({ ...draft, text: e.target.value })} placeholder="Write your text…"/><div><button onClick={() => closeDraft()}>Cancel</button><button className="primary" disabled={!draft.text.trim()} onClick={addText}>Add to canvas</button></div></div>}
      </section>
      <footer><select aria-label="Page" value={runtime.pageID} onChange={e => runtime.setPage(e.target.value)}>{doc.pages.map((p, index) => <option value={p.id} key={p.id}>Page {index + 1} of {doc.pages.length}</option>)}</select>
        <span>{runtime.pending ? `${runtime.pending} change awaiting host` : runtime.host ? 'Accepted edits save on the host' : runtime.connected ? 'Live with the host' : 'Reconnect to edit'}</span>
        <span className="revision" data-testid="revision">{`Revision ${doc.revision}`}</span></footer>
    </>}
    {runtime.error && <div role="alert" className="error">{runtime.error}</div>}
    {sharing && <div className="scrim"><section className="dialog" role="dialog" aria-label="Invite people"><button className="close" onClick={() => setSharing(false)} aria-label="Close invitation">×</button><span className="eyebrow">Bring people in</span><h2>Scan. Join. Write.</h2><p>Keep the host open while everyone works.</p>{qr && <img alt="Session invitation QR code" src={qr}/>}
      <input aria-label="Session link" readOnly value={runtime.link(runtime.publicURL || location.href)}/><button className="primary" onClick={() => navigator.clipboard.writeText(runtime.link(runtime.publicURL || location.href))}>Copy link</button></section></div>}
    {settings && <div className="scrim"><section className="dialog" role="dialog" aria-label="Connection options"><button className="close" onClick={() => setSettings(false)} aria-label="Close connection options">×</button><h2>Connection options</h2><label className="check"><input type="checkbox" checked={forceRelay} onChange={e => { setForceRelay(e.target.checked); localStorage.setItem('mb-force-relay', e.target.checked ? 'yes' : 'no'); }}/>Prefer the relay for new connections</label><p>Useful on networks that block direct connections. The bundled public relay failed our relay-only test. Add working provider credentials below to test your network.</p><label className="relay-label">Provider ICE servers JSON<textarea aria-label="Provider ICE servers JSON" value={ice} onChange={e => setICE(e.target.value)} placeholder={'[{"urls":"turns:your-provider:443?transport=tcp","username":"…","credential":"…"}]'}/></label><button onClick={() => { try { if (ice.trim()) { const value = JSON.parse(ice); if (!Array.isArray(value) || !value.length || !value.every(s => s && s.urls)) throw Error('Enter an array of ICE servers.'); localStorage.setItem('mb-ice-servers', JSON.stringify(value)); } else localStorage.removeItem('mb-ice-servers'); setICEError('Saved for the next connection.'); } catch { setICEError('Enter valid ICE servers JSON.'); } }}>Save relay settings</button><p role="status">{iceError}</p></section></div>}
  </main>;
}

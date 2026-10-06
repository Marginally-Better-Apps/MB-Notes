import { Host, Replica, newID, parseInvite, inviteURL, type Channel, type Document, type Invite, type Mutation, type Presence, type Wire } from '../../Packages/NoteEngine/Collaboration/session';
import { native, WebPeers } from './network';

const demo = (): Document => ({ id: newID(), title: 'Classroom board', pages: [{ id: newID(), width: 1000, height: 720 }], objects: [], revision: 0 });
export class Runtime {
  document?: Document;
  invite?: Invite;
  host?: Host;
  replica?: Replica;
  status = 'Choose a session';
  error = '';
  client = newID();
  name = 'Guest';
  backgrounds = new Map<string, string>();
  presences = new Map<string, { value: Presence; at: number }>();
  participants = 1;
  pageID = '';
  publicURL = '';
  private web?: WebPeers;
  private nativeGuest = false;
  private activeChannel?: Channel;
  private saves = new Map<string, { resolve: () => void; reject: (error: Error) => void }>();
  private listeners = new Set<() => void>();
  private version = 0;
  private expiry = setInterval(() => {
    let removed = false;
    for (const [id, entry] of this.presences) if (Date.now() - entry.at > 1500) { this.presences.delete(id); removed = true; }
    if (removed) this.emit();
  }, 500);
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  snapshot = () => this.version;
  get connected() { return !!this.host || this.replica?.connected === true; }
  get pending() { return this.replica?.pending.size ?? 0; }
  private emit() { this.version++; for (const listener of this.listeners) listener(); }
  private setStatus = (status: string) => { this.status = status; native({ type: 'status', value: status }); this.emit(); };
  private setPresence = (client: string, value: Presence | null) => {
    if (client === this.client) return;
    if (value) this.presences.set(client, { value, at: Date.now() }); else this.presences.delete(client);
    this.emit();
  };
  private changed = async (doc: Document, mutation?: Mutation) => {
    if (window.webkit?.messageHandlers?.collaboration && mutation) {
      await new Promise<void>((resolve, reject) => {
        this.saves.set(mutation.id, { resolve, reject });
        native({ type: 'persist', documentID: doc.id, mutation, revision: doc.revision });
      });
    } else localStorage.setItem('mb-collaboration-host-' + doc.id, JSON.stringify(doc));
    this.document = doc;
    this.emit();
  };
  saved(id: string, error?: string) {
    const task = this.saves.get(id); this.saves.delete(id);
    if (error) { this.error = error; task?.reject(new Error(error)); }
    else task?.resolve();
    this.emit();
  }
  startHost(document = demo(), invite?: Invite) {
    this.stop();
    this.name = 'Host';
    this.document = structuredClone(document); this.pageID = document.pages.find(p => p.id === invite?.page)?.id ?? document.pages[0]?.id ?? '';
    const session = newID();
    this.invite = invite ?? { v: 1, session, document: document.id, token: newID() + newID(), peer: 'mb-' + session, nearby: 'mb-' + session.slice(0, 8) };
    this.host = new Host(this.invite, document, this.changed, this.setPresence, pageID => this.backgrounds.get(pageID), pageID => native({ type: 'backgroundRequest', pageID }));
    this.web = this.makeWeb();
    this.setStatus(window.webkit ? 'Nearby sharing ready · connecting browser sharing…' : 'Starting browser sharing…');
    void this.web.start(this.invite.peer);
    this.requestBackground(this.pageID);
    this.emit();
  }
  join(input: string | Invite, nativeGuest = false) {
    this.stop();
    try { this.invite = typeof input === 'string' ? parseInvite(input) : input; }
    catch (error) { this.error = String(error); this.emit(); return; }
    this.nativeGuest = nativeGuest;
    this.replica = new Replica(this.client, this.invite, () => {
      this.document = this.replica?.document;
      this.participants = this.replica?.participants ?? 1;
      if (!this.pageID && this.document) { this.pageID = this.document.pages.find(p => p.id === this.invite?.page)?.id ?? this.document.pages[0]?.id ?? ''; this.requestBackground(this.pageID); }
      this.emit();
    }, this.setPresence, (id, data) => { this.backgrounds.set(id, data); this.emit(); }, message => { this.error = message; this.emit(); });
    this.setStatus(nativeGuest ? 'Finding nearby host…' : 'Connecting…');
    if (!nativeGuest) this.fallback();
  }
  fallback() {
    if (!this.invite || !this.replica || this.replica.connected) return;
    this.web?.stop(); this.web = this.makeWeb();
    this.setStatus('Connecting through public signaling…');
    void this.web.start(undefined, this.invite.peer);
  }
  private makeWeb() {
    return new WebPeers(channel => this.opened(channel), (id, message) => this.receive(id, message), id => this.closed(id), this.setStatus, localStorage.getItem('mb-force-relay') === 'yes');
  }
  opened(channel: Channel) {
    if (this.host) { this.host.attach(channel); this.emit(); }
    else if (this.replica) {
      const old = this.activeChannel; this.activeChannel = channel;
      if (channel.id.startsWith("nearby-")) this.setStatus("Connected nearby");
      if (old && old.id !== channel.id) old.close();
      if (this.nativeGuest && channel.id.startsWith('nearby-')) { this.web?.stop(); this.web = undefined; }
      this.replica.attach(message => channel.send(message), this.name); this.emit(); }
  }
  receive(id: string, message: Wire) {
    if (this.host) { this.host.receive(id, message); this.participants = this.host.participants; }
    else if (this.activeChannel?.id === id) {
      this.replica?.receive(message);
      if (message.type === 'closed') { this.web?.stop(); this.web = undefined; this.activeChannel?.close(); this.activeChannel = undefined; this.setStatus('The host ended this session'); }
    }
    this.emit();
  }
  closed(id: string) {
    if (this.host) { this.host.detach(id); this.participants = this.host.participants; }
    else if (this.activeChannel?.id === id) { this.activeChannel = undefined; this.replica?.disconnected(); this.presences.clear(); }
    this.emit();
  }
  edit(mutation: Mutation) {
    this.error = '';
    if (this.host) void this.host.edit(this.client, mutation).catch(error => { this.error = String(error); this.emit(); });
    else this.replica?.edit(mutation);
    this.emit();
  }
  presence(value: Presence) { this.presences.set(this.client, { value, at: Date.now() }); this.emit(); if (this.host) this.host.sendPresence(this.client, value); else this.replica?.sendPresence(value); }
  requestBackground(pageID: string) {
    if (this.backgrounds.has(pageID)) return;
    if (this.host) native({ type: 'backgroundRequest', pageID });
    else this.replica?.requestBackground(pageID);
  }
  background(pageID: string, data: string) {
    this.backgrounds.set(pageID, data);
    while (this.backgrounds.size > 4) this.backgrounds.delete(this.backgrounds.keys().next().value!);
    this.host?.backgroundReady(pageID, data); this.emit();
  }
  link(base = location.href) { return this.invite ? inviteURL(base, { ...this.invite, page: this.pageID || this.invite.page }) : ''; }
  setPage(id: string) { this.pageID = id; this.requestBackground(id); this.emit(); }
  stop() {
    this.host?.close(); this.web?.stop(); this.replica?.disconnected();
    this.host = undefined; this.replica = undefined; this.web = undefined; this.activeChannel = undefined;
    this.document = undefined; this.invite = undefined; this.pageID = ''; this.participants = 1;
    this.backgrounds.clear(); this.presences.clear(); this.error = ''; this.nativeGuest = false;
    for (const task of this.saves.values()) task.reject(new Error('Session ended'));
    this.saves.clear();
    this.emit();
  }
  dispose() { this.stop(); clearInterval(this.expiry); }
}
export const runtime = new Runtime();
window.mbNative = {
  startHost: payload => { const data = payload as { document: Document; invite: Invite; publicURL?: string }; runtime.publicURL = data.publicURL ?? ""; runtime.startHost(data.document, data.invite); },
  startGuest: invite => runtime.join(invite as Invite, true),
  opened: id => runtime.opened({ id, send: message => native({ type: 'send', id, message }), close: () => native({ type: 'close', id }) }),
  receive: (id, message) => runtime.receive(id, message),
  closed: id => runtime.closed(id),
  background: (pageID, data) => runtime.background(pageID, data),
  fallback: () => runtime.fallback(),
  saved: (id, error) => runtime.saved(id, error),
};

window.addEventListener('mb-stop', () => runtime.stop());

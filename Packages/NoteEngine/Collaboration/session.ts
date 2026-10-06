/** One host orders accepted changes. Guests are connected-only replicas, not offline editors. */
export const VERSION = 1;
export type Point = { x: number; y: number };
export type Page = { id: string; width: number; height: number };
export type Ink = { kind: 'stroke'; points: Point[]; color: string; width: number };
export type Text = { kind: 'text'; text: string; x: number; y: number; width: number; fontSize: number; color: string };
export type Content = (Ink | Text) & { id: string; pageID: string; author: string };
export type Document = { id: string; title: string; pages: Page[]; objects: Content[]; revision: number };
export type Invite = { v: number; session: string; document: string; token: string; peer: string; nearby: string; page?: string };
export type Mutation = { id: string; kind: 'add'; object: Content } | { id: string; kind: 'remove'; objectID: string };
export type Presence = { pageID: string; x: number; y: number; laser: boolean; name: string };
export type Wire =
  | { type: 'hello'; v: number; session: string; document: string; token: string; client: string; name: string }
  | { type: 'welcome'; session: string; document: Document; participants: number }
  | { type: 'change'; mutation: Mutation; revision: number }
  | { type: 'ack'; id: string; revision: number }
  | { type: 'reject'; id?: string; reason: string }
  | { type: 'edit'; mutation: Mutation }
  | { type: 'presence'; client: string; presence: Presence }
  | { type: 'participants'; count: number }
  | { type: 'backgroundRequest'; pageID: string }
  | { type: 'background'; pageID: string; data: string }
  | { type: 'resync' }
  | { type: 'closed' };
export interface Channel { id: string; send(message: Wire): void; close(): void }
export const newID = () => crypto.randomUUID();
export function inviteURL(base: string, invite: Invite): string {
  const url = new URL(base);
  url.hash = new URLSearchParams({ mb: JSON.stringify(invite) }).toString();
  return url.toString();
}
export function parseInvite(input: string): Invite {
  const raw = input.trim();
  const payload = raw.startsWith('{') ? raw : new URLSearchParams(new URL(raw).hash.slice(1)).get('mb');
  if (!payload) throw new Error('This is not an MB Notes invitation.');
  const value = JSON.parse(payload);
  if (value.v !== VERSION || !['session', 'document', 'token', 'peer', 'nearby'].every(key => typeof value[key] === 'string') || value.token.length < 24) throw new Error('This invitation is invalid or uses a newer protocol.');
  return value;
}
function validMutation(value: Mutation, doc: Document, client: string): boolean {
  if (!value || typeof value.id !== 'string' || value.id.length > 100 || value.id.length < 8) return false;
  if (value.kind === 'remove') return typeof value.objectID === 'string' && doc.objects.some(o => o.id === value.objectID && o.author === client);
  if (value.kind !== 'add' || !value.object) return false;
  const o = value.object;
  if (o.id !== value.id || o.author !== client || !doc.pages.some(p => p.id === o.pageID) || doc.objects.some(item => item.id === o.id)) return false;
  const coordinate = (n: number) => Number.isFinite(n) && Math.abs(n) <= 1e8;
  if (!/^#[0-9a-f]{6}$/i.test(o.color)) return false;
  if (o.kind === 'text') return typeof o.text === 'string' && o.text.length > 0 && o.text.length <= 10000 && coordinate(o.x) && coordinate(o.y) && o.width >= 24 && o.width <= 10000 && o.fontSize >= 8 && o.fontSize <= 100;
  return o.kind === 'stroke' && Array.isArray(o.points) && o.points.length >= 2 && o.points.length <= 4096 && o.width >= 0.5 && o.width <= 100 && o.points.every(p => p != null && coordinate(p.x) && coordinate(p.y));
}
export function applyMutation(doc: Document, mutation: Mutation, revision: number): Document {
  const objects = mutation.kind === 'add' ? [...doc.objects, structuredClone(mutation.object)] : doc.objects.filter(o => o.id !== mutation.objectID);
  return { ...doc, objects, revision };
}

export class Host {
  document: Document;
  private clients = new Map<string, { channel: Channel; client: string }>();
  private accepted = new Map<string, number>();
  private queues = new Map<string, Channel>();
  private transaction = Promise.resolve();
  private active = true;
  constructor(public invite: Invite, document: Document, private changed: (doc: Document, mutation?: Mutation) => void | Promise<void>,
              private presence: (client: string, value: Presence | null) => void,
              private background: (pageID: string) => string | undefined,
              private requestBackground: (pageID: string) => void) { this.document = structuredClone(document); }
  get participants() { return this.clients.size + 1; }
  attach(channel: Channel) {
    if (!this.active || this.queues.size >= 16) { channel.close(); return; }
    this.queues.set(channel.id, channel);
  }
  detach(id: string) {
    const entry = this.clients.get(id);
    this.queues.delete(id); this.clients.delete(id);
    if (entry) this.presence(entry.client, null);
    this.broadcast({ type: 'participants', count: this.participants });
  }
  receive(id: string, message: Wire) {
    const channel = this.queues.get(id);
    if (!channel || !message || typeof message.type !== 'string') return;
    if (message.type === 'hello') {
      if (message.v !== VERSION || message.session !== this.invite.session || message.document !== this.document.id || message.token !== this.invite.token || typeof message.client !== 'string' || message.client.length < 8 || message.client.length > 100) {
        channel.send({ type: 'reject', reason: 'The invitation is invalid or the session has ended.' }); channel.close(); this.detach(id); return;
      }
      for (const [key, entry] of this.clients) if (entry.client === message.client && key !== id) { entry.channel.close(); this.detach(key); }
      if (this.clients.size >= 9 && !this.clients.has(id)) { channel.send({ type: 'reject', reason: 'This session is full.' }); channel.close(); this.detach(id); return; }
      this.clients.set(id, { channel, client: message.client });
      channel.send({ type: 'welcome', session: this.invite.session, document: structuredClone(this.document), participants: this.participants });
      this.broadcast({ type: 'participants', count: this.participants });
      return;
    }
    const entry = this.clients.get(id);
    if (!entry) { channel.close(); return; }
    if (message.type === 'edit') void this.edit(entry.client, message.mutation, channel).catch(() => {});
    if (message.type === 'resync') channel.send({ type: 'welcome', session: this.invite.session, document: structuredClone(this.document), participants: this.participants });
    if (message.type === 'presence') this.sendPresence(entry.client, message.presence);
    if (message.type === 'backgroundRequest' && this.document.pages.some(p => p.id === message.pageID)) {
      const data = this.background(message.pageID);
      if (data) channel.send({ type: 'background', pageID: message.pageID, data });
      else this.requestBackground(message.pageID);
    }
  }
  edit(client: string, mutation: Mutation, channel?: Channel): Promise<void> {
    const work = this.transaction.then(() => this.accept(client, mutation, channel));
    this.transaction = work.catch(() => {});
    return work;
  }
  private async accept(client: string, mutation: Mutation, channel?: Channel) {
    if (!this.active || !mutation || typeof mutation.id !== 'string') return;
    const prior = this.accepted.get(mutation.id);
    if (prior !== undefined) { channel?.send({ type: 'ack', id: mutation.id, revision: prior }); return; }
    if (this.accepted.size >= 20000 || !validMutation(mutation, this.document, client)) { channel?.send({ type: 'reject', id: mutation.id, reason: 'This change could not be accepted.' }); return; }
    const next = applyMutation(this.document, mutation, this.document.revision + 1);
    if (new TextEncoder().encode(JSON.stringify(next)).length > 2 * 1024 * 1024) {
      channel?.send({ type: 'reject', id: mutation.id, reason: 'This session reached its size limit. Ask the host to start a new session.' }); return;
    }
    // Persistence/bridge exceptions must prevent acknowledgment of an unsaved change.
    try { await this.changed(next, mutation); }
    catch {
      const reason = 'The host could not save this change. Try again.';
      if (!channel) throw new Error(reason);
      channel.send({ type: 'reject', id: mutation.id, reason }); return;
    }
    if (!this.active) return;
    this.document = next;
    this.accepted.set(mutation.id, next.revision);
    this.broadcast({ type: 'change', mutation, revision: next.revision });
    channel?.send({ type: 'ack', id: mutation.id, revision: next.revision });
  }
  sendPresence(client: string, value: Presence) {
    if (!value || !Number.isFinite(value.x) || !Number.isFinite(value.y) || !this.document.pages.some(p => p.id === value.pageID)) return;
    const clean = { ...value, name: String(value.name).slice(0, 32), laser: value.laser === true };
    this.presence(client, clean);
    this.broadcast({ type: 'presence', client, presence: clean });
  }
  backgroundReady(pageID: string, data: string) { this.broadcast({ type: 'background', pageID, data }); }
  broadcast(message: Wire) {
    for (const { channel } of [...this.clients.values()]) {
      try { channel.send(message); } catch { channel.close(); this.clients.delete(channel.id); this.queues.delete(channel.id); }
    }
  }
  close() { this.active = false; this.broadcast({ type: 'closed' }); for (const channel of this.queues.values()) channel.close(); this.queues.clear(); this.clients.clear(); }
}

export class Replica {
  document?: Document;
  connected = false;
  participants = 1;
  readonly pending = new Map<string, Mutation>();
  private send?: (message: Wire) => void;
  constructor(readonly client: string, readonly invite: Invite, private changed: () => void,
              private presence: (client: string, value: Presence | null) => void,
              private background: (pageID: string, data: string) => void,
              private error: (message: string) => void) {}
  attach(send: (message: Wire) => void, name: string) {
    this.send = send; this.connected = false;
    send({ type: 'hello', v: VERSION, session: this.invite.session, document: this.invite.document, token: this.invite.token, client: this.client, name });
  }
  disconnected() { this.connected = false; this.send = undefined; this.changed(); }
  receive(message: Wire) {
    if (!message || typeof message.type !== 'string') return;
    if (message.type === 'welcome') {
      if (message.session !== this.invite.session || message.document.id !== this.invite.document) { this.error('This is a different note or session.'); this.disconnected(); return; }
      this.document = structuredClone(message.document); this.connected = true; this.participants = message.participants;
      for (const mutation of this.pending.values()) this.send?.({ type: 'edit', mutation });
    }
    if (message.type === 'change' && this.document) {
      this.pending.delete(message.mutation.id);
      if (message.revision === this.document.revision + 1) this.document = applyMutation(this.document, message.mutation, message.revision);
      else if (message.revision > this.document.revision + 1) this.send?.({ type: 'resync' });
    }
    if (message.type === 'ack') this.pending.delete(message.id);
    if (message.type === 'reject') { if (message.id) this.pending.delete(message.id); this.error(message.reason); }
    if (message.type === 'participants') this.participants = message.count;
    if (message.type === 'presence') this.presence(message.client, message.presence);
    if (message.type === 'background') this.background(message.pageID, message.data);
    if (message.type === 'closed') { this.error('The host ended this session.'); this.disconnected(); }
    this.changed();
  }
  edit(mutation: Mutation) {
    if (!this.connected) throw new Error('Reconnect before editing.');
    this.pending.set(mutation.id, mutation); this.send?.({ type: 'edit', mutation }); this.changed();
  }
  sendPresence(value: Presence) { if (this.connected) this.send?.({ type: 'presence', client: this.client, presence: value }); }
  requestBackground(pageID: string) { if (this.connected) this.send?.({ type: 'backgroundRequest', pageID }); }
}

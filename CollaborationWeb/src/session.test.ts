import { describe, expect, it } from 'vitest';
import { Host, Replica, inviteURL, parseInvite, type Document, type Invite, type Mutation, type Wire } from '../../Packages/NoteEngine/Collaboration/session';
const invite: Invite = { v: 1, session: 'session-123', document: 'doc-12345', token: 'a'.repeat(40), peer: 'peer-123', nearby: 'mb-test' };
const doc: Document = { id: invite.document, title: 'Seminar', pages: [{ id: 'page-123', width: 800, height: 1000 }], objects: [], revision: 0 };
const addition = (id = 'object-12345', author = 'guest-123'): Mutation => ({ id, kind: 'add', object: { id, author, pageID: 'page-123', kind: 'text', text: 'A shared idea', x: 10, y: 20, width: 300, fontSize: 18, color: '#4C3AD6' } });
const settle = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function fixture(save: (doc: Document, mutation?: Mutation) => void | Promise<void> = () => {}) {
  const presence: unknown[] = [];
  const host = new Host(invite, doc, save, (...value) => presence.push(value), () => undefined, () => {});
  function guest(client = 'guest-123', token = invite.token) {
    const errors: string[] = [], output: Wire[] = [];
    const replica = new Replica(client, { ...invite, token }, () => {}, () => {}, () => {}, reason => errors.push(reason));
    let drop = false;
    const id = 'channel-' + client;
    const connect = () => {
      host.attach({ id, send: message => { output.push(message); if (!drop) replica.receive(message); }, close: () => replica.disconnected() });
      replica.attach(message => host.receive(id, message), 'Guest');
    };
    connect();
    return { replica, errors, output, connect, disconnect() { drop = true; replica.disconnected(); host.detach(id); }, dropResponses() { drop = true; }, reconnect() { drop = false; connect(); } };
  }
  return { host, presence, guest };
}
describe('host-owned collaboration protocol', () => {
  it('round trips an invitation in a URL fragment', () => {
    const url = inviteURL('https://notes.example/demo', invite);
    expect(parseInvite(url)).toEqual(invite);
    expect(new URL(url).search).toBe('');
    expect(() => parseInvite('https://notes.example/')).toThrow();
  });
  it('orders concurrent changes and converges all guests', async () => {
    const { host, guest } = fixture(); const a = guest(), b = guest('guest-456');
    a.replica.edit(addition()); b.replica.edit(addition('object-45678', 'guest-456'));
    await settle();
    expect(host.document.revision).toBe(2);
    expect(a.replica.document).toEqual(host.document); expect(b.replica.document).toEqual(host.document);
    expect(a.replica.pending.size + b.replica.pending.size).toBe(0);
  });
  it('does not acknowledge or publish a change before persistence completes', async () => {
    let finish!: () => void;
    const { host, guest } = fixture(() => new Promise<void>(resolve => { finish = resolve; })); const a = guest();
    a.replica.edit(addition()); await settle();
    expect(host.document.revision).toBe(0); expect(a.replica.pending.size).toBe(1);
    finish(); await settle(); expect(host.document.revision).toBe(1); expect(a.replica.pending.size).toBe(0);
  });
  it('rejects failed persistence without changing the document', async () => {
    const { host, guest } = fixture(() => { throw Error('disk full'); }); const a = guest();
    a.replica.edit(addition()); await settle();
    expect(host.document.revision).toBe(0); expect(a.replica.document?.objects).toEqual([]);
    expect(a.errors.at(-1)).toContain('could not save'); expect(a.replica.pending.size).toBe(0);
  });
  it('retries a submitted change after an acknowledgment is lost without duplicating it', async () => {
    const { host, guest } = fixture(); const a = guest(); a.dropResponses();
    a.replica.edit(addition()); await settle(); a.disconnect();
    expect(a.replica.pending.size).toBe(1); expect(() => a.replica.edit(addition('other-1234'))).toThrow('Reconnect');
    a.reconnect(); await settle();
    expect(host.document.objects).toHaveLength(1); expect(host.document.revision).toBe(1);
    expect(a.replica.document).toEqual(host.document); expect(a.replica.pending.size).toBe(0);
  });
  it('resynchronizes a revision gap and catches up after a disconnected interval', async () => {
    const { host, guest } = fixture(); const a = guest();
    a.replica.receive({ type: 'change', revision: 50, mutation: addition() });
    expect(a.replica.document).toEqual(host.document);
    a.disconnect(); await host.edit('host-1234', addition('host-object-123', 'host-1234')); a.reconnect();
    expect(a.replica.document).toEqual(host.document);
  });
  it('allows ten participants and rejects wrong tokens and the eleventh participant', () => {
    const { host, guest } = fixture(); expect(guest('guest-bad', 'wrong').replica.connected).toBe(false);
    for (let i = 0; i < 9; i++) expect(guest('guest-000' + i).replica.connected).toBe(true);
    expect(host.participants).toBe(10); const extra = guest('guest-extra'); expect(extra.errors).toContain('This session is full.');
  });
  it('prevents guests from changing another author’s object and rejects malformed geometry', async () => {
    const { host, guest } = fixture(); const a = guest(), b = guest('guest-456');
    a.replica.edit(addition()); await settle();
    b.replica.edit({ id: 'remove-123', kind: 'remove', objectID: 'object-12345' }); await settle();
    expect(host.document.objects).toHaveLength(1); expect(b.errors).toHaveLength(1);
    const bad = addition('bad-object'); if (bad.kind === 'add' && bad.object.kind === 'text') bad.object.x = NaN;
    a.replica.edit(bad); await settle(); expect(host.document.revision).toBe(1);
    a.replica.edit({ id: 'remove-456', kind: 'remove', objectID: 'object-12345' }); await settle(); expect(host.document.objects).toHaveLength(0);
  });
  it('keeps laser presence out of document revisions and ends guest editing when host closes', () => {
    const { host, presence, guest } = fixture(); const a = guest();
    a.replica.sendPresence({ pageID: 'page-123', x: 200, y: 100, laser: true, name: 'Guest' });
    expect(presence).toHaveLength(1); expect(host.document).toEqual(doc);
    host.close(); expect(a.replica.connected).toBe(false); expect(a.errors).toContain('The host ended this session.');
  });
});

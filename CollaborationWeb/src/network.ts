import Peer, { type DataConnection } from 'peerjs';
import type { Channel, Wire } from '../../Packages/NoteEngine/Collaboration/session';

export type NativeBridge = { postMessage(message: unknown): void };
declare global {
  interface Window {
    webkit?: { messageHandlers?: { collaboration?: NativeBridge } };
    mbNative?: {
      startHost(payload: unknown): void;
      startGuest(invite: unknown): void;
      opened(id: string): void;
      receive(id: string, message: Wire): void;
      closed(id: string): void;
      background(pageID: string, data: string): void;
      fallback(): void;
      saved(id: string, error?: string): void;
    };
  }
}
export const native = (message: unknown) => window.webkit?.messageHandlers?.collaboration?.postMessage(message);

/** The published static-auth relay accepts the standard short-lived TURN REST credentials. */
export async function relayConfiguration(forceRelay = false): Promise<RTCConfiguration> {
  const custom = localStorage.getItem('mb-ice-servers');
  if (custom) {
    const servers: unknown = JSON.parse(custom);
    if (!Array.isArray(servers) || servers.length === 0 || servers.length > 16 || !servers.every(server => server && (typeof server.urls === 'string' || Array.isArray(server.urls)))) throw new Error('Invalid ICE server configuration');
    return { iceTransportPolicy: forceRelay ? 'relay' : 'all', iceServers: servers as RTCIceServer[] };
  }
  const username = String(Math.floor(Date.now() / 1000) + 3600);
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode('openrelayprojectsecret'), { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']);
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(username));
  const credential = btoa(String.fromCharCode(...new Uint8Array(signature)));
  return {
    iceTransportPolicy: forceRelay ? 'relay' : 'all',
    iceServers: [
      { urls: 'stun:stun.l.google.com:19302' },
      { urls: ['turns:staticauth.openrelay.metered.ca:443?transport=tcp', 'turn:staticauth.openrelay.metered.ca:443?transport=tcp', 'turn:staticauth.openrelay.metered.ca:80?transport=tcp'], username, credential },
    ],
  };
}

export class WebPeers {
  private peer?: Peer;
  private connections = new Map<string, DataConnection>();
  private timers = new Map<string, ReturnType<typeof setTimeout>>();
  private retry?: ReturnType<typeof setTimeout>;
  private stopped = false;
  private attempts = 0;
  private lastName?: string;
  private target?: string;
  private generation = 0;
  constructor(private opened: (channel: Channel) => void, private received: (id: string, message: Wire) => void,
              private closed: (id: string) => void, private status: (status: string) => void, private forceRelay = false) {}
  async start(name?: string, target?: string) {
    const generation = ++this.generation;
    clearTimeout(this.retry); this.retry = undefined;
    this.lastName = name; this.target = target;
    this.stopped = false;
    try {
      const config = await relayConfiguration(this.forceRelay);
      if (this.stopped || generation !== this.generation) return;
      for (const id of this.connections.keys()) this.closed(id);
      this.connections.clear();
      for (const timer of this.timers.values()) clearTimeout(timer);
      this.timers.clear();
      this.peer?.destroy();
      this.peer = name ? new Peer(name, { secure: true, config }) : new Peer({ secure: true, config });
      const peer = this.peer;
      this.peer.on('open', () => {
        if (this.stopped || generation !== this.generation) return;
        this.attempts = 0;
        this.status(target ? 'Connecting to host…' : 'Browser sharing ready');
        if (target) this.attach(peer.connect(target, { reliable: true, serialization: 'binary' }));
      });
      this.peer.on('connection', conn => this.attach(conn));
      this.peer.on('disconnected', () => { if (this.stopped || generation !== this.generation) return; this.status('Signaling disconnected. Retrying…'); if (!this.stopped) this.peer?.reconnect(); });
      this.peer.on('error', error => { if (this.stopped || generation !== this.generation) return; this.status(`Connection unavailable: ${error.type}`); if (this.target || ['network', 'server-error', 'socket-error', 'socket-closed'].includes(error.type)) this.scheduleRetry(); });
    } catch { this.status('Unable to prepare the connection. Check the relay configuration.'); this.scheduleRetry(); }
  }
  private attach(conn: DataConnection) {
    const generation = this.generation;
    const id = 'web-' + conn.peer;
    this.connections.get(id)?.close();
    this.connections.set(id, conn);
    this.timers.set(id, setTimeout(() => { if (!this.stopped && generation === this.generation && !conn.open) { conn.close(); this.status('Connection timed out. Check signaling and relay access.'); if (this.target) this.scheduleRetry(); } }, 15000));
    conn.on('open', () => {
      if (this.stopped || generation !== this.generation) { conn.close(); return; }
      clearTimeout(this.timers.get(id)); this.timers.delete(id);
      this.opened({ id, send: message => { if (conn.open) conn.send(message); }, close: () => conn.close() });
      this.status('Connected');
      void this.describeRoute(conn);
    });
    conn.on('data', data => { if (!this.stopped && generation === this.generation && data && typeof data === 'object') this.received(id, data as Wire); });
    conn.on('close', () => {
      clearTimeout(this.timers.get(id)); this.timers.delete(id);
      if (this.stopped || generation !== this.generation || this.connections.get(id) !== conn) return;
      this.connections.delete(id); this.closed(id);
      if (this.target) { this.status('Disconnected. Reconnecting…'); this.scheduleRetry(); }
    });
    conn.on('error', () => { conn.close(); if (!this.stopped && generation === this.generation && this.target) this.scheduleRetry(); });
  }
  private async describeRoute(conn: DataConnection) {
    try {
      const stats = await conn.peerConnection.getStats();
      if (this.stopped || this.connections.get('web-' + conn.peer) !== conn) return;
      stats.forEach(report => {
        if (report.type === 'candidate-pair' && report.state === 'succeeded' && report.nominated) {
          const candidate = stats.get(report.localCandidateId);
          this.status(candidate?.candidateType === 'relay' ? 'Connected through relay' : 'Connected directly');
        }
      });
    } catch { /* Route inspection is diagnostic, not required for editing. */ }
  }
  private scheduleRetry() {
    if (this.stopped || this.retry) return;
    this.retry = setTimeout(() => {
      this.retry = undefined;
      if (!this.stopped) void this.start(this.lastName, this.target);
    }, Math.min(15000, 1000 * 2 ** Math.min(4, this.attempts++)));
  }
  stop() {
    this.stopped = true; this.generation++; clearTimeout(this.retry); this.retry = undefined;
    for (const timer of this.timers.values()) clearTimeout(timer);
    this.timers.clear(); this.peer?.destroy(); this.peer = undefined;
    this.connections.clear();
  }
}

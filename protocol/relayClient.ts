// Minimal Azure Web PubSub client (subprotocol json.webpubsub.azure.v1).
// Runs unchanged in Node 24 and in the browser on the glasses: it only needs a
// global WebSocket. Reconnects forever with backoff; delivery is best effort,
// because the bridge republishes whole state and devices resync with "hello".

const SUBPROTOCOL = 'json.webpubsub.azure.v1';

export type RelayStatus = 'connecting' | 'open' | 'closed';

export type RelayOptions = {
  /** Full client URL including access_token. A function is called on every (re)connect. */
  url: string | (() => string | Promise<string>);
  /** Groups to join after connecting. */
  join: string[];
  onMessage: (group: string, data: unknown, fromUserId: string | undefined) => void;
  onStatus?: (status: RelayStatus) => void;
  log?: (msg: string) => void;
};

type Frame =
  | { type: 'message'; from: string; group?: string; dataType?: string; data?: unknown; fromUserId?: string }
  | { type: 'ack'; ackId: number; success: boolean; error?: { name: string; message?: string } }
  | { type: 'system'; event: string; message?: string; userId?: string; connectionId?: string };

export class RelayClient {
  private ws: WebSocket | undefined;
  private status: RelayStatus = 'closed';
  private stopped = false;
  private attempt = 0;
  private ackId = 0;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private pendingAcks = new Map<number, (ok: boolean) => void>();
  /** Number of sendToGroup frames written since start (for quota metering). */
  sent = 0;
  private readonly opts: RelayOptions;

  constructor(opts: RelayOptions) {
    this.opts = opts;
  }

  start(): void {
    this.stopped = false;
    void this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    this.ws?.close();
    this.setStatus('closed');
  }

  get isOpen(): boolean {
    return this.status === 'open';
  }

  /** Publish JSON to a group. Returns false when not connected (the message is dropped). */
  send(group: string, data: unknown): boolean {
    if (!this.ws || this.status !== 'open') return false;
    try {
      this.ws.send(JSON.stringify({ type: 'sendToGroup', group, dataType: 'json', data, noEcho: true }));
      this.sent++;
      return true;
    } catch (err) {
      this.opts.log?.(`send failed: ${String(err)}`);
      return false;
    }
  }

  /** Round trip to the relay service itself. Resolves false on timeout or when closed. */
  probe(timeoutMs = 8000): Promise<boolean> {
    const group = this.opts.join[0];
    if (!this.ws || this.status !== 'open' || !group) return Promise.resolve(false);
    const id = ++this.ackId;
    return new Promise<boolean>((resolve) => {
      const t = setTimeout(() => {
        this.pendingAcks.delete(id);
        resolve(false);
      }, timeoutMs);
      this.pendingAcks.set(id, (ok) => {
        clearTimeout(t);
        resolve(ok);
      });
      try {
        this.ws!.send(JSON.stringify({ type: 'joinGroup', group, ackId: id }));
      } catch {
        clearTimeout(t);
        this.pendingAcks.delete(id);
        resolve(false);
      }
    });
  }

  /** Drop the socket and reconnect now (used when a heartbeat fails). */
  reconnect(): void {
    this.ws?.close();
  }

  private setStatus(s: RelayStatus): void {
    if (this.status === s) return;
    this.status = s;
    this.opts.onStatus?.(s);
  }

  private async connect(): Promise<void> {
    if (this.stopped) return;
    this.setStatus('connecting');
    let url: string;
    try {
      url = typeof this.opts.url === 'function' ? await this.opts.url() : this.opts.url;
    } catch (err) {
      this.opts.log?.(`could not get relay url: ${String(err)}`);
      this.scheduleReconnect();
      return;
    }
    let ws: WebSocket;
    try {
      ws = new WebSocket(url, SUBPROTOCOL);
    } catch (err) {
      this.opts.log?.(`socket could not be created: ${String(err)}`);
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;

    ws.onopen = () => {
      // Joins are acknowledged; we go "open" once the last one is confirmed.
      let waiting = this.opts.join.length;
      if (waiting === 0) {
        this.attempt = 0;
        this.setStatus('open');
        return;
      }
      for (const group of this.opts.join) {
        const id = ++this.ackId;
        this.pendingAcks.set(id, (ok) => {
          if (!ok) {
            this.opts.log?.(`join "${group}" refused`);
            ws.close();
            return;
          }
          if (--waiting === 0) {
            this.attempt = 0;
            this.setStatus('open');
          }
        });
        ws.send(JSON.stringify({ type: 'joinGroup', group, ackId: id }));
      }
    };

    ws.onmessage = (ev) => {
      if (typeof ev.data !== 'string') return;
      let frame: Frame;
      try {
        frame = JSON.parse(ev.data) as Frame;
      } catch {
        return;
      }
      if (frame.type === 'message' && frame.from === 'group' && frame.group) {
        this.opts.onMessage(frame.group, frame.data, frame.fromUserId);
      } else if (frame.type === 'ack') {
        const done = this.pendingAcks.get(frame.ackId);
        if (done) {
          this.pendingAcks.delete(frame.ackId);
          done(frame.success || frame.error?.name === 'Duplicate');
        }
      } else if (frame.type === 'system' && frame.event === 'disconnected') {
        this.opts.log?.(`relay disconnected us: ${frame.message ?? ''}`);
      }
    };

    ws.onerror = () => {
      // onclose follows; nothing useful is exposed here.
    };

    ws.onclose = () => {
      if (this.ws !== ws) return;
      this.ws = undefined;
      for (const done of this.pendingAcks.values()) done(false);
      this.pendingAcks.clear();
      this.setStatus('closed');
      this.scheduleReconnect();
    };
  }

  private scheduleReconnect(): void {
    if (this.stopped) return;
    const base = Math.min(10_000, 500 * 2 ** this.attempt++);
    const delay = base / 2 + Math.random() * (base / 2);
    this.timer = setTimeout(() => void this.connect(), delay);
  }
}

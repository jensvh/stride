// Local stand-in for Azure Web PubSub. It speaks just enough of the
// json.webpubsub.azure.v1 subprotocol (join, publish, ack, roles, fromUserId)
// for the bridge, the lens and the CLI to run unchanged on one PC.
import { WebSocketServer, type WebSocket } from 'ws';
import { HUB } from '../../protocol/schema.ts';
import { verifyJwt } from './tokens.ts';

type Client = { ws: WebSocket; userId: string; roles: string[]; groups: Set<string> };

export function startDevRelay(port: number, key: string, log: (m: string) => void): { close: () => void } {
  const clients = new Set<Client>();
  const wss = new WebSocketServer({
    host: '127.0.0.1',
    port,
    handleProtocols: (protocols) =>
      protocols.has('json.webpubsub.azure.v1') ? 'json.webpubsub.azure.v1' : false,
  });

  const allowed = (c: Client, verb: 'joinLeaveGroup' | 'sendToGroup', group: string) =>
    c.roles.includes(`webpubsub.${verb}`) || c.roles.includes(`webpubsub.${verb}.${group}`);

  wss.on('connection', (ws, req) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const claims = verifyJwt(url.searchParams.get('access_token') ?? '', key);
    if (url.pathname !== `/client/hubs/${HUB}` || !claims || typeof claims.sub !== 'string') {
      ws.close(1008, 'unauthorized');
      return;
    }
    const role = claims.role;
    const client: Client = {
      ws,
      userId: claims.sub,
      roles: Array.isArray(role) ? role.map(String) : typeof role === 'string' ? [role] : [],
      groups: new Set(),
    };
    clients.add(client);
    ws.send(JSON.stringify({ type: 'system', event: 'connected', userId: client.userId, connectionId: crypto.randomUUID() }));

    ws.on('message', (raw) => {
      let m: { type?: string; group?: string; ackId?: number; data?: unknown; dataType?: string; noEcho?: boolean };
      try {
        m = JSON.parse(String(raw));
      } catch {
        return;
      }
      const ack = (success: boolean, name?: string) => {
        if (m.ackId === undefined) return;
        ws.send(JSON.stringify({ type: 'ack', ackId: m.ackId, success, ...(name ? { error: { name } } : {}) }));
      };
      if (!m.group) return ack(false, 'InvalidRequest');
      if (m.type === 'joinGroup') {
        if (!allowed(client, 'joinLeaveGroup', m.group)) return ack(false, 'Forbidden');
        client.groups.add(m.group);
        return ack(true);
      }
      if (m.type === 'sendToGroup') {
        if (!allowed(client, 'sendToGroup', m.group)) return ack(false, 'Forbidden');
        const frame = JSON.stringify({
          type: 'message',
          from: 'group',
          group: m.group,
          dataType: m.dataType ?? 'json',
          data: m.data,
          fromUserId: client.userId,
        });
        for (const other of clients) {
          if (other === client && m.noEcho) continue;
          if (other.groups.has(m.group) && other.ws.readyState === other.ws.OPEN) other.ws.send(frame);
        }
        return ack(true);
      }
    });
    ws.on('close', () => clients.delete(client));
    ws.on('error', () => clients.delete(client));
  });

  wss.on('listening', () => log(`dev relay listening on ws://127.0.0.1:${port}`));
  wss.on('error', (err) => log(`dev relay error: ${String(err)}`));
  return { close: () => wss.close() };
}

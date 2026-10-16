// SyncHub Durable Object: per-user WebSocket fan-out for realtime sync.
// One instance per user id (idFromName(uid)). Clients connect with a valid
// Firebase ID token as ?token=. Server publishes via the internal /publish route.

interface SyncEnv {
  SYNC: DurableObjectNamespace;
}

export class SyncHub implements DurableObject {
  private sockets = new Set<WebSocket>();
  private state: DurableObjectState;

  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === '/publish' && request.method === 'POST') {
      // Internal only: called by the Worker itself via stub.fetch().
      const event = await request.text();
      for (const ws of this.sockets) {
        try {
          ws.send(event);
        } catch {
          /* drop dead socket */
        }
      }
      return new Response(JSON.stringify({ delivered: this.sockets.size }), {
        headers: { 'content-type': 'application/json' },
      });
    }
    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('expected websocket', { status: 426 });
    }
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair) as [WebSocket, WebSocket];
    server.accept();
    this.sockets.add(server);
    server.addEventListener('close', () => this.sockets.delete(server));
    server.addEventListener('error', () => this.sockets.delete(server));
    // Heartbeat: client pings, we echo. Keeps NAT mappings alive.
    server.addEventListener('message', (ev) => {
      if (ev.data === 'ping') {
        try {
          server.send('pong');
        } catch {
          /* ignore */
        }
      }
    });
    return new Response(null, { status: 101, webSocket: client });
  }
}

// Fan out one event object to a user's connected devices.
export async function publishToUser(env: { SYNC: DurableObjectNamespace }, uid: string, event: unknown) {
  try {
    const id = env.SYNC.idFromName(`user:${uid}`);
    const stub = env.SYNC.get(id);
    await stub.fetch('https://sync/publish', {
      method: 'POST',
      body: JSON.stringify(event),
    });
  } catch {
    // Realtime is best-effort; the D1 record is the source of truth.
  }
}

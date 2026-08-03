// Live-sync doorbell — a per-account Durable Object holding hibernatable
// WebSockets, one connection per device.
//
// The write leg is already prompt; the lag is that other devices only learn of a
// change on their poll timer. This closes that gap: when any device writes (PUT
// or DELETE /relic), the Worker pokes the account's DO, which broadcasts a
// content-free {"t":"wake"} nudge to the OTHER connected devices. Each receiver
// then does exactly what it does on a poll tick — GET /relics?since=<cursor> over
// the normal authenticated path. The nudge carries no ciphertext and no payload,
// so this touches none of the E2E crypto or wire format; the pull stays the sole
// source of truth.
//
// Cost/scale: idle sockets use the WebSocket Hibernation API, so they accrue no
// duration billing — we pay only for the brief broadcast bursts. One DO per
// account id means connections are naturally sharded with no hot key.
//
// Self-host runs this same Worker code WITHOUT a Durable Object binding, so
// pokeSync() and the /sync/socket route both no-op there and the client falls
// back to its poll cadence.

import type { Env } from "./env";

interface Attachment {
  device: string;
}

export class SyncSocket {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {}

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);

    // Internal broadcast trigger (Worker -> DO stub, never reachable from the
    // public edge — the outer Worker only calls this via env.SYNC.get(id)).
    if (url.pathname === "/broadcast") {
      const { origin } = await req
        .json<{ origin?: string | null }>()
        .catch(() => ({ origin: null }));
      this.broadcast(origin ?? undefined);
      return new Response(null, { status: 204 });
    }

    // Device WebSocket upgrade (forwarded by the Worker AFTER authenticate()).
    if (req.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const device = req.headers.get("X-Relic-Device") ?? "";
    const { 0: client, 1: server } = new WebSocketPair();
    // Hibernatable accept: the socket survives isolate eviction. The device id is
    // stashed as an attachment (persists across hibernation) so a broadcast can
    // skip the originator without re-sending them their own write.
    this.state.acceptWebSocket(server);
    server.serializeAttachment({ device } satisfies Attachment);
    return new Response(null, { status: 101, webSocket: client });
  }

  private broadcast(origin?: string): void {
    const msg = JSON.stringify({ t: "wake" });
    for (const ws of this.state.getWebSockets()) {
      const att = ws.deserializeAttachment() as Attachment | null;
      if (origin && att?.device && att.device === origin) continue; // skip sender
      try {
        ws.send(msg);
      } catch {
        // socket is mid-close; the hibernation runtime will reap it.
      }
    }
  }

  // --- Hibernation API handlers -------------------------------------------
  // Defining these lets the runtime hibernate idle sockets (no wall-clock
  // billing while nothing is happening). Clients only send periodic keepalive
  // pings, so there is nothing to act on.
  webSocketMessage(_ws: WebSocket, _message: string | ArrayBuffer): void {}

  webSocketClose(ws: WebSocket, code: number): void {
    try {
      // 1000/1005 are normal; anything <1000 is invalid to echo back.
      ws.close(code >= 1000 ? code : 1000, "bye");
    } catch {
      // already closed
    }
  }

  webSocketError(_ws: WebSocket, _err: unknown): void {}
}

// Poke an account's doorbell after a committed write. Fire-and-forget via
// waitUntil so the write response latency is unchanged. No-op when the DO
// binding is absent (self-host), which keeps that path on its poll cadence.
export function pokeSync(
  env: Env,
  ctx: ExecutionContext | undefined,
  account: string,
  origin?: string,
): void {
  if (!env.SYNC) return;
  const stub = env.SYNC.get(env.SYNC.idFromName(account));
  const p = stub
    .fetch("https://do.invalid/broadcast", {
      method: "POST",
      body: JSON.stringify({ origin: origin ?? null }),
    })
    .then(() => {})
    .catch(() => {});
  if (ctx) ctx.waitUntil(p);
  else void p;
}

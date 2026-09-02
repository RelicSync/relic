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
// duration billing, and keepalives are answered by the runtime via an
// auto-response pair rather than waking us — so we pay only for the brief
// broadcast bursts. One DO per account id means connections are naturally
// sharded with no hot key.
//
// Self-host runs this same Worker code WITHOUT a Durable Object binding, so
// pokeSync() and the /sync/socket route both no-op there and the client falls
// back to its poll cadence.

import type { Env } from "./env";

interface Attachment {
  device: string;
}

// The client's keepalive, byte for byte. Registered as an auto-response pair
// below; both halves must match what app/lib/data/sync_socket.dart sends.
const PING = JSON.stringify({ t: "ping" });
const PONG = JSON.stringify({ t: "pong" });

// Hard ceiling on concurrent sockets per account DO. Nothing legitimate comes
// close. Max is the largest tier and it caps devices at unlimited only in the
// sense of "no cap enforced here", while a real account runs a handful. Without
// a ceiling one authenticated token could open sockets until the DO fell over,
// taking live sync down for every device on that account. Clients already treat
// a failed upgrade as "poll instead", so the 429 degrades quietly.
const MAX_SOCKETS = 32;

export class SyncSocket {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {
    // Answer keepalives without waking up. An application-level ping is an
    // ordinary message: it would leave hibernation, run webSocketMessage() to do
    // nothing, and bill a request plus a slice of wall clock — every 30s, for
    // every connected device, forever. Registering the pair hands the reply to
    // the runtime instead, which the docs are explicit about not charging for.
    //
    // This has to live on the server even though new clients now use protocol
    // ping frames (which never reach us at all): builds already in the wild keep
    // sending the JSON ping for as long as they run.
    state.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);

    // Internal broadcast trigger (Worker -> DO stub, never reachable from the
    // public edge — the outer Worker only calls this via env.SYNC.get(id)).
    if (url.pathname === "/broadcast") {
      // The body still carries {origin} and pokeSync still sends it, so no call
      // site changes and X-Relic-Device stays optional, but broadcast() no
      // longer acts on it. See the note on broadcast() below.
      await req.json<{ origin?: string | null }>().catch(() => ({ origin: null }));
      this.broadcast();
      return new Response(null, { status: 204 });
    }

    // Device WebSocket upgrade (forwarded by the Worker AFTER authenticate()).
    if (req.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    if (this.state.getWebSockets().length >= MAX_SOCKETS) {
      return new Response("too many sockets", { status: 429 });
    }
    const device = req.headers.get("X-Relic-Device") ?? "";
    const { 0: client, 1: server } = new WebSocketPair();
    // Hibernatable accept: the socket survives isolate eviction. The device id
    // rides along as an attachment (it persists across hibernation) purely so a
    // connection is identifiable in a debug session; broadcast() no longer
    // branches on it.
    this.state.acceptWebSocket(server);
    server.serializeAttachment({ device } satisfies Attachment);
    return new Response(null, { status: 101, webSocket: client });
  }

  // Wake EVERY socket, including the writer's own.
  //
  // This used to skip the originating device, matched on the X-Relic-Device the
  // writer put on its request against the id the socket asserted at connect
  // time. Both halves are self-asserted by the client, and an account's sibling
  // device ids are enumerable through GET /account/devices, so any device could
  // name a sibling and suppress that sibling's wake: a targeted "your other
  // machine never hears about this write" with no way for the DO to tell the
  // difference. Nothing keyed on device ids inside one account can be made
  // unspoofable, so the suppression is gone rather than patched.
  //
  // Cost of waking the writer too: one extra self-wake per write, which the
  // client answers with an incremental GET /relics?since=<cursor> that finds
  // nothing new. Cheap, and it cannot be weaponised.
  private broadcast(): void {
    const msg = JSON.stringify({ t: "wake" });
    for (const ws of this.state.getWebSockets()) {
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

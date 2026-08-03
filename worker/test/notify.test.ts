import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import { putRelic } from "../src/index";
import { pokeSync, SyncSocket } from "../src/notify";
import { setupSchema } from "./helpers";

// deno-lint-ignore no-explicit-any
const E = env as any;

const WAKE = JSON.stringify({ t: "wake" });

function envelope(uid: string, updated_at: number) {
  return {
    v: 1, uid, created_at: 1000, updated_at, byte_size: 10,
    promoted: false, n: "nonce", ct: "cipher",
  };
}

// A stub SYNC namespace that records every /broadcast body it is asked to send.
function fakeSync() {
  const bodies: Array<{ origin: string | null }> = [];
  return {
    bodies,
    ns: {
      idFromName: (name: string) => ({ name }),
      // deno-lint-ignore no-explicit-any
      get: (_id: any) => ({
        // deno-lint-ignore no-explicit-any
        fetch: (_url: string, init: any) => {
          bodies.push(JSON.parse(init.body));
          return Promise.resolve(new Response(null, { status: 204 }));
        },
      }),
    },
  };
}

const noopCtx = { waitUntil: (_p: Promise<unknown>) => {} } as unknown as ExecutionContext;

function put(env2: unknown, uid: string, updated_at: number, device?: string) {
  const req = new Request(`http://x/relic/${uid}`, {
    method: "PUT",
    body: JSON.stringify(envelope(uid, updated_at)),
  });
  const auth = { account: "A", tier: "free", device } as never;
  return putRelic(req, env2 as never, auth, uid, noopCtx);
}

describe("doorbell: pokeSync wiring in putRelic", () => {
  beforeEach(async () => {
    await setupSchema(E.DB);
  });

  it("pokes the account DO on a real write, carrying the origin device", async () => {
    const f = fakeSync();
    const env2 = { ...E, SYNC: f.ns };
    const resp = await put(env2, "u1", 1000, "devA");
    expect(await resp.json()).toEqual({ stale: false });
    expect(f.bodies).toEqual([{ origin: "devA" }]);
  });

  it("does NOT poke on a stale (LWW-rejected) write", async () => {
    const f = fakeSync();
    const env2 = { ...E, SYNC: f.ns };
    await put(env2, "u1", 2000, "devA"); // first write
    expect(f.bodies.length).toBe(1);
    const stale = await put(env2, "u1", 1000, "devA"); // older updated_at
    expect(await stale.json()).toEqual({ stale: true });
    expect(f.bodies.length).toBe(1); // no second poke
  });

  it("no-ops cleanly when the SYNC binding is absent (self-host)", async () => {
    const env2 = { ...E, SYNC: undefined };
    const resp = await put(env2, "u2", 1000);
    expect(await resp.json()).toEqual({ stale: false }); // write still succeeds
  });
});

// A minimal fake WebSocket + DurableObjectState so we can exercise broadcast()
// through the DO's own /broadcast fetch path without miniflare WS plumbing.
function fakeWs(device: string) {
  const sent: string[] = [];
  return {
    sent,
    ws: {
      deserializeAttachment: () => ({ device }),
      send: (m: string) => sent.push(m),
    } as unknown as WebSocket,
  };
}

function fakeState(sockets: WebSocket[]) {
  return {
    getWebSockets: () => sockets,
    acceptWebSocket: () => {},
  } as unknown as DurableObjectState;
}

async function triggerBroadcast(state: DurableObjectState, origin: string | null) {
  const so = new SyncSocket(state, {} as Env);
  await so.fetch(
    new Request("https://do.invalid/broadcast", {
      method: "POST",
      body: JSON.stringify({ origin }),
    }),
  );
}

describe("doorbell: SyncSocket.broadcast", () => {
  it("wakes every device except the originator", async () => {
    const a = fakeWs("devA");
    const b = fakeWs("devB");
    await triggerBroadcast(fakeState([a.ws, b.ws]), "devA");
    expect(a.sent).toEqual([]); // sender is skipped
    expect(b.sent).toEqual([WAKE]);
  });

  it("wakes all devices when there is no origin", async () => {
    const a = fakeWs("devA");
    const b = fakeWs("devB");
    await triggerBroadcast(fakeState([a.ws, b.ws]), null);
    expect(a.sent).toEqual([WAKE]);
    expect(b.sent).toEqual([WAKE]);
  });
});

describe("doorbell: pokeSync guard", () => {
  it("never touches waitUntil without a SYNC binding", () => {
    let waited = 0;
    const ctx = { waitUntil: () => { waited++; } } as unknown as ExecutionContext;
    pokeSync({} as Env, ctx, "acct", "dev");
    expect(waited).toBe(0);
  });
});

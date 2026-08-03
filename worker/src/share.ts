// E2EE share links (docs: app share dialog → POST /share → GET /s/:id).
//
// The app encrypts the item client-side (AES-GCM-256, AAD "relic.share.v1:<id>",
// wire = iv(12) || ct || tag(16)) and uploads only ciphertext; the decryption
// key travels in the URL FRAGMENT, which never reaches this Worker. Recipients
// need no account: /s/:id serves a self-contained branded page whose inline JS
// fetches the ciphertext and decrypts with WebCrypto.
//
// One-time semantics that survive link-preview bots: the page NEVER increments
// the view count — only the ciphertext fetch does, atomically, so bots that
// snarf the URL for a preview can't burn a one-time share (they don't run JS,
// and even the ones that do still need a user click on Reveal).
//
// Storage follows the established split: R2 holds the opaque bytes
// (shares/<id>, a public namespace — ownership lives in D1), D1 holds the
// metadata row. Create is authed; view is public behind a per-IP rate limit.

import type { Env } from "./env";
import type { Auth } from "./auth";
import { TIERS } from "./tiers";
import { CORS, err, json } from "./http";

// Client-minted 128-bit id (16 bytes → unpadded base64url = 22 chars). Minted
// client-side so the AAD can bind ciphertext to id BEFORE upload.
const ID_RE = /^[A-Za-z0-9_-]{22}$/;
const TTLS = new Set([3600, 86400, 604800]); // 1 hour / 1 day / 7 days
const MIN_WIRE = 29; // iv(12) + tag(16) + at least 1 ct byte

export const shareR2Key = (id: string) => `shares/${id}`;
export const isShareId = (s: string) => ID_RE.test(s);

const now = () => Math.floor(Date.now() / 1000);

/** POST /share?id=&ttl=&views= — body is raw ciphertext. Authed. */
export async function createShare(
  req: Request,
  url: URL,
  env: Env,
  auth: Auth,
): Promise<Response> {
  const id = url.searchParams.get("id") ?? "";
  if (!ID_RE.test(id)) return err(400, "bad_request", "bad share id");
  const ttl = Number(url.searchParams.get("ttl"));
  if (!TTLS.has(ttl)) return err(400, "bad_request", "ttl must be 3600, 86400 or 604800");
  const viewsRaw = url.searchParams.get("views");
  let maxViews: number | null = null;
  if (viewsRaw !== null) {
    maxViews = Number(viewsRaw);
    if (!Number.isInteger(maxViews) || maxViews < 1 || maxViews > 100) {
      return err(400, "bad_request", "views must be 1-100");
    }
  }

  const data = await req.arrayBuffer();
  const caps = TIERS[auth.tier];
  if (data.byteLength < MIN_WIRE) return err(400, "bad_request", "ciphertext too short");
  if (data.byteLength > caps.shareBytes) {
    return err(413, "too_large", "share exceeds tier cap");
  }

  // Active-share cap (expired or fully-viewed shares don't count).
  if (caps.shares !== null) {
    const active = await env.DB.prepare(
      `SELECT COUNT(*) AS n FROM shares
       WHERE account_id = ?1 AND expires_at > ?2
         AND (max_views IS NULL OR views < max_views)`,
    ).bind(auth.account, now()).first<{ n: number }>();
    if ((active?.n ?? 0) >= caps.shares) {
      return err(402, "share_cap", "active share limit reached");
    }
  }

  // D1 INSERT first: reserves the id atomically (PK violation → 409, the
  // client re-mints), and guarantees no orphan R2 object can exist — a crash
  // between insert and put leaves a row whose blob fetch 410s and which the
  // sweep reaps at expiry.
  const expiresAt = now() + ttl;
  try {
    await env.DB.prepare(
      `INSERT INTO shares (id, account_id, created_at, expires_at, max_views, views, byte_size)
       VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6)`,
    ).bind(id, auth.account, now(), expiresAt, maxViews, data.byteLength).run();
  } catch {
    return err(409, "share_id_collision", "id already exists; mint a new one");
  }
  try {
    await env.STORE.put(shareR2Key(id), data);
  } catch (e) {
    await env.DB.prepare("DELETE FROM shares WHERE id = ?1").bind(id).run();
    throw e;
  }

  return json({ id, url: `${url.origin}/s/${id}`, expires_at: expiresAt });
}

/** GET /share/:id/blob — public ciphertext fetch WITH view accounting. */
export async function fetchShareBlob(
  env: Env,
  ctx: ExecutionContext | undefined,
  id: string,
): Promise<Response> {
  if (!ID_RE.test(id)) return err(404, "not_found", "no such share");
  // Atomic claim: expiry enforced at read time (no sweep dependency); two
  // racing one-time fetches — exactly one row comes back.
  const row = await env.DB.prepare(
    `UPDATE shares SET views = views + 1
     WHERE id = ?1 AND expires_at > ?2
       AND (max_views IS NULL OR views < max_views)
     RETURNING views, max_views`,
  ).bind(id, now()).first<{ views: number; max_views: number | null }>();
  if (!row) {
    const exists = await env.DB.prepare("SELECT 1 FROM shares WHERE id = ?1").bind(id).first();
    return exists
      ? err(410, "share_gone", "this share has expired or was already viewed")
      : err(404, "not_found", "no such share");
  }
  const obj = await env.STORE.get(shareR2Key(id));
  if (!obj) return err(410, "share_gone", "share content is no longer available");
  const headers = {
    ...CORS,
    "Content-Type": "application/octet-stream",
    "Cache-Control": "no-store",
  };
  // Last permitted view: buffer the bytes BEFORE dropping the ciphertext (the
  // response must not stream from an object we're deleting). The D1 row stays
  // so later hits say "already viewed" (nicer than a generic 404) until the
  // sweep reaps it.
  if (row.max_views !== null && row.views >= row.max_views) {
    const data = await obj.arrayBuffer();
    const del = env.STORE.delete(shareR2Key(id));
    if (ctx) ctx.waitUntil(del);
    else await del;
    return new Response(data, { headers });
  }
  return new Response(obj.body, { headers });
}

/** DELETE /share/:id — owner revoke. Idempotent. */
export async function revokeShare(env: Env, auth: Auth, id: string): Promise<Response> {
  if (!ID_RE.test(id)) return err(400, "bad_request", "bad share id");
  const gone = await env.DB.prepare(
    "DELETE FROM shares WHERE id = ?1 AND account_id = ?2 RETURNING id",
  ).bind(id, auth.account).first();
  if (gone) await env.STORE.delete(shareR2Key(id));
  return json({ ok: true });
}

/** Cron GC: expired or fully-viewed shares. R2 first so a crash re-sweeps. */
export async function sweepShares(env: Env): Promise<void> {
  const rows = await env.DB.prepare(
    `SELECT id FROM shares
     WHERE expires_at < ?1 OR (max_views IS NOT NULL AND views >= max_views)
     LIMIT 100`,
  ).bind(now()).all<{ id: string }>();
  for (const { id } of rows.results) {
    await env.STORE.delete(shareR2Key(id));
    await env.DB.prepare("DELETE FROM shares WHERE id = ?1").bind(id).run();
  }
}

/** GET /s/:id — the branded recipient page. NEVER touches the view count. */
export async function sharePageResponse(env: Env, id: string): Promise<Response> {
  const headers = {
    ...CORS,
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Robots-Tag": "noindex",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy":
      "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src blob:",
  };
  if (!ID_RE.test(id)) return new Response(sharePage("gone"), { status: 404, headers });
  const row = await env.DB.prepare(
    "SELECT expires_at, max_views, views FROM shares WHERE id = ?1",
  ).bind(id).first<{ expires_at: number; max_views: number | null; views: number }>();
  const live = !!row && row.expires_at > now() &&
    (row.max_views === null || row.views < row.max_views);
  if (!live) return new Response(sharePage("gone"), { status: 404, headers });
  return new Response(
    sharePage({ id, oneTime: row!.max_views === 1, expiresAt: row!.expires_at }),
    { headers },
  );
}

// The page is fully self-contained (strict CSP, zero external requests). `id`
// is regex-validated above, so interpolation is safe. Dark card styled after
// relic.space.
function sharePage(
  state: { id: string; oneTime: boolean; expiresAt: number } | "gone",
): string {
  const gone = state === "gone";
  const boot = gone
    ? '{"gone":true}'
    : JSON.stringify({ id: state.id, oneTime: state.oneTime, expiresAt: state.expiresAt });
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Encrypted share · Relic</title>
<style>
  :root { color-scheme: dark; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    min-height: 100vh; display: flex; align-items: center; justify-content: center;
    background: #0f1115; color: #e8e8ea; padding: 20px;
    font: 15px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif;
  }
  .card {
    width: 100%; max-width: 560px; background: #15181f;
    border: 1px solid #262b36; border-radius: 14px; padding: 28px;
  }
  .wordmark {
    display: flex; align-items: center; gap: 9px; margin-bottom: 22px;
    font-family: ui-monospace, "Cascadia Mono", monospace;
    font-size: 12px; letter-spacing: 2.5px; color: #8b8f98;
  }
  .gem { color: #daa43e; font-size: 14px; }
  h1 { font-size: 19px; font-weight: 600; margin-bottom: 6px; }
  .meta { font-size: 13px; color: #8b8f98; margin-bottom: 22px; }
  button {
    font: inherit; font-weight: 600; cursor: pointer; border: 0;
    background: #daa43e; color: #1a1405; border-radius: 9px; padding: 11px 22px;
  }
  button:hover { background: #e6b355; }
  button.ghost {
    background: #1d212b; color: #c8ccd4; border: 1px solid #2e3442;
    font-weight: 500; padding: 8px 16px; font-size: 13px;
  }
  #out { display: none; margin-top: 6px; }
  pre {
    background: #0f1115; border: 1px solid #262b36; border-radius: 9px;
    padding: 14px; white-space: pre-wrap; word-break: break-word;
    font: 13.5px/1.5 ui-monospace, "Cascadia Mono", monospace; color: #e8e8ea;
    max-height: 55vh; overflow: auto; margin-bottom: 12px;
  }
  img { max-width: 100%; border-radius: 9px; border: 1px solid #262b36; margin-bottom: 12px; }
  a.dl {
    display: inline-block; background: #daa43e; color: #1a1405; font-weight: 600;
    text-decoration: none; border-radius: 9px; padding: 11px 22px;
  }
  .err { color: #e07a6b; font-size: 14px; }
  .foot {
    margin-top: 24px; padding-top: 16px; border-top: 1px solid #232833;
    font-size: 12px; color: #6b7079;
  }
  .foot a { color: #8b8f98; }
</style>
</head>
<body>
<div class="card">
  <div class="wordmark"><span class="gem">&#9670;</span>RELIC</div>
  <h1 id="title">Someone sent you an encrypted item</h1>
  <p class="meta" id="meta"></p>
  <div id="action"><button id="reveal">Reveal</button></div>
  <div id="out"></div>
  <p class="foot">End-to-end encrypted. The key in this link stays in your browser and never reaches the server. Sent with <a href="https://relic.space">Relic</a>.</p>
</div>
<script>
(function () {
  var S = ${boot};
  var meta = document.getElementById('meta');
  var out = document.getElementById('out');
  var action = document.getElementById('action');
  var title = document.getElementById('title');

  function fail(msg) {
    title.textContent = 'Nothing to see here';
    action.style.display = 'none';
    meta.className = 'err';
    meta.textContent = msg;
  }
  function b64urlToBytes(s) {
    s = s.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    var bin = atob(s), a = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i);
    return a;
  }
  function b64ToBytes(s) {
    var bin = atob(s), a = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i);
    return a;
  }

  if (S.gone) {
    return fail('This share has expired or was already viewed.');
  }
  var frag = location.hash.slice(1);
  if (frag.length !== 43) {
    return fail('This link is incomplete. Ask the sender to resend the full link, including everything after the # sign.');
  }
  var when = new Date(S.expiresAt * 1000);
  meta.textContent = (S.oneTime ? 'One-time view · ' : '') + 'expires ' +
    when.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  if (S.oneTime) {
    meta.textContent += '. Revealing it consumes the link.';
  }

  document.getElementById('reveal').addEventListener('click', function () {
    this.disabled = true;
    this.textContent = 'Decrypting\\u2026';
    var self = this;
    fetch('/share/' + S.id + '/blob')
      .then(function (r) {
        if (r.status === 404 || r.status === 410) throw new Error('gone');
        if (!r.ok) throw new Error('net');
        return r.arrayBuffer();
      })
      .then(function (buf) {
        var bytes = new Uint8Array(buf);
        return crypto.subtle.importKey('raw', b64urlToBytes(frag), 'AES-GCM', false, ['decrypt'])
          .then(function (key) {
            return crypto.subtle.decrypt(
              { name: 'AES-GCM', iv: bytes.slice(0, 12),
                additionalData: new TextEncoder().encode('relic.share.v1:' + S.id) },
              key, bytes.slice(12));
          });
      })
      .then(function (plain) {
        var p = JSON.parse(new TextDecoder().decode(plain));
        action.style.display = 'none';
        out.style.display = 'block';
        if (p.kind === 'text') {
          title.textContent = 'Here it is';
          var pre = document.createElement('pre');
          pre.textContent = p.text || '';
          out.appendChild(pre);
          var copy = document.createElement('button');
          copy.className = 'ghost';
          copy.textContent = 'Copy';
          copy.addEventListener('click', function () {
            navigator.clipboard.writeText(p.text || '').then(function () {
              copy.textContent = 'Copied \\u2713';
              setTimeout(function () { copy.textContent = 'Copy'; }, 1600);
            });
          });
          out.appendChild(copy);
        } else {
          var blob = new Blob([b64ToBytes(p.data || '')], { type: p.mime || 'application/octet-stream' });
          var u = URL.createObjectURL(blob);
          if (p.kind === 'image') {
            title.textContent = 'Here it is';
            var img = document.createElement('img');
            img.src = u;
            out.appendChild(img);
          }
          var a = document.createElement('a');
          a.className = 'dl';
          a.href = u;
          a.download = p.name || (p.kind === 'image' ? 'image' : 'file');
          a.textContent = p.kind === 'image' ? 'Download image' : 'Download ' + (p.name || 'file');
          if (p.kind !== 'image') title.textContent = 'A file was shared with you';
          out.appendChild(a);
        }
      })
      .catch(function (e) {
        if (e && e.message === 'gone') {
          fail('This share has expired or was already viewed.');
        } else if (e && e.message === 'net') {
          self.disabled = false;
          self.textContent = 'Reveal';
          meta.className = 'err';
          meta.textContent = 'Network hiccup. Try again.';
        } else {
          fail("Couldn't decrypt this share. The link may be damaged.");
        }
      });
  });
})();
</script>
</body>
</html>`;
}

// Shared HTTP helpers. CORS is permissive on purpose: auth is a bearer token,
// not cookies, so there is no ambient-authority (CSRF) risk in allowing any
// origin. Stripe-Signature is allowed so the webhook works cross-origin too.
export const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,PUT,POST,PATCH,DELETE,OPTIONS",
  "Access-Control-Allow-Headers": "Authorization,Content-Type,Stripe-Signature,X-Relic-Device,X-Relic-App-Version",
  "Access-Control-Max-Age": "86400",
};

export const json = (data: unknown, status = 200): Response =>
  Response.json(data, { status, headers: CORS });

export const err = (status: number, code: string, message: string): Response =>
  Response.json({ error: code, message }, { status, headers: CORS });

/// Page size for the cursor-paginated list routes (listRelics, listAi). The raw
/// value came off the query string and was interpolated straight into the SQL
/// text, so `limit=abc` reached D1 as `LIMIT NaN` and `limit=-1` as an
/// unbounded scan: a 500 or a full table read rather than a page. Clamped to
/// [1, 500] and bound as a parameter at both call sites. Shipped clients only
/// ever send 1 or 500, both inside the clamp, so no live install changes shape.
export const clampLimit = (raw: string | null): number => {
  const n = Math.trunc(Number(raw ?? 500));
  if (!Number.isFinite(n)) return 500;
  return Math.min(Math.max(n, 1), 500);
};

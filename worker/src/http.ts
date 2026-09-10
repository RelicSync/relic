// Shared HTTP helpers. CORS is permissive on purpose: auth is a bearer token,
// not cookies, so there is no ambient-authority (CSRF) risk in allowing any
// origin. Stripe-Signature is allowed so the webhook works cross-origin too.
export const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,PUT,POST,PATCH,DELETE,OPTIONS",
  "Access-Control-Allow-Headers": "Authorization,Content-Type,Stripe-Signature,X-Relic-Device,X-Relic-App-Version",
  "Access-Control-Max-Age": "86400",
  // So a browser client (the web vault) can read the pacing and
  // deprecation headers, which are not on the CORS safelist.
  "Access-Control-Expose-Headers":
    "RateLimit,RateLimit-Policy,RateLimit-Limit,RateLimit-Remaining,RateLimit-Reset,Retry-After,Deprecation,Sunset,Link",
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

/// The headers a route carries while it is being retired (docs/api.md
/// "Versioning and deprecation"): `Deprecation` (RFC 9745) says since when,
/// `Sunset` (RFC 8594) says the date it stops answering, and a
/// `successor-version` link says where to go instead. Nothing is deprecated
/// today; this is the one place the policy's wire format lives, so the first
/// retirement does not invent its own.
export function deprecated(
  res: Response,
  opts: { since: Date; sunset: Date; successor?: string },
): Response {
  res.headers.set("Deprecation", `@${Math.floor(opts.since.getTime() / 1000)}`);
  res.headers.set("Sunset", opts.sunset.toUTCString());
  if (opts.successor) res.headers.append("Link", `<${opts.successor}>; rel="successor-version"`);
  return res;
}

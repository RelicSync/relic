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

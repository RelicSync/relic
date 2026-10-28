// The free plan's sync rule (env.SYNC_PLAN_GATE === "on").
//
// Free is one device. A new free account syncs on every device for its first
// SYNC_WEEK; after that, one device (accounts.sync_device) keeps syncing and the
// rest are refused with 403 sync_paused. A computer keeps working locally when
// paused; a phone shows the paused screen. Paying lifts the rule at once.
//
// accounts.sync_until overrides the sign-up week (set by hand for accounts given
// extra time at launch). accounts.sync_device_at is when the user last PICKED
// the device; an automatic pick leaves it NULL so the first real choice is free.
//
// Off by default so the server can ship before the apps that explain the 403.
// Self-host never sets the flag. Plan: docs/free-plan-sync-week-2026-10.md
// (private repo).
import type { Auth } from "./auth";
import type { Env } from "./env";
import { err, json } from "./http";
import { type NudgeMail, sendNudgeMail } from "./stripe";

export const SYNC_WEEK = 7 * 86400;
export const SYNC_SWITCH_COOLDOWN = 7 * 86400;

export interface SyncPlan {
  /** Unix seconds free multi-device sync ends. Null = no limit (paid, flag
   *  off, or no account row). */
  syncUntil: number | null;
  /** The device that keeps syncing once the week is over. Null until the
   *  first time the rule applies, or when it is not in force. */
  syncDevice: string | null;
  /** Unix seconds the user last picked the device by hand. Null = never. */
  syncDeviceAt: number | null;
  /** Active (non-revoked) devices on the account. */
  devices: number;
}

const NO_LIMIT: SyncPlan = { syncUntil: null, syncDevice: null, syncDeviceAt: null, devices: 0 };

export const syncPlanOn = (env: Env) => env.SYNC_PLAN_GATE === "on";

// One D1 read per data-plane request would be a lot for a rule that changes a
// few times in an account's life, so warm isolates keep the plan for a minute.
// A pick through POST /account/sync-device clears this isolate's copy; another
// isolate can be up to CACHE_S behind, which only delays a switch.
const CACHE_S = 60;
const cache = new Map<string, { at: number; plan: SyncPlan }>();

export function forgetSyncPlan(account: string) {
  cache.delete(account);
}

/** The account's sync plan. Paid tiers, a disabled gate and an account with no
 *  row all come back as "no limit". */
export async function readSyncPlan(env: Env, auth: Auth): Promise<SyncPlan> {
  if (!syncPlanOn(env) || auth.tier !== "free") return NO_LIMIT;
  const now = Math.floor(Date.now() / 1000);
  const hit = cache.get(auth.account);
  if (hit && hit.at > now - CACHE_S) return hit.plan;

  const row = await env.DB.prepare(
    `SELECT a.created_at, a.sync_until, a.sync_device, a.sync_device_at,
            (SELECT COUNT(*) FROM devices d
              WHERE d.account_id = a.account_id AND d.revoked_at IS NULL) AS n,
            (SELECT 1 FROM devices d
              WHERE d.account_id = a.account_id AND d.device_id = a.sync_device
                AND d.revoked_at IS NULL) AS kept,
            (SELECT 1 FROM devices d
              WHERE d.account_id = a.account_id AND d.device_id = ?2
                AND d.revoked_at IS NULL) AS mine,
            (SELECT d.device_id FROM devices d
              WHERE d.account_id = a.account_id AND d.revoked_at IS NULL
              ORDER BY d.last_seen_at DESC LIMIT 1) AS latest
       FROM accounts a WHERE a.account_id = ?1`,
  ).bind(auth.account, auth.device ?? null).first<{
    created_at: number;
    sync_until: number | null;
    sync_device: string | null;
    sync_device_at: number | null;
    n: number;
    kept: number | null;
    mine: number | null;
    latest: string | null;
  }>();
  if (!row) return NO_LIMIT; // legacy token with no account row: grandfathered

  const until = row.sync_until ?? row.created_at + SYNC_WEEK;
  const plan: SyncPlan = {
    syncUntil: until,
    syncDevice: row.kept ? row.sync_device : null,
    syncDeviceAt: row.kept ? row.sync_device_at : null,
    devices: Number(row.n) || 0,
  };

  // Past the week with no live pick: settle one now and write it down, so the
  // choice never drifts after this. The first device to sync after the week
  // keeps syncing. That is usually the computer, which checks in all day while
  // a phone only does when it is opened. "Most recently seen" cannot be used
  // here: touchDevice() stamps the calling device just before this runs, so it
  // would name the caller anyway, only less predictably. A request with no
  // device id falls back to the most recently seen device. The user can change
  // the pick once for free. The WHERE keeps a concurrent pick from being
  // overwritten; the re-read takes whichever pick won.
  const pick = row.mine ? auth.device! : row.latest;
  if (now >= until && plan.syncDevice === null && pick) {
    await env.DB.prepare(
      `UPDATE accounts SET sync_device = ?2, sync_device_at = NULL
        WHERE account_id = ?1 AND (sync_device IS NULL OR sync_device = ?3)`,
    ).bind(auth.account, pick, row.sync_device).run();
    const won = await env.DB.prepare("SELECT sync_device FROM accounts WHERE account_id = ?1")
      .bind(auth.account).first<{ sync_device: string | null }>();
    plan.syncDevice = won?.sync_device ?? pick;
    plan.syncDeviceAt = null;
  }

  cache.set(auth.account, { at: now, plan });
  return plan;
}

/** True when this request's device may not sync under the plan. */
export function isSyncPaused(plan: SyncPlan, device: string | undefined, now = Math.floor(Date.now() / 1000)): boolean {
  if (plan.syncUntil === null || now < plan.syncUntil) return false;
  if (plan.devices <= 1) return false; // one device is the free plan
  // A request that does not say which device it is cannot be the kept one.
  return !device || device !== plan.syncDevice;
}

/** The 403 a paused device gets. Carries what the app needs to draw its
 *  "pick a device or upgrade" screen without another round trip. */
export function syncPausedResponse(plan: SyncPlan, devices: unknown[]): Response {
  return json(
    {
      error: "sync_paused",
      message: "Free plans sync one device. Sync is paused on this one.",
      sync_until: plan.syncUntil,
      sync_device: plan.syncDevice,
      devices,
    },
    403,
  );
}

/** POST /account/sync-device { device_id }: pick the device that keeps
 *  syncing. Free accounts may switch once per SYNC_SWITCH_COOLDOWN; the first
 *  pick after an automatic one is always allowed. */
export async function pickSyncDevice(req: Request, env: Env, auth: Auth): Promise<Response> {
  let b: { device_id?: unknown };
  try {
    b = await req.json();
  } catch {
    return err(400, "bad_request", "not JSON");
  }
  const id = typeof b.device_id === "string" ? b.device_id : "";
  if (!id || id.length > 64) return err(400, "bad_request", "bad device_id");

  const row = await env.DB.prepare(
    `SELECT a.sync_device, a.sync_device_at,
            (SELECT 1 FROM devices d WHERE d.account_id = a.account_id
                AND d.device_id = ?2 AND d.revoked_at IS NULL) AS known
       FROM accounts a WHERE a.account_id = ?1`,
  ).bind(auth.account, id).first<{
    sync_device: string | null;
    sync_device_at: number | null;
    known: number | null;
  }>();
  if (!row) return err(404, "not_found", "no account");
  if (!row.known) return err(404, "not_found", "unknown or removed device");
  if (row.sync_device === id) return json({ ok: true, sync_device: id });

  const now = Math.floor(Date.now() / 1000);
  if (auth.tier === "free" && row.sync_device_at !== null && now - row.sync_device_at < SYNC_SWITCH_COOLDOWN) {
    const retryAt = row.sync_device_at + SYNC_SWITCH_COOLDOWN;
    return json(
      {
        error: "sync_switch_cooldown",
        message: "You can change the syncing device once a week.",
        retry_at: retryAt,
      },
      429,
    );
  }
  await env.DB.prepare(
    "UPDATE accounts SET sync_device = ?2, sync_device_at = ?3 WHERE account_id = ?1",
  ).bind(auth.account, id, now).run();
  forgetSyncPlan(auth.account);
  return json({ ok: true, sync_device: id });
}

// ---- the end-of-week email (cron) -------------------------------------------

const SYNC_EMAIL_BATCH = 50;
/// A device counts as in use if it synced within this long. Older devices are
/// not paused in any way a person would notice, so they don't earn an email.
const SYNC_EMAIL_ACTIVE = 14 * 86400;

/// One email per free account, when its free week ends and it still uses two
/// or more devices: sync now runs on one of them, how to pick which, and what
/// Pro costs. Runs from the cron, only while the rule is on, and never on an
/// account with a subscription. accounts.sync_email_at keeps it to one.
///
/// Accounts given extra time at launch have a later sync_until, so they get
/// theirs when that runs out, not on switch day.
export async function syncWeekSweep(env: Env): Promise<void> {
  // Checked before any query: self-host has no Resend key and the rule off.
  if (!syncPlanOn(env) || !env.RESEND_API_KEY) return;
  const now = Math.floor(Date.now() / 1000);
  const due = await env.DB.prepare(
    `SELECT a.account_id, a.email
       FROM accounts a
      WHERE a.tier = 'free'
        AND a.email IS NOT NULL
        AND a.sync_email_at IS NULL
        AND COALESCE(a.sync_until, a.created_at + ?1) <= ?2
        AND NOT EXISTS (SELECT 1 FROM subscriptions s WHERE s.account_id = a.account_id)
        AND (SELECT COUNT(*) FROM devices d
              WHERE d.account_id = a.account_id AND d.revoked_at IS NULL
                AND d.last_seen_at > ?3) >= 2
      LIMIT ?4`,
  ).bind(SYNC_WEEK, now, now - SYNC_EMAIL_ACTIVE, SYNC_EMAIL_BATCH)
    .all<{ account_id: string; email: string }>();

  for (const row of due.results ?? []) {
    if (await sendNudgeMail(env, "sync_week_email", row.account_id, row.email, syncWeekMail())) {
      await env.DB.prepare("UPDATE accounts SET sync_email_at = ?2 WHERE account_id = ?1")
        .bind(row.account_id, now).run();
    }
  }
}

export function syncWeekMail(): NudgeMail {
  const upgrade = "https://relic.space/upgrade?source=sync_week_email";
  const help = "https://relic.space/help/how-sync-works";
  return {
    subject: "Relic now syncs one of your devices",
    text:
      "Your free week of sync on all your devices is over.\n\n" +
      "The free plan syncs one device. Relic keeps syncing the first device " +
      "that checked in after your week ended, and sync is paused on the " +
      "others. Nothing is lost. Each device keeps everything it already has " +
      "and keeps saving new things.\n\n" +
      "To pick which device syncs, open Relic on it and choose \"Sync this " +
      "device instead\". You can switch once a week.\n\n" +
      "Pro syncs all your devices for $7 a month or $60 a year.\n\n" +
      `${upgrade}\n\n` +
      `More about how sync works: ${help}\n\n` +
      "Reply to this email if anything is off.\n\n" +
      "The Relic team",
    html:
      "<p>Your free week of sync on all your devices is over.</p>" +
      "<p>The free plan syncs one device. Relic keeps syncing the first " +
      "device that checked in after your week ended, and sync is paused on " +
      "the others. Nothing is lost. Each device keeps everything it already " +
      "has and keeps saving new things.</p>" +
      "<p>To pick which device syncs, open Relic on it and choose \"Sync this " +
      "device instead\". You can switch once a week.</p>" +
      "<p>Pro syncs all your devices for $7 a month or $60 a year.</p>" +
      `<p><a href="${upgrade}">Get Pro</a></p>` +
      `<p><a href="${help}">More about how sync works</a></p>` +
      "<p>Reply to this email if anything is off.</p>" +
      "<p>The Relic team</p>",
  };
}

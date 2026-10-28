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
// Self-host never sets the flag.
//
// Only accounts made since the rule started (env.SYNC_PLAN_SINCE) are under
// it. An account counts as older when its row or any device it ever had
// predates that, because rows are made lazily (auth.ts), so an older user
// signing in for the first time in a while can get a brand new row.
//
// Only apps that can explain a pause are ever paused: a device whose recorded
// app version is older than SYNC_PAUSE_MIN_VERSION, or unknown (the web vault,
// legacy clients, a request with no device id), keeps syncing. Old installs
// rarely update, and an old app shows a bare "Offline" for a 403, so they are
// left alone instead. When one updates, the rule reaches it on its own. Plan: docs/free-plan-sync-week-2026-10.md
// (private repo).
import type { Auth } from "./auth";
import type { Env } from "./env";
import { err, json } from "./http";
import { type NudgeMail, sendNudgeMail } from "./stripe";

export const SYNC_WEEK = 7 * 86400;
export const SYNC_SWITCH_COOLDOWN = 7 * 86400;
/** A kept device not seen for this long can be switched away from at once. */
export const SYNC_KEPT_QUIET = 3 * 86400;
/** The first app release that explains sync_paused (banner, "Sync this device
 *  instead"). Older apps are never paused. */
export const SYNC_PAUSE_MIN_VERSION = "1.0.64";

/** Numeric parts of "1.0.64" or "1.0.64+82". Null for anything else. */
function versionParts(v: string | null | undefined): number[] | null {
  const m = /^(\d+)\.(\d+)\.(\d+)(?:[+-].*)?$/.exec((v ?? "").trim());
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

/** True when an app at version `v` can explain a pause. Unknown or
 *  unparseable versions cannot. */
export function canExplainPause(v: string | null | undefined): boolean {
  const have = versionParts(v);
  const need = versionParts(SYNC_PAUSE_MIN_VERSION)!;
  if (!have) return false;
  for (let i = 0; i < 3; i++) {
    if (have[i] !== need[i]) return have[i] > need[i];
  }
  return true;
}

/// A device counts for the rule only when its app can explain a pause and it
/// was seen within this long. Every other device is invisible to the rule:
/// never paused, never counted, never kept. That covers old apps, the web
/// vault, and device ids left behind by a reinstall or a lost phone, so none of
/// them can hold the one syncing slot.
export const SYNC_ACTIVE = 14 * 86400;

export interface PlanDevice {
  id: string;
  /** Recorded app version (null = never reported). */
  version: string | null;
  lastSeen: number;
}

export interface SyncPlan {
  /** Unix seconds free multi-device sync ends. Null = no limit (paid, flag
   *  off, or no account row). */
  syncUntil: number | null;
  /** The device that keeps syncing once the week is over. Only ever a device
   *  that counts. Null until the first time the rule applies, or when it is
   *  not in force. */
  syncDevice: string | null;
  /** Unix seconds the user last picked the device by hand. Null = never. */
  syncDeviceAt: number | null;
  /** Active (non-revoked) devices on the account. */
  devices: PlanDevice[];
}

const NO_LIMIT: SyncPlan = { syncUntil: null, syncDevice: null, syncDeviceAt: null, devices: [] };

export const syncPlanOn = (env: Env) => env.SYNC_PLAN_GATE === "on";

/** When the rule started, or null when env.SYNC_PLAN_SINCE is unset or junk
 *  (then the rule reaches nobody). */
export function syncPlanSince(env: Env): number | null {
  const n = Number(env.SYNC_PLAN_SINCE);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : null;
}

const counts = (d: PlanDevice | undefined, now: number): boolean =>
  !!d && canExplainPause(d.version) && d.lastSeen > now - SYNC_ACTIVE;

/** Whether the calling device counts. It is live by definition, so only its
 *  version matters: the request's own X-Relic-App-Version or the recorded one,
 *  whichever is new enough. Taking either means an app that just updated counts
 *  at once, and a client can't dodge the rule by sending an old version. A
 *  device id the account doesn't have never counts. */
function callerCounts(plan: SyncPlan, device: string | undefined, appVersion: string | null | undefined): boolean {
  const d = device ? plan.devices.find((x) => x.id === device) : undefined;
  return !!d && (canExplainPause(appVersion) || canExplainPause(d.version));
}

// One D1 read per data-plane request would be a lot for a rule that changes a
// few times in an account's life, so warm isolates keep the plan for a minute.
// A pick, a new device and a removed device clear this isolate's copy; another
// isolate can be up to CACHE_S behind, which only delays a change.
const CACHE_S = 60;
const cache = new Map<string, { at: number; plan: SyncPlan }>();

export function forgetSyncPlan(account: string) {
  cache.delete(account);
}

/** The account's sync plan. Paid tiers, a disabled gate and an account with no
 *  row all come back as "no limit". `appVersion` is the request's
 *  X-Relic-App-Version. */
export async function readSyncPlan(env: Env, auth: Auth, appVersion?: string | null): Promise<SyncPlan> {
  const since = syncPlanSince(env);
  if (!syncPlanOn(env) || since === null || auth.tier !== "free") return NO_LIMIT;
  const now = Math.floor(Date.now() / 1000);
  const hit = cache.get(auth.account);
  if (hit && hit.at > now - CACHE_S) return hit.plan;

  const row = await env.DB.prepare(
    "SELECT created_at, sync_until, sync_device, sync_device_at FROM accounts WHERE account_id = ?1",
  ).bind(auth.account).first<{
    created_at: number;
    sync_until: number | null;
    sync_device: string | null;
    sync_device_at: number | null;
  }>();
  if (!row) return NO_LIMIT; // legacy token with no account row: grandfathered

  // A free account has at most a handful of devices. Removed ones are read too,
  // for the age check below.
  const devs = await env.DB.prepare(
    "SELECT device_id, app_version, last_seen_at, created_at, revoked_at FROM devices WHERE account_id = ?1",
  ).bind(auth.account).all<{
    device_id: string;
    app_version: string | null;
    last_seen_at: number | null;
    created_at: number | null;
    revoked_at: number | null;
  }>();
  const all = devs.results ?? [];
  // Made before the rule started: never under it. A missing date counts as old.
  if (row.created_at < since || all.some((d) => !(Number(d.created_at) >= since))) {
    cache.set(auth.account, { at: now, plan: NO_LIMIT });
    return NO_LIMIT;
  }

  const until = row.sync_until ?? row.created_at + SYNC_WEEK;
  const plan: SyncPlan = {
    syncUntil: until,
    syncDevice: null,
    syncDeviceAt: null,
    devices: all.filter((d) => d.revoked_at === null).map((d) => ({
      id: d.device_id,
      version: d.app_version,
      lastSeen: Number(d.last_seen_at) || 0,
    })),
  };
  const mine = callerCounts(plan, auth.device, appVersion);
  const kept = row.sync_device;
  if (kept && (counts(plan.devices.find((d) => d.id === kept), now) || (kept === auth.device && mine))) {
    plan.syncDevice = kept;
    plan.syncDeviceAt = row.sync_device_at;
  }

  // Past the week with no kept device that counts: settle one now and write it
  // down, so the choice doesn't drift. The first counting device to sync after
  // the week keeps syncing. That is usually the computer, which checks in all
  // day while a phone only does when it is opened. A caller that doesn't count
  // (old app, web vault, no device id) hands the slot to the most recently seen
  // device that does. A kept device that stopped counting (removed, gone quiet
  // for SYNC_ACTIVE, or never new enough) is replaced the same way, so a lost
  // phone can't leave the only real device paused. An automatic pick leaves
  // sync_device_at NULL, so the user's next pick is free. The WHERE keeps a
  // concurrent pick from being overwritten; the re-read takes whichever won.
  if (now >= until && plan.syncDevice === null) {
    const pick = mine
      ? auth.device!
      : plan.devices.filter((d) => counts(d, now)).sort((a, b) => b.lastSeen - a.lastSeen)[0]?.id;
    if (pick) {
      await env.DB.prepare(
        `UPDATE accounts SET sync_device = ?2, sync_device_at = NULL
          WHERE account_id = ?1 AND (sync_device IS NULL OR sync_device = ?3)`,
      ).bind(auth.account, pick, kept).run();
      const won = await env.DB.prepare("SELECT sync_device, sync_device_at FROM accounts WHERE account_id = ?1")
        .bind(auth.account).first<{ sync_device: string | null; sync_device_at: number | null }>();
      plan.syncDevice = won?.sync_device ?? pick;
      plan.syncDeviceAt = won?.sync_device === pick ? null : (won?.sync_device_at ?? null);
    }
  }

  cache.set(auth.account, { at: now, plan });
  return plan;
}

/** True when this request's device may not sync under the plan. Only a device
 *  that counts is ever paused (see SYNC_ACTIVE and callerCounts), and only when
 *  a different device that counts holds the slot. */
export function isSyncPaused(
  plan: SyncPlan,
  device: string | undefined,
  appVersion?: string | null,
  now = Math.floor(Date.now() / 1000),
): boolean {
  if (plan.syncUntil === null || now < plan.syncUntil) return false;
  // A request that doesn't say which device it is can't be matched to a
  // version, so it can't be shown why it stopped. Leave it syncing.
  if (!device || !callerCounts(plan, device, appVersion)) return false;
  if (!plan.syncDevice || device === plan.syncDevice) return false;
  return true;
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
                AND d.device_id = ?2 AND d.revoked_at IS NULL) AS known,
            (SELECT d.last_seen_at FROM devices d WHERE d.account_id = a.account_id
                AND d.device_id = a.sync_device AND d.revoked_at IS NULL) AS kept_seen
       FROM accounts a WHERE a.account_id = ?1`,
  ).bind(auth.account, id).first<{
    sync_device: string | null;
    sync_device_at: number | null;
    known: number | null;
    kept_seen: number | null;
  }>();
  if (!row) return err(404, "not_found", "no account");
  if (!row.known) return err(404, "not_found", "unknown or removed device");
  if (row.sync_device === id) return json({ ok: true, sync_device: id });

  const now = Math.floor(Date.now() / 1000);
  // Moving off a device that is gone (removed, or not seen for a few days, like
  // an old phone after a switch to a new one) is always allowed.
  const keptQuiet = row.kept_seen === null || row.kept_seen < now - SYNC_KEPT_QUIET;
  if (
    auth.tier === "free" && !keptQuiet && row.sync_device_at !== null &&
    now - row.sync_device_at < SYNC_SWITCH_COOLDOWN
  ) {
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
const SYNC_EMAIL_SCAN = 1000;

/// One email per free account, when its free week ends and it still uses two
/// or more devices: sync now runs on one of them, how to pick which, and what
/// Pro costs. Runs from the cron, only while the rule is on, and never on an
/// account with a subscription. accounts.sync_email_at keeps it to one.
///
/// Accounts given extra time at launch have a later sync_until, so they get
/// theirs when that runs out, not on switch day.
export async function syncWeekSweep(env: Env): Promise<void> {
  // Checked before any query: self-host has no Resend key and the rule off.
  const since = syncPlanSince(env);
  if (!syncPlanOn(env) || since === null || !env.RESEND_API_KEY) return;
  const now = Math.floor(Date.now() / 1000);
  // Only accounts where a device is really paused: the kept device is settled
  // and counts, and another device that counts (new enough app, seen within
  // SYNC_ACTIVE) is in use. The SQL narrows to accounts with a kept device and
  // some other recent device that reported a version; the version check itself
  // runs here. Accounts it drops stay unstamped, so they are looked at again,
  // in case an old app updates. random() keeps them from filling the scan
  // window every run. No subscription check: an account that paid and lapsed
  // is free again and is paused like any other.
  const due = await env.DB.prepare(
    `SELECT a.account_id, a.email,
            (SELECT d.app_version FROM devices d
              WHERE d.account_id = a.account_id AND d.device_id = a.sync_device) AS kept,
            (SELECT group_concat(d.app_version, '|') FROM devices d
              WHERE d.account_id = a.account_id AND d.revoked_at IS NULL
                AND d.last_seen_at > ?3 AND d.device_id <> a.sync_device
                AND d.app_version IS NOT NULL) AS others
       FROM accounts a
      WHERE a.tier = 'free'
        AND a.email IS NOT NULL
        AND a.sync_email_at IS NULL
        AND a.sync_device IS NOT NULL
        AND COALESCE(a.sync_until, a.created_at + ?1) <= ?2
        AND a.created_at >= ?5
        AND NOT EXISTS (SELECT 1 FROM devices d
              WHERE d.account_id = a.account_id
                AND (d.created_at IS NULL OR d.created_at < ?5))
        AND EXISTS (SELECT 1 FROM devices d
              WHERE d.account_id = a.account_id AND d.device_id = a.sync_device
                AND d.revoked_at IS NULL AND d.last_seen_at > ?3)
        AND EXISTS (SELECT 1 FROM devices d
              WHERE d.account_id = a.account_id AND d.revoked_at IS NULL
                AND d.last_seen_at > ?3 AND d.device_id <> a.sync_device
                AND d.app_version IS NOT NULL)
      ORDER BY random()
      LIMIT ?4`,
  ).bind(SYNC_WEEK, now, now - SYNC_ACTIVE, SYNC_EMAIL_SCAN, since)
    .all<{ account_id: string; email: string; kept: string | null; others: string | null }>();

  const paused = (due.results ?? [])
    .filter((r) => canExplainPause(r.kept) && (r.others ?? "").split("|").some(canExplainPause))
    .slice(0, SYNC_EMAIL_BATCH);
  for (const row of paused) {
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
      "To pick which device syncs, open Relic on it and choose \"Sync this PC " +
      "instead\" (or this Mac, or this phone). You can switch once a week.\n\n" +
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
      "<p>To pick which device syncs, open Relic on it and choose \"Sync this PC " +
      "instead\" (or this Mac, or this phone). You can switch once a week.</p>" +
      "<p>Pro syncs all your devices for $7 a month or $60 a year.</p>" +
      `<p><a href="${upgrade}">Get Pro</a></p>` +
      `<p><a href="${help}">More about how sync works</a></p>` +
      "<p>Reply to this email if anything is off.</p>" +
      "<p>The Relic team</p>",
  };
}

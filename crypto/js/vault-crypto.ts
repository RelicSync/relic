// Browser port of the Relic vault crypto (app/lib/data/crypto.dart, itself a
// port of relic-core/docs/crypto.md). Wire-compatible with every client:
// Argon2id KEK → unwrap XChaCha20-Poly1305 master key → open/seal relic
// payloads and blobs. Same AADs, nonces, and ct||tag(16) layout as the apps,
// so anything sealed here decrypts on desktop/mobile and vice versa.
//
// WebCrypto speaks neither Argon2 nor XChaCha20, hence the two deps:
// hash-wasm (Argon2id, wasm inlined as base64 — nothing fetched at runtime,
// CSP-safe on the static export) and @noble/ciphers (XChaCha20-Poly1305,
// audited pure TS).

import { argon2id } from "hash-wasm";
import { xchacha20poly1305 } from "@noble/ciphers/chacha.js";

const NONCE_LEN = 24;
const KEY_LEN = 32;

const te = new TextEncoder();
const td = new TextDecoder();

export function b64decode(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function b64encode(b: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < b.length; i++) bin += String.fromCharCode(b[i]);
  return btoa(bin);
}

export interface KeyParams {
  v: number;
  salt: string; // b64
  argon2: { m_kib: number; t: number; p: number };
  mk_nonce: string; // b64
  wrapped_mk: string; // b64
  mk_fp?: string; // b64 — additive (Wave 2); older readers ignore it
}

export interface Envelope {
  v: number;
  uid: string;
  created_at: number;
  updated_at: number;
  byte_size: number;
  promoted: boolean;
  blob_key?: string;
  n: string; // b64 nonce(24)
  ct: string; // b64 ciphertext||tag(16)
}

// The decrypted private payload (worker_repo.dart _push / docs/api.md).
export interface RelicPayload {
  kind?: string;
  source?: string;
  device?: string;
  mime?: string;
  filename?: string;
  tags?: string[];
  user_tags?: string[];
  title?: string;
  note?: string;
  content?: string;
  preview?: string;
  attachments?: unknown[];
  /** Formatting flavors for a text relic: `{h, html?, rtf?}`, rtf base64,
   *  capped at 256 KiB. The vault re-seals the decrypted payload map verbatim,
   *  so this survives a web edit without any handling here. */
  rich?: { h: number; html?: string; rtf?: string };
}

/** Argon2id(passphrase, salt) → 32-byte KEK. Params come from the keyparams
 * record (the app pins m=65536 KiB, t=3, p=4, v0x13). Takes ~1-3 s in a
 * browser by design — this is the brute-force wall. */
export async function deriveKek(
  passphrase: string,
  salt: Uint8Array,
  params: { m_kib: number; t: number; p: number },
): Promise<Uint8Array> {
  return argon2id({
    password: te.encode(passphrase),
    salt,
    iterations: params.t,
    parallelism: params.p,
    memorySize: params.m_kib,
    hashLength: KEY_LEN,
    outputType: "binary",
  });
}

/** deriveKek, but in a web worker when possible so the ~3 s Argon2 wall
 * doesn't freeze the tab. Falls back to the main thread (identical output)
 * if workers are unavailable or the worker errors. */
export function deriveKekOffThread(
  passphrase: string,
  salt: Uint8Array,
  params: { m_kib: number; t: number; p: number },
): Promise<Uint8Array> {
  if (typeof Worker === "undefined") return deriveKek(passphrase, salt, params);
  return new Promise((resolve, reject) => {
    let worker: Worker;
    try {
      worker = new Worker(new URL("./vault-kek.worker.ts", import.meta.url));
    } catch {
      deriveKek(passphrase, salt, params).then(resolve, reject);
      return;
    }
    const fallback = () => {
      worker.terminate();
      deriveKek(passphrase, salt, params).then(resolve, reject);
    };
    worker.onerror = fallback;
    worker.onmessage = (e: MessageEvent) => {
      worker.terminate();
      const d = e.data as { ok: boolean; kek?: Uint8Array };
      if (d.ok && d.kek) resolve(new Uint8Array(d.kek));
      else fallback();
    };
    worker.postMessage({ passphrase, salt, params });
  });
}

/** AEAD-open. `ctWithTag` is ciphertext||tag(16) (Rust/Dart layout, which is
 * also what @noble expects). Returns null on auth failure. */
function open(
  key: Uint8Array,
  nonce: Uint8Array,
  ctWithTag: Uint8Array,
  aad: string,
): Uint8Array | null {
  if (ctWithTag.length < 16) return null;
  try {
    return xchacha20poly1305(key, nonce, te.encode(aad)).decrypt(ctWithTag);
  } catch {
    return null;
  }
}

/** Unwrap the master key from a keyparams record. Null = wrong passphrase.
 * The Argon2 step runs in a web worker when the browser allows it. */
export async function unwrapMasterKey(
  keyparams: KeyParams,
  passphrase: string,
): Promise<Uint8Array | null> {
  const kek = await deriveKekOffThread(passphrase, b64decode(keyparams.salt), keyparams.argon2);
  return open(kek, b64decode(keyparams.mk_nonce), b64decode(keyparams.wrapped_mk), "relic.mkwrap.v1");
}

/** Decrypt a relic envelope's private payload → JSON. The AAD binds the uid,
 * so an envelope can't be replayed under another id. Null on failure. */
export function openRelicPayload(mk: Uint8Array, env: Envelope): RelicPayload | null {
  const clear = open(mk, b64decode(env.n), b64decode(env.ct), `relic.relic.v1:${env.uid}`);
  if (!clear) return null;
  try {
    return JSON.parse(td.decode(clear)) as RelicPayload;
  } catch {
    return null;
  }
}

/** Decrypt a blob (wire = nonce(24) ‖ ct||tag) given its client id. */
export function openBlob(mk: Uint8Array, blobId: string, wire: Uint8Array): Uint8Array | null {
  if (wire.length < NONCE_LEN) return null;
  return open(mk, wire.subarray(0, NONCE_LEN), wire.subarray(NONCE_LEN), `relic.blob.v1:${blobId}`);
}

// ---- seal side (writing from the browser) ----------------------------------

function randomNonce(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(NONCE_LEN));
}

function seal(key: Uint8Array, nonce: Uint8Array, plaintext: Uint8Array, aad: string): Uint8Array {
  return xchacha20poly1305(key, nonce, te.encode(aad)).encrypt(plaintext);
}

/** Seal a relic payload → `{n, ct}` b64 for the envelope (fresh nonce, AAD
 * binds the uid). Mirror of RelicCrypto.sealRelicPayload. */
export function sealRelicPayload(
  mk: Uint8Array,
  uid: string,
  payload: Record<string, unknown>,
): { n: string; ct: string } {
  const nonce = randomNonce();
  const ct = seal(mk, nonce, te.encode(JSON.stringify(payload)), `relic.relic.v1:${uid}`);
  return { n: b64encode(nonce), ct: b64encode(ct) };
}

/** Encrypt a blob → wire bytes `nonce(24) ‖ ct||tag`, AAD bound to the blob
 * id. Mirror of RelicCrypto.sealBlob. */
export function sealBlob(mk: Uint8Array, blobId: string, bytes: Uint8Array): Uint8Array {
  const nonce = randomNonce();
  const ct = seal(mk, nonce, bytes, `relic.blob.v1:${blobId}`);
  const wire = new Uint8Array(nonce.length + ct.length);
  wire.set(nonce);
  wire.set(ct, nonce.length);
  return wire;
}

// ---- master-key wrapping (recovery-kit import / passphrase change) ----------

const SALT_LEN = 16;

/** Pinned Argon2id parameters for a fresh wrap. Must match the Dart app's
 * RelicCrypto (64 MiB / t=3 / p=4, v0x13) exactly. */
export const ARGON2_DEFAULTS = { m_kib: 64 * 1024, t: 3, p: 4 } as const;

async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  const d = await crypto.subtle.digest("SHA-256", bytes);
  return new Uint8Array(d);
}

/** Short, non-secret fingerprint of a master key: the first 8 bytes of
 * SHA-256('relic.mkfp.v1' ‖ mk). Mirror of RelicCrypto.mkFingerprint — lets a
 * caller confirm an MK opens *this* account's vault without revealing it. */
export async function mkFingerprint(mk: Uint8Array): Promise<Uint8Array> {
  const prefix = te.encode("relic.mkfp.v1");
  const buf = new Uint8Array(prefix.length + mk.length);
  buf.set(prefix);
  buf.set(mk, prefix.length);
  return (await sha256(buf)).subarray(0, 8);
}

/** How the Argon2 KEK is derived when re-wrapping. Injectable so a test can pin
 * a fixed KEK instead of paying the ~3 s Argon2 cost. */
export type KekDeriver = (
  passphrase: string,
  salt: Uint8Array,
  params: { m_kib: number; t: number; p: number },
) => Promise<Uint8Array>;

/** Re-wrap an existing master key under a new passphrase → a fresh keyparams
 * record (new salt + nonce, AAD `relic.mkwrap.v1`, additive `mk_fp`). Byte-for-
 * byte mirror of RelicCrypto.rewrapKeyParams; the caller PUTs it with
 * ?replace=1. The MK is unchanged, so existing ciphertext and the recovery kit
 * both stay valid. */
export async function rewrapKeyParams(
  mk: Uint8Array,
  newPassphrase: string,
  deriveKekFn: KekDeriver = deriveKekOffThread,
): Promise<KeyParams> {
  const salt = crypto.getRandomValues(new Uint8Array(SALT_LEN));
  const kek = await deriveKekFn(newPassphrase, salt, ARGON2_DEFAULTS);
  const nonce = randomNonce();
  const wrapped = seal(kek, nonce, mk, "relic.mkwrap.v1");
  return {
    v: 1,
    salt: b64encode(salt),
    argon2: { m_kib: ARGON2_DEFAULTS.m_kib, t: ARGON2_DEFAULTS.t, p: ARGON2_DEFAULTS.p },
    mk_nonce: b64encode(nonce),
    wrapped_mk: b64encode(wrapped),
    mk_fp: b64encode(await mkFingerprint(mk)),
  };
}

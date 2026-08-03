// Browser port of the Relic recovery-kit codec (app/lib/data/recovery.dart).
// Parses a `relic-mk-v1` kit — Crockford base32, 14 groups of 4, the last group
// a 2-byte SHA-256 checksum over the key bytes only — back to the 32-byte master
// key. Human-tolerant exactly as the Dart decoder: it ignores spaces / hyphens /
// line breaks, accepts lower case, and folds the look-alikes I/L -> 1 and O -> 0
// (U stays invalid, so it can never be confused with V).

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

function foldSymbol(ch: string): string {
  if (ch === "I" || ch === "L") return "1";
  if (ch === "O") return "0";
  return ch;
}

/** Crockford base32 decode → bytes. Throws on any symbol outside the alphabet
 * (after folding). Trailing sub-byte bits are dropped, mirroring the encoder. */
export function crockfordDecode(s: string): Uint8Array {
  const out: number[] = [];
  let buffer = 0;
  let bits = 0;
  for (const rune of s.toUpperCase()) {
    if (rune === " " || rune === "-" || rune === "\n" || rune === "\r" || rune === "\t") continue;
    const val = ALPHABET.indexOf(foldSymbol(rune));
    if (val < 0) throw new Error(`invalid base32 symbol: ${rune}`);
    buffer = (buffer << 5) | val;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xff);
      buffer &= (1 << bits) - 1;
    }
  }
  return new Uint8Array(out);
}

export type RecoveryKitErrorKind = "format" | "checksum";

/** Why parseRecoveryKit failed. `format` = not a Relic kit (the `relic-mk-v1`
 * tag is missing) — show "that doesn't look like a recovery kit". `checksum` =
 * it IS a kit but the key bytes don't add up (a mistype or dropped char) — show
 * "this kit looks mistyped, check it again". Mirrors RecoveryKitError (Dart). */
export class RecoveryKitError extends Error {
  kind: RecoveryKitErrorKind;
  constructor(kind: RecoveryKitErrorKind) {
    super(`recovery kit ${kind}`);
    this.name = "RecoveryKitError";
    this.kind = kind;
  }
}

async function checksumBytes(mk: Uint8Array): Promise<Uint8Array> {
  const d = await crypto.subtle.digest("SHA-256", mk);
  return new Uint8Array(d).subarray(0, 2);
}

/** Parse kit text back to the master key (+ the email it carried). Throws a
 * RecoveryKitError('format') when the `relic-mk-v1` tag is absent, or
 * ('checksum') when the key body is the wrong length, undecodable, or fails the
 * checksum. Byte-for-byte mirror of RecoveryKit.parse. */
export async function parseRecoveryKit(text: string): Promise<{ mk: Uint8Array; email: string }> {
  const raw = text.trim();
  if (!raw.toLowerCase().includes("relic-mk-v1")) {
    throw new RecoveryKitError("format");
  }

  const emailMatch = /email:\s*(\S+)/i.exec(raw);
  const email = emailMatch?.[1] ?? "";

  // Strip the tag and the whole email line, then keep only base32 symbols.
  const body = raw.replace(/relic-mk-v1/gi, " ").replace(/email:\s*\S+/gi, " ");
  const filtered = body.replace(/[^0-9A-Za-z]/g, "").toUpperCase();
  if (filtered.length !== 56) throw new RecoveryKitError("checksum");

  let mk: Uint8Array;
  let ck: Uint8Array;
  try {
    mk = crockfordDecode(filtered.slice(0, 52));
    ck = crockfordDecode(filtered.slice(52));
  } catch {
    throw new RecoveryKitError("checksum");
  }
  if (mk.length !== 32 || ck.length < 2) throw new RecoveryKitError("checksum");

  const expect = await checksumBytes(mk);
  if (ck[0] !== expect[0] || ck[1] !== expect[1]) throw new RecoveryKitError("checksum");
  return { mk, email };
}

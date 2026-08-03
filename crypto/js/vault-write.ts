// Write path for the web vault: build payloads/envelopes the same way the
// apps do (worker_repo.dart captureText/captureImage/captureFile/updateMeta),
// seal them with vault-crypto, and push through vault-api. Edits re-seal the
// ORIGINAL decrypted payload map with fields changed, so payload fields this
// client doesn't know about (attachments, future keys) survive a web edit.

import { type Envelope, sealBlob, sealRelicPayload } from "./vault-crypto";
import { WriteRejected, deleteRelic, putEnvelope, uploadBlobWire } from "./vault-api";

export { WriteRejected };

export interface VaultItem {
  uid: string;
  createdAt: number;
  updatedAt: number;
  byteSize: number;
  promoted: boolean;
  blobKey?: string;
  p: Record<string, unknown>; // decrypted payload, verbatim
}

const now = () => Math.floor(Date.now() / 1000);
const utf8len = (s: string) => new TextEncoder().encode(s).length;

/** First line, capped at 100 chars — mirror of the apps' _previewLine. */
export function previewLine(s: string): string {
  const line = s.trim().split("\n")[0] ?? "";
  return line.length > 100 ? `${line.slice(0, 100)}…` : line;
}

// Mini port of file_types.dart fileTypeChips — the common cases, so files
// added from the web get the same friendly search chips.
const FILE_TYPES: Record<string, [string, string]> = {
  pdf: ["document", "pdf"], doc: ["document", "word"], docx: ["document", "word"],
  odt: ["document", "word"], rtf: ["document", "word"], txt: ["document", "text"],
  md: ["document", "markdown"], xls: ["spreadsheet", "excel"], xlsx: ["spreadsheet", "excel"],
  csv: ["spreadsheet", "csv"], ods: ["spreadsheet", "excel"], ppt: ["presentation", "powerpoint"],
  pptx: ["presentation", "powerpoint"], png: ["image", "png"], jpg: ["image", "jpeg"],
  jpeg: ["image", "jpeg"], gif: ["image", "gif"], webp: ["image", "webp"], svg: ["image", "svg"],
  heic: ["image", "heic"], mp4: ["video", "mp4"], mov: ["video", "mov"], mkv: ["video", "mkv"],
  webm: ["video", "webm"], mp3: ["audio", "mp3"], wav: ["audio", "wav"], flac: ["audio", "flac"],
  m4a: ["audio", "m4a"], zip: ["archive", "zip"], rar: ["archive", "rar"], "7z": ["archive", "7z"],
  tar: ["archive", "tar"], gz: ["archive", "gzip"], json: ["code", "json"], js: ["code", "javascript"],
  ts: ["code", "typescript"], py: ["code", "python"], dart: ["code", "dart"], rs: ["code", "rust"],
  html: ["code", "html"], css: ["code", "css"], exe: ["app", "windows"], apk: ["app", "android"],
  dmg: ["app", "mac"],
};

export function fileTypeChips(filename?: string): string[] {
  const ext = filename?.split(".").pop()?.toLowerCase();
  const ft = ext ? FILE_TYPES[ext] : undefined;
  if (!ft) return [];
  return ft[0] === ft[1] ? [ft[0]] : ft;
}

const URL_RE = /^https?:\/\/\S+$/i;

function makeEnvelope(mk: Uint8Array, item: VaultItem): Envelope {
  const sealed = sealRelicPayload(mk, item.uid, item.p);
  return {
    v: 1,
    uid: item.uid,
    created_at: item.createdAt,
    updated_at: item.updatedAt,
    byte_size: item.byteSize,
    promoted: item.promoted,
    ...(item.blobKey ? { blob_key: item.blobKey } : {}),
    n: sealed.n,
    ct: sealed.ct,
  };
}

/** Deliberate captures are born promoted, like the apps (SPEC §1). */
export async function addText(token: string, mk: Uint8Array, text: string): Promise<VaultItem> {
  const t = text.trim();
  const ts = now();
  const item: VaultItem = {
    uid: crypto.randomUUID(),
    createdAt: ts,
    updatedAt: ts,
    byteSize: utf8len(t),
    promoted: true,
    p: {
      kind: "string",
      source: "api",
      device: "Web",
      tags: URL_RE.test(t) ? ["url"] : [],
      user_tags: [],
      content: t,
      preview: previewLine(t),
    },
  };
  await putEnvelope(token, makeEnvelope(mk, item));
  return item;
}

/** Add a file or image: seal + upload the blob first (the cap check), then
 * the envelope. Images become kind "photo" like the apps' captureImage. */
export async function addFile(
  token: string,
  mk: Uint8Array,
  file: { name: string; type: string; bytes: Uint8Array },
  onProgress?: (fraction: number) => void,
): Promise<VaultItem> {
  const ts = now();
  const isImage = file.type.startsWith("image/");
  const blobKey = crypto.randomUUID();
  const name = file.name || (isImage ? "Pasted image.png" : "file");
  await uploadBlobWire(token, blobKey, sealBlob(mk, blobKey, file.bytes), onProgress);
  const item: VaultItem = {
    uid: crypto.randomUUID(),
    createdAt: ts,
    updatedAt: ts,
    byteSize: file.bytes.length,
    promoted: true,
    blobKey,
    p: {
      kind: isImage ? "photo" : "file",
      source: "upload",
      device: "Web",
      mime: file.type || undefined,
      filename: name,
      tags: fileTypeChips(name),
      user_tags: [],
      title: name,
      preview: name,
    },
  };
  await putEnvelope(token, makeEnvelope(mk, item));
  return item;
}

/** Mirror of updateMeta: body edits only for non-secret text items; empty
 * content means unchanged; byte_size follows content on blob-less items. */
export async function saveEdit(
  token: string,
  mk: Uint8Array,
  item: VaultItem,
  edits: { title?: string; note?: string; userTags?: string[]; content?: string },
): Promise<VaultItem> {
  const tags = (item.p.tags as string[] | undefined) ?? [];
  const isSecret = tags.includes("secret");
  const newContent =
    isSecret || !edits.content || !edits.content.trim() ? null : edits.content;
  const p = { ...item.p };
  if (edits.title !== undefined) {
    if (edits.title.trim()) p.title = edits.title.trim();
    else delete p.title;
  }
  if (edits.note !== undefined) {
    if (edits.note.trim()) p.note = edits.note.trim();
    else delete p.note;
  }
  if (edits.userTags !== undefined) p.user_tags = edits.userTags;
  if (newContent !== null) {
    p.content = newContent;
    p.preview = previewLine(newContent);
  }
  const updated: VaultItem = {
    ...item,
    p,
    byteSize:
      newContent !== null && !item.blobKey ? utf8len(newContent) : item.byteSize,
    updatedAt: now(),
  };
  await putEnvelope(token, makeEnvelope(mk, updated));
  return updated;
}

/** Keep/unkeep (the apps' promote). 402 = vault cap on the free tier. */
export async function setKept(
  token: string,
  mk: Uint8Array,
  item: VaultItem,
  promoted: boolean,
): Promise<VaultItem> {
  const updated: VaultItem = { ...item, promoted, updatedAt: now() };
  await putEnvelope(token, makeEnvelope(mk, updated));
  return updated;
}

export async function removeItem(token: string, uid: string): Promise<void> {
  await deleteRelic(token, uid);
}

// Client-side search for the web vault — a browser port of the desktop's
// fused ranking (local_desk_repo.dart): lexical + trigram (typo/substring)
// + tag + tag-intent legs fused with weighted Reciprocal Rank Fusion, plus a
// low-weight recency leg so two similar hits break toward the newer one. The
// desktop's semantic-vector leg needs the on-device ML sidecar and stays
// desktop-only.
//
// Query syntax (same spirit as the apps):
//   plain words        any-field match, typo-tolerant
//   "exact phrase"     must appear verbatim
//   -word              exclude items matching it
//   tag:foo            item must carry the tag
//   kind:text|image|file   filter by kind
//   is:kept            only vault-kept items
//   has:file           only items with an attached blob
//   before:/after:YYYY-MM-DD   date bounds

import { tagIntentOf } from "./vault-tag-intents";

export interface Searchable {
  uid: string;
  createdAt: number; // epoch seconds
  promoted: boolean;
  kind: string; // string | photo | file | other
  hasBlob: boolean;
  title?: string;
  content?: string;
  preview?: string;
  note?: string;
  filename?: string;
  device?: string;
  tags: string[];
  userTags: string[];
}

interface Parsed {
  terms: string[];
  phrases: string[];
  negations: string[];
  tagFilters: string[];
  kindFilter: string | null;
  keptOnly: boolean;
  blobOnly: boolean;
  before: number | null; // epoch seconds
  after: number | null;
}

const KIND_ALIASES: Record<string, string> = {
  text: "string",
  string: "string",
  image: "photo",
  photo: "photo",
  img: "photo",
  file: "file",
  files: "file",
  other: "other",
};

function parseDate(s: string): number | null {
  const t = Date.parse(s);
  return Number.isFinite(t) ? Math.floor(t / 1000) : null;
}

export function parseQuery(raw: string): Parsed {
  const p: Parsed = {
    terms: [], phrases: [], negations: [], tagFilters: [],
    kindFilter: null, keptOnly: false, blobOnly: false, before: null, after: null,
  };
  // pull "quoted phrases" out first
  const rest = raw.replace(/"([^"]+)"/g, (_, ph: string) => {
    p.phrases.push(ph.toLowerCase());
    return " ";
  });
  for (const tok of rest.toLowerCase().split(/\s+/).filter(Boolean)) {
    if (tok.startsWith("tag:") && tok.length > 4) p.tagFilters.push(tok.slice(4));
    else if (tok.startsWith("kind:")) p.kindFilter = KIND_ALIASES[tok.slice(5)] ?? tok.slice(5);
    else if (tok === "is:kept" || tok === "is:vault") p.keptOnly = true;
    else if (tok === "has:file" || tok === "has:image" || tok === "has:blob") p.blobOnly = true;
    else if (tok.startsWith("before:")) p.before = parseDate(tok.slice(7));
    else if (tok.startsWith("after:")) p.after = parseDate(tok.slice(6));
    else if (tok.startsWith("-") && tok.length > 1) p.negations.push(tok.slice(1));
    else p.terms.push(tok);
  }
  return p;
}

// ---- lexical leg -------------------------------------------------------------

// Field weights: title/user tags lead, body text trails — same instinct as
// the desktop FTS column weighting.
const FIELDS: { get: (s: Searchable) => string | undefined; w: number }[] = [
  { get: (s) => s.title, w: 3.0 },
  { get: (s) => s.userTags.join(" "), w: 2.6 },
  { get: (s) => s.filename, w: 2.4 },
  { get: (s) => s.tags.join(" "), w: 2.0 },
  { get: (s) => s.note, w: 1.6 },
  { get: (s) => s.content, w: 1.0 },
  { get: (s) => s.preview, w: 0.8 },
  { get: (s) => s.device, w: 0.5 },
];

function lexicalScore(s: Searchable, terms: string[]): number {
  let total = 0;
  let matched = 0;
  for (const term of terms) {
    let best = 0;
    for (const f of FIELDS) {
      const hay = f.get(s)?.toLowerCase();
      if (!hay) continue;
      let hit = 0;
      const idx = hay.indexOf(term);
      if (idx >= 0) {
        const atWordStart = idx === 0 || !/[a-z0-9]/.test(hay[idx - 1]);
        const atWordEnd = idx + term.length >= hay.length || !/[a-z0-9]/.test(hay[idx + term.length]);
        hit = atWordStart && atWordEnd ? 1 : atWordStart ? 0.75 : 0.45; // word > prefix > substring
      }
      if (hit * f.w > best) best = hit * f.w;
    }
    if (best > 0) matched++;
    total += best;
  }
  if (matched === 0) return 0;
  // all-terms bonus — an item hitting every word should beat scattered hits
  return matched === terms.length ? total * 1.5 : total * (matched / terms.length);
}

// ---- trigram leg (typo/substring recall) --------------------------------------

function trigrams(s: string): Set<string> {
  const out = new Set<string>();
  const t = `  ${s.toLowerCase()} `;
  for (let i = 0; i < t.length - 2; i++) out.add(t.slice(i, i + 3));
  return out;
}

function triSimilarity(query: Set<string>, hay: Set<string>): number {
  if (query.size === 0 || hay.size === 0) return 0;
  let inter = 0;
  for (const g of query) if (hay.has(g)) inter++;
  return inter / query.size; // containment, not jaccard — the item text is long
}

// ---- RRF fusion ----------------------------------------------------------------

// Mirrors the desktop constants: lexical 2.0, trigram 1.0, tag 0.4,
// tag-intent 2.0, recency 0.5, k=60 (semantic leg omitted — desktop-only ML).
const W_LEX = 2.0;
const W_TRI = 1.0;
const W_TAG = 0.4;
const W_TAG_INTENT = 2.0;
const W_RECENCY = 0.5;
// Kept items win NEAR-TIES against clipboard noise. A multiplier, not a leg:
// rank-adjacent items sit ~1.5% apart in RRF space while a clear relevance
// win leads by 10%+, so an exclusive extra leg would jump kept items over
// clearly better matches; a 5% factor flips near-ties and nothing else.
const KEPT_BOOST = 1.05;
const RRF_K = 60;
const TRI_POOL = 50;
const TRI_POOL_WITH_LEX = 15;
const TRI_FLOOR = 0.45;

function rrf(lists: string[][], weights: number[], boost?: Set<string>): string[] {
  const score = new Map<string, number>();
  lists.forEach((list, l) => {
    list.forEach((uid, rank) => {
      score.set(uid, (score.get(uid) ?? 0) + weights[l] / (RRF_K + rank + 1));
    });
  });
  if (boost) {
    for (const uid of boost) {
      const s = score.get(uid);
      if (s !== undefined) score.set(uid, s * KEPT_BOOST);
    }
  }
  return [...score.entries()].sort((a, b) => b[1] - a[1]).map(([uid]) => uid);
}

function passesFilters(s: Searchable, p: Parsed): boolean {
  if (p.kindFilter && s.kind !== p.kindFilter) return false;
  if (p.keptOnly && !s.promoted) return false;
  if (p.blobOnly && !s.hasBlob) return false;
  if (p.before !== null && s.createdAt > p.before) return false;
  if (p.after !== null && s.createdAt < p.after) return false;
  for (const t of p.tagFilters) {
    if (!s.tags.includes(t) && !s.userTags.includes(t)) return false;
  }
  if (p.negations.length) {
    const hay = allText(s);
    for (const n of p.negations) if (hay.includes(n)) return false;
  }
  return true;
}

function allText(s: Searchable): string {
  return [s.title, s.content, s.preview, s.note, s.filename, ...s.tags, ...s.userTags]
    .filter(Boolean)
    .join("\n")
    .toLowerCase();
}

/** Rank `items` for `raw`. Empty/filter-only queries return newest-first
 * (after filters). Result = uids in rank order. */
export function searchVault(items: Searchable[], raw: string): string[] {
  const p = parseQuery(raw);
  const pool = items.filter((s) => passesFilters(s, p));
  const newestFirst = [...pool].sort((a, b) => b.createdAt - a.createdAt);

  const needles = [...p.terms, ...p.phrases];
  if (needles.length === 0) return newestFirst.map((s) => s.uid);

  // phrases are hard requirements
  const candidates = p.phrases.length
    ? pool.filter((s) => p.phrases.every((ph) => allText(s).includes(ph)))
    : pool;

  // lexical leg
  const lex = candidates
    .map((s) => ({ uid: s.uid, score: lexicalScore(s, needles) }))
    .filter((x) => x.score > 0)
    .sort((a, b) => b.score - a.score)
    .map((x) => x.uid);

  // trigram leg — kept tight when the literal query already hits
  const qGrams = trigrams(needles.join(" "));
  const tri = candidates
    .map((s) => ({ uid: s.uid, score: triSimilarity(qGrams, trigrams(allText(s).slice(0, 2000))) }))
    .filter((x) => x.score >= TRI_FLOOR)
    .sort((a, b) => b.score - a.score)
    .slice(0, lex.length ? TRI_POOL_WITH_LEX : TRI_POOL)
    .map((x) => x.uid);

  // tag leg — query words that ARE tags
  const tag = candidates
    .filter((s) => p.terms.some((t) => s.tags.includes(t) || s.userTags.includes(t)))
    .map((s) => s.uid);

  // tag-intent leg — a term that NAMES a tag ("link" -> url) means the user
  // wants items that ARE that type, filtered by the residual terms; for an
  // actual link the word "link" never appears literally, so the lexical leg
  // alone ranks it below any long text that merely says "link". Mirrors the
  // desktop tagIntentCandidates: max 2 fired tags, a residual that matches
  // nothing inside the tag set contributes nothing (no bare tag dump), no
  // residual lists the tag's items newest-first. Quoted queries mean literal
  // text and skip the leg.
  let tagIntent: string[] = [];
  if (p.phrases.length === 0) {
    const fired: string[] = [];
    const residual: string[] = [];
    for (const t of p.terms) {
      const named = tagIntentOf(t);
      if (named && !fired.includes(named) && fired.length < 2) fired.push(named);
      else if (!named) residual.push(t);
    }
    if (fired.length) {
      const inTag = candidates.filter((s) =>
        fired.some((t) => s.tags.includes(t) || s.userTags.includes(t)));
      tagIntent = residual.length
        ? inTag
            .map((s) => ({ uid: s.uid, score: lexicalScore(s, residual) }))
            .filter((x) => x.score > 0)
            .sort((a, b) => b.score - a.score)
            .slice(0, 50)
            .map((x) => x.uid)
        : [...inTag].sort((a, b) => b.createdAt - a.createdAt).slice(0, 50).map((s) => s.uid);
    }
  }

  // recency leg over the candidate union
  const inAny = new Set([...lex, ...tri, ...tag, ...tagIntent]);
  const recency = newestFirst.filter((s) => inAny.has(s.uid)).map((s) => s.uid);
  const kept = new Set(pool.filter((s) => s.promoted).map((s) => s.uid));

  return rrf(
    [lex, tri, tag, tagIntent, recency],
    [W_LEX, W_TRI, W_TAG, W_TAG_INTENT, W_RECENCY],
    kept,
  );
}

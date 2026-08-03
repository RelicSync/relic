# relic-sift

Relic's classification pipeline (spec: [`relic-sift-classification-pipeline-spec.md`](relic-sift-classification-pipeline-spec.md)),
implemented as a standalone Rust crate + `sift` CLI. Three-stage cascade:

- **Stage A — deterministic** (no ML): gitleaks-seeded secret rules + Shannon
  entropy, structural regex (URL/email/phone/IP/UUID/card/color/path), format
  heuristics (JSON/YAML/XML/CSV/INI shape, log timestamps, stack traces, code
  density), magic-byte file routing, EXIF/dimension image priors.
- **Stage B — small local ONNX models**: bge-small-en-v1.5 (int8) sentence
  embeddings + a nearest-centroid head built from `taxonomy.json` prototypes;
  CLIP ViT-B/32 (int8) zero-shot image classification with prompts straight
  from the taxonomy; ocrs OCR feeder whose text re-enters the text path (a
  screenshot of an API key is still caught as `api_key`).
- **Stage C — fusion**: noisy-OR vote combination, deterministic rules win
  outright at ≥0.95, model-overrides-weak-prior with a clear-margin guard,
  per-category confidence thresholds, escalation to `unsorted` +
  `needs_review`.
- **Labeling (opt-in) — Qwen3.5-0.8B** (`--label`): a small local multimodal
  model that gives an item a human-readable **title** and free-form topical
  **tags**, for text *and* images. This is the open-vocabulary layer the closed
  taxonomy structurally cannot provide. Off by default and ~0.7 s/item on CPU —
  meant for an async pass off the capture path. See "Labeling" below.

Local-only: nothing leaves the device on the classification path. Network is
touched exclusively by `sift models download` (and the first-run auto-download).

## Zero-setup install

```powershell
# from the repo root
powershell -ExecutionPolicy Bypass -File scripts\install-sift.ps1

# or by hand:
cargo install --path relic-sift --locked
sift classify --text "hello"      # first run auto-downloads models (~750 MB core set)
sift doctor                       # verify everything
```

Models land in `%LOCALAPPDATA%\relic-sift\models` (override with
`RELIC_SIFT_HOME`). Everything downloaded is MIT/permissively licensed and
redistributable (spec §15): ONNX Runtime 1.24.2, bge-small-en-v1.5 int8,
CLIP ViT-B/32 int8, ocrs detection+recognition. Without models (`--offline`
/ `--no-ml`) the pipeline degrades gracefully to Stage A.

## CLI

```
sift classify <paths…> [--text S] [--stdin] [--serve] [--kind auto|string|image|file]
              [--offline] [--no-ml] [--compact] [--vectors]
              [--label]
sift label <paths…> [--text S] [--stdin] [--offline] [--raw] [--compact]
sift tags bound [--threshold 0.85] [--min-count 2] [--reconcile]   # stdin JSON
sift models download [--label] | status | path
sift models prune [--deep] [--dry-run] [--json]
sift --speed gentle|balanced|fast <any subcommand>   # CPU budget, default balanced
sift eval <manifest.json> [--report out.md] [--json out.json] [--limit N]
sift doctor
sift taxonomy
sift rules [init | test --text "…"]   # user-defined global tagging rules
```

`models prune` deletes files from model generations we no longer ship, so an
upgrade doesn't leave them in the cache forever — Florence-2's ~246 MB, plus the
`dml/` DirectML runtime if that install ever enabled it. It is idempotent and the
retired set is an explicit list, never "anything the registry doesn't name": the
model dir also holds `taxonomy.json`, the prompt/head caches and the runtime
DLLs. `--deep` additionally drops fallbacks this install can't reach (CLIP behind
MobileCLIP2, BGE behind Gemma, the text tower with no user taxonomy) for ~691 MB
total, but each is re-downloaded on demand if the primary ever goes missing, so
it stays opt-in. Relic runs the safe sweep itself, once per upgrade.

`--speed` sets the CPU budget for every on-device pass. Labeling costs roughly
7.5 core-seconds per item, which is background noise on a 16-thread desktop and
most of a 4-thread laptop, so the thread count scales with the host instead of
sitting at a fixed 6 — six threads contending for four cores is *slower* than
asking for two. Everything but `fast` also drops the process to below-normal
priority, so a long backlog can't make the machine feel stalled.

Measured over 8 text items on a 16-thread desktop, two runs each: wall time is
the same within noise across all three (12–16 s), while CPU burned is cleanly
ordered — gentle ~41 s, balanced ~52 s, fast ~65 s. These q4f16 graphs are
memory-bandwidth-bound, so past a point extra threads buy CPU, not speed. On a
machine with 8+ cores `balanced` resolves to exactly the 6 threads used before
the flag existed, so nothing regresses. `SIFT_THREADS` overrides the count
outright, which is what the Python parity harness pins.

`classify` prints one `ClassificationRecord` (spec §9) per item: primary
category + full score vector + confidence, multi-label flags (`pii_present`),
`relic_tags` (what the app writes into `Relic.tags` — see
[`docs/sift-integration.md`](../docs/sift-integration.md)), masked entities,
extracted/OCR text (secrets masked), embedding refs, full provenance, and
per-stage timings.

## Library

```rust
use relic_sift::{Sift, SiftConfig, NormalizedItem, SourceKind, Origin};

let mut sift = Sift::new(SiftConfig::default()); // loads whatever models exist
let record = sift.classify(&NormalizedItem {
    bytes: b"AKIAIOSFODNN7EXAMPLE".to_vec(),
    source_kind: SourceKind::String,
    declared_mime: None,
    origin: Origin::default(),
});
assert_eq!(record.category.primary, "api_key");
```

`Sift` is stateless w.r.t. storage and synchronous (spec §10); the relic-app
watcher will call it directly at M6+.

## Taxonomy & tags (v1.2)

Categories are data, not code: `taxonomy.json` (embedded; overridable by
dropping a copy in the model dir). Each entry carries its modality, confidence
threshold, `relic_tags` mapping, CLIP prompts, and head prototypes. Adding an
image category = adding prompt strings; adding a text category = adding a few
example prototypes (the centroid head rebuilds automatically — the cache is
fingerprinted on prototype content).

v1.2 granularity, all flowing into `Relic.tags` (full map:
[`docs/sift-integration.md`](../docs/sift-integration.md)):

- categories: `tracking_number`, `otp_code`, `address`, `todo_list` (on top
  of the seed set)
- structural tags: `yaml`/`xml`/`csv`/`toml`/`ini`, `uuid`, `version`,
  `date`, `geo`, `crypto`, `iban`, `tracking`, `otp` — with guards so public
  identifiers (UUIDs, crypto addresses, IBANs) never false-positive as
  `secret`
- code language tags: `python` `rust` `javascript` `go` `java` `sql` `shell`
  `powershell` `cpp`
- CLIP image content tags (multi-label, same forward pass): `people`
  `animal` `food` `nature` `city` `vehicle` `whiteboard` `qrcode` `chart`
- screenshot content tags from OCR (a chat screenshot is `screenshot`+`chat`)
- user-defined global rules (`sift rules init`): regex → tags (+ optional
  capped category vote) applied to every text the pipeline sees; one-off
  per-item tags remain the app's `user_tags`, which sift never touches

## Labeling (opt-in, open-vocabulary)

`sift classify --label` (or the standalone `sift label`) runs **Qwen3.5-0.8B**
(Apache-2.0) locally to produce, for text and images alike:

```json
{"title": "Kessler Roofing quote", "tags": ["roofing", "quote", "construction"]}
```

The title lands on `caption` (and, for images, is folded into the searchable
`extracted_text`); the tags join the content-tag stream and end up in
`relic_tags`. **This is the point of the model**: no classifier can emit a
string that isn't already in `taxonomy.json`, and 74.3% of a real vault carries
no subject tag at all — see [`docs/phase0-vault-eval-2026-07.md`](../docs/phase0-vault-eval-2026-07.md).

It replaced Florence-2, which only captioned images, had no title or tag
channel, and cost ~9 s/image.

**Architecture (the state plumbing is the whole trick).** 24 layers with
`full_attention_interval: 4` → 18 Gated-DeltaNet `linear_attention` layers +
6 `full_attention` at indices 3, 7, 11, 15, 19, 23. The graph names state by
**layer index**, not a dense counter. Linear layers carry a **fixed-size**
state (`past_conv` (B, 6144, 4) + `past_recurrent` (B, 16, 128, 128)), so
prefill passes real zeros at full size — not the zero-length tensor a KV cache
starts from. Only the 6 attention layers get a growing KV pair. `position_ids`
is **(3, B, S)** mRoPE; with an image in the prompt, position and token count
stop being the same number. State is f16, `inputs_embeds` is f32.

**Speed.** Two things make it fast enough to be practical:

- **Prefix priming.** The few-shot system prompt is ~390 tokens and an item is
  ~40, so the prefix is prefilled *once* and the state snapshot cloned per
  item. This works cleanly only because DeltaNet's per-layer state is
  fixed-size: the snapshot is a constant ~10 MB no matter how long the prefix
  is. Guarded by a retokenization check — BPE merging across the prefix/body
  seam would resume the model from a state that doesn't match its input, so a
  dirty seam disables priming rather than risking it.
- **Chunked prefill.** The export emits logits for every position at a vocab of
  248320, so priming 390 tokens in one call would allocate ~192 MB purely to
  discard it. At chunk 64 that transient is ~32 MB, for identical output.

Measured in-process: **~0.8 s/item** (22 clips, release build, 6 threads) —
matching the Python reference. Loading the model and priming costs ~4.4 s on
top of the rest of the pipeline, which is why anything labeling more than one
item should use `classify --serve`: same 22 items take **~128 s across 22
processes but ~23 s through one**. Serve reads one JSON request per stdin line
and writes one record per line:

```
{"kind":"string","text":"…","label":true}
{"kind":"image","path":"/…/shot.png"}
```

`label` is per-request on purpose. Whether an item earns a generated title is
the caller's decision (a vault note yes, an ephemeral clipboard line no), and
making it a process flag would force a respawn — throwing away exactly the
model load resident mode exists to amortize. A request that fails answers with
`{"error": …}` instead of killing the server, so one unreadable file can't end
an enrichment pass.

**Parity.** Greedy decode is deterministic, so the Rust port must reproduce the
Python reference (`relic-sift-next/harness/qwen35.py`) *exactly*, and
`harness/compare_rust.py` checks it: **22/22 byte-identical completions**,
across different ONNX Runtimes (1.24.2 vs 1.27.0). The image patchify is pinned
to reference bytes by a unit test; image *captions* agree on 19/20 corpus
images, the one difference coming from PIL BICUBIC vs the `image` crate's
CatmullRom, which are the same filter family but not bit-identical.

Model: three q4f16 ONNX components (decoder, token embeddings, vision tower)
plus tokenizer, ~666 MB, fetched on first `--label` use (it is **not** part of
the default `sift models download`; add `--label` to fetch it). Never on the
capture hot path.

Safety: the title is generated text, so it is secret-masked exactly like OCR
text, and the whole pass is **skipped on any item already flagged
`secret`/`pii_present`** — for text as well as images. The image prompt
forbids describing a person's identity or appearance.

### Bounding the tag vocabulary

Open vocabulary means unbounded vocabulary, and measured on a real vault that
was the problem: **193 items produced 550 emissions over 327 distinct tags, 65%
used exactly once.** Coverage was perfect and the result was useless as a facet
— a facet you see once is not a facet. So the labeler's tags ship on their own
record field (`label_tags`, never mixed into the curated `relic_tags`) and a
consumer bounds them with `sift tags bound`:

1. **Snap** near-duplicates onto one representative by EmbeddingGemma cosine, so
   `deployment`/`deploy`/`deployments` are one facet. This is what makes "bound
   it to tags we already have" work without a hand-maintained list — and a
   whitelist genuinely doesn't work here: only **8%** of what the model invents
   maps onto the existing machine vocabulary at 0.85, so a whitelist would throw
   away 92% of the signal.
2. **Recurrence**: a representative becomes a visible facet only on its second
   sighting. Before that it is *provisional* — still written to the item so
   full-text search finds it, just not rendered as a chip.

| cosine | ≥2 vocab | coverage | example merges                       |
|--------|----------|----------|--------------------------------------|
| 0.85   | 119      | 94%      | development←dev,developer,programming |
| 0.80   | 110      | 96%      | development←**project**,dev,developer |
| 0.75   | 101      | 98%      | python←**development,script,ai**      |

0.80 buys 2% coverage by folding `project` into `development`; 0.75 is plainly
wrong. 0.85 is the last threshold whose merges are all synonyms.

The command is **stateless** — the vocabulary goes in, the update comes back,
and the caller's store stays the source of truth (spec §9.1). Ordering is
frequency-first so the corpus's own dominant wording becomes canonical rather
than whichever string arrived first; since online absorption can't do that,
`--reconcile` re-derives the whole grouping periodically. **Reconcile must be
given every distinct emitted string, aliases included** — handed only the
current representatives it is a no-op by construction, because a representative
exists precisely because nothing was within threshold of it.

Verified against the batch prototype in `relic-sift-next/harness/`: one-shot
reproduces it exactly (119 facets, 94% coverage), the same emissions fed in
25-item chunks drift to 121, and reconcile pulls it back to 119 and is a fixed
point.

## Evaluation

A 65-item labeled dev corpus plus a 17-item held-out golden set live in
`corpus/` (generated by `corpus/make_corpus.py` / `make_holdout.py` — text,
documents, real screenshots, downloaded photos, rendered receipts/scans/
diagrams/memes, and adversarial cases). Current results — dev: 100% primary
accuracy, macro-F1 1.000, secret recall 100%; held-out (untuned): 100%, with
the caveats documented in [`eval/README.md`](eval/README.md).

## Known v0.1 limits

- OCR is ocrs (pure Rust); great on rendered text, weaker on camera photos.
  RapidOCR remains the documented upgrade path (spec §8). Large images run
  0.5–2 s; the spec's <400 ms image target needs the tiny-OCR profile.
- Labeling (Qwen3.5, `--label`) is opt-in and CPU-bound (~0.7 s/item
  in-process, ~5.8 s for a cold one-shot CLI call — see "Labeling"); it's an
  async-pass feature, not part of the synchronous classify hot path.
- Tag bounding is measured on one 193-item vault. Whether 0.85/2 holds as a
  corpus grows by an order of magnitude is unverified; the knobs are flags.
- PII is regex-spans (EMAIL/PHONE/CREDIT_CARD/US_SSN/IP), not a context model.
- Automatic onnxruntime download covers win-x64; other platforms set
  `ORT_DYLIB_PATH` to a system library.

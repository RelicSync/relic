# sift evaluation (spec §14)

Two labeled corpora live under `../corpus/`:

| set | items | generator | role |
|---|---|---|---|
| main (`corpus/manifest.json`) | 79 | `corpus/make_corpus.py` | development set — thresholds, priors and head prototypes were tuned against it |
| held-out (`corpus/holdout/manifest.json`) | 17 | `corpus/make_holdout.py` | golden set — generated *after* tuning, evaluated with zero further changes |

The taxonomy v1.2 pass (2026-06-12) grew the dev set from 65 to 79: tracking
numbers, OTP codes, addresses, todo lists, uuid/version/crypto/geo/iban
one-liners, a QR-code image, plus language/format/content-tag golds on
existing items. Holdout changes were gold-correctness only (`address` added
to one item's `any_of` after the category came to exist).

Both mix all three modalities: text strings (secrets, URLs, code, logs, chat,
email bodies, prose, configs, PII), documents (PDF, DOCX, HTML, MD, JSON, CSV,
YAML, ZIP, raw binary), and images (real desktop captures, synthetic UI
screenshots, Lorem Picsum photos, rendered receipts / document scans /
diagrams / memes — including the spec §6.2 adversarial case: a terminal
screenshot containing an AWS key, which must classify as `api_key` via OCR).

Reproduce:

```
python corpus/make_corpus.py        # regenerates the dev set (photos are seeded)
python corpus/make_holdout.py       # regenerates the held-out set
sift eval corpus/manifest.json --report eval/report.md --json eval/report.json
sift eval corpus/holdout/manifest.json --report eval/holdout-report.md
```

## Results (2026-06-12, taxonomy v1.2, Windows x64 CPU, int8 models)

| metric | dev (79) | held-out (17) |
|---|---|---|
| primary accuracy | **100.0%** | **100.0%** |
| macro-F1 | 1.000 | 1.000 |
| secret recall (safety-critical) | **100%** (10 items) | **100%** (3 items) |
| `pii_present` label recall | 100% | 100% |
| required-relic-tag pass | 98.7% | 100% |
| needs_review rate | 13.9% | 0% |
| p50 latency | 9 ms | 9 ms |
| p95 latency | 0.76 s | 0.41 s |

(The dev needs_review rate rose with v1.2 because the corpus now contains
more deliberately category-less one-liners — uuid, version, geo, iban — whose
correct outcome *is* `unsorted`+review; their value is the tag.)

Full per-category tables: `report.md` / `holdout-report.md`.

### Reading the numbers honestly

- The dev set was tuned against (three iterations: fusion override margin,
  image-format priors, head prototypes), so its 100% is partly fit. The
  held-out 100% with zero tuning is the meaningful number, but 17 items is
  small — treat it as "no systematic failure mode surfaced", not "solved".
- Accuracy counts an item correct when the prediction matches `gold.primary`
  or any entry in `gold.any_of`. `any_of` is used where categories genuinely
  overlap (a rendered bar chart is defensibly `diagram` or `screenshot`; a
  letter PDF is `email_body` or `note_prose`). Strict-primary misses worth
  knowing about: `diagram_barchart.png` lands on `screenshot` (the one
  required-tag failure in the dev set).
- Structural one-liners (a bare path / email address / phone number) have no
  semantic category by design; gold is `unsorted` and the value is carried by
  relic tags (`path`, `email`, `phone`) + `pii_present`. The pipeline now
  skips the ML head for these instead of letting it guess.
- p95 is OCR-bound (large images through ocrs on CPU). The spec target for
  the full image path is <400 ms with RapidOCR's tiny profile; the v0.1
  ocrs feeder is the documented placeholder (spec §8) and runs 0.5–2 s on
  large captures. Text items hit the <80 ms Stage A+B target comfortably.

### Enrichment (Florence-2) spot-check

The `--enrich` VLM pass is **off by default**, so the dev/holdout numbers above
are unaffected by it (verified: identical with and without the model present).
Its output — free-form captions and open-vocabulary object labels — can't be
graded by the exact-match harness, so it's checked by sampling instead:

```
sift classify --enrich corpus/images/photo_03_forest.jpg --compact
```

Read `extracted_text` (the caption) and the object tags, and rate them by hand.
Observed on the dev photos (2026-06-15, q4f16 CPU): coherent captions
describing scene/subjects, object tags like `building`/`window`/`footwear`,
~6–8 s setup + seconds of O(n²) decode per image. The safety contract is
pinned by an automated test instead of by sampling:

```
cargo test -p relic-sift --lib enrich_skips_apikey_screenshot -- --ignored
```

— a secret screenshot must stay `api_key` and get **no** caption (the PII gate).
The test is `#[ignore]`d because it loads the ~215 MB model.

### Regression gate (spec §14)

Before changing models, thresholds, prompts or prototypes:

1. `sift eval corpus/manifest.json` — `api_key`+`secret_other` recall must
   stay 100%, macro-F1 must not drop below 0.94.
2. `sift eval corpus/holdout/manifest.json` — accuracy must not drop below
   its previous value. The held-out set must never be tuned against; if it
   gets contaminated, regenerate fresh items first.

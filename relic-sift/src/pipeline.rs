//! The pipeline (spec §2): Stage 0 normalize/route → Stage A deterministic →
//! (extraction / OCR feeders) → Stage B models → Stage C fusion → record.
//! Stateless and synchronous (spec §10); pure w.r.t. storage (spec §9.1).

use std::collections::BTreeMap;
use std::path::Path;
use std::time::Instant;

use image::DynamicImage;

use crate::extract;
use crate::fusion;
use crate::models;
use crate::ocr::{self, OcrBackend};
use crate::pii;
use crate::record::*;
use crate::stage_a;
use crate::stage_a::text::SecretMatch;
use crate::labeler::Labeler;
use crate::stage_b::image::ClipClassifier;
use crate::stage_b::text::TextClassifier;
use crate::taxonomy::{self, Taxonomy};
use crate::user_rules::UserRules;

/// OCR-fed text votes are demoted so image categories usually keep primary —
/// except deterministic secret rules, which always win (spec §6.2).
const OCR_DEMOTE: f32 = 0.5;

#[derive(Debug, Clone)]
pub struct SiftConfig {
    pub model_dir: std::path::PathBuf,
    /// Load no ONNX models at all (Stage A only).
    pub enable_ml: bool,
    pub enable_ocr: bool,
    /// Emit CLIP content tags (the multi-label `people`/`animal`/object tags on
    /// images). When false, the image category still classifies — only the
    /// extra content tags are suppressed. Independent of `enable_ml`.
    pub enable_image_tags: bool,
    /// Opt-in open-vocabulary labeling (title + free-form topical tags) with
    /// the local Qwen3.5 model. Off by default: it is ~0.7 s/item on CPU and
    /// meant for an async pass off the capture hot path.
    ///
    /// Unlike the Florence-2 enrichment this replaces, it runs on **text as
    /// well as images** — which is the point, since most of a vault is text and
    /// 74.3% of it carries no subject tag (docs/phase0-vault-eval-2026-07.md).
    pub enable_labeling: bool,
    /// Include raw embedding vectors inline in records.
    pub include_vectors: bool,
}

impl Default for SiftConfig {
    fn default() -> Self {
        SiftConfig {
            model_dir: models::model_dir(),
            enable_ml: true,
            enable_ocr: true,
            enable_image_tags: true,
            enable_labeling: false,
            include_vectors: false,
        }
    }
}

pub struct Sift {
    pub taxonomy: Taxonomy,
    config: SiftConfig,
    text_model: Option<TextClassifier>,
    clip: Option<ClipClassifier>,
    ocr: Option<OcrBackend>,
    /// Optional open-vocabulary labeler (gated by `enable_labeling`).
    labeler: Option<Labeler>,
    /// User-defined global tagging rules (`user-rules.json` in the model dir).
    pub user_rules: UserRules,
    /// Load warnings (model missing/failed) — surfaced by `doctor` and CLI.
    pub warnings: Vec<String>,
}

impl Sift {
    /// Load whatever models are present in `config.model_dir`. Absent models
    /// degrade the pipeline instead of failing (spec §1.6); the only
    /// hard-required pieces are pure Rust.
    pub fn new(config: SiftConfig) -> Self {
        let taxonomy = Taxonomy::load(&config.model_dir);
        let mut warnings = Vec::new();
        let mut text_model = None;
        let mut clip = None;
        let mut ocr = None;
        let mut labeler = None;
        let ort_ready = if config.enable_ml {
            match init_ort(&config.model_dir) {
                Ok(()) => true,
                Err(e) => {
                    warnings.push(format!("onnxruntime unavailable: {e}"));
                    false
                }
            }
        } else {
            false
        };
        if config.enable_ml && ort_ready {
            if models::is_present(&config.model_dir, &models::BGE) {
                match TextClassifier::load(&config.model_dir, &taxonomy) {
                    Ok(m) => text_model = Some(m),
                    Err(e) => warnings.push(format!("text model unavailable: {e}")),
                }
            } else {
                warnings.push("text model not downloaded (run `sift models download`)".into());
            }
            if models::image_present(&config.model_dir) {
                match ClipClassifier::load(&config.model_dir, &taxonomy) {
                    Ok(m) => clip = Some(m),
                    Err(e) => warnings.push(format!("image model unavailable: {e}")),
                }
            } else {
                warnings.push("image model not downloaded (run `sift models download`)".into());
            }
            if config.enable_labeling {
                if models::is_present(&config.model_dir, &models::QWEN35) {
                    // Vision on: the pipeline sees images and text through the
                    // same Sift, so the tower has to be there either way.
                    match Labeler::load(&config.model_dir, true) {
                        Ok(m) => labeler = Some(m),
                        Err(e) => warnings.push(format!("labeler unavailable: {e}")),
                    }
                } else {
                    warnings.push(
                        "labeler not downloaded (run `sift models download --label`)".into(),
                    );
                }
            }
        }
        // OCR: PP-OCRv6 (ONNX) when present, else ocrs (rten, usable without the
        // dll). OcrBackend::load handles the selection + fallback.
        if config.enable_ml && config.enable_ocr {
            if models::ocr_v6_present(&config.model_dir)
                || models::is_present(&config.model_dir, &models::OCR)
            {
                match OcrBackend::load(&config.model_dir) {
                    Ok(m) => ocr = Some(m),
                    Err(e) => warnings.push(format!("ocr unavailable: {e}")),
                }
            } else {
                warnings.push("ocr models not downloaded (run `sift models download`)".into());
            }
        }
        let (user_rules, rule_warnings) = UserRules::load(&config.model_dir, &taxonomy);
        warnings.extend(rule_warnings);
        Sift { taxonomy, config, text_model, clip, ocr, labeler, user_rules, warnings }
    }

    pub fn has_text_model(&self) -> bool {
        self.text_model.is_some()
    }
    pub fn has_image_model(&self) -> bool {
        self.clip.is_some()
    }
    pub fn has_ocr(&self) -> bool {
        self.ocr.is_some()
    }
    pub fn has_labeler(&self) -> bool {
        self.labeler.is_some()
    }

    /// Turn labeling on/off for subsequent items without unloading the model.
    ///
    /// The resident server (`classify --serve`) needs this: whether an item is
    /// worth labeling is a per-item decision the caller makes (a vault note yes,
    /// an ephemeral clipboard line no), and re-spawning the process to change a
    /// flag would throw away the ~4.4 s model load that resident mode exists to
    /// amortize. No effect if the labeler was never loaded.
    pub fn set_labeling(&mut self, on: bool) {
        self.config.enable_labeling = on;
    }

    /// Classify one item (spec §9.1 `classify`). Synchronous, single-item,
    /// never touches the network.
    pub fn classify(&mut self, item: &NormalizedItem) -> ClassificationRecord {
        let t_total = Instant::now();
        let mut ctx = Ctx::default();
        ctx.mime = item.declared_mime.clone();

        match item.source_kind {
            SourceKind::String | SourceKind::Textblob => {
                let text = String::from_utf8_lossy(&item.bytes).into_owned();
                ctx.mime = Some("text/plain".into());
                self.text_path(&text, 1.0, true, &mut ctx);
                ctx.preview_source = Some(text);
            }
            SourceKind::Image => self.image_path(&item.bytes, &mut ctx),
            SourceKind::File => self.file_path(&item.bytes, &mut ctx),
        }

        // Label non-image items from whatever text the earlier stages produced.
        // Images were already labeled inside `image_path`, from the pixels
        // rather than their OCR — running both would waste a second and let the
        // weaker signal overwrite the stronger one.
        if !ctx.is_image {
            let body = ctx
                .preview_source
                .as_deref()
                .or(ctx.extracted_text.as_deref())
                .unwrap_or("")
                .to_string();
            if !body.trim().is_empty() {
                self.run_labeler(LabelInput::Text(&body), &mut ctx);
            }
        }

        let mut outcome = fusion::fuse(&ctx.votes, &self.taxonomy);
        let mut labels = Vec::new();
        if pii::implies_pii(&ctx.entities) {
            labels.push("pii_present".to_string());
        }

        // Images also carry *content* tags for what's visible in them: the
        // OCR-fed text categories that scored (a chat screenshot tags `chat`,
        // a code screenshot tags `code`) plus the CLIP content-tag bank.
        if matches!(item.source_kind, SourceKind::Image)
            || ctx.mime.as_deref().is_some_and(|m| m.starts_with("image/"))
        {
            for (cat, score) in &outcome.category.scores {
                if *score >= 0.25
                    && *cat != outcome.category.primary
                    && self
                        .taxonomy
                        .category(cat)
                        .is_some_and(|c| c.modality == taxonomy::Modality::Text)
                {
                    ctx.extra_tags.extend(self.taxonomy.relic_tags_for_category(cat).to_vec());
                }
            }
        }

        let mut relic_tags =
            taxonomy::relic_tags(&self.taxonomy, &ctx.structural, &outcome.category.primary, &labels);
        for tag in &ctx.extra_tags {
            let tag = taxonomy::normalize_tag(tag);
            if !tag.is_empty() && !relic_tags.contains(&tag) {
                outcome.provenance.push(Provenance {
                    stage: Stage::CFusion,
                    signal: format!("extra_tag:{tag}"),
                    score: 0.0,
                });
                relic_tags.push(tag);
            }
        }
        // Open-vocabulary tags: normalized like every other tag, but emitted on
        // their own field and never duplicating one the taxonomy already
        // produced (the labeler will happily say "receipt" about a receipt).
        let mut label_tags: Vec<String> = Vec::new();
        for tag in &ctx.label_tags {
            let tag = taxonomy::normalize_tag(tag);
            if !tag.is_empty() && !relic_tags.contains(&tag) && !label_tags.contains(&tag) {
                label_tags.push(tag);
            }
        }
        outcome.provenance.append(&mut ctx.extra_provenance);

        // Mask secrets out of every searchable field (spec §12).
        let preview_text = ctx
            .preview_source
            .as_deref()
            .or(ctx.extracted_text.as_deref())
            .unwrap_or("");
        let preview = make_preview(&mask_secrets(preview_text, &ctx.secrets_in_preview));
        let extracted_text = ctx
            .extracted_text
            .as_deref()
            .map(|t| mask_secrets(t, &ctx.secrets_in_extracted));

        let mut model_versions = BTreeMap::new();
        if let Some(m) = &self.text_model {
            // Report the stored search-vector model (Gemma when active); the
            // classification head model may differ (BGE).
            model_versions.insert("emb".to_string(), m.embed_version().to_string());
        }
        if let Some(m) = &self.clip {
            model_versions.insert("img".to_string(), m.model_version.clone());
        }
        if let Some(m) = &self.ocr {
            model_versions.insert("ocr".to_string(), m.model_version().to_string());
        }
        if let Some(m) = &self.labeler {
            model_versions.insert("label".to_string(), m.model_version().to_string());
        }

        ctx.timing.total = t_total.elapsed().as_millis() as u64;

        ClassificationRecord {
            item_id: item_id(&item.bytes),
            schema_version: SCHEMA_VERSION.to_string(),
            source_kind: item.source_kind,
            mime: ctx.mime,
            category: outcome.category,
            labels,
            relic_tags,
            label_tags,
            extracted_text,
            caption: ctx.caption,
            preview,
            entities: ctx.entities,
            embeddings: ctx.embeddings,
            provenance: outcome.provenance,
            model_versions,
            timing_ms: ctx.timing,
            created_at: now_rfc3339(),
        }
    }

    /// Classify a file from disk, routing by magic bytes (spec §4).
    pub fn classify_path(&mut self, path: &Path, kind: Option<SourceKind>) -> Result<ClassificationRecord, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
        let source_kind = kind.unwrap_or_else(|| {
            match infer::get(&bytes) {
                Some(t) if t.mime_type().starts_with("image/") => SourceKind::Image,
                _ => SourceKind::File,
            }
        });
        let item = NormalizedItem {
            bytes,
            source_kind,
            declared_mime: None,
            origin: Origin { app: None, path: Some(path.display().to_string()) },
        };
        Ok(self.classify(&item))
    }

    // -- paths --------------------------------------------------------------

    fn text_path(&mut self, text: &str, demote: f32, structural: bool, ctx: &mut Ctx) {
        let t_a = Instant::now();
        let mut votes = stage_a::text::votes(text, demote);
        // User-defined rules see every text the pipeline sees, undemoted —
        // a user's "tag ACME as work" applies to screenshots of ACME too.
        let (rule_tags, rule_votes) = self.user_rules.apply(text);
        ctx.extra_tags.extend(rule_tags);
        votes.extend(rule_votes);
        let secrets = stage_a::text::find_secrets(text);
        if structural {
            ctx.structural = stage_a::text::structural_tags(text);
        }
        let mut entities = pii::scan(text);
        for s in &secrets {
            entities.push(secret_entity(text, s));
        }
        entities.sort_by_key(|e| e.span[0]);
        ctx.entities.extend(entities);
        ctx.secrets_in_preview = secrets.clone();
        if !ctx.is_image {
            ctx.secrets_in_extracted = secrets.clone();
        }
        // Deterministic secret/url rules at ≥0.9 resolve the item; running
        // the semantic head on a token would only add noise (spec §1.2).
        let rule_won = votes.iter().any(|v| v.score >= 0.9 && v.signal.starts_with("rule:"));
        // A *whole-string* structural fact (the clip IS a path/email/UUID/card…)
        // is not semantic content — the head has nothing to say about it. NB: this
        // checks the whole-string facts only, NOT the in-prose scanners, so prose
        // that merely mentions an email/phone/card still reaches the head.
        let structural_fact = stage_a::text::is_bare_fact(text);
        ctx.votes.extend(votes);
        ctx.timing.stage_a += t_a.elapsed().as_millis() as u64;

        // Stage B *votes* run only on what rules didn't resolve (spec §1.2) —
        // but the document embedding is produced either way: a rule-resolved
        // secret/url or a bare structural fact (a clip that IS a link/email/
        // path/UUID) still needs a stored vector, or semantic search can never
        // reach the most common clipboard items ("the pricing link I saved").
        // Everything embedded on the no-vote path — and every chunk vector —
        // is secret-MASKED first (spec §12: a stored vector must not be a
        // derived artifact of raw secret material). Chunk passes only run when
        // the caller asked for vectors at all; without --vectors they'd be
        // discarded by embedding_info_chunked anyway.
        if text.trim().chars().count() >= 4 {
            if let Some(model) = &mut self.text_model {
                let t_b = Instant::now();
                let want_vectors = self.config.include_vectors;
                if !rule_won && !structural_fact {
                    match model.classify(text, demote) {
                        Ok((votes, emb)) => {
                            ctx.votes.extend(votes);
                            if ctx.embeddings.text.is_none() {
                                let chunks = if want_vectors {
                                    let masked = mask_secrets(text, &secrets);
                                    model.embed_chunks(&masked).unwrap_or_default()
                                } else {
                                    vec![]
                                };
                                ctx.embeddings.text = Some(embedding_info_chunked(
                                    model.embed_version(),
                                    emb,
                                    chunks,
                                    want_vectors,
                                ));
                            }
                        }
                        Err(e) => ctx.votes.push(Vote::new("unsorted", 0.0, Stage::BText, &format!("error:{e}"))),
                    }
                } else if ctx.embeddings.text.is_none() && text.trim().chars().count() >= 12 {
                    // Embed-only pass: the head has nothing to say (spec §1.2),
                    // so no votes — just the doc vector (plus chunks for long
                    // rule-resolved texts, e.g. an .env file). The ≥12 guard
                    // skips tiny bare facts ("1.2.4", "#ff8800") whose vectors
                    // are near-valueless noise.
                    let masked = mask_secrets(text, &secrets);
                    match model.embed_doc(&masked) {
                        Ok(emb) => {
                            let chunks = if want_vectors {
                                model.embed_chunks(&masked).unwrap_or_default()
                            } else {
                                vec![]
                            };
                            ctx.embeddings.text = Some(embedding_info_chunked(
                                model.embed_version(),
                                emb,
                                chunks,
                                want_vectors,
                            ));
                        }
                        Err(e) => ctx.votes.push(Vote::new("unsorted", 0.0, Stage::BText, &format!("embed_error:{e}"))),
                    }
                }
                ctx.timing.stage_b += t_b.elapsed().as_millis() as u64;
            }
        }
    }

    fn image_path(&mut self, bytes: &[u8], ctx: &mut Ctx) {
        ctx.is_image = true;
        let mime = infer::get(bytes).map(|t| t.mime_type().to_string());
        ctx.mime = mime.clone();
        let decoded: Option<DynamicImage> = image::load_from_memory(bytes).ok();

        let t_a = Instant::now();
        if let Some(img) = &decoded {
            let (_, votes) = stage_a::image::analyze(bytes, img.width(), img.height(), mime.as_deref());
            ctx.votes.extend(votes);
        } else {
            ctx.votes.push(Vote::new("file_binary", 0.6, Stage::AFile, "image_decode_failed"));
        }
        ctx.timing.stage_a += t_a.elapsed().as_millis() as u64;

        let Some(img) = decoded else { return };

        // OCR feeder: extracted text re-enters the text path, demoted —
        // except secrets, which keep full strength (spec §6.2).
        if let Some(ocr_engine) = &mut self.ocr {
            let t_ocr = Instant::now();
            match ocr_engine.run(&img) {
                Ok(out) => {
                    ctx.timing.ocr = t_ocr.elapsed().as_millis() as u64;
                    if !out.text.trim().is_empty() {
                        ctx.votes.extend(ocr::density_votes(&out));
                        let text = out.text.clone();
                        ctx.extracted_text = Some(text.clone());
                        self.text_path(&text, OCR_DEMOTE, false, ctx);
                        ctx.secrets_in_extracted = ctx.secrets_in_preview.clone();
                        ctx.preview_source = None; // preview falls back to extracted
                    }
                }
                Err(e) => {
                    ctx.timing.ocr = t_ocr.elapsed().as_millis() as u64;
                    ctx.votes.push(Vote::new("unsorted", 0.0, Stage::AImage, &format!("ocr_error:{e}")));
                }
            }
        }

        if let Some(clip) = &mut self.clip {
            let t_b = Instant::now();
            match clip.classify(&img) {
                Ok((votes, emb, content_tags)) => {
                    ctx.votes.extend(votes);
                    if self.config.enable_image_tags {
                        ctx.extra_tags.extend(content_tags);
                    }
                    ctx.embeddings.image = Some(embedding_info(
                        &clip.model_version,
                        emb,
                        self.config.include_vectors,
                    ));
                }
                Err(e) => ctx.votes.push(Vote::new("unsorted", 0.0, Stage::BImage, &format!("error:{e}"))),
            }
            ctx.timing.stage_b += t_b.elapsed().as_millis() as u64;
        }

        // Open-vocabulary labeling of the image itself (opt-in, off the capture
        // hot path). Runs here rather than in `classify` because this is where
        // the decoded image lives.
        self.run_labeler(LabelInput::Image(&img), ctx);
    }

    /// Label one item: a title (→ `caption`, and folded into searchable text)
    /// plus free-form topical tags (→ the content-tag stream).
    ///
    /// PII gate: skip anything that already produced secret or PII evidence. A
    /// generated title is free-form text that could surface sensitive content
    /// the span-based masker can't catch — a name, a context — so those items
    /// are never sent to the model at all.
    fn run_labeler(&mut self, input: LabelInput, ctx: &mut Ctx) {
        if !self.config.enable_labeling {
            return; // toggled off per-item by `set_labeling`
        }
        let Some(lab) = &mut self.labeler else { return };
        let stage = if ctx.is_image { Stage::BImage } else { Stage::BText };
        if enrichment_blocked_by_pii(&ctx.entities) {
            ctx.extra_provenance.push(Provenance {
                stage,
                signal: "labeling_skipped:sensitive".into(),
                score: 0.0,
            });
            return;
        }
        let t_e = Instant::now();
        let result = match input {
            LabelInput::Text(t) => lab.label_text(t),
            LabelInput::Image(img) => lab.label_image(img),
        };
        match result {
            Ok(Some(label)) => {
                if !label.title.is_empty() {
                    // Generated text: mask any secret it happens to contain
                    // before it enters a searchable field (spec §12), exactly
                    // like OCR text.
                    let secrets = stage_a::text::find_secrets(&label.title);
                    let masked = mask_secrets(&label.title, &secrets);
                    ctx.caption = Some(masked.clone());
                    // Before the image branch below, which moves `masked` into
                    // the searchable text.
                    self.embed_caption(&masked, ctx);
                    // Images fold the title into searchable text; text items
                    // already *are* their own searchable text, and appending a
                    // paraphrase of them would only dilute the FTS scoring.
                    if ctx.is_image {
                        match &mut ctx.extracted_text {
                            Some(t) => {
                                t.push_str("\n\n");
                                t.push_str(&masked);
                            }
                            None => ctx.extracted_text = Some(masked),
                        }
                    }
                    ctx.extra_provenance.push(Provenance {
                        stage,
                        signal: "label_title".into(),
                        score: 0.0,
                    });
                }
                // Open-vocabulary tags are kept *apart* from the taxonomy's own
                // (they leave on `label_tags`, not `relic_tags`) because the
                // consumer has to treat them differently: they are unbounded
                // and need snapping/recurrence before they can be shown, while
                // a curated tag like `photo` or `receipt` must pass through
                // untouched. Folding them together would mean either bounding
                // the closed vocabulary too, or not bounding at all.
                ctx.label_tags.extend(label.tags);
            }
            // No parseable JSON. Not an error — the item just goes unlabeled.
            Ok(None) => ctx.extra_provenance.push(Provenance {
                stage,
                signal: "label_unparsed".into(),
                score: 0.0,
            }),
            Err(e) => ctx.extra_provenance.push(Provenance {
                stage,
                signal: format!("label_error:{e}"),
                score: 0.0,
            }),
        }
        ctx.timing.labeling = t_e.elapsed().as_millis() as u64;
    }

    /// Fold the generated title into the vectors as its OWN chunk.
    ///
    /// Deliberately not concatenated into the document vector. Chunk 0 has to
    /// keep meaning exactly what it meant in every vault indexed before this,
    /// because cosine ranking compares vectors across a whole corpus: change
    /// the recipe and newly-indexed items carry a query-shaped summary that
    /// older ones lack, so they outrank them on relevance they don't actually
    /// have. The only way back to a consistent corpus would be re-embedding
    /// every item on every recipe change, per user, forever. As a separate
    /// chunk this is purely additive — the client already takes the max over
    /// an item's chunks (best-chunk-wins), so no search-side change and no
    /// vault needs re-indexing.
    ///
    /// It also contains an unverified guess. A wrong title can surface its own
    /// item under the wrong topic, but it cannot distort that item's real
    /// content vector, and the chunk can be dropped without touching it.
    ///
    /// The gain is largest where a title is not a paraphrase of something
    /// already embedded: an image, whose vector is otherwise OCR text alone.
    /// With no readable text there is no document vector at all today, so the
    /// caption becomes it — those items are currently unreachable by semantic
    /// search entirely, which is the biggest single gap this closes.
    fn embed_caption(&mut self, caption: &str, ctx: &mut Ctx) {
        // Without --vectors nothing is stored, so the embed would be wasted
        // work on the enrichment hot path.
        if !self.config.include_vectors {
            return;
        }
        let caption = caption.trim();
        // Same floor the embed-only text path uses: a two-word title's vector
        // is noise, not signal.
        if caption.chars().count() < 4 {
            return;
        }
        let Some(model) = &mut self.text_model else {
            return;
        };
        // The caption is already secret-masked by the caller (spec §12), like
        // any other generated text that reaches a searchable field.
        let Ok(vec) = model.embed_doc(caption) else {
            return; // a failed title embed must not fail the item
        };
        match &mut ctx.embeddings.text {
            Some(info) => {
                // Inline vectors only, matching `chunks`' existing contract.
                if info.vector.is_some() {
                    info.chunks.get_or_insert_with(Vec::new).push(vec);
                }
            }
            None => {
                ctx.embeddings.text =
                    Some(embedding_info(model.embed_version(), vec, true));
            }
        }
    }

    fn file_path(&mut self, bytes: &[u8], ctx: &mut Ctx) {
        use stage_a::file::FileRoute;
        let t_a = Instant::now();
        let (route, mime, file_votes) = stage_a::file::route(bytes);
        ctx.mime = mime;
        ctx.timing.stage_a += t_a.elapsed().as_millis() as u64;

        match route {
            FileRoute::Image { .. } => {
                self.image_path(bytes, ctx);
            }
            FileRoute::Pdf | FileRoute::Office { .. } => {
                let t_e = Instant::now();
                let text = match route {
                    FileRoute::Pdf => extract::pdf(bytes),
                    _ => extract::office(bytes),
                };
                ctx.timing.extract = t_e.elapsed().as_millis() as u64;
                match text {
                    Some(text) => {
                        // Extraction succeeded: content classifies; keep the
                        // container as a low fallback floor, not a prior.
                        for mut v in file_votes {
                            v.score = 0.35;
                            v.signal = format!("{}:fallback", v.signal);
                            ctx.votes.push(v);
                        }
                        ctx.extracted_text = Some(text.clone());
                        self.text_path(&text, 1.0, false, ctx);
                    }
                    None => ctx.votes.extend(file_votes),
                }
            }
            FileRoute::Text => {
                let text = String::from_utf8_lossy(bytes).into_owned();
                let trimmed = text.trim_start().to_ascii_lowercase();
                if trimmed.starts_with("<!doctype html") || trimmed.starts_with("<html") {
                    let t_e = Instant::now();
                    if let Some(extracted) = extract::html(&text) {
                        ctx.timing.extract = t_e.elapsed().as_millis() as u64;
                        ctx.mime = Some("text/html".into());
                        ctx.extracted_text = Some(extracted.clone());
                        self.text_path(&extracted, 1.0, false, ctx);
                        return;
                    }
                }
                self.text_path(&text, 1.0, true, ctx);
                ctx.preview_source = Some(text);
            }
            FileRoute::Archive { .. } | FileRoute::Binary { .. } => {
                ctx.votes.extend(file_votes);
            }
        }
    }
}

/// Point `ort` at the dynamically-loaded onnxruntime library, once per
/// process. Honors `ORT_DYLIB_PATH`; defaults to the model cache copy that
/// `sift models download` fetches.
pub(crate) fn init_ort(model_dir: &Path) -> Result<(), String> {
    static ORT_INIT: std::sync::OnceLock<Result<(), String>> = std::sync::OnceLock::new();
    ORT_INIT
        .get_or_init(|| {
            // Process-global: the first init wins.
            let path = match std::env::var("ORT_DYLIB_PATH") {
                Ok(p) => std::path::PathBuf::from(p),
                Err(_) => {
                    let cache = models::ort_dll_path(model_dir);
                    if cache.exists() {
                        cache
                    } else {
                        // Packaged fallback: the macOS .app ships the dylib
                        // beside the sift binary (build_release_macos.sh), so
                        // first run works before any download.
                        models::ort_beside_exe().unwrap_or(cache)
                    }
                }
            };
            if !path.exists() {
                return Err(format!(
                    "onnxruntime library not found at {} (run `sift models download`)",
                    path.display()
                ));
            }
            match ort::init_from(path.to_string_lossy().as_ref()) {
                Ok(builder) => {
                    builder.commit();
                    Ok(())
                }
                Err(e) => Err(e.to_string()),
            }
        })
        .clone()
}

#[derive(Default)]
struct Ctx {
    votes: Vec<Vote>,
    structural: Vec<String>,
    /// Extra relic tags beyond the structural/category/label mapping: CLIP
    /// content tags, screenshot-content tags, user-rule tags, Florence objects.
    extra_tags: Vec<String>,
    /// Open-vocabulary tags from the labeler. Separate from `extra_tags`
    /// because they ship on their own record field — see `run_labeler`.
    label_tags: Vec<String>,
    /// Provenance entries from post-fusion stages (e.g. the Florence caption)
    /// that have no category vote; merged into the record's provenance.
    extra_provenance: Vec<Provenance>,
    entities: Vec<Entity>,
    extracted_text: Option<String>,
    caption: Option<String>,
    preview_source: Option<String>,
    secrets_in_preview: Vec<SecretMatch>,
    secrets_in_extracted: Vec<SecretMatch>,
    embeddings: Embeddings,
    timing: TimingMs,
    mime: Option<String>,
    is_image: bool,
}

/// What the labeler is being asked to describe.
enum LabelInput<'a> {
    Text(&'a str),
    Image(&'a DynamicImage),
}

/// The labeling gate: never describe a capture that already produced secret or
/// PII evidence. A generated title is free-form text that could surface
/// sensitive content the span-based masker can't catch (a name, a context), so
/// for these items the model is not run at all.
fn enrichment_blocked_by_pii(entities: &[Entity]) -> bool {
    entities.iter().any(|e| e.kind == "SECRET") || pii::implies_pii(entities)
}

fn secret_entity(text: &str, m: &SecretMatch) -> Entity {
    let value = &text[m.span[0]..m.span[1]];
    Entity {
        kind: "SECRET".into(),
        span: m.span,
        value_masked: mask_secret_value(value, m.rule),
    }
}

fn mask_secret_value(value: &str, rule: &str) -> String {
    let head: String = value.chars().take(4).collect();
    format!("{head}•••• [{rule}]")
}

/// Replace secret spans with masked forms so raw values never land in
/// searchable fields (spec §12).
fn mask_secrets(text: &str, secrets: &[SecretMatch]) -> String {
    if secrets.is_empty() {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    let mut pos = 0;
    for m in secrets {
        let [start, end] = m.span;
        if start < pos || end > text.len() {
            continue;
        }
        out.push_str(&text[pos..start]);
        out.push_str(&mask_secret_value(&text[start..end], m.rule));
        pos = end;
    }
    out.push_str(&text[pos..]);
    out
}

fn embedding_info(model: &str, vector: Vec<f32>, include: bool) -> EmbeddingInfo {
    let bytes: Vec<u8> = vector.iter().flat_map(|f| f.to_le_bytes()).collect();
    EmbeddingInfo {
        model: model.to_string(),
        dim: vector.len(),
        vec_ref: format!("vec:{}", blake3::hash(&bytes).to_hex()),
        vector: if include { Some(vector) } else { None },
        chunks: None,
    }
}

/// [`embedding_info`] plus per-chunk vectors for long documents (inline-only,
/// like `vector` — the ref always addresses the whole-doc embedding).
fn embedding_info_chunked(
    model: &str,
    vector: Vec<f32>,
    chunks: Vec<Vec<f32>>,
    include: bool,
) -> EmbeddingInfo {
    let mut info = embedding_info(model, vector, include);
    if include && !chunks.is_empty() {
        info.chunks = Some(chunks);
    }
    info
}

fn now_rfc3339() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn offline_sift() -> Sift {
        Sift::new(SiftConfig {
            model_dir: std::env::temp_dir().join("relic-sift-test-nomodels"),
            enable_ml: false,
            enable_ocr: false,
            enable_image_tags: false,
            enable_labeling: false,
            include_vectors: false,
        })
    }

    fn classify_str(s: &str) -> ClassificationRecord {
        let mut sift = offline_sift();
        sift.classify(&NormalizedItem {
            bytes: s.as_bytes().to_vec(),
            source_kind: SourceKind::String,
            declared_mime: None,
            origin: Origin::default(),
        })
    }

    #[test]
    fn aws_key_string_offline() {
        let r = classify_str("AKIAIOSFODNN7EXAMPLE");
        assert_eq!(r.category.primary, "api_key");
        assert!(r.category.confidence >= 0.95);
        assert!(!r.category.needs_review);
        assert!(r.relic_tags.contains(&"secret".to_string()));
        // raw key never in preview
        assert!(!r.preview.contains("AKIAIOSFODNN7EXAMPLE"), "preview: {}", r.preview);
        assert!(r.entities.iter().any(|e| e.kind == "SECRET"));
    }

    #[test]
    fn url_string_offline() {
        let r = classify_str("https://example.com/docs?page=2");
        assert_eq!(r.category.primary, "url");
        assert_eq!(r.relic_tags, vec!["url"]);
    }

    /// Rule-resolved and bare-structural-fact clips must still get a stored
    /// document vector (no votes) so semantic search can reach them. Ignored:
    /// needs the downloaded text model — run with
    /// `cargo test -p relic-sift -- --ignored bare_fact`.
    #[test]
    #[ignore]
    fn bare_fact_and_rule_won_still_get_embedding() {
        let dir = crate::models::model_dir();
        if !crate::models::is_present(&dir, crate::models::text_embedding_spec(&dir))
            || !crate::models::is_present(&dir, crate::models::classifier_spec(&dir))
        {
            eprintln!("skip: text models not downloaded");
            return;
        }
        let mut sift = Sift::new(SiftConfig { include_vectors: true, ..Default::default() });
        for s in [
            "https://example.com/pricing-2026",        // rule-won url
            "lena.ortiz@bayclinic.example",            // bare structural fact
            "C:\\Users\\jordan\\Documents\\taxes.xlsx", // bare path
        ] {
            let r = sift.classify(&NormalizedItem {
                bytes: s.as_bytes().to_vec(),
                source_kind: SourceKind::String,
                declared_mime: None,
                origin: Origin::default(),
            });
            let emb = r.embeddings.text.unwrap_or_else(|| panic!("no embedding for {s}"));
            assert!(emb.vector.is_some(), "no inline vector for {s}");
        }
    }

    #[test]
    fn json_string_offline_is_structured_data() {
        let r = classify_str(r#"{"a": 1, "b": [true, null]}"#);
        assert_eq!(r.category.primary, "structured_data");
        assert!(r.relic_tags.contains(&"json".to_string()));
        assert!(r.relic_tags.contains(&"data".to_string()));
    }

    #[test]
    fn prose_offline_escalates_gracefully() {
        let r = classify_str("We decided to leave early on Saturday and beat the traffic.");
        // no models loaded → weak/no votes → unsorted + needs_review (spec §7.3)
        assert_eq!(r.category.primary, "unsorted");
        assert!(r.category.needs_review);
    }

    #[test]
    fn pii_label_and_masking() {
        let r = classify_str("reach me at jane.doe@example.com or +1 (555) 123-4567");
        assert!(r.labels.contains(&"pii_present".to_string()));
        // the label/flag stays (drives masking + enrichment-skip), but no `pii` tag
        assert!(!r.relic_tags.contains(&"pii".to_string()));
        assert!(r.entities.iter().any(|e| e.kind == "EMAIL" && e.value_masked == "j•••@•••.com"));
    }

    #[test]
    fn binary_file_offline() {
        let mut sift = offline_sift();
        let r = sift.classify(&NormalizedItem {
            bytes: b"\xff\xfe\x13\x37\x00\x01\x02\xfa".to_vec(),
            source_kind: SourceKind::File,
            declared_mime: None,
            origin: Origin::default(),
        });
        assert_eq!(r.category.primary, "file_binary");
        assert!(r.relic_tags.contains(&"file".to_string()));
    }

    #[test]
    fn env_blob_with_assigned_secret_wins_api_key() {
        let r = classify_str("DB_HOST=localhost\nAPI_KEY=q7zP2vXr9kT4wY8mB3nF6hJ1dL5gC0aS\nDEBUG=false");
        assert_eq!(r.category.primary, "api_key");
        assert!(!r.preview.contains("q7zP2vXr9kT4wY8mB3nF6hJ1dL5gC0aS"));
    }

    #[test]
    fn labeling_gate_blocks_secret_and_pii_only() {
        let ent = |kind: &str| Entity { kind: kind.into(), span: [0, 4], value_masked: "x".into() };
        assert!(enrichment_blocked_by_pii(&[ent("SECRET")]), "secret must block");
        assert!(enrichment_blocked_by_pii(&[ent("EMAIL")]), "email must block");
        assert!(enrichment_blocked_by_pii(&[ent("IBAN")]), "iban must block");
        // Nothing sensitive → labeling is allowed.
        assert!(!enrichment_blocked_by_pii(&[]));
        assert!(!enrichment_blocked_by_pii(&[ent("IP"), ent("URL")]));
    }

    /// Full-pipeline PII gate on the **image** path: a screenshot of an API key
    /// must classify `api_key` and never reach the labeler (spec §6.2).
    /// Ignored by default — it loads the ~666 MB model.
    /// Run with `cargo test -p relic-sift -- --ignored label`.
    #[test]
    #[ignore]
    fn labeling_skips_apikey_screenshot() {
        let Some(mut sift) = labeling_sift() else { return };
        let bytes = std::fs::read("corpus/images/screenshot_terminal_apikey.png").unwrap();
        let r = sift.classify(&NormalizedItem {
            bytes,
            source_kind: SourceKind::Image,
            declared_mime: None,
            origin: Origin::default(),
        });
        assert_eq!(r.category.primary, "api_key");
        let signals: Vec<&str> = r.provenance.iter().map(|p| p.signal.as_str()).collect();
        assert!(
            signals.contains(&"labeling_skipped:sensitive"),
            "gate should fire; provenance: {signals:?}"
        );
        assert!(!signals.contains(&"label_title"), "no title on a secret capture");
        assert_eq!(r.timing_ms.labeling, 0, "labeler must not run");
        assert!(r.caption.is_none());
    }

    /// The same gate on the **text** path — new with the Qwen labeler, since
    /// Florence only ever saw images. A pasted AWS key must not be described.
    #[test]
    #[ignore]
    fn labeling_skips_secret_text() {
        let Some(mut sift) = labeling_sift() else { return };
        let r = sift.classify(&NormalizedItem {
            bytes: b"AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY".to_vec(),
            source_kind: SourceKind::String,
            declared_mime: None,
            origin: Origin::default(),
        });
        let signals: Vec<&str> = r.provenance.iter().map(|p| p.signal.as_str()).collect();
        assert!(
            signals.contains(&"labeling_skipped:sensitive"),
            "gate should fire on text too; provenance: {signals:?}"
        );
        assert!(r.caption.is_none());
    }

    /// Ordinary text gets a title and open-vocabulary tags — the thing the
    /// closed taxonomy cannot emit, and the reason this model is here.
    #[test]
    #[ignore]
    fn labeling_titles_and_tags_plain_text() {
        let Some(mut sift) = labeling_sift() else { return };
        let r = sift.classify(&NormalizedItem {
            bytes: b"Quote from Kessler Roofing: $14,200 for a full tear-off and \
                     30-year architectural shingles, 3 week lead time."
                .to_vec(),
            source_kind: SourceKind::String,
            declared_mime: None,
            origin: Origin::default(),
        });
        let caption = r.caption.expect("a title should be produced");
        assert!(!caption.is_empty());
        // Open-vocab tags ship on their own field, NOT mixed into relic_tags —
        // they are unbounded and the consumer has to snap them first.
        assert!(
            r.label_tags.iter().any(|t| t.contains("roof")),
            "expected an open-vocab roofing tag; got {:?}",
            r.label_tags
        );
        assert!(
            !r.relic_tags.iter().any(|t| t.contains("roof")),
            "curated relic_tags must stay closed; got {:?}",
            r.relic_tags
        );
        // The title is a *description*, not a copy of the item (spec of the prompt).
        assert!(caption.len() < 80, "title should be short: {caption:?}");
    }

    /// A labeling Sift that also emits inline vectors (the in-app config).
    fn labeling_sift_vectors(label: bool) -> Option<Sift> {
        let dir = models::model_dir();
        if !models::is_present(&dir, &models::QWEN35) {
            eprintln!("skip: labeler not downloaded (run `sift models download --label`)");
            return None;
        }
        Some(Sift::new(SiftConfig {
            model_dir: dir,
            enable_ml: true,
            enable_ocr: true,
            enable_image_tags: true,
            enable_labeling: label,
            include_vectors: true,
        }))
    }

    fn text_item(s: &str) -> NormalizedItem {
        NormalizedItem {
            bytes: s.as_bytes().to_vec(),
            source_kind: SourceKind::String,
            declared_mime: None,
            origin: Origin::default(),
        }
    }

    /// The whole point of putting the title in its OWN chunk: the document
    /// vector must come out bit-identical whether or not the item was labeled.
    ///
    /// If this ever fails, vaults indexed before and after the change hold two
    /// different document representations, and cosine ranking compares them
    /// against each other — newer items would outrank older ones on relevance
    /// they don't have, and the only fix would be re-embedding every corpus.
    #[test]
    #[ignore]
    fn title_chunk_leaves_the_document_vector_untouched() {
        let (Some(mut plain), Some(mut labeled)) =
            (labeling_sift_vectors(false), labeling_sift_vectors(true))
        else {
            return;
        };
        // Short enough that length alone produces no chunks — so any chunk
        // present in the labeled run came from the title.
        let text = "Quote from Kessler Roofing: $14,200 for a full tear-off and \
                    30-year architectural shingles, 3 week lead time.";

        let a = plain.classify(&text_item(text));
        let b = labeled.classify(&text_item(text));

        let ea = a.embeddings.text.expect("plain run should embed the document");
        let eb = b.embeddings.text.expect("labeled run should embed the document");
        assert_eq!(
            ea.vector, eb.vector,
            "labeling changed the document vector; it must only ADD a chunk"
        );
        assert_eq!(ea.vec_ref, eb.vec_ref, "content address of chunk 0 moved");

        assert!(b.caption.is_some(), "expected a title on this item");
        let chunks = eb.chunks.expect("labeled run should carry a title chunk");
        assert_eq!(
            chunks.len(),
            ea.chunks.map(|c| c.len()).unwrap_or(0) + 1,
            "expected exactly one added chunk (the title)"
        );
        assert_eq!(
            chunks.last().unwrap().len(),
            ea.vector.unwrap().len(),
            "title chunk must live in the same space as the document vector"
        );
    }

    /// The gap this actually closes: a photo with no readable text has no
    /// document vector at all, so it cannot be reached by semantic search.
    /// The caption becomes that vector.
    #[test]
    #[ignore]
    fn a_captioned_photo_becomes_reachable_by_vector() {
        let (Some(mut plain), Some(mut labeled)) =
            (labeling_sift_vectors(false), labeling_sift_vectors(true))
        else {
            return;
        };
        let bytes = std::fs::read("corpus/images/photo_01_mountain.jpg").unwrap();
        let item = |b: &Vec<u8>| NormalizedItem {
            bytes: b.clone(),
            source_kind: SourceKind::File,
            declared_mime: None,
            origin: Origin::default(),
        };

        let a = plain.classify(&item(&bytes));
        let b = labeled.classify(&item(&bytes));
        assert!(b.caption.is_some(), "expected a caption for a photo");

        let count = |e: &Option<crate::record::EmbeddingInfo>| match e {
            None => 0,
            Some(i) => {
                i.vector.iter().len() + i.chunks.as_ref().map(|c| c.len()).unwrap_or(0)
            }
        };
        let (na, nb) = (count(&a.embeddings.text), count(&b.embeddings.text));
        assert!(
            nb > na,
            "labeling must never reduce vector coverage and should add one \
             here (plain={na}, labeled={nb})"
        );
        if a.embeddings.text.is_none() {
            let e = b.embeddings.text.unwrap();
            assert!(
                e.vector.is_some_and(|v| !v.is_empty()),
                "a photo with no OCR text should get its vector from the caption"
            );
        }
    }

    fn labeling_sift() -> Option<Sift> {
        let dir = models::model_dir();
        if !models::is_present(&dir, &models::QWEN35) {
            eprintln!("skip: labeler not downloaded (run `sift models download --label`)");
            return None;
        }
        Some(Sift::new(SiftConfig {
            model_dir: dir,
            enable_ml: true,
            enable_ocr: true,
            enable_image_tags: true,
            enable_labeling: true,
            include_vectors: false,
        }))
    }

    #[test]
    fn record_serializes_per_contract() {
        let r = classify_str("https://example.com");
        let json = serde_json::to_value(&r).unwrap();
        assert_eq!(json["schema_version"], "sift/0.1");
        assert!(json["item_id"].as_str().unwrap().starts_with("blake3:"));
        assert_eq!(json["source_kind"], "string");
        assert!(json["category"]["scores"].is_object());
        assert!(json["provenance"].is_array());
    }
}

//! `sift` — Relic's classification pipeline, standalone CLI.
//!
//! Zero-setup: the first classify run downloads the (small, redistributable)
//! ONNX models to a local cache; `--offline` or `--no-ml` skips that and
//! degrades gracefully to the deterministic Stage A (spec §1.6).

use std::io::Read;
use std::path::PathBuf;

use clap::{Parser, Subcommand};
use relic_sift::{
    eval, models, NormalizedItem, Origin, Sift, SiftConfig, SourceKind, Taxonomy,
};

#[derive(Parser)]
#[command(name = "sift", version, about = "Relic's local classification pipeline")]
struct Cli {
    /// How much of the machine the on-device passes may take:
    /// `gentle` (a quarter of the cores), `balanced` (default — spare cores up
    /// to 6, below foreground priority), or `fast` (up to 8, normal priority).
    ///
    /// Labeling costs ~7.5 core-seconds per item, so on a small machine this is
    /// the difference between background noise and a stalled desktop.
    /// `SIFT_THREADS` overrides the thread count outright.
    #[arg(long, global = true, default_value = "balanced")]
    speed: relic_sift::perf::Speed,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Classify files or stdin; prints one ClassificationRecord (JSON) per item.
    Classify {
        /// Files to classify (magic-byte routed: image/file/text)
        paths: Vec<PathBuf>,
        /// Classify this literal string instead of files
        #[arg(long)]
        text: Option<String>,
        /// Read item content from stdin (classified as a string)
        #[arg(long)]
        stdin: bool,
        /// Resident mode: load every model once, then read one JSON request per
        /// stdin line and print one ClassificationRecord per line.
        ///
        ///   {"kind":"string","text":"…"}
        ///   {"kind":"image","path":"C:\\…\\shot.png"}
        ///
        /// Model loading dominates a one-shot run — with the labeler on it is
        /// ~5 s of setup for ~0.7 s of work — so a background enricher going
        /// item-by-item should always use this instead of re-spawning. The
        /// flags above are fixed for the life of the process; restart to change
        /// them.
        #[arg(long)]
        serve: bool,
        /// Force the source kind for file paths
        #[arg(long, value_parser = ["auto", "string", "image", "file"], default_value = "auto")]
        kind: String,
        /// Never touch the network (skip the first-run model download)
        #[arg(long)]
        offline: bool,
        /// Stage A only: no ONNX models, no OCR
        #[arg(long)]
        no_ml: bool,
        /// Skip OCR (no extracted text from images); keeps tags/category/embeddings
        #[arg(long)]
        no_ocr: bool,
        /// Skip CLIP content tags on images; keeps the image category
        #[arg(long)]
        no_image_tags: bool,
        /// Run the open-vocabulary labeler (title → `caption` + searchable text,
        /// topical tags → relic_tags) on text and images. ~0.7 s/item on CPU;
        /// downloads the model (~666 MB) on first use.
        ///
        /// `--enrich` is the old name for this and still works: it used to mean
        /// the Florence-2 caption pass, which this replaced.
        #[arg(long, alias = "enrich")]
        label: bool,
        /// Deprecated no-ops from the Florence-2 enrichment pass. Accepted so a
        /// previously-shipped app that still passes them keeps working; the
        /// labeler has no caption-length or object-detection knob.
        #[arg(long, hide = true)]
        enrich_detail: Option<String>,
        #[arg(long, hide = true)]
        enrich_objects: bool,
        /// Include raw embedding vectors inline
        #[arg(long)]
        vectors: bool,
        /// Compact single-line JSON
        #[arg(long)]
        compact: bool,
    },
    /// Embed a search query into a bge vector (query-prefixed, L2-normalized),
    /// matching the document vectors `classify --vectors` emits. With --serve,
    /// loads the model once and reads one query per stdin line, printing one
    /// compact vector JSON per line (for fast search-as-you-type).
    Embed {
        #[arg(long)]
        query: Option<String>,
        #[arg(long)]
        serve: bool,
        #[arg(long)]
        compact: bool,
    },
    /// Manage local models
    Models {
        #[command(subcommand)]
        action: ModelsAction,
    },
    /// Run the evaluation harness over a labeled corpus manifest
    Eval {
        manifest: PathBuf,
        /// Write a markdown report here
        #[arg(long)]
        report: Option<PathBuf>,
        /// Write the full JSON report here
        #[arg(long)]
        json: Option<PathBuf>,
        /// Only the first N items
        #[arg(long)]
        limit: Option<usize>,
        #[arg(long)]
        offline: bool,
        #[arg(long)]
        no_ml: bool,
    },
    /// Check the installation: models, runtimes, and a self-test
    Doctor,
    /// Print the effective taxonomy (categories, thresholds, tag mapping)
    Taxonomy,
    /// Manage user-defined global tagging rules (user-rules.json)
    Rules {
        #[command(subcommand)]
        action: Option<RulesAction>,
    },
    /// Tag tooling (e.g. the query-side tag-expansion vector table)
    Tags {
        #[command(subcommand)]
        action: TagsAction,
    },
    /// Bake the taxonomy's image-prompt embeddings into the shippable asset.
    ///
    /// Build-time only, and the reason the 254 MB MobileCLIP2 text tower is no
    /// longer in the default download: it embeds the ~60 fixed prompt strings
    /// once, here, and the result is compiled into the binary. Re-run whenever
    /// taxonomy.json's clip_prompts or image_tags change, or the loader will
    /// miss the baked cache (fingerprint mismatch) and ask for the tower again.
    ///
    ///   sift prompts bake --out relic-sift/assets/mobileclip2-prompts.json
    Prompts {
        #[command(subcommand)]
        action: PromptsAction,
    },
    /// Open-vocabulary label: a title plus free-form topical tags, from the
    /// local Qwen3.5 labeler. This is the output the closed taxonomy cannot
    /// produce; `classify` still owns the category.
    ///
    /// Prints one JSON object per item. Downloads the model (~666 MB) on first
    /// use unless --offline.
    Label {
        /// Images or text files to label (images use the vision tower)
        paths: Vec<PathBuf>,
        /// Label this literal string instead of files
        #[arg(long)]
        text: Option<String>,
        /// Read the item from stdin
        #[arg(long)]
        stdin: bool,
        /// Never touch the network (fail instead of downloading the model)
        #[arg(long)]
        offline: bool,
        /// Emit the model's raw completion alongside the parsed label. This is
        /// what `relic-sift-next/harness/label_qwen35.py` prints, so the two can
        /// be diffed token-for-token — greedy decode is deterministic, so any
        /// divergence is a porting bug, not noise.
        #[arg(long)]
        raw: bool,
        /// Compact single-line JSON
        #[arg(long)]
        compact: bool,
    },
}

#[derive(Subcommand)]
enum PromptsAction {
    /// Embed the taxonomy prompts with the text tower and write the asset
    Bake {
        /// Where to write the JSON (default: stdout)
        #[arg(long)]
        out: Option<PathBuf>,
    },
}

#[derive(Subcommand)]
enum TagsAction {
    /// Bound the open-vocabulary tag stream: snap near-duplicates onto one
    /// representative and report which representatives have recurred enough to
    /// become visible facets.
    ///
    /// Stateless — the corpus vocabulary is passed in and the updated one comes
    /// back, so the vault stays the single source of truth. Reads one JSON
    /// object on stdin:
    ///
    ///   {"vocabulary": [{"tag": "development", "count": 18, "vec": [...]}],
    ///    "emitted": ["dev", "roofing", "roofing"]}
    ///
    /// and prints {mapping, added, counts, promoted}. `emitted` may repeat;
    /// repeats are counted, which is what drives promotion. `added` carries
    /// every newly-embedded string — aliases included — and all of it must be
    /// stored, because --reconcile needs the alias rows to work at all.
    Bound {
        /// Cosine at or above which two tags are the same facet
        #[arg(long, default_value_t = relic_sift::tag_vocab::DEFAULT_THRESHOLD)]
        threshold: f32,
        /// Emissions before a tag becomes a visible facet
        #[arg(long, default_value_t = relic_sift::tag_vocab::DEFAULT_MIN_COUNT)]
        min_count: u32,
        /// Re-agglomerate the passed-in vocabulary against itself instead of
        /// absorbing `emitted`. Run periodically: online absorption sees tags
        /// in arrival order, so representatives drift.
        #[arg(long)]
        reconcile: bool,
        #[arg(long)]
        compact: bool,
    },
    /// Embed every searchable tag's gloss (document prefix) and print the table
    /// as JSON `{model_version, dim, gloss_hash, tags:[{tag, vec}]}` — the
    /// query-side tag-expansion table the app loads for semantic tag matching.
    Vectors {
        #[arg(long)]
        compact: bool,
    },
}

#[derive(Subcommand)]
enum RulesAction {
    /// Create a commented sample user-rules.json (won't overwrite)
    Init,
    /// Apply the rules to a text and show what they'd tag
    Test {
        #[arg(long)]
        text: String,
    },
}

#[derive(Subcommand)]
enum ModelsAction {
    /// Download the core models (~750 MB total) to the local cache
    Download {
        /// Also fetch the optional Qwen3.5 open-vocabulary labeler (~666 MB).
        /// `--enrich` is accepted as the old name for this.
        #[arg(long, alias = "enrich")]
        label: bool,
    },
    /// Show what's downloaded
    Status,
    /// Print the model cache directory
    Path,
    /// Delete models this install can no longer use (e.g. Florence-2, which
    /// Qwen3.5 replaced). Run on upgrade; safe to run repeatedly.
    Prune {
        /// Also drop fallbacks this install will never reach: CLIP behind
        /// MobileCLIP2, BGE behind Gemma, and the text tower when no user
        /// taxonomy needs it. All re-downloadable.
        #[arg(long)]
        deep: bool,
        /// Report what would go without deleting anything.
        #[arg(long)]
        dry_run: bool,
        /// Emit JSON instead of a human summary.
        #[arg(long)]
        json: bool,
    },
}

fn main() {
    let cli = Cli::parse();
    // Before anything loads a model: the thread counts are read at session
    // construction, and priority should cover the whole process.
    relic_sift::perf::set_speed(cli.speed);
    relic_sift::perf::lower_priority(cli.speed);
    let code = match run(cli) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("error: {e}");
            1
        }
    };
    std::process::exit(code);
}

fn run(cli: Cli) -> Result<(), String> {
    match cli.command {
        Command::Classify {
            paths, text, stdin, serve, kind, offline, no_ml, no_ocr, no_image_tags, label,
            enrich_detail: _, enrich_objects: _, vectors, compact,
        } => {
            if paths.is_empty() && text.is_none() && !stdin && !serve {
                return Err(
                    "nothing to classify: pass paths, --text, --stdin, or --serve".into()
                );
            }
            let mut sift = build_sift(offline, no_ml, no_ocr, no_image_tags, vectors, label)?;
            if serve {
                return serve_classify(&mut sift);
            }
            let mut records = Vec::new();
            if let Some(t) = text {
                records.push(classify_string(&mut sift, t.into_bytes()));
            }
            if stdin {
                let mut buf = Vec::new();
                std::io::stdin().read_to_end(&mut buf).map_err(|e| e.to_string())?;
                records.push(classify_string(&mut sift, buf));
            }
            let forced = match kind.as_str() {
                "string" => Some(SourceKind::String),
                "image" => Some(SourceKind::Image),
                "file" => Some(SourceKind::File),
                _ => None,
            };
            for p in &paths {
                records.push(sift.classify_path(p, forced)?);
            }
            for r in &records {
                let json = if compact {
                    serde_json::to_string(r)
                } else {
                    serde_json::to_string_pretty(r)
                }
                .map_err(|e| e.to_string())?;
                println!("{json}");
            }
            Ok(())
        }
        Command::Embed { query, serve, compact } => {
            let dir = models::model_dir();
            let mut emb = relic_sift::Embedder::load(&dir)?;
            let model = emb.model_version.clone();
            let emit = |v: Vec<f32>, compact: bool| -> Result<(), String> {
                let out = serde_json::json!({
                    "model": model,
                    "dim": v.len(),
                    "vector": v,
                });
                let s = if compact {
                    serde_json::to_string(&out)
                } else {
                    serde_json::to_string_pretty(&out)
                }
                .map_err(|e| e.to_string())?;
                println!("{s}");
                Ok(())
            };
            if serve {
                use std::io::{BufRead, Write};
                let stdin = std::io::stdin();
                for line in stdin.lock().lines() {
                    let q = line.map_err(|e| e.to_string())?;
                    if q.trim().is_empty() {
                        continue;
                    }
                    let v = emb.embed_query(&q)?;
                    emit(v, true)?;
                    std::io::stdout().flush().ok();
                }
                Ok(())
            } else {
                let q = query.ok_or("embed: pass --query or --serve")?;
                emit(emb.embed_query(&q)?, compact)
            }
        }
        Command::Models { action } => match action {
            ModelsAction::Download { label } => {
                let dir = models::model_dir();
                eprintln!("model cache: {}", dir.display());
                models::download_all(&dir, false)?;
                if label {
                    models::download_labeler(&dir, false)?;
                }
                eprintln!("all models present.");
                Ok(())
            }
            ModelsAction::Status => {
                let dir = models::model_dir();
                println!("model cache: {}", dir.display());
                let print = |s: &models::ModelStatus, optional: bool| {
                    println!(
                        "  {:<24} {:<26} {:>9.1} MB  {}  [{}]",
                        s.id,
                        s.role,
                        s.bytes as f64 / 1e6,
                        if s.present {
                            "present"
                        } else if optional {
                            "optional"
                        } else {
                            "MISSING"
                        },
                        s.license
                    );
                };
                for s in models::status(&dir) {
                    print(&s, false);
                }
                print(&models::labeler_status(&dir), true);
                Ok(())
            }
            ModelsAction::Path => {
                println!("{}", models::model_dir().display());
                Ok(())
            }
            ModelsAction::Prune { deep, dry_run, json } => {
                let dir = models::model_dir();
                let removed = models::prune(&dir, deep, dry_run);
                let bytes: u64 = removed.iter().map(|f| f.bytes).sum();
                if json {
                    println!(
                        "{}",
                        serde_json::to_string(&serde_json::json!({
                            "dry_run": dry_run,
                            "freed_bytes": bytes,
                            "removed": removed,
                        }))
                        .map_err(|e| e.to_string())?
                    );
                } else if removed.is_empty() {
                    println!("nothing to prune ({})", dir.display());
                } else {
                    for f in &removed {
                        println!(
                            "  {} {:<38} {:>8.1} MB  [{}]",
                            if dry_run { "would remove" } else { "removed" },
                            f.name,
                            f.bytes as f64 / 1e6,
                            f.reason
                        );
                    }
                    println!("{:.1} MB{}", bytes as f64 / 1e6, if dry_run { " reclaimable" } else { " freed" });
                }
                Ok(())
            }
        },
        Command::Eval { manifest, report, json, limit, offline, no_ml } => {
            let mut sift =
                build_sift(offline, no_ml, false, false, false, false)?;
            let t0 = std::time::Instant::now();
            let result = eval::run(&mut sift, &manifest, limit)?;
            let title = format!(
                "sift eval — {} ({} items, ml={}, ocr={})",
                manifest.display(),
                result.items,
                sift.has_text_model() || sift.has_image_model(),
                sift.has_ocr(),
            );
            let md = eval::markdown(&result, &title);
            println!("{md}");
            eprintln!("eval wall time: {:.1}s", t0.elapsed().as_secs_f64());
            if let Some(p) = report {
                std::fs::write(&p, &md).map_err(|e| e.to_string())?;
                eprintln!("report written to {}", p.display());
            }
            if let Some(p) = json {
                std::fs::write(&p, serde_json::to_string_pretty(&result).unwrap())
                    .map_err(|e| e.to_string())?;
                eprintln!("json written to {}", p.display());
            }
            Ok(())
        }
        Command::Doctor => doctor(),
        Command::Prompts { action } => match action {
            PromptsAction::Bake { out } => {
                let dir = models::model_dir();
                // MUST come before any session is built. `Sift::new` does this
                // via pipeline::init_ort; a command that builds a session
                // without going through Sift has to do it itself, and the
                // failure mode is nasty — `ort` with `load-dynamic` HANGS at 0%
                // CPU instead of returning "library not registered".
                relic_sift::ensure_runtime(&dir)?;
                let taxonomy = Taxonomy::load(&dir);
                let json = relic_sift::stage_b::image::bake_prompts(&dir, &taxonomy)?;
                match out {
                    Some(p) => {
                        std::fs::write(&p, &json).map_err(|e| format!("write {}: {e}", p.display()))?;
                        eprintln!("baked {} bytes -> {}", json.len(), p.display());
                    }
                    None => println!("{json}"),
                }
                Ok(())
            }
        },
        Command::Label { paths, text, stdin, offline, raw, compact } => {
            cmd_label(paths, text, stdin, offline, raw, compact)
        }
        Command::Taxonomy => {
            let t = Taxonomy::load(&models::model_dir());
            println!("taxonomy v{} ({} categories)", t.version, t.categories.len());
            println!("{:<16} {:<8} {:>9}  {:<20} {}", "category", "modality", "threshold", "relic_tags", "detector");
            for c in &t.categories {
                let detector = if !c.clip_prompts.is_empty() {
                    format!("clip×{}", c.clip_prompts.len())
                } else if !c.prototypes.is_empty() {
                    format!("head×{}", c.prototypes.len())
                } else {
                    "rules".to_string()
                };
                println!(
                    "{:<16} {:<8} {:>9.2}  {:<20} {}",
                    c.id,
                    format!("{:?}", c.modality).to_lowercase(),
                    c.threshold,
                    c.relic_tags.join(","),
                    detector
                );
            }
            for l in &t.labels {
                println!("label: {:<16} relic_tags={}", l.id, l.relic_tags.join(","));
            }
            if let Some(bank) = &t.image_tags {
                let ids: Vec<&str> = bank.tags.iter().map(|x| x.id.as_str()).collect();
                println!(
                    "image content tags (threshold {:.2}): {}",
                    bank.threshold,
                    ids.join(", ")
                );
            }
            Ok(())
        }
        Command::Rules { action } => {
            let dir = models::model_dir();
            let path = relic_sift::user_rules::UserRules::path(&dir);
            match action {
                Some(RulesAction::Init) => {
                    if path.exists() {
                        return Err(format!("{} already exists", path.display()));
                    }
                    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
                    std::fs::write(&path, relic_sift::user_rules::UserRules::SAMPLE)
                        .map_err(|e| e.to_string())?;
                    println!("sample rules written to {}", path.display());
                    Ok(())
                }
                Some(RulesAction::Test { text }) => {
                    let taxonomy = Taxonomy::load(&dir);
                    let (rules, warnings) =
                        relic_sift::user_rules::UserRules::load(&dir, &taxonomy);
                    for w in &warnings {
                        eprintln!("warning: {w}");
                    }
                    let (tags, votes) = rules.apply(&text);
                    println!("tags: {}", if tags.is_empty() { "(none)".into() } else { tags.join(", ") });
                    for v in votes {
                        println!("category vote: {} {:.2} ({})", v.category, v.score, v.signal);
                    }
                    Ok(())
                }
                None => {
                    let taxonomy = Taxonomy::load(&dir);
                    let (rules, warnings) =
                        relic_sift::user_rules::UserRules::load(&dir, &taxonomy);
                    for w in &warnings {
                        eprintln!("warning: {w}");
                    }
                    if rules.rules.is_empty() {
                        println!(
                            "no user rules. Create {} with `sift rules init`.",
                            path.display()
                        );
                    } else {
                        println!("{} rule(s) from {}:", rules.rules.len(), path.display());
                        for r in &rules.rules {
                            let cat = r
                                .category
                                .as_deref()
                                .map(|c| format!("  → category {c} ({:.2})", r.confidence))
                                .unwrap_or_default();
                            println!("  {:<20} tags=[{}]{}", r.name, r.tags.join(","), cat);
                        }
                    }
                    Ok(())
                }
            }
        }
        Command::Tags { action } => match action {
            TagsAction::Bound { threshold, min_count, reconcile, compact } => {
                cmd_tags_bound(threshold, min_count, reconcile, compact)
            }
            TagsAction::Vectors { compact } => {
                let dir = models::model_dir();
                let tax = Taxonomy::load(&dir);
                let mut model = relic_sift::stage_b::encoder::TextEmbedModel::load(&dir)?;
                let tag_ids = relic_sift::tags::searchable_tags(&tax);
                // Embed each tag's gloss with the DOCUMENT prefix (same space the
                // query↔document retrieval uses).
                let glosses: Vec<&str> = tag_ids
                    .iter()
                    .map(|t| relic_sift::tags::gloss(t).unwrap_or(t.as_str()))
                    .collect();
                let vecs = model.embed_docs(&glosses)?;
                let tags: Vec<_> = tag_ids
                    .iter()
                    .zip(vecs)
                    .map(|(tag, vec)| serde_json::json!({ "tag": tag, "vec": vec }))
                    .collect();
                let out = serde_json::json!({
                    "model_version": model.model_version,
                    "dim": model.dim,
                    "gloss_hash": relic_sift::tags::gloss_fingerprint(&tax),
                    "tags": tags,
                });
                let s = if compact {
                    serde_json::to_string(&out)
                } else {
                    serde_json::to_string_pretty(&out)
                }
                .map_err(|e| e.to_string())?;
                println!("{s}");
                Ok(())
            }
        },
    }
}

fn build_sift(
    offline: bool,
    no_ml: bool,
    no_ocr: bool,
    no_image_tags: bool,
    vectors: bool,
    label: bool,
) -> Result<Sift, String> {
    let dir = models::model_dir();
    if !no_ml && !offline {
        // Zero-setup: fetch anything missing before the (network-free) hot path.
        let missing: Vec<_> = models::status(&dir).into_iter().filter(|s| !s.present).collect();
        if !missing.is_empty() {
            eprintln!(
                "first run: downloading {} model(s) to {} (one-time, ~750 MB total; use --offline to skip)",
                missing.len(),
                dir.display()
            );
            models::download_all(&dir, false)?;
        }
        // The labeler is fetched on demand the first time --label runs.
        if label && !models::labeler_status(&dir).present {
            eprintln!("--label: downloading the Qwen3.5 labeler (~666 MB, one-time)");
            models::download_labeler(&dir, false)?;
        }
    }
    let sift = Sift::new(SiftConfig {
        model_dir: dir,
        enable_ml: !no_ml,
        enable_ocr: !no_ml && !no_ocr,
        enable_image_tags: !no_image_tags,
        enable_labeling: label,
        include_vectors: vectors,
    });
    for w in &sift.warnings {
        eprintln!("warning: {w}");
    }
    Ok(sift)
}

/// `sift tags bound` — snap near-duplicate tags together and report which have
/// recurred enough to become visible facets. See `tag_vocab.rs` for why.
fn cmd_tags_bound(
    threshold: f32,
    min_count: u32,
    reconcile: bool,
    compact: bool,
) -> Result<(), String> {
    use relic_sift::tag_vocab::{self, Rep};

    #[derive(serde::Deserialize)]
    struct Input {
        #[serde(default)]
        vocabulary: Vec<Rep>,
        #[serde(default)]
        emitted: Vec<String>,
    }

    let mut buf = String::new();
    std::io::stdin().read_to_string(&mut buf).map_err(|e| e.to_string())?;
    let input: Input = serde_json::from_str(&buf).map_err(|e| format!("parse stdin: {e}"))?;

    let dir = models::model_dir();
    let mut reps = input.vocabulary;
    let mut model_version = String::new();
    let mut dim = reps.first().map(|r| r.vec.len()).unwrap_or(0);
    // Every string embedded this run — representatives *and* aliases. The
    // caller has to persist all of them: reconcile needs the alias rows to
    // re-derive the grouping in frequency order (see tag_vocab::reconcile).
    let mut added: Vec<Rep> = Vec::new();

    let mapping = if reconcile {
        let (m, rebuilt) = tag_vocab::reconcile(&reps, threshold);
        reps = rebuilt;
        m
    } else if input.emitted.is_empty() {
        Default::default()
    } else {
        // Count first: `emitted` is a raw stream and repeats are exactly the
        // signal promotion runs on.
        let mut counts: std::collections::BTreeMap<&str, u32> = Default::default();
        for t in &input.emitted {
            *counts.entry(t.as_str()).or_default() += 1;
        }
        // Tags already known by name need no embedding — this is the common
        // case once a vault has settled, and the encoder is the slow part.
        let fresh: Vec<&str> =
            counts.keys().copied().filter(|t| !reps.iter().any(|r| r.tag == *t)).collect();
        let mut vecs: std::collections::HashMap<&str, Vec<f32>> = Default::default();
        if !fresh.is_empty() {
            let mut model = relic_sift::stage_b::encoder::TextEmbedModel::load(&dir)?;
            model_version = model.model_version.clone();
            dim = model.dim;
            // DOCUMENT prefix: the same space the stored tag-gloss vectors and
            // the prototype used. A query-prefixed vector would not be
            // comparable to the ones already in the vault.
            for (t, v) in fresh.iter().zip(model.embed_docs(&fresh)?) {
                vecs.insert(t, v);
            }
        }
        let emitted: Vec<(String, Vec<f32>, u32)> = counts
            .iter()
            .map(|(t, c)| {
                // Empty only for a tag already in `reps` by name, which
                // `absorb` short-circuits before it ever looks at the vector.
                let v = vecs.remove(*t).unwrap_or_default();
                (t.to_string(), v, *c)
            })
            .collect();
        added = emitted
            .iter()
            .filter(|(_, v, _)| !v.is_empty())
            .map(|(t, v, c)| Rep { tag: t.clone(), count: *c, vec: v.clone() })
            .collect();
        tag_vocab::absorb_with(&mut reps, &emitted, threshold)
    };
    let counts: std::collections::BTreeMap<&str, u32> =
        reps.iter().map(|r| (r.tag.as_str(), r.count)).collect();
    let out = serde_json::json!({
        "model_version": model_version,
        "dim": dim,
        "threshold": threshold,
        "min_count": min_count,
        "mapping": mapping,
        "added": added,
        "counts": counts,
        "promoted": tag_vocab::promoted(&reps, min_count),
        "vocabulary_size": reps.len(),
    });
    let s = if compact { serde_json::to_string(&out) } else { serde_json::to_string_pretty(&out) }
        .map_err(|e| e.to_string())?;
    println!("{s}");
    Ok(())
}

/// `sift label` — run the open-vocabulary labeler over items.
///
/// The vision tower is built only when an image is actually in the batch: it is
/// another ~62 MB of session and a text-only run has no use for it.
fn cmd_label(
    paths: Vec<PathBuf>,
    text: Option<String>,
    stdin: bool,
    offline: bool,
    raw: bool,
    compact: bool,
) -> Result<(), String> {
    let dir = models::model_dir();
    if !models::labeler_status(&dir).present {
        if offline {
            return Err("labeler model not downloaded (drop --offline, or run `sift models download --label`)".into());
        }
        eprintln!("downloading the Qwen3.5 labeler (~666 MB, one-time)");
        models::download_labeler(&dir, false)?;
    }

    let wants_vision = paths.iter().any(|p| is_image(p));
    let mut labeler = relic_sift::Labeler::load(&dir, wants_vision)?;

    let emit = |name: &str, label: Option<relic_sift::Label>, raw_text: Option<String>| {
        let mut v = serde_json::json!({ "item": name, "label": label });
        if let Some(r) = raw_text {
            v["raw"] = serde_json::Value::String(r);
        }
        let s = if compact {
            serde_json::to_string(&v)
        } else {
            serde_json::to_string_pretty(&v)
        };
        println!("{}", s.unwrap_or_default());
    };

    let label_text = |labeler: &mut relic_sift::Labeler, name: &str, body: &str| -> Result<(), String> {
        if raw {
            let g = labeler.raw_text(body)?;
            let parsed = relic_sift::labeler::normalize_str(&g.text);
            eprintln!(
                "[{name}] {} prompt + {} new, {} ms ({} ms prefill)",
                g.n_prompt, g.n_new, g.total_ms, g.prefill_ms
            );
            emit(name, parsed, Some(g.text));
        } else {
            emit(name, labeler.label_text(body)?, None);
        }
        Ok(())
    };

    if let Some(t) = text {
        label_text(&mut labeler, "--text", &t)?;
    }
    if stdin {
        let mut buf = String::new();
        std::io::stdin().read_to_string(&mut buf).map_err(|e| e.to_string())?;
        label_text(&mut labeler, "--stdin", &buf)?;
    }
    for p in &paths {
        let name = p.display().to_string();
        if is_image(p) {
            let img = image::open(p).map_err(|e| format!("open {name}: {e}"))?;
            emit(&name, labeler.label_image(&img)?, None);
        } else {
            let body = std::fs::read_to_string(p).map_err(|e| format!("read {name}: {e}"))?;
            label_text(&mut labeler, &name, &body)?;
        }
    }
    Ok(())
}

/// Magic-byte image detection, matching how `classify` routes files — the
/// extension is a hint, not evidence.
fn is_image(p: &std::path::Path) -> bool {
    infer::get_from_path(p)
        .ok()
        .flatten()
        .map(|t| t.matcher_type() == infer::MatcherType::Image)
        .unwrap_or(false)
}

/// `classify --serve`: one JSON request per stdin line, one record per line.
///
/// Exists because model loading dwarfs the work. A background enricher
/// classifying items one at a time pays ~5 s of session setup per item to do
/// ~0.7 s of inference; holding the process open makes that a one-time cost.
///
/// A request that fails answers with `{"error": …}` rather than killing the
/// server — one unreadable file must not take the whole enrichment pass down.
fn serve_classify(sift: &mut Sift) -> Result<(), String> {
    use std::io::{BufRead, Write};

    #[derive(serde::Deserialize)]
    struct Req {
        #[serde(default)]
        kind: String,
        #[serde(default)]
        text: Option<String>,
        #[serde(default)]
        path: Option<PathBuf>,
        /// Per-item labeling override. Whether an item earns a generated title
        /// is the caller's call (a vault note yes, an ephemeral clipboard line
        /// no), and it must NOT be a process flag — flipping a flag would mean
        /// respawning, throwing away the model load resident mode exists for.
        /// Defaults to whatever `--label` set.
        #[serde(default)]
        label: Option<bool>,
    }

    let label_default = sift.has_labeler();

    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let line = line.map_err(|e| e.to_string())?;
        if line.trim().is_empty() {
            continue;
        }
        let out = match serde_json::from_str::<Req>(&line) {
            Err(e) => Err(format!("bad request: {e}")),
            Ok(req) => {
                sift.set_labeling(req.label.unwrap_or(label_default));
                match (req.path, req.text) {
                (Some(p), _) => {
                    let forced = match req.kind.as_str() {
                        "image" => Some(SourceKind::Image),
                        "file" => Some(SourceKind::File),
                        "string" => Some(SourceKind::String),
                        _ => None,
                    };
                    sift.classify_path(&p, forced)
                }
                    (None, Some(t)) => Ok(classify_string(sift, t.into_bytes())),
                    (None, None) => Err("request needs `text` or `path`".into()),
                }
            }
        };
        let json = match out {
            Ok(rec) => serde_json::to_string(&rec).map_err(|e| e.to_string())?,
            Err(e) => serde_json::json!({ "error": e }).to_string(),
        };
        println!("{json}");
        std::io::stdout().flush().ok();
    }
    Ok(())
}

fn classify_string(sift: &mut Sift, bytes: Vec<u8>) -> relic_sift::ClassificationRecord {
    sift.classify(&NormalizedItem {
        bytes,
        source_kind: SourceKind::String,
        declared_mime: None,
        origin: Origin::default(),
    })
}

fn doctor() -> Result<(), String> {
    let dir = models::model_dir();
    println!("sift doctor");
    println!("  model cache : {}", dir.display());
    let statuses = models::status(&dir);
    let mut all_present = true;
    for s in &statuses {
        println!(
            "  {:<24} {}",
            s.id,
            if s.present { format!("present ({:.1} MB)", s.bytes as f64 / 1e6) } else { "MISSING".into() }
        );
        all_present &= s.present;
    }
    let lab = models::labeler_status(&dir);
    println!(
        "  {:<24} {} (optional)",
        lab.id,
        if lab.present { format!("present ({:.1} MB)", lab.bytes as f64 / 1e6) } else { "not downloaded".into() }
    );
    if !all_present {
        println!("  → run `sift models download` (or any classify, which auto-downloads)");
    }

    print!("  loading pipeline … ");
    let mut sift = Sift::new(SiftConfig { model_dir: dir, ..Default::default() });
    println!(
        "ok (text-ml={}, image-ml={}, ocr={})",
        sift.has_text_model(),
        sift.has_image_model(),
        sift.has_ocr()
    );
    for w in &sift.warnings {
        println!("  warning: {w}");
    }

    // self-test: a secret, a url, and a tiny image must classify sanely
    let r = sift.classify(&NormalizedItem {
        bytes: b"AKIAIOSFODNN7EXAMPLE".to_vec(),
        source_kind: SourceKind::String,
        declared_mime: None,
        origin: Origin::default(),
    });
    check("secret detection", r.category.primary == "api_key")?;

    let r = sift.classify(&NormalizedItem {
        bytes: b"https://example.com/x".to_vec(),
        source_kind: SourceKind::String,
        declared_mime: None,
        origin: Origin::default(),
    });
    check("url detection", r.category.primary == "url")?;

    if sift.has_text_model() {
        let r = sift.classify(&NormalizedItem {
            bytes: b"hey are you coming tonight? we're meeting at 8".to_vec(),
            source_kind: SourceKind::String,
            declared_mime: None,
            origin: Origin::default(),
        });
        check(
            "text head",
            !r.category.scores.is_empty() && r.embeddings.text.is_some(),
        )?;
    }
    if sift.has_image_model() {
        // 64x64 mid-gray png built in-memory
        let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(
            64,
            64,
            image::Rgb([128, 128, 128]),
        ));
        let mut buf = std::io::Cursor::new(Vec::new());
        img.write_to(&mut buf, image::ImageFormat::Png).map_err(|e| e.to_string())?;
        let r = sift.classify(&NormalizedItem {
            bytes: buf.into_inner(),
            source_kind: SourceKind::Image,
            declared_mime: None,
            origin: Origin::default(),
        });
        check("image pipeline", !r.category.scores.is_empty())?;
    }
    // "All checks passed" next to a column of MISSING models reads like a
    // contradiction; say which mode the passing verdict is for.
    if sift.has_text_model() || sift.has_image_model() {
        println!("  all checks passed.");
    } else {
        println!(
            "  all checks passed (deterministic pipeline; no models downloaded — run `sift models download` for ML)."
        );
    }
    Ok(())
}

fn check(name: &str, ok: bool) -> Result<(), String> {
    println!("  self-test: {name} … {}", if ok { "ok" } else { "FAILED" });
    if ok {
        Ok(())
    } else {
        Err(format!("self-test failed: {name}"))
    }
}

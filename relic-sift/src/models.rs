//! Model registry (spec §8) + downloader. Downloads happen only here —
//! never on the classification hot path (spec §1). Every model is optional:
//! absent models degrade the pipeline gracefully (spec §1.6).
//!
//! Default registry (all redistributable — spec §15/§16.1):
//! - text embedding + classification head: EmbeddingGemma-300M int8 MRL-256
//!   (Gemma license); bge-small kept as an absent-Gemma fallback, not bundled
//! - image zero-shot: MobileCLIP2-S2 (fp16 vision); OpenAI CLIP present-only
//! - OCR: PP-OCRv6 (hand-rolled), ocrs detection+recognition as fallback

use std::fs;
use std::io::{Read, Write};
use std::path::PathBuf;

use serde::Serialize;

#[derive(Debug, Clone, Copy)]
pub struct ModelFile {
    pub name: &'static str,
    pub url: &'static str,
    pub min_bytes: u64,
}

#[derive(Debug, Clone, Copy)]
pub struct ModelSpec {
    pub id: &'static str,
    pub role: &'static str,
    pub version: &'static str,
    pub license: &'static str,
    pub files: &'static [ModelFile],
}

pub const BGE: ModelSpec = ModelSpec {
    id: "bge-small-en-v1.5",
    role: "text-embedding",
    version: "bge-small-en-v1.5@int8",
    license: "MIT",
    files: &[
        ModelFile {
            name: "bge-small-en-v1.5.int8.onnx",
            url: "https://models.relic.space/relic-sift/v1/bge-small-en-v1.5.int8.onnx",
            min_bytes: 10_000_000,
        },
        ModelFile {
            name: "bge-small-en-v1.5.tokenizer.json",
            url: "https://models.relic.space/relic-sift/v1/bge-small-en-v1.5.tokenizer.json",
            min_bytes: 100_000,
        },
    ],
};

/// EmbeddingGemma-300M int8 (MRL-256) — the upgraded text embedder (validated
/// in relic-sift-next: recall@1 0.757→0.973 over BGE on a hard retrieval set).
/// Weights live in an external-data file referenced *by basename* from the
/// graph, so the data file MUST be named exactly `model_quantized.onnx_data`
/// alongside the graph (ORT resolves it relative to the model dir).
pub const GEMMA: ModelSpec = ModelSpec {
    id: "embeddinggemma-300m",
    role: "text-embedding",
    version: "embeddinggemma-300m@int8-mrl256",
    license: "Gemma",
    files: &[
        ModelFile {
            name: "embeddinggemma-300m.int8.onnx",
            url: "https://models.relic.space/relic-sift/v1/embeddinggemma-300m.int8.onnx",
            min_bytes: 400_000,
        },
        ModelFile {
            name: "model_quantized.onnx_data",
            url: "https://models.relic.space/relic-sift/v1/model_quantized.onnx_data",
            min_bytes: 250_000_000,
        },
        ModelFile {
            name: "embeddinggemma-300m.tokenizer.json",
            url: "https://models.relic.space/relic-sift/v1/embeddinggemma-300m.tokenizer.json",
            min_bytes: 10_000_000,
        },
    ],
};

/// The active **search** embedding model (stored document vectors + query
/// vectors): prefer EmbeddingGemma when present, else BGE. Gemma's validated win
/// is retrieval, so it owns the search vector space (spec §1.6 selection).
pub fn text_embedding_spec(dir: &std::path::Path) -> &'static ModelSpec {
    if is_present(dir, &GEMMA) {
        &GEMMA
    } else {
        &BGE
    }
}

/// The **classification head** embedding model: EmbeddingGemma (classify prefix).
/// Validated better than BGE on the hard/diverse prose eval in relic-sift-next
/// (head accuracy 0.875→0.969; drives multi-label F1 0.509→0.861) and fixes the
/// todo_list/chat weak spots. The head prototypes were recalibrated for Gemma's
/// cosine space (see taxonomy.json: complex-SQL + product-CSV exemplars) so the
/// dev/holdout corpora still pass. Falls back to BGE only if Gemma is absent.
pub fn classifier_spec(dir: &std::path::Path) -> &'static ModelSpec {
    if is_present(dir, &GEMMA) {
        &GEMMA
    } else {
        &BGE
    }
}

pub const CLIP: ModelSpec = ModelSpec {
    id: "clip-vit-base-patch32",
    role: "image-zeroshot",
    version: "clip-vit-base-patch32@int8",
    license: "MIT",
    files: &[
        ModelFile {
            name: "clip-vit-base-patch32.int8.onnx",
            url: "https://huggingface.co/Xenova/clip-vit-base-patch32/resolve/main/onnx/model_quantized.onnx",
            min_bytes: 50_000_000,
        },
        ModelFile {
            name: "clip-vit-base-patch32.tokenizer.json",
            url: "https://huggingface.co/Xenova/clip-vit-base-patch32/resolve/main/tokenizer.json",
            min_bytes: 500_000,
        },
    ],
};

/// MobileCLIP2-S2 (Apple, open_clip / FastViT) — the upgraded image zero-shot
/// model (validated in relic-sift-next: top-1 0.783→0.913 over CLIP-B/32, and
/// faster). Dual-tower: a separate vision + text ONNX. The vision tower ships
/// fp16 (~72 MB, lossless — int8 collapses this architecture); the text tower
/// is fp32 but runs only at load to embed the taxonomy prompts (cached).
/// `files[0]`=vision, `files[1]`=text, `files[2]`=tokenizer.
pub const MOBILECLIP2: ModelSpec = ModelSpec {
    id: "mobileclip2-s2",
    role: "image-zeroshot",
    version: "mobileclip2-s2@fp16-vision",
    license: "Apple ASCL / MIT (open_clip)",
    files: &[
        ModelFile {
            name: "mobileclip2-s2.vision.onnx",
            url: "https://models.relic.space/relic-sift/v1/mobileclip2-s2.vision.onnx",
            min_bytes: 60_000_000,
        },
        ModelFile {
            name: "mobileclip2-s2.tokenizer.json",
            url: "https://models.relic.space/relic-sift/v1/mobileclip2-s2.tokenizer.json",
            min_bytes: 1_000_000,
        },
    ],
};

/// The MobileCLIP2 **text** tower — 254 MB of fp32 whose entire job is to embed
/// ~60 fixed taxonomy prompt strings once, after which only the cached
/// `[n_prompts × 512]` matrix is ever used.
///
/// So it is no longer in [`ALL`]. The default taxonomy's prompt embeddings ship
/// **baked into the binary** (`assets/mobileclip2-prompts.json`, ~350 KB,
/// generated by `sift prompts bake` through the exact same code path that would
/// compute them at runtime, so the bytes cannot drift). The tower is fetched
/// only when someone overrides `taxonomy.json` and the baked fingerprint no
/// longer matches — see [`needs_text_tower`].
pub const MOBILECLIP2_TEXT: ModelSpec = ModelSpec {
    id: "mobileclip2-s2-text",
    role: "image-prompt-encoder",
    version: "mobileclip2-s2@fp32-text",
    license: "Apple ASCL / MIT (open_clip)",
    files: &[ModelFile {
        name: "mobileclip2-s2.text.onnx",
        url: "https://models.relic.space/relic-sift/v1/mobileclip2-s2.text.onnx",
        min_bytes: 200_000_000,
    }],
};

/// Whether this install actually needs the 254 MB text tower: only when the
/// model dir carries a user `taxonomy.json`, since the built-in taxonomy's
/// prompt embeddings are baked into the binary.
pub fn needs_text_tower(dir: &std::path::Path) -> bool {
    dir.join("taxonomy.json").exists() && !is_present(dir, &MOBILECLIP2_TEXT)
}

/// The active image zero-shot model: prefer MobileCLIP2 when present, else CLIP.
pub fn image_spec(dir: &std::path::Path) -> &'static ModelSpec {
    if is_present(dir, &MOBILECLIP2) {
        &MOBILECLIP2
    } else {
        &CLIP
    }
}

/// Whether any image zero-shot model is available.
pub fn image_present(dir: &std::path::Path) -> bool {
    is_present(dir, &MOBILECLIP2) || is_present(dir, &CLIP)
}

pub const OCR: ModelSpec = ModelSpec {
    id: "ocrs",
    role: "ocr",
    version: "ocrs-2024",
    license: "permissive (robertknight/ocrs-models)",
    files: &[
        ModelFile {
            name: "ocrs-text-detection.rten",
            url: "https://models.relic.space/relic-sift/v1/ocrs-text-detection.rten",
            min_bytes: 1_000_000,
        },
        ModelFile {
            name: "ocrs-text-recognition.rten",
            url: "https://models.relic.space/relic-sift/v1/ocrs-text-recognition.rten",
            min_bytes: 1_000_000,
        },
    ],
};

/// PP-OCRv6 mobile (PaddleOCR via rapidocr) — the upgraded OCR engine
/// (validated in relic-sift-next: CER 0.084→0.030, WER 0.218→0.049 over ocrs,
/// and the Rust port reads API keys / receipts intact). `files`: det, rec, keys
/// — the 18,710-line CTC table (`["blank"] + dict + [" "]`), extracted offline
/// from the rec model's ONNX metadata. The pipeline keeps the always-present
/// ocrs engine as a fallback.
pub const OCR_V6: ModelSpec = ModelSpec {
    id: "ppocrv6-mobile",
    role: "ocr",
    version: "ppocrv6-mobile@small",
    license: "Apache-2.0 (PaddleOCR)",
    files: &[
        ModelFile {
            name: "ppocrv6-det.onnx",
            url: "https://models.relic.space/relic-sift/v1/ppocrv6-det.onnx",
            min_bytes: 5_000_000,
        },
        ModelFile {
            name: "ppocrv6-rec.onnx",
            url: "https://models.relic.space/relic-sift/v1/ppocrv6-rec.onnx",
            min_bytes: 15_000_000,
        },
        ModelFile {
            // The full CTC table (`["blank"] + dict + [" "]`), derived offline
            // from the rec model's "character" metadata and hosted on our mirror.
            name: "ppocrv6-keys.txt",
            url: "https://models.relic.space/relic-sift/v1/ppocrv6-keys.txt",
            min_bytes: 50_000,
        },
    ],
};

/// Whether the PP-OCRv6 engine is usable: det + rec + the keys table present.
pub fn ocr_v6_present(dir: &std::path::Path) -> bool {
    OCR_V6
        .files
        .iter()
        .all(|f| fs::metadata(file_path(dir, f)).map(|m| m.len() >= f.min_bytes).unwrap_or(false))
}

/// Qwen3.5-0.8B (Apache-2.0) — the **open-vocabulary labeler** that replaces
/// Florence-2's enrichment slot. Where Florence only captioned images, this one
/// labels text *and* images with a human-readable title plus free-form topical
/// tags, which is the thing a closed `taxonomy.json` structurally cannot emit.
///
/// Three q4f16 ONNX components, each with its weights in an **external data
/// file**. ORT resolves that sidecar by the basename recorded inside the graph,
/// relative to the graph's directory, so the `.onnx_data` names below are NOT
/// free to change — they must stay exactly as exported (same constraint as
/// Gemma's `model_quantized.onnx_data`). The `.onnx` graphs themselves are
/// loaded by path and so are renamed to our `qwen35-*` convention.
///
/// Mirrored on our R2 rather than fetched from HuggingFace, for the same reason
/// the ONNX Runtime is: a 666 MB first-run download should not depend on a third
/// party's availability or rate limits. See `scripts/mirror-large-model/` — the
/// 416 MiB decoder weights exceed what `wrangler r2 object put` will accept.
///
/// NOT in `ALL`: ~666 MB, downloaded on demand the first time labeling is used.
pub const QWEN35: ModelSpec = ModelSpec {
    id: "qwen3.5-0.8b",
    role: "vision-language (labeling)",
    version: "qwen3.5-0.8b@q4f16",
    license: "Apache-2.0",
    files: &[
        ModelFile {
            name: "qwen35-decoder-merged.q4f16.onnx",
            url: "https://models.relic.space/relic-sift/v1/qwen35-decoder-merged.q4f16.onnx",
            min_bytes: 1_000_000,
        },
        ModelFile {
            name: "decoder_model_merged_q4f16.onnx_data",
            url: "https://models.relic.space/relic-sift/v1/decoder_model_merged_q4f16.onnx_data",
            min_bytes: 430_000_000,
        },
        ModelFile {
            name: "qwen35-embed-tokens.q4f16.onnx",
            url: "https://models.relic.space/relic-sift/v1/qwen35-embed-tokens.q4f16.onnx",
            min_bytes: 1_000,
        },
        ModelFile {
            name: "embed_tokens_q4f16.onnx_data",
            url: "https://models.relic.space/relic-sift/v1/embed_tokens_q4f16.onnx_data",
            min_bytes: 145_000_000,
        },
        ModelFile {
            name: "qwen35-vision-encoder.q4f16.onnx",
            url: "https://models.relic.space/relic-sift/v1/qwen35-vision-encoder.q4f16.onnx",
            min_bytes: 200_000,
        },
        ModelFile {
            name: "vision_encoder_q4f16.onnx_data",
            url: "https://models.relic.space/relic-sift/v1/vision_encoder_q4f16.onnx_data",
            min_bytes: 60_000_000,
        },
        ModelFile {
            name: "qwen35-tokenizer.json",
            url: "https://models.relic.space/relic-sift/v1/qwen35-tokenizer.json",
            min_bytes: 18_000_000,
        },
    ],
};

/// Index of each [`QWEN35`] file, so call sites don't hard-code positions.
pub mod qwen35_files {
    pub const DECODER: usize = 0;
    pub const EMBED: usize = 2;
    pub const VISION: usize = 4;
    pub const TOKENIZER: usize = 6;
}

/// Default model set fetched by `sift models download`. The upgraded stack:
/// EmbeddingGemma (search vectors **and** the classification head) + MobileCLIP2
/// (image zero-shot) + PP-OCRv6 (OCR), with ocrs kept as the OCR fallback. BGE is
/// no longer bundled — Gemma owns both the head and search — but its spec is kept
/// as the absent-Gemma fallback and it's still used if already present from an
/// older install (graceful selection — spec §1.6). CLIP is likewise present-only.
/// The OCR keys table is mirrored alongside the det/rec graphs, so PP-OCRv6 is
/// self-contained; `ocrs` stays in the set as the always-available fallback, and
/// image OCR therefore survives PP-OCRv6 failing to load at all.
pub const ALL: &[&ModelSpec] = &[&GEMMA, &MOBILECLIP2, &OCR_V6, &OCR];

/// ONNX Runtime itself is loaded dynamically (`ort` feature `load-dynamic`),
/// so the shared library is fetched like a model — from our R2 mirror (the
/// CPU library + on Windows its providers-shared companion), no GitHub/HF
/// dependency. The name is per-platform; version must match the `ort` crate's
/// pinned API level (`api-24` ⇒ 1.24.x).
pub const ORT_VERSION: &str = "1.24.2";
#[cfg(target_os = "windows")]
pub const ORT_DLL: &str = "onnxruntime.dll";
#[cfg(target_os = "macos")]
pub const ORT_DLL: &str = "libonnxruntime.dylib";
#[cfg(not(any(target_os = "windows", target_os = "macos")))]
pub const ORT_DLL: &str = "libonnxruntime.so";
const ORT_SHARED_DLL: &str = "onnxruntime_providers_shared.dll";

/// Public R2 mirror base for the default model stack + runtime. Served via the
/// custom domain (Cloudflare-cached, no r2.dev rate limits).
pub const MIRROR_BASE: &str = "https://models.relic.space/relic-sift/v1";

pub fn ort_dll_path(dir: &std::path::Path) -> PathBuf {
    dir.join(ORT_DLL)
}

pub fn ort_present(dir: &std::path::Path) -> bool {
    fs::metadata(ort_dll_path(dir)).map(|m| m.len() > 1_000_000).unwrap_or(false)
}

/// The runtime shipped beside the running executable — a packaged install
/// (the macOS .app bundles the dylib next to sift) needs no download.
/// pipeline::init_ort loads from the same spot.
pub fn ort_beside_exe() -> Option<PathBuf> {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|d| d.join(ORT_DLL)))
        .filter(|p| fs::metadata(p).map(|m| m.len() > 1_000_000).unwrap_or(false))
}

/// Whether ANY usable runtime exists (model cache or beside the executable).
/// Gates both `models download` (skip the fetch) and `models status`.
pub fn runtime_available(dir: &std::path::Path) -> bool {
    ort_present(dir) || ort_beside_exe().is_some()
}

/// Download the onnxruntime shared library from the R2 mirror. Windows x64
/// gets the CPU dll + its providers-shared companion; macOS arm64 and Linux
/// x64 each get a single library staged under their own prefix on the same
/// mirror (`macos-arm64/`, `linux-x64/`; uploaded by
/// app/scripts/build_release_macos.sh --stage-ort and
/// app/scripts/build_release_linux.sh --stage-ort). On any other target, point
/// `ORT_DYLIB_PATH` at a system onnxruntime instead.
pub fn download_runtime(dir: &std::path::Path, quiet: bool) -> Result<(), String> {
    if runtime_available(dir) {
        return Ok(());
    }
    let win_x64 = cfg!(all(target_os = "windows", target_arch = "x86_64"));
    let mac_arm64 = cfg!(all(target_os = "macos", target_arch = "aarch64"));
    let linux_x64 = cfg!(all(target_os = "linux", target_arch = "x86_64"));
    if !win_x64 && !mac_arm64 && !linux_x64 {
        return Err(format!(
            "automatic onnxruntime download supports win-x64, macos-arm64 and linux-x64; put the library at {} or set ORT_DYLIB_PATH",
            ort_dll_path(dir).display()
        ));
    }
    fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    if !quiet {
        eprintln!("downloading onnxruntime {ORT_VERSION} …");
    }
    if win_x64 {
        for (dll, min) in [(ORT_DLL, 1_000_000u64), (ORT_SHARED_DLL, 10_000)] {
            let url = format!("{MIRROR_BASE}/{dll}");
            fetch(&url, &dir.join(dll), min, quiet).map_err(|e| format!("download {url}: {e}"))?;
        }
    } else {
        let prefix = if mac_arm64 { "macos-arm64" } else { "linux-x64" };
        let url = format!("{MIRROR_BASE}/{prefix}/{ORT_DLL}");
        fetch(&url, &dir.join(ORT_DLL), 1_000_000, quiet)
            .map_err(|e| format!("download {url}: {e}"))?;
    }
    if !ort_present(dir) {
        return Err(format!("onnxruntime download did not produce {ORT_DLL}"));
    }
    if !quiet {
        eprintln!("  onnxruntime ready.");
    }
    Ok(())
}

/// Model cache directory: `RELIC_SIFT_HOME` override, else
/// `%LOCALAPPDATA%\relic-sift\models` (or `~/.cache/relic-sift/models`).
pub fn model_dir() -> PathBuf {
    if let Ok(home) = std::env::var("RELIC_SIFT_HOME") {
        return PathBuf::from(home).join("models");
    }
    let base = std::env::var("LOCALAPPDATA")
        .map(PathBuf::from)
        .or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".cache")))
        .unwrap_or_else(|_| PathBuf::from("."));
    base.join("relic-sift").join("models")
}

pub fn file_path(dir: &std::path::Path, f: &ModelFile) -> PathBuf {
    dir.join(f.name)
}

pub fn is_present(dir: &std::path::Path, spec: &ModelSpec) -> bool {
    spec.files.iter().all(|f| {
        fs::metadata(file_path(dir, f)).map(|m| m.len() >= f.min_bytes).unwrap_or(false)
    })
}

/// Files from model generations we no longer ship. An install that predates the
/// Qwen3.5 labeler keeps ~235 MB of Florence-2 on disk that nothing can load
/// again — plus, if that install ever enabled the DirectML path, a `dml/`
/// directory holding a second ONNX Runtime and a 170 MB fp16 vision graph.
///
/// This is an explicit list rather than "anything the registry doesn't name".
/// The model dir also holds `taxonomy.json`, the prompt/head caches and the
/// runtime DLLs, none of which are `ModelFile`s; an allowlist rule would delete
/// user data the first time someone put an unmodelled file here.
pub const RETIRED_FILES: &[&str] = &[
    // Florence-2 — replaced by Qwen3.5, which labels text as well as images.
    "florence2-decoder-merged.int8.onnx",
    "florence2-encoder.int8.onnx",
    "florence2-embed-tokens.int8.onnx",
    "florence2-vision-encoder.q4f16.onnx",
    "florence2-vision-encoder.fp16.onnx",
    "florence2-tokenizer.json",
];

/// Subdirectories of the model dir that are retired wholesale. `dml/` held the
/// DirectML-enabled `onnxruntime.dll` for Florence's vision tower.
pub const RETIRED_DIRS: &[&str] = &["dml"];

/// One file removed by [`prune`].
#[derive(Debug, Serialize)]
pub struct PrunedFile {
    pub name: String,
    pub bytes: u64,
    /// Why it went: `retired` (nothing can load it) or `redundant` (a live
    /// fallback that this install will never reach, re-downloadable on demand).
    pub reason: &'static str,
}

/// Delete model files this install can no longer use.
///
/// Default: only [`RETIRED_FILES`] / [`RETIRED_DIRS`] — dead weight by
/// definition, so this is safe to run unattended on upgrade.
///
/// `deep` additionally drops present-but-unreachable fallbacks: CLIP when
/// MobileCLIP2 is installed, BGE when Gemma is, and the MobileCLIP2 text tower
/// when no user `taxonomy.json` needs it. Each is re-downloadable, but each is
/// a deliberate fallback, so removing them is opt-in rather than automatic.
pub fn prune(dir: &std::path::Path, deep: bool, dry_run: bool) -> Vec<PrunedFile> {
    let mut out = Vec::new();
    let mut take = |name: String, reason: &'static str| {
        let path = dir.join(&name);
        let Ok(meta) = fs::metadata(&path) else { return };
        let bytes = if meta.is_dir() { dir_bytes(&path) } else { meta.len() };
        if !dry_run {
            let removed =
                if meta.is_dir() { fs::remove_dir_all(&path) } else { fs::remove_file(&path) };
            if removed.is_err() {
                return;
            }
        }
        out.push(PrunedFile { name, bytes, reason });
    };

    for name in RETIRED_FILES {
        take((*name).to_string(), "retired");
    }
    for name in RETIRED_DIRS {
        take((*name).to_string(), "retired");
    }
    if deep {
        // Only ever drop the fallback while its replacement is actually usable.
        if is_present(dir, &MOBILECLIP2) {
            for f in CLIP.files {
                take(f.name.to_string(), "redundant");
            }
        }
        if is_present(dir, &GEMMA) {
            for f in BGE.files {
                take(f.name.to_string(), "redundant");
            }
        }
        if !dir.join("taxonomy.json").exists() {
            for f in MOBILECLIP2_TEXT.files {
                take(f.name.to_string(), "redundant");
            }
        }
    }
    out
}

fn dir_bytes(dir: &std::path::Path) -> u64 {
    let Ok(entries) = fs::read_dir(dir) else { return 0 };
    entries
        .filter_map(|e| e.ok())
        .map(|e| match e.metadata() {
            Ok(m) if m.is_dir() => dir_bytes(&e.path()),
            Ok(m) => m.len(),
            Err(_) => 0,
        })
        .sum()
}

#[derive(Debug, Serialize)]
pub struct ModelStatus {
    pub id: String,
    pub role: String,
    pub present: bool,
    pub bytes: u64,
    pub license: String,
}

pub fn status(dir: &std::path::Path) -> Vec<ModelStatus> {
    let runtime_path =
        if ort_present(dir) { ort_dll_path(dir) } else { ort_beside_exe().unwrap_or_else(|| ort_dll_path(dir)) };
    let runtime = ModelStatus {
        id: format!("onnxruntime-{ORT_VERSION}"),
        role: "inference-runtime".into(),
        present: runtime_available(dir),
        bytes: fs::metadata(&runtime_path).map(|m| m.len()).unwrap_or(0),
        license: "MIT".into(),
    };
    std::iter::once(runtime).chain(model_status(dir)).collect()
}

fn model_status(dir: &std::path::Path) -> impl Iterator<Item = ModelStatus> + '_ {
    ALL.iter()
        .map(|spec| {
            let bytes = spec
                .files
                .iter()
                .filter_map(|f| fs::metadata(file_path(dir, f)).ok().map(|m| m.len()))
                .sum();
            ModelStatus {
                id: spec.id.into(),
                role: spec.role.into(),
                present: is_present(dir, spec),
                bytes,
                license: spec.license.into(),
            }
        })
}

/// Download every missing file of `spec` into `dir`. Atomic per file
/// (`.part` then rename); size-validated.
pub fn download(dir: &std::path::Path, spec: &ModelSpec, quiet: bool) -> Result<(), String> {
    fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    for f in spec.files {
        let dest = file_path(dir, f);
        if fs::metadata(&dest).map(|m| m.len() >= f.min_bytes).unwrap_or(false) {
            continue;
        }
        if f.url.is_empty() {
            // Provisioned out of band (e.g. the OCR keys table, derived from the
            // rec model's metadata) — not a fetchable artifact.
            continue;
        }
        if !quiet {
            eprintln!("downloading {} …", f.name);
        }
        fetch(f.url, &dest, f.min_bytes, quiet)
            .map_err(|e| format!("download {}: {e}", f.url))?;
    }
    Ok(())
}

pub fn download_all(dir: &std::path::Path, quiet: bool) -> Result<(), String> {
    download_runtime(dir, quiet)?;
    for spec in ALL {
        download(dir, spec, quiet)?;
    }
    // The MobileCLIP2 text tower is 254 MB whose only job is embedding the
    // taxonomy's prompt strings, and the built-in taxonomy's embeddings ship
    // baked into the binary. So it is fetched only for a custom taxonomy.
    if needs_text_tower(dir) {
        if !quiet {
            eprintln!(
                "custom taxonomy.json detected — fetching the MobileCLIP2 text tower \
                 to embed its prompts"
            );
        }
        download(dir, &MOBILECLIP2_TEXT, quiet)?;
    }
    Ok(())
}

/// Download the optional Qwen3.5 labeler (and the runtime, in case labeling is
/// the only thing ever run). Separate from `download_all` so the default setup
/// stays small.
pub fn download_labeler(dir: &std::path::Path, quiet: bool) -> Result<(), String> {
    download_runtime(dir, quiet)?;
    download(dir, &QWEN35, quiet)
}

/// Status of the optional labeler (not part of the default `ALL`, so it never
/// forces the first-run download of the core set).
pub fn labeler_status(dir: &std::path::Path) -> ModelStatus {
    let bytes = QWEN35
        .files
        .iter()
        .filter_map(|f| fs::metadata(file_path(dir, f)).ok().map(|m| m.len()))
        .sum();
    ModelStatus {
        id: QWEN35.id.into(),
        role: QWEN35.role.into(),
        present: is_present(dir, &QWEN35),
        bytes,
        license: QWEN35.license.into(),
    }
}

fn fetch(url: &str, dest: &std::path::Path, min_bytes: u64, quiet: bool) -> Result<(), String> {
    let mut resp = ureq::get(url).call().map_err(|e| e.to_string())?;
    let total: Option<u64> = resp
        .headers()
        .get("content-length")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse().ok());
    let part = dest.with_extension("part");
    let mut out = fs::File::create(&part).map_err(|e| e.to_string())?;
    let mut reader = resp.body_mut().as_reader();
    let mut buf = vec![0u8; 1 << 16];
    let mut done: u64 = 0;
    let mut last_pct = 0;
    loop {
        let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        done += n as u64;
        if !quiet {
            if let Some(total) = total {
                let pct = (done * 100 / total.max(1)) as u32;
                if pct >= last_pct + 10 {
                    last_pct = pct;
                    eprintln!("  {pct}% ({:.1} / {:.1} MB)", done as f64 / 1e6, total as f64 / 1e6);
                }
            }
        }
    }
    out.flush().map_err(|e| e.to_string())?;
    drop(out);
    if done < min_bytes {
        let _ = fs::remove_file(&part);
        return Err(format!("file too small ({done} bytes, expected ≥ {min_bytes})"));
    }
    fs::rename(&part, dest).map_err(|e| e.to_string())?;
    if !quiet {
        eprintln!("  done ({:.1} MB)", done as f64 / 1e6);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sift-prune-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(dir: &std::path::Path, name: &str, len: usize) {
        let path = dir.join(name);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, vec![0u8; len]).unwrap();
    }

    #[test]
    fn prune_removes_florence_and_the_dml_dir() {
        let dir = scratch("florence");
        write(&dir, "florence2-encoder.int8.onnx", 32);
        write(&dir, "florence2-tokenizer.json", 8);
        write(&dir, "dml/onnxruntime.dll", 64);

        let removed = prune(&dir, false, false);
        let freed: u64 = removed.iter().map(|f| f.bytes).sum();

        assert_eq!(removed.len(), 3, "{removed:?}");
        assert_eq!(freed, 104, "dml/ must be counted recursively, not as 0");
        assert!(removed.iter().all(|f| f.reason == "retired"));
        assert!(!dir.join("dml").exists());
        assert!(!dir.join("florence2-encoder.int8.onnx").exists());
        fs::remove_dir_all(&dir).unwrap();
    }

    /// The model dir holds files no `ModelSpec` names. Prune must never touch
    /// them — this is why the retired set is an explicit list and not "delete
    /// anything unrecognised".
    #[test]
    fn prune_leaves_unmodelled_files_alone() {
        let dir = scratch("unmodelled");
        for name in ["taxonomy.json", "image-prompt-cache.json", "text-head-cache.json",
                     "onnxruntime.dll", "onnxruntime_providers_shared.dll", "notes-from-a-user.txt"] {
            write(&dir, name, 4);
        }
        write(&dir, "florence2-tokenizer.json", 4);

        let removed = prune(&dir, true, false);

        assert_eq!(removed.len(), 1);
        assert_eq!(removed[0].name, "florence2-tokenizer.json");
        for name in ["taxonomy.json", "image-prompt-cache.json", "text-head-cache.json",
                     "onnxruntime.dll", "onnxruntime_providers_shared.dll", "notes-from-a-user.txt"] {
            assert!(dir.join(name).exists(), "{name} was deleted");
        }
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn dry_run_reports_without_deleting() {
        let dir = scratch("dry");
        write(&dir, "florence2-encoder.int8.onnx", 16);

        let removed = prune(&dir, false, true);

        assert_eq!(removed.len(), 1);
        assert_eq!(removed[0].bytes, 16);
        assert!(dir.join("florence2-encoder.int8.onnx").exists(), "dry run deleted the file");
        fs::remove_dir_all(&dir).unwrap();
    }

    /// A fallback is only redundant while its replacement is usable. With
    /// MobileCLIP2 absent, CLIP is the only image model there is.
    #[test]
    fn deep_prune_keeps_the_fallback_when_its_replacement_is_missing() {
        let dir = scratch("fallback");
        for f in CLIP.files {
            write(&dir, f.name, f.min_bytes as usize + 1);
        }

        let removed = prune(&dir, true, false);

        assert!(removed.is_empty(), "{removed:?}");
        assert!(CLIP.files.iter().all(|f| dir.join(f.name).exists()));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn deep_prune_drops_the_fallback_once_the_replacement_is_installed() {
        let dir = scratch("replaced");
        for f in CLIP.files {
            write(&dir, f.name, f.min_bytes as usize + 1);
        }
        for f in MOBILECLIP2.files {
            write(&dir, f.name, f.min_bytes as usize + 1);
        }

        let removed = prune(&dir, true, false);

        assert_eq!(removed.len(), CLIP.files.len(), "{removed:?}");
        assert!(removed.iter().all(|f| f.reason == "redundant"));
        assert!(MOBILECLIP2.files.iter().all(|f| dir.join(f.name).exists()));
        fs::remove_dir_all(&dir).unwrap();
    }

    /// The text tower is 242 MB that only a user-supplied taxonomy needs.
    #[test]
    fn deep_prune_keeps_the_text_tower_when_a_user_taxonomy_needs_it() {
        let dir = scratch("taxonomy");
        write(&dir, "taxonomy.json", 4);
        for f in MOBILECLIP2_TEXT.files {
            write(&dir, f.name, 8);
        }

        assert!(prune(&dir, true, false).is_empty());
        assert!(dir.join("mobileclip2-s2.text.onnx").exists());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn prune_is_idempotent_and_quiet_on_a_clean_dir() {
        let dir = scratch("clean");
        write(&dir, "florence2-encoder.int8.onnx", 16);

        assert_eq!(prune(&dir, true, false).len(), 1);
        assert!(prune(&dir, true, false).is_empty(), "second run must be a no-op");
        fs::remove_dir_all(&dir).unwrap();
    }
}

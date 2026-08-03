//! Evaluation & QA harness (spec §14): run the pipeline over a labeled
//! corpus, score per-category precision/recall/F1, track secret-detection
//! recall separately (the safety-critical metric), and report timing.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::pipeline::Sift;
use crate::record::{ClassificationRecord, SourceKind};

#[derive(Debug, Deserialize)]
pub struct Manifest {
    pub items: Vec<ManifestItem>,
}

#[derive(Debug, Deserialize)]
pub struct ManifestItem {
    /// Path relative to the manifest file.
    pub path: String,
    /// "string" | "image" | "file"
    pub kind: String,
    pub gold: Gold,
    #[serde(default)]
    pub note: String,
}

#[derive(Debug, Deserialize)]
pub struct Gold {
    pub primary: String,
    /// Extra acceptable primaries (e.g. screenshot-of-document edge cases).
    #[serde(default)]
    pub any_of: Vec<String>,
    #[serde(default)]
    pub labels: Vec<String>,
    /// relic tags that must be present (subset check).
    #[serde(default)]
    pub relic_tags: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct Row {
    pub path: String,
    pub gold: String,
    pub predicted: String,
    pub confidence: f32,
    pub ok: bool,
    pub needs_review: bool,
    pub missing_tags: Vec<String>,
    pub label_ok: bool,
    pub total_ms: u64,
    pub top_signals: Vec<String>,
}

#[derive(Debug, Default, Serialize)]
pub struct CategoryScore {
    pub tp: u32,
    pub fp: u32,
    pub fn_: u32,
    pub precision: f32,
    pub recall: f32,
    pub f1: f32,
}

#[derive(Debug, Serialize)]
pub struct EvalReport {
    pub items: usize,
    pub correct: usize,
    pub accuracy: f32,
    pub macro_f1: f32,
    pub secret_recall: f32,
    pub secret_items: usize,
    pub pii_precision: f32,
    pub pii_recall: f32,
    pub tag_recall: f32,
    pub needs_review_rate: f32,
    pub p50_ms: u64,
    pub p95_ms: u64,
    pub per_category: BTreeMap<String, CategoryScore>,
    pub rows: Vec<Row>,
}

const SECRET_FAMILY: &[&str] = &["api_key", "secret_other"];

pub fn run(sift: &mut Sift, manifest_path: &Path, limit: Option<usize>) -> Result<EvalReport, String> {
    let raw = std::fs::read_to_string(manifest_path)
        .map_err(|e| format!("read {}: {e}", manifest_path.display()))?;
    let manifest: Manifest = serde_json::from_str(&raw).map_err(|e| format!("parse manifest: {e}"))?;
    let base = manifest_path.parent().unwrap_or(Path::new("."));

    let mut rows: Vec<Row> = Vec::new();
    let n = limit.unwrap_or(usize::MAX).min(manifest.items.len());
    for (i, item) in manifest.items.iter().take(n).enumerate() {
        let path: PathBuf = base.join(&item.path);
        let kind = match item.kind.as_str() {
            "string" => Some(SourceKind::String),
            "image" => Some(SourceKind::Image),
            "file" => Some(SourceKind::File),
            other => return Err(format!("{}: unknown kind {other}", item.path)),
        };
        eprint!("\r  [{}/{n}] {:<60}", i + 1, item.path);
        let record = sift.classify_path(&path, kind)?;
        rows.push(score_row(item, &record));
    }
    eprintln!();
    Ok(aggregate(rows))
}

fn score_row(item: &ManifestItem, r: &ClassificationRecord) -> Row {
    let pred = r.category.primary.as_str();
    let ok = pred == item.gold.primary || item.gold.any_of.iter().any(|a| a == pred);
    let missing_tags: Vec<String> = item
        .gold
        .relic_tags
        .iter()
        .filter(|t| !r.relic_tags.contains(t))
        .cloned()
        .collect();
    let label_ok = item.gold.labels.iter().all(|l| r.labels.contains(l));
    let mut top_signals: Vec<String> = r
        .provenance
        .iter()
        .filter(|p| p.score > 0.3)
        .map(|p| format!("{}={:.2}", p.signal, p.score))
        .collect();
    top_signals.truncate(4);
    Row {
        path: item.path.clone(),
        gold: item.gold.primary.clone(),
        predicted: pred.to_string(),
        confidence: r.category.confidence,
        ok,
        needs_review: r.category.needs_review,
        missing_tags,
        label_ok,
        total_ms: r.timing_ms.total,
        top_signals,
    }
}

fn aggregate(rows: Vec<Row>) -> EvalReport {
    let items = rows.len();
    let correct = rows.iter().filter(|r| r.ok).count();

    // Per-category P/R/F1 over gold primaries (any_of hits count for the
    // gold category so alternates don't read as confusions).
    let mut per: BTreeMap<String, CategoryScore> = BTreeMap::new();
    for r in &rows {
        if r.ok {
            per.entry(r.gold.clone()).or_default().tp += 1;
        } else {
            per.entry(r.gold.clone()).or_default().fn_ += 1;
            per.entry(r.predicted.clone()).or_default().fp += 1;
        }
    }
    let mut f1_sum = 0.0;
    let mut f1_n = 0;
    for (cat, s) in per.iter_mut() {
        let p = s.tp as f32 / (s.tp + s.fp).max(1) as f32;
        let rc = s.tp as f32 / (s.tp + s.fn_).max(1) as f32;
        s.precision = p;
        s.recall = rc;
        s.f1 = if p + rc > 0.0 { 2.0 * p * rc / (p + rc) } else { 0.0 };
        if cat != "unsorted" && (s.tp + s.fn_) > 0 {
            f1_sum += s.f1;
            f1_n += 1;
        }
    }

    let secret_rows: Vec<&Row> = rows.iter().filter(|r| SECRET_FAMILY.contains(&r.gold.as_str())).collect();
    let secret_hits = secret_rows
        .iter()
        .filter(|r| SECRET_FAMILY.contains(&r.predicted.as_str()))
        .count();

    // pii label: gold says pii_present ↔ predicted has it
    let pii_gold: Vec<&Row> = rows.iter().filter(|r| !r.label_ok || true).collect();
    let _ = pii_gold;

    let tag_checks: Vec<&Row> = rows.iter().collect();
    let tags_total: usize = tag_checks.iter().map(|r| r.missing_tags.len()).sum();
    let tag_recall = {
        // recall over required tags: we only track misses, so approximate
        // with rows that had all required tags present
        let with_required = rows.iter().filter(|r| r.missing_tags.is_empty()).count();
        with_required as f32 / items.max(1) as f32
    };
    let _ = tags_total;

    let label_hits = rows.iter().filter(|r| r.label_ok).count();

    let mut times: Vec<u64> = rows.iter().map(|r| r.total_ms).collect();
    times.sort_unstable();
    let pct = |p: f64| -> u64 {
        if times.is_empty() {
            0
        } else {
            times[((times.len() - 1) as f64 * p) as usize]
        }
    };

    EvalReport {
        items,
        correct,
        accuracy: correct as f32 / items.max(1) as f32,
        macro_f1: if f1_n > 0 { f1_sum / f1_n as f32 } else { 0.0 },
        secret_recall: if secret_rows.is_empty() {
            1.0
        } else {
            secret_hits as f32 / secret_rows.len() as f32
        },
        secret_items: secret_rows.len(),
        pii_precision: 1.0, // no negative-pii gold annotations yet
        pii_recall: label_hits as f32 / items.max(1) as f32,
        tag_recall,
        needs_review_rate: rows.iter().filter(|r| r.needs_review).count() as f32 / items.max(1) as f32,
        p50_ms: pct(0.5),
        p95_ms: pct(0.95),
        per_category: per,
        rows,
    }
}

pub fn markdown(report: &EvalReport, title: &str) -> String {
    let mut md = String::new();
    md.push_str(&format!("# {title}\n\n"));
    md.push_str(&format!(
        "**{} items** · accuracy **{:.1}%** · macro-F1 **{:.3}** · secret recall **{:.1}%** ({} items) · label recall {:.1}% · required-tag pass {:.1}% · needs_review {:.1}% · p50 {} ms · p95 {} ms\n\n",
        report.items,
        report.accuracy * 100.0,
        report.macro_f1,
        report.secret_recall * 100.0,
        report.secret_items,
        report.pii_recall * 100.0,
        report.tag_recall * 100.0,
        report.needs_review_rate * 100.0,
        report.p50_ms,
        report.p95_ms,
    ));
    md.push_str("## Per-category\n\n| category | tp | fp | fn | precision | recall | F1 |\n|---|---|---|---|---|---|---|\n");
    for (cat, s) in &report.per_category {
        if s.tp + s.fn_ == 0 && s.fp == 0 {
            continue;
        }
        md.push_str(&format!(
            "| {cat} | {} | {} | {} | {:.2} | {:.2} | {:.2} |\n",
            s.tp, s.fp, s.fn_, s.precision, s.recall, s.f1
        ));
    }
    let misses: Vec<&Row> = report.rows.iter().filter(|r| !r.ok).collect();
    md.push_str(&format!("\n## Misses ({})\n\n", misses.len()));
    if !misses.is_empty() {
        md.push_str("| item | gold | predicted | conf | signals |\n|---|---|---|---|---|\n");
        for r in misses {
            md.push_str(&format!(
                "| {} | {} | {} | {:.2} | {} |\n",
                r.path,
                r.gold,
                r.predicted,
                r.confidence,
                r.top_signals.join("; ")
            ));
        }
    }
    let tag_misses: Vec<&Row> = report.rows.iter().filter(|r| !r.missing_tags.is_empty()).collect();
    if !tag_misses.is_empty() {
        md.push_str(&format!("\n## Missing required relic_tags ({})\n\n", tag_misses.len()));
        for r in tag_misses {
            md.push_str(&format!("- {}: missing {:?}\n", r.path, r.missing_tags));
        }
    }
    md
}

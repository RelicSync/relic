//! Stage B — small local ML classifiers (spec §6). All models are quantized
//! ONNX on ONNX Runtime (spec §1.3); each is optional and absence lowers
//! confidence instead of failing (spec §1.6).

pub mod encoder;
pub mod image;
pub mod qwen35;
pub mod text;

/// Build an ONNX Runtime session with our standard options. The small Stage-B
/// models (bge, CLIP) are fast; 2 intra-op threads keeps them light.
pub(crate) fn make_session(path: &std::path::Path) -> Result<ort::session::Session, String> {
    make_session_threads(path, 2)
}

/// Build a session with an explicit intra-op thread count. The Qwen3.5 labeler
/// is bandwidth-bound on weight dequant rather than compute-bound, so its count
/// is tuned (6) rather than maximal — see `qwen35::THREADS`.
pub(crate) fn make_session_threads(
    path: &std::path::Path,
    threads: usize,
) -> Result<ort::session::Session, String> {
    ort::session::Session::builder()
        .map_err(|e| e.to_string())?
        .with_optimization_level(ort::session::builder::GraphOptimizationLevel::Level3)
        .map_err(|e| e.to_string())?
        .with_intra_threads(threads.max(1))
        .map_err(|e| e.to_string())?
        .commit_from_file(path)
        .map_err(|e| format!("load {}: {e}", path.display()))
}

/// Extract an f32 tensor from an ort output as (shape, flat data).
pub(crate) fn extract_f32(
    value: &ort::value::Value,
) -> Result<(Vec<usize>, Vec<f32>), ort::Error> {
    let (shape, data) = value.try_extract_tensor::<f32>()?;
    Ok((shape.iter().map(|&d| d as usize).collect(), data.to_vec()))
}

pub(crate) fn softmax(xs: &[f32]) -> Vec<f32> {
    let max = xs.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
    let exps: Vec<f32> = xs.iter().map(|x| (x - max).exp()).collect();
    let sum: f32 = exps.iter().sum();
    exps.iter().map(|e| e / sum.max(1e-12)).collect()
}

pub(crate) fn l2_normalize(v: &mut [f32]) {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-12);
    for x in v {
        *x /= norm;
    }
}

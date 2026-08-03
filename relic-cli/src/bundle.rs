//! Bundle packing: multiple attachments concatenated into one blob, sliced back
//! apart using the manifest (`Attachment.size` gives each part's length).
//! Mirrors `app/lib/data/bundle.dart` so bundles interoperate with the app.

use crate::models::Attachment;

/// Concatenate attachment payloads in manifest order.
pub fn pack(parts: &[Vec<u8>]) -> Vec<u8> {
    let total: usize = parts.iter().map(Vec::len).sum();
    let mut out = Vec::with_capacity(total);
    for p in parts {
        out.extend_from_slice(p);
    }
    out
}

/// Slice one attachment's bytes out of `bundle` by manifest order. Returns
/// `None` if the id isn't in the manifest or the manifest overruns the bundle.
pub fn slice<'a>(bundle: &'a [u8], manifest: &[Attachment], id: &str) -> Option<&'a [u8]> {
    let mut off = 0usize;
    for a in manifest {
        let size = a.size as usize;
        if a.id == id {
            return if off + size <= bundle.len() { Some(&bundle[off..off + size]) } else { None };
        }
        off += size;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn att(id: &str, size: u64) -> Attachment {
        Attachment { id: id.into(), name: format!("{id}.bin"), mime: None, size }
    }

    #[test]
    fn pack_then_slice_round_trips() {
        let parts = vec![b"AAA".to_vec(), b"BBBB".to_vec(), b"C".to_vec()];
        let manifest = vec![att("a", 3), att("b", 4), att("c", 1)];
        let bundle = pack(&parts);
        assert_eq!(bundle, b"AAABBBBC");
        assert_eq!(slice(&bundle, &manifest, "a"), Some(&b"AAA"[..]));
        assert_eq!(slice(&bundle, &manifest, "b"), Some(&b"BBBB"[..]));
        assert_eq!(slice(&bundle, &manifest, "c"), Some(&b"C"[..]));
        assert_eq!(slice(&bundle, &manifest, "missing"), None);
    }

    #[test]
    fn slice_rejects_manifest_overrun() {
        let manifest = vec![att("a", 3), att("b", 99)];
        assert_eq!(slice(b"AAAB", &manifest, "b"), None);
    }
}

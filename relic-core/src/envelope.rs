//! The persisted wire format (`docs/wire-format.md`): plaintext envelope +
//! AEAD-sealed private payload. `v` gates breaking changes; unknown fields
//! within a version are ignored.

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde::{Deserialize, Serialize};

use crate::crypto::{
    decrypt_relic_payload, encrypt_relic_payload, CryptoError, MasterKey, NONCE_LEN,
};
use crate::relic::{Attachment, Kind, Relic, Source};

pub const WIRE_VERSION: u8 = 1;

/// One R2 object / `PUT /relic/:uid` body. Plaintext fields are exactly what
/// the Worker needs to order, page, enforce caps, and prune (SPEC §8).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EncryptedRelic {
    pub v: u8,
    pub uid: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub byte_size: u64,
    pub promoted: bool,
    /// Plaintext so DELETE/prune can remove the blob — a random server-side
    /// object key the server sees on every blob request anyway.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blob_key: Option<String>,
    /// base64, NONCE_LEN bytes
    pub n: String,
    /// base64 AEAD ciphertext of [`PrivatePayload`]
    pub ct: String,
}

/// Everything the operator must never see — JSON inside `ct`.
/// `uid`/timestamps/`byte_size`/`promoted` are NOT duplicated here; the
/// envelope is authoritative and `uid` is tamper-bound via AAD.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct PrivatePayload {
    kind: Kind,
    source: Source,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    device: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    mime: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    filename: Option<String>,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    user_tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    collection: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    content: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    preview: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    attachments: Vec<Attachment>,
    /// Formatting flavors (HTML / RTF) for a text relic, capped at 256 KiB.
    /// Opaque here on purpose: relic-core never renders or rewrites them, it
    /// only has to round-trip them so a re-seal does not silently drop the
    /// field. Shape is `{"h": <fingerprint>, "html"?: str, "rtf"?: base64}`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    rich: Option<serde_json::Value>,
}

#[derive(Debug, thiserror::Error)]
pub enum EnvelopeError {
    #[error(transparent)]
    Crypto(#[from] CryptoError),
    #[error("unsupported wire version {0}")]
    Version(u8),
    #[error("malformed envelope: {0}")]
    Malformed(&'static str),
}

/// Encrypt a relic into its wire form.
pub fn seal_relic(mk: &MasterKey, relic: &Relic) -> Result<EncryptedRelic, EnvelopeError> {
    let payload = PrivatePayload {
        kind: relic.kind,
        source: relic.source,
        device: relic.device.clone(),
        mime: relic.mime.clone(),
        filename: relic.filename.clone(),
        tags: relic.tags.clone(),
        user_tags: relic.user_tags.clone(),
        title: relic.title.clone(),
        collection: relic.collection.clone(),
        note: relic.note.clone(),
        content: relic.content.clone(),
        preview: relic.preview.clone(),
        attachments: relic.attachments.clone(),
        rich: relic.rich.clone(),
    };
    let plaintext =
        serde_json::to_vec(&payload).map_err(|_| EnvelopeError::Malformed("payload json"))?;
    let (nonce, ct) = encrypt_relic_payload(mk, &relic.uid, &plaintext)?;

    Ok(EncryptedRelic {
        v: WIRE_VERSION,
        uid: relic.uid.clone(),
        created_at: relic.created_at,
        updated_at: relic.updated_at,
        byte_size: relic.byte_size,
        promoted: relic.promoted,
        blob_key: relic.blob_key.clone(),
        n: B64.encode(nonce),
        ct: B64.encode(ct),
    })
}

/// Decrypt a wire envelope back into a relic.
pub fn open_relic(mk: &MasterKey, env: &EncryptedRelic) -> Result<Relic, EnvelopeError> {
    if env.v != WIRE_VERSION {
        return Err(EnvelopeError::Version(env.v));
    }
    let nonce: [u8; NONCE_LEN] = B64
        .decode(&env.n)
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or(EnvelopeError::Malformed("nonce"))?;
    let ct = B64.decode(&env.ct).map_err(|_| EnvelopeError::Malformed("ct"))?;

    let plaintext = decrypt_relic_payload(mk, &env.uid, &nonce, &ct)?;
    let p: PrivatePayload =
        serde_json::from_slice(&plaintext).map_err(|_| EnvelopeError::Malformed("payload json"))?;

    Ok(Relic {
        uid: env.uid.clone(),
        created_at: env.created_at,
        updated_at: env.updated_at,
        byte_size: env.byte_size,
        promoted: env.promoted,
        blob_key: env.blob_key.clone(),
        kind: p.kind,
        source: p.source,
        device: p.device,
        mime: p.mime,
        filename: p.filename,
        tags: p.tags,
        user_tags: p.user_tags,
        title: p.title,
        collection: p.collection,
        note: p.note,
        content: p.content,
        preview: p.preview,
        attachments: p.attachments,
        rich: p.rich,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Relic {
        Relic {
            uid: "0190a8e2-7c4d-7000-8000-1a2b3c4d5e6f".into(),
            created_at: 1_765_400_000,
            updated_at: 1_765_400_000,
            kind: Kind::String,
            source: Source::Clipboard,
            promoted: false,
            byte_size: 26,
            device: Some("test-device".into()),
            mime: None,
            filename: None,
            blob_key: None,
            tags: vec!["url".into()],
            user_tags: vec![],
            title: None,
            collection: None,
            note: None,
            content: Some("https://example.com/secret".into()),
            preview: Some("https://example.com…".into()),
            attachments: vec![],
            rich: None,
        }
    }

    #[test]
    fn seal_open_roundtrip() {
        let mk = MasterKey::generate();
        let relic = sample();
        let env = seal_relic(&mk, &relic).unwrap();
        let back = open_relic(&mk, &env).unwrap();
        assert_eq!(serde_json::to_value(&back).unwrap(), serde_json::to_value(&relic).unwrap());
    }

    #[test]
    fn rich_survives_a_reseal() {
        // The whole reason PrivatePayload carries `rich`: a client that opens a
        // relic and pushes it back must not silently strip the formatting. The
        // field is opaque here, so this also pins that we do not reshape it.
        let mk = MasterKey::generate();
        let mut relic = sample();
        relic.rich = Some(serde_json::json!({
            "h": 123456789,
            "html": "<b>hello</b>",
            "rtf": "e1xydGYxfQ==",
        }));

        let back = open_relic(&mk, &seal_relic(&mk, &relic).unwrap()).unwrap();
        assert_eq!(back.rich, relic.rich);

        // And again, the way a re-push actually happens: open, then re-seal.
        let again = open_relic(&mk, &seal_relic(&mk, &back).unwrap()).unwrap();
        assert_eq!(again.rich, relic.rich);
    }

    #[test]
    fn an_unknown_payload_field_is_ignored_not_fatal() {
        // docs/wire-format.md: "clients ignore unknown fields within a
        // version". Guards against anyone adding deny_unknown_fields.
        let json = serde_json::json!({
            "kind": "string",
            "source": "clipboard",
            "tags": [],
            "user_tags": [],
            "content": "hi",
            "some_future_field": {"a": 1},
        });
        let p: PrivatePayload = serde_json::from_value(json).unwrap();
        assert_eq!(p.content.as_deref(), Some("hi"));
    }

    #[test]
    fn envelope_plaintext_is_exactly_the_contract() {
        let mk = MasterKey::generate();
        let env = seal_relic(&mk, &sample()).unwrap();
        let json: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&env).unwrap()).unwrap();
        let mut keys: Vec<&str> =
            json.as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            ["byte_size", "created_at", "ct", "n", "promoted", "uid", "updated_at", "v"]
        );
        // the secret must not appear anywhere in the wire form
        assert!(!serde_json::to_string(&env).unwrap().contains("example.com"));

        // blob relics additionally expose blob_key (and only that)
        let mut blob_relic = sample();
        blob_relic.blob_key = Some("users/a/blob/k1".into());
        let env = seal_relic(&mk, &blob_relic).unwrap();
        let json: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&env).unwrap()).unwrap();
        assert_eq!(json.as_object().unwrap().len(), 9);
        assert_eq!(json["blob_key"], "users/a/blob/k1");
    }

    #[test]
    fn attachments_round_trip_and_stay_secret() {
        let mk = MasterKey::generate();
        let mut r = sample();
        r.attachments = vec![Attachment {
            id: "a1".into(),
            name: "quarterly.pdf".into(),
            mime: Some("application/pdf".into()),
            size: 1234,
        }];
        let env = seal_relic(&mk, &r).unwrap();
        // manifest rides inside the ciphertext, never in the plaintext envelope.
        assert!(!serde_json::to_string(&env).unwrap().contains("quarterly.pdf"));
        assert_eq!(open_relic(&mk, &env).unwrap().attachments, r.attachments);
    }

    #[test]
    fn tampered_uid_fails_open() {
        let mk = MasterKey::generate();
        let mut env = seal_relic(&mk, &sample()).unwrap();
        env.uid = "attacker-chosen-uid".into();
        assert!(matches!(open_relic(&mk, &env), Err(EnvelopeError::Crypto(_))));
    }

    #[test]
    fn future_version_is_rejected() {
        let mk = MasterKey::generate();
        let mut env = seal_relic(&mk, &sample()).unwrap();
        env.v = 2;
        assert!(matches!(open_relic(&mk, &env), Err(EnvelopeError::Version(2))));
    }

    #[test]
    fn unknown_envelope_fields_are_ignored() {
        let mk = MasterKey::generate();
        let env = seal_relic(&mk, &sample()).unwrap();
        let mut json: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&env).unwrap()).unwrap();
        json["future_field"] = serde_json::json!("ignored");
        let reparsed: EncryptedRelic = serde_json::from_value(json).unwrap();
        assert!(open_relic(&mk, &reparsed).is_ok());
    }
}

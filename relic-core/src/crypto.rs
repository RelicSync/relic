//! E2E crypto per `docs/crypto.md` — wrapped master key, Argon2id KDF,
//! XChaCha20-Poly1305 AEAD with AAD domain separation. Parameters are pinned;
//! any change is a wire-format version bump.

use argon2::{Algorithm, Argon2, Params, Version};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use chacha20poly1305::aead::rand_core::RngCore;
use chacha20poly1305::aead::{Aead, AeadCore, KeyInit, OsRng, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, Zeroizing};

pub const KEY_LEN: usize = 32;
pub const SALT_LEN: usize = 16;
pub const NONCE_LEN: usize = 24;

/// Pinned KDF config (docs/crypto.md). Stored alongside the wrapped key so
/// future param changes can coexist; current clients always *write* these.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Argon2Cfg {
    pub m_kib: u32,
    pub t: u32,
    pub p: u32,
}

pub const ARGON2_PINNED: Argon2Cfg = Argon2Cfg { m_kib: 64 * 1024, t: 3, p: 4 };

const AAD_MKWRAP: &[u8] = b"relic.mkwrap.v1";

fn aad_relic(uid: &str) -> Vec<u8> {
    format!("relic.relic.v1:{uid}").into_bytes()
}

// AAD binds the client-generated blob id — the trailing segment of the
// server-side blob_key — since the full key (with account prefix) isn't
// known until after upload.
fn aad_blob(blob_id: &str) -> Vec<u8> {
    format!("relic.blob.v1:{blob_id}").into_bytes()
}

#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    #[error("wrong passphrase or corrupted key params")]
    UnwrapFailed,
    #[error("decryption failed: wrong key or tampered data")]
    DecryptFailed,
    #[error("invalid {0}")]
    Invalid(&'static str),
}

/// The 256-bit master key. Encrypts all content; lives only in memory
/// (zeroized on drop) or, wrapped, on the server. The recovery kit is these
/// bytes verbatim.
pub struct MasterKey(Zeroizing<[u8; KEY_LEN]>);

impl MasterKey {
    pub fn generate() -> Self {
        let mut k = Zeroizing::new([0u8; KEY_LEN]);
        OsRng.fill_bytes(k.as_mut());
        MasterKey(k)
    }

    pub fn from_bytes(bytes: [u8; KEY_LEN]) -> Self {
        MasterKey(Zeroizing::new(bytes))
    }

    pub fn as_bytes(&self) -> &[u8; KEY_LEN] {
        &self.0
    }
}

/// Derive the KEK from a passphrase. `cfg` comes from stored key-params on
/// unlock and is `ARGON2_PINNED` on creation.
pub fn derive_kek(
    passphrase: &str,
    salt: &[u8; SALT_LEN],
    cfg: Argon2Cfg,
) -> Result<Zeroizing<[u8; KEY_LEN]>, CryptoError> {
    let params = Params::new(cfg.m_kib, cfg.t, cfg.p, Some(KEY_LEN))
        .map_err(|_| CryptoError::Invalid("argon2 params"))?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut kek = Zeroizing::new([0u8; KEY_LEN]);
    argon
        .hash_password_into(passphrase.as_bytes(), salt, kek.as_mut())
        .map_err(|_| CryptoError::Invalid("kdf input"))?;
    Ok(kek)
}

/// Server-side per-account key record (docs/crypto.md). Safe to store remotely:
/// recovering MK from it requires the passphrase.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyParams {
    pub v: u8,
    pub salt: String, // b64, SALT_LEN bytes
    pub argon2: Argon2Cfg,
    pub mk_nonce: String,    // b64, NONCE_LEN bytes
    pub wrapped_mk: String,  // b64, AEAD(KEK, mk_nonce, MK, aad=mkwrap)
}

impl KeyParams {
    /// First-device setup: generate MK and wrap it under `passphrase`.
    pub fn create(passphrase: &str) -> Result<(KeyParams, MasterKey), CryptoError> {
        let mk = MasterKey::generate();
        let params = Self::wrap(&mk, passphrase, ARGON2_PINNED)?;
        Ok((params, mk))
    }

    /// Wrap an existing MK (passphrase change / recovery-kit re-wrap).
    /// Fresh salt and nonce every time.
    pub fn wrap(mk: &MasterKey, passphrase: &str, cfg: Argon2Cfg) -> Result<KeyParams, CryptoError> {
        let mut salt = [0u8; SALT_LEN];
        OsRng.fill_bytes(&mut salt);
        let kek = derive_kek(passphrase, &salt, cfg)?;

        let cipher = XChaCha20Poly1305::new(kek.as_ref().into());
        let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);
        let wrapped = cipher
            .encrypt(&nonce, Payload { msg: mk.as_bytes(), aad: AAD_MKWRAP })
            .map_err(|_| CryptoError::Invalid("wrap"))?;

        Ok(KeyParams {
            v: 1,
            salt: B64.encode(salt),
            argon2: cfg,
            mk_nonce: B64.encode(nonce),
            wrapped_mk: B64.encode(wrapped),
        })
    }

    /// New-device unlock. `Err(UnwrapFailed)` ⇒ wrong passphrase (this is the
    /// key-check; clients never trial-decrypt real relics).
    pub fn unlock(&self, passphrase: &str) -> Result<MasterKey, CryptoError> {
        let salt: [u8; SALT_LEN] = decode_fixed(&self.salt, "salt")?;
        let nonce: [u8; NONCE_LEN] = decode_fixed(&self.mk_nonce, "mk_nonce")?;
        let wrapped = B64
            .decode(&self.wrapped_mk)
            .map_err(|_| CryptoError::Invalid("wrapped_mk"))?;

        let kek = derive_kek(passphrase, &salt, self.argon2)?;
        let cipher = XChaCha20Poly1305::new(kek.as_ref().into());
        let mut mk_bytes = cipher
            .decrypt(XNonce::from_slice(&nonce), Payload { msg: &wrapped, aad: AAD_MKWRAP })
            .map_err(|_| CryptoError::UnwrapFailed)?;

        let mk: [u8; KEY_LEN] = mk_bytes
            .as_slice()
            .try_into()
            .map_err(|_| CryptoError::Invalid("mk length"))?;
        mk_bytes.zeroize();
        Ok(MasterKey::from_bytes(mk))
    }
}

fn decode_fixed<const N: usize>(b64: &str, what: &'static str) -> Result<[u8; N], CryptoError> {
    B64.decode(b64)
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or(CryptoError::Invalid(what))
}

/// AEAD-encrypt a relic's private payload. Returns `(nonce, ciphertext)` for
/// the envelope's `n`/`ct` fields (caller base64-encodes).
pub fn encrypt_relic_payload(
    mk: &MasterKey,
    uid: &str,
    plaintext: &[u8],
) -> Result<([u8; NONCE_LEN], Vec<u8>), CryptoError> {
    let cipher = XChaCha20Poly1305::new(mk.as_bytes().into());
    let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);
    let ct = cipher
        .encrypt(&nonce, Payload { msg: plaintext, aad: &aad_relic(uid) })
        .map_err(|_| CryptoError::Invalid("encrypt"))?;
    Ok((nonce.into(), ct))
}

pub fn decrypt_relic_payload(
    mk: &MasterKey,
    uid: &str,
    nonce: &[u8; NONCE_LEN],
    ct: &[u8],
) -> Result<Zeroizing<Vec<u8>>, CryptoError> {
    let cipher = XChaCha20Poly1305::new(mk.as_bytes().into());
    cipher
        .decrypt(XNonce::from_slice(nonce), Payload { msg: ct, aad: &aad_relic(uid) })
        .map(Zeroizing::new)
        .map_err(|_| CryptoError::DecryptFailed)
}

/// Client-generated blob id (the AAD binding and the final path segment of
/// the server's blob_key).
pub fn random_blob_id() -> String {
    let mut id = [0u8; 16];
    OsRng.fill_bytes(&mut id);
    id.iter().map(|b| format!("{b:02x}")).collect()
}

/// Extract the blob id from a full server-side `blob_key`
/// (`users/<acct>/blob/<id>` → `<id>`; a bare id passes through).
pub fn blob_id_of(blob_key: &str) -> &str {
    blob_key.rsplit('/').next().unwrap_or(blob_key)
}

/// Encrypt a blob to its wire form: `nonce ‖ ciphertext` (docs/wire-format.md).
pub fn encrypt_blob(mk: &MasterKey, blob_id: &str, plaintext: &[u8]) -> Result<Vec<u8>, CryptoError> {
    let cipher = XChaCha20Poly1305::new(mk.as_bytes().into());
    let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);
    let ct = cipher
        .encrypt(&nonce, Payload { msg: plaintext, aad: &aad_blob(blob_id) })
        .map_err(|_| CryptoError::Invalid("encrypt"))?;
    let mut out = Vec::with_capacity(NONCE_LEN + ct.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    Ok(out)
}

pub fn decrypt_blob(mk: &MasterKey, blob_id: &str, wire: &[u8]) -> Result<Zeroizing<Vec<u8>>, CryptoError> {
    if wire.len() < NONCE_LEN {
        return Err(CryptoError::Invalid("blob too short"));
    }
    let (nonce, ct) = wire.split_at(NONCE_LEN);
    let cipher = XChaCha20Poly1305::new(mk.as_bytes().into());
    cipher
        .decrypt(XNonce::from_slice(nonce), Payload { msg: ct, aad: &aad_blob(blob_id) })
        .map(Zeroizing::new)
        .map_err(|_| CryptoError::DecryptFailed)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Cheap KDF config for wrap/unwrap tests — pinned params are exercised
    /// once in `kdf_vector_is_pinned` (64 MiB Argon2id is slow in debug).
    const CHEAP: Argon2Cfg = Argon2Cfg { m_kib: 16, t: 1, p: 1 };

    #[test]
    fn wrap_unwrap_roundtrip_and_wrong_passphrase() {
        let mk = MasterKey::generate();
        let params = KeyParams::wrap(&mk, "correct horse", CHEAP).unwrap();

        let unlocked = params.unlock("correct horse").unwrap();
        assert_eq!(unlocked.as_bytes(), mk.as_bytes());

        assert!(matches!(
            params.unlock("incorrect horse"),
            Err(CryptoError::UnwrapFailed)
        ));
    }

    #[test]
    fn rewrap_preserves_mk_with_new_salt_and_nonce() {
        let mk = MasterKey::generate();
        let a = KeyParams::wrap(&mk, "old pass", CHEAP).unwrap();
        let b = KeyParams::wrap(&mk, "new pass", CHEAP).unwrap();
        assert_ne!(a.salt, b.salt);
        assert_ne!(a.mk_nonce, b.mk_nonce);
        assert_eq!(b.unlock("new pass").unwrap().as_bytes(), mk.as_bytes());
        assert!(b.unlock("old pass").is_err());
    }

    #[test]
    fn keyparams_serde_matches_contract() {
        let mk = MasterKey::generate();
        let params = KeyParams::wrap(&mk, "p", CHEAP).unwrap();
        let json: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&params).unwrap()).unwrap();
        for field in ["v", "salt", "argon2", "mk_nonce", "wrapped_mk"] {
            assert!(json.get(field).is_some(), "missing {field}");
        }
        assert_eq!(json["argon2"]["m_kib"], 16);
    }

    #[test]
    fn relic_payload_roundtrip_and_aad_binding() {
        let mk = MasterKey::generate();
        let (nonce, ct) = encrypt_relic_payload(&mk, "uid-1", b"secret payload").unwrap();

        let pt = decrypt_relic_payload(&mk, "uid-1", &nonce, &ct).unwrap();
        assert_eq!(pt.as_slice(), b"secret payload");

        // server swaps ciphertext under a different uid → AAD mismatch
        assert!(decrypt_relic_payload(&mk, "uid-2", &nonce, &ct).is_err());

        // bit-flip in ciphertext → auth failure
        let mut bad = ct.clone();
        bad[0] ^= 1;
        assert!(decrypt_relic_payload(&mk, "uid-1", &nonce, &bad).is_err());

        // wrong key → auth failure
        let other = MasterKey::generate();
        assert!(decrypt_relic_payload(&other, "uid-1", &nonce, &ct).is_err());
    }

    #[test]
    fn blob_roundtrip_and_aad_binding() {
        let mk = MasterKey::generate();
        let data = vec![7u8; 100_000];
        let wire = encrypt_blob(&mk, "users/a/blob/k1", &data).unwrap();
        assert_eq!(wire.len(), NONCE_LEN + data.len() + 16); // +Poly1305 tag

        assert_eq!(decrypt_blob(&mk, "users/a/blob/k1", &wire).unwrap().as_slice(), &data[..]);
        assert!(decrypt_blob(&mk, "users/a/blob/k2", &wire).is_err());
        assert!(decrypt_blob(&mk, "users/a/blob/k1", &wire[..NONCE_LEN - 1]).is_err());
    }

    /// Snapshot of the pinned KDF: if a dependency upgrade or param edit ever
    /// changes key derivation, this fails before it can strand users' data.
    #[test]
    fn kdf_vector_is_pinned() {
        let salt = [0x42u8; SALT_LEN];
        let kek = derive_kek("correct horse battery staple", &salt, ARGON2_PINNED).unwrap();
        let hex: String = kek.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(
            hex,
            "dde64ab2660a0dedd449fa0414587bd0407e68ebe4a3f1595f2c167f1f7ff3cd"
        );
    }
}

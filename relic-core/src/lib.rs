//! relic-core — shared engine: types, deterministic classification, crypto,
//! local SQLite/FTS index, sync, and storage backends (SPEC §3).
//!
//! Contracts implemented here: `docs/crypto.md`, `docs/wire-format.md`,
//! `relics.sql`. Build order: `docs/build-order.md`.

pub mod classify;
pub mod crypto;
pub mod envelope;
pub mod index;
pub mod relic;
pub mod store;
pub mod store_http;
pub mod store_local;
pub mod sync;

pub use classify::{detect_tags, make_preview, sniff_kind};
pub use crypto::{blob_id_of, random_blob_id, CryptoError, KeyParams, MasterKey};
pub use envelope::{open_relic, seal_relic, EncryptedRelic, EnvelopeError};
pub use index::{IndexError, LocalIndex, Order, Query};
pub use relic::{Attachment, Kind, Relic, Source};
pub use store::{AccountInfo, Page, RelicStore, StoreError, Tombstone};
pub use store_http::HttpStore;
pub use store_local::LocalStore;
pub use sync::{PullStats, SyncEngine, SyncError};

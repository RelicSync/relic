//! M5 smoke test (docs/build-order.md): drives a real client flow against a
//! running Worker. Run via scripts/smoke.ps1, or directly:
//!
//!   RELIC_URL=http://127.0.0.1:8787 RELIC_TOKEN=relic-dev-token \
//!     cargo run -p relic-core --example smoke
//!
//! Asserts: keyparams set/fetch/unlock, push/pull text + blob relics,
//! promote (LWW upsert), stale-put no-op, delete + tombstone, size-cap 413,
//! vault-cap 402 (free tier), wrong token 401.

use relic_core::crypto::{decrypt_blob, encrypt_blob, KeyParams};
use relic_core::{
    blob_id_of, random_blob_id, seal_relic, HttpStore, Kind, LocalIndex, Query, Relic, RelicStore,
    Source, SyncEngine,
};

fn relic(uid: &str, content: &str, ts: i64) -> Relic {
    Relic {
        uid: uid.into(),
        created_at: ts,
        updated_at: ts,
        kind: Kind::String,
        source: Source::Clipboard,
        promoted: false,
        byte_size: content.len() as u64,
        device: Some("smoke".into()),
        mime: None,
        filename: None,
        blob_key: None,
        tags: vec![],
        user_tags: vec![],
        title: None,
        collection: None,
        note: None,
        content: Some(content.into()),
        preview: Some(content.into()),
        attachments: vec![],
        rich: None,
    }
}

struct Harness {
    passed: u32,
    failed: u32,
}

impl Harness {
    fn check(&mut self, name: &str, ok: bool) {
        println!("{}  {name}", if ok { "PASS" } else { "FAIL" });
        if ok {
            self.passed += 1;
        } else {
            self.failed += 1;
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let url = std::env::var("RELIC_URL").unwrap_or_else(|_| "http://127.0.0.1:8787".into());
    let token = std::env::var("RELIC_TOKEN").unwrap_or_else(|_| "relic-dev-token".into());
    let mut h = Harness { passed: 0, failed: 0 };
    let http = reqwest::Client::new();

    // -- auth: bad token rejected
    let resp = http.get(format!("{url}/account")).bearer_auth("wrong").send().await.unwrap();
    h.check("401 for unknown token", resp.status() == 401);

    // -- keyparams: create, set, fetch, unlock on a "second device"
    let (params, mk) = KeyParams::create("smoke passphrase").unwrap();
    let resp = http
        .put(format!("{url}/keyparams?replace=1"))
        .bearer_auth(&token)
        .json(&params)
        .send()
        .await
        .unwrap();
    h.check("PUT /keyparams", resp.status().is_success());
    let fetched: KeyParams = http
        .get(format!("{url}/keyparams"))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let mk2 = fetched.unlock("smoke passphrase").unwrap();
    h.check("fetched keyparams unlock to same MK", mk2.as_bytes() == mk.as_bytes());
    h.check("wrong passphrase rejected", fetched.unlock("nope").is_err());

    // -- device A pushes, device B pulls
    let store_a = HttpStore::new(&url, &token);
    let a = SyncEngine::new(LocalIndex::open_in_memory().unwrap(), store_a, mk);
    let b = SyncEngine::new(
        LocalIndex::open_in_memory().unwrap(),
        HttpStore::new(&url, &token),
        mk2,
    );

    a.save(&relic("smoke-r1", "hello through the worker", 100)).await.unwrap();
    a.save(&relic("smoke-r2", "second capture", 101)).await.unwrap();
    let stats = b.pull().await.unwrap();
    h.check("pull applies pushed relics", stats.applied >= 2);
    let r1 = b.index().get("smoke-r1").unwrap();
    h.check(
        "content decrypts end-to-end",
        r1.as_ref().and_then(|r| r.content.clone()).as_deref() == Some("hello through the worker"),
    );
    let hits = b
        .index()
        .search(&Query { text: Some("worker".into()), ..Query::new() })
        .unwrap();
    h.check("FTS finds synced relic", hits.iter().any(|r| r.uid == "smoke-r1"));

    // -- promote on B (LWW upsert), converges to A
    let mut r1 = r1.unwrap();
    r1.promoted = true;
    r1.title = Some("kept".into());
    r1.updated_at = 110;
    b.save(&r1).await.unwrap();
    a.pull().await.unwrap();
    h.check(
        "promotion converges via LWW",
        a.index().get("smoke-r1").unwrap().map(|r| r.promoted) == Some(true),
    );

    // -- stale put is a no-op
    let mut stale = a.index().get("smoke-r1").unwrap().unwrap();
    stale.updated_at = 50;
    stale.title = Some("stale overwrite".into());
    let env = seal_relic(a.mk(), &stale).unwrap();
    let resp = http
        .put(format!("{url}/relic/smoke-r1"))
        .bearer_auth(&token)
        .json(&env)
        .send()
        .await
        .unwrap();
    let body: serde_json::Value = resp.json().await.unwrap();
    h.check("stale PUT reports stale:true", body["stale"] == true);

    // -- blob lifecycle: encrypt under a client-generated id, upload, fetch,
    //    decrypt with the id recovered from the returned key
    let blob_plain = vec![42u8; 64 * 1024];
    let blob_id = random_blob_id();
    let wire = encrypt_blob(a.mk(), &blob_id, &blob_plain).unwrap();
    let key = a.store().push_blob(&blob_id, &wire).await.unwrap();
    h.check("blob key embeds client id", blob_id_of(&key) == blob_id);
    let fetched = a.store().get_blob(&key).await.unwrap();
    let plain = decrypt_blob(a.mk(), blob_id_of(&key), &fetched).unwrap();
    h.check("blob decrypts end-to-end", plain.as_slice() == blob_plain.as_slice());
    let mut photo = relic("smoke-p1", "", 120);
    photo.kind = Kind::Photo;
    photo.byte_size = wire.len() as u64;
    photo.blob_key = Some(key.clone());
    a.save(&photo).await.unwrap();

    // -- delete + tombstone + resurrection block
    a.delete("smoke-r2", 130).await.unwrap();
    let stats = b.pull().await.unwrap();
    h.check("delete propagates via tombstone", stats.deleted == 1);
    let zombie = seal_relic(a.mk(), &relic("smoke-r2", "zombie", 95)).unwrap();
    let resp = http
        .put(format!("{url}/relic/smoke-r2"))
        .bearer_auth(&token)
        .json(&zombie)
        .send()
        .await
        .unwrap();
    let body: serde_json::Value = resp.json().await.unwrap();
    h.check("tombstone blocks resurrection", body["stale"] == true);

    // -- size cap (free: 10MB byte_size)
    let mut big = relic("smoke-big", "x", 140);
    big.byte_size = 11 * 1024 * 1024;
    let env = seal_relic(a.mk(), &big).unwrap();
    let resp = http
        .put(format!("{url}/relic/smoke-big"))
        .bearer_auth(&token)
        .json(&env)
        .send()
        .await
        .unwrap();
    h.check("413 over per-item cap", resp.status() == 413);

    // -- vault cap (free: 25 promoted; smoke-r1 already holds one slot)
    let mut cap_hit = false;
    for i in 0..30 {
        let mut r = relic(&format!("smoke-v{i}"), &format!("vault filler {i}"), 200 + i);
        r.promoted = true;
        let env = seal_relic(a.mk(), &r).unwrap();
        let resp = http
            .put(format!("{url}/relic/{}", r.uid))
            .bearer_auth(&token)
            .json(&env)
            .send()
            .await
            .unwrap();
        if resp.status() == 402 {
            cap_hit = true;
            break;
        }
    }
    h.check("402 vault_cap on free tier", cap_hit);

    // -- account endpoint
    let acct: serde_json::Value = http
        .get(format!("{url}/account"))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    h.check("account reports free tier + caps", acct["tier"] == "free" && acct["vault_cap"] == 25);

    println!("\n{} passed, {} failed", h.passed, h.failed);
    std::process::exit(if h.failed > 0 { 1 } else { 0 });
}

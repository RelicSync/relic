//! `http` backend (SPEC §7): the hosted Worker or any server implementing
//! `docs/api.md`. The reference production backend.

use serde::Deserialize;

use crate::envelope::EncryptedRelic;
use crate::store::{Page, RelicStore, StoreError, Tombstone};

pub struct HttpStore {
    base: String,
    token: String,
    client: reqwest::Client,
}

impl HttpStore {
    pub fn new(base_url: impl Into<String>, token: impl Into<String>) -> Self {
        HttpStore {
            base: base_url.into().trim_end_matches('/').to_string(),
            token: token.into(),
            client: reqwest::Client::new(),
        }
    }

    fn req(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        self.client
            .request(method, format!("{}{path}", self.base))
            .bearer_auth(&self.token)
    }

    /// Fetch the account's key-params record; `None` if never set (new account).
    pub async fn get_keyparams(&self) -> Result<Option<crate::crypto::KeyParams>, StoreError> {
        let resp = self.req(reqwest::Method::GET, "/keyparams").send().await.map_err(net)?;
        match check(resp).await {
            Ok(resp) => Ok(Some(resp.json().await.map_err(net)?)),
            Err(StoreError::NotFound(_)) => Ok(None),
            Err(e) => Err(e),
        }
    }

    pub async fn put_keyparams(
        &self,
        params: &crate::crypto::KeyParams,
        replace: bool,
    ) -> Result<(), StoreError> {
        let path = if replace { "/keyparams?replace=1" } else { "/keyparams" };
        let resp = self.req(reqwest::Method::PUT, path).json(params).send().await.map_err(net)?;
        check(resp).await?;
        Ok(())
    }
}

#[derive(Deserialize)]
struct ApiError {
    error: String,
    message: String,
}

/// Map non-2xx responses to StoreError with the server's error code.
/// 400/402/409/413 are permanent → `Rejected` (queue drops the op);
/// 401/429/5xx are transient → `Backend` (op stays queued and retries).
async fn check(resp: reqwest::Response) -> Result<reqwest::Response, StoreError> {
    if resp.status().is_success() {
        return Ok(resp);
    }
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    if status == reqwest::StatusCode::NOT_FOUND {
        return Err(StoreError::NotFound(body));
    }
    let detail = serde_json::from_str::<ApiError>(&body)
        .map(|e| format!("{} ({})", e.message, e.error))
        .unwrap_or(body);
    let msg = format!("{status}: {detail}");
    match status.as_u16() {
        400 | 402 | 409 | 413 => Err(StoreError::Rejected(msg)),
        _ => Err(StoreError::Backend(msg)),
    }
}

fn net(e: reqwest::Error) -> StoreError {
    StoreError::Backend(format!("network: {e}"))
}

#[derive(Deserialize)]
struct ListResponse {
    items: Vec<EncryptedRelic>,
    next_cursor: Option<String>,
}

#[derive(Deserialize)]
struct TombstonesResponse {
    items: Vec<Tombstone>,
}

#[derive(Deserialize)]
struct BlobResponse {
    key: String,
}

#[async_trait::async_trait]
impl RelicStore for HttpStore {
    async fn push(&self, env: &EncryptedRelic) -> Result<(), StoreError> {
        let resp = self
            .req(reqwest::Method::PUT, &format!("/relic/{}", env.uid))
            .json(env)
            .send()
            .await
            .map_err(net)?;
        check(resp).await?;
        Ok(())
    }

    async fn list(&self, since: i64, cursor: Option<&str>, limit: usize) -> Result<Page, StoreError> {
        let mut req = self
            .req(reqwest::Method::GET, "/relics")
            .query(&[("since", since.to_string()), ("limit", limit.to_string())]);
        if let Some(c) = cursor {
            req = req.query(&[("cursor", c)]);
        }
        let resp = check(req.send().await.map_err(net)?).await?;
        let body: ListResponse = resp.json().await.map_err(net)?;
        Ok(Page { items: body.items, next: body.next_cursor })
    }

    async fn delete(&self, uid: &str, deleted_at: i64) -> Result<(), StoreError> {
        let resp = self
            .req(reqwest::Method::DELETE, &format!("/relic/{uid}"))
            .query(&[("deleted_at", deleted_at.to_string())])
            .send()
            .await
            .map_err(net)?;
        check(resp).await?;
        Ok(())
    }

    async fn tombstones(&self, since: i64) -> Result<Vec<Tombstone>, StoreError> {
        let resp = self
            .req(reqwest::Method::GET, "/tombstones")
            .query(&[("since", since.to_string())])
            .send()
            .await
            .map_err(net)?;
        let body: TombstonesResponse = check(resp).await?.json().await.map_err(net)?;
        Ok(body.items)
    }

    async fn push_blob(&self, id: &str, data: &[u8]) -> Result<String, StoreError> {
        let resp = self
            .req(reqwest::Method::POST, "/blob")
            .query(&[("id", id)])
            .body(data.to_vec())
            .send()
            .await
            .map_err(net)?;
        let body: BlobResponse = check(resp).await?.json().await.map_err(net)?;
        Ok(body.key)
    }

    async fn get_blob(&self, key: &str) -> Result<Vec<u8>, StoreError> {
        let resp = self
            .req(reqwest::Method::GET, &format!("/blob/{key}"))
            .send()
            .await
            .map_err(net)?;
        Ok(check(resp).await?.bytes().await.map_err(net)?.to_vec())
    }

    async fn account(&self) -> Result<Option<crate::store::AccountInfo>, StoreError> {
        let resp = self.req(reqwest::Method::GET, "/account").send().await.map_err(net)?;
        Ok(Some(check(resp).await?.json().await.map_err(net)?))
    }
}

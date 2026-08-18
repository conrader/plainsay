//! Client for the same Plainsay Cloud API the Mac app speaks
//! (`PlainsayCloud.swift`, `CloudTranscriptionEngine.swift`,
//! `CloudCleanupService.swift`). No new backend work — this just re-implements
//! that contract in Rust.

use serde::Deserialize;
use serde_json::json;

pub const DEFAULT_BASE_URL: &str = "https://api.plainsay.app";

/// Windows Credential Manager, mirroring the Mac client's rule: this is the
/// only thing about a Cloud session that ever touches disk. Provider keys
/// never existed on this client either way — both transcription and cleanup
/// are proxied through the server with this token.
const KEYRING_SERVICE: &str = "com.plainsay.dictation";
const KEYRING_ACCOUNT: &str = "cloud-session-token";

#[derive(Debug, thiserror::Error)]
pub enum CloudError {
    #[error("not signed in")]
    NotSignedIn,
    #[error("no active Plainsay Cloud subscription (status: {0})")]
    NoSubscription(String),
    #[error("Plainsay Cloud returned HTTP {status}: {message}")]
    Http { status: u16, message: String },
    #[error("network error: {0}")]
    Network(String),
    #[error("unexpected response from Plainsay Cloud")]
    Malformed,
}

pub struct CloudClient {
    base_url: String,
    http: reqwest::Client,
}

#[derive(Debug, Deserialize)]
pub struct Account {
    pub email: Option<String>,
    #[serde(default = "default_status")]
    pub status: String,
    #[serde(default)]
    pub usage: Option<Usage>,
}

fn default_status() -> String {
    "none".to_string()
}

#[derive(Debug, Deserialize)]
pub struct Usage {
    #[serde(rename = "usedSeconds")]
    pub used_seconds: u64,
    #[serde(rename = "limitSeconds")]
    pub limit_seconds: u64,
}

impl Account {
    pub fn is_active(&self) -> bool {
        matches!(self.status.as_str(), "active" | "trialing" | "past_due")
    }
}

impl CloudClient {
    pub fn new() -> Self {
        Self {
            base_url: DEFAULT_BASE_URL.to_string(),
            http: reqwest::Client::new(),
        }
    }

    pub fn is_signed_in(&self) -> bool {
        Self::stored_token().is_some()
    }

    fn stored_token() -> Option<String> {
        keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
            .ok()?
            .get_password()
            .ok()
    }

    fn store_token(token: &str) -> Result<(), CloudError> {
        keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
            .map_err(|e| CloudError::Network(e.to_string()))?
            .set_password(token)
            .map_err(|e| CloudError::Network(e.to_string()))
    }

    pub fn sign_out() {
        if let Ok(entry) = keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT) {
            let _ = entry.delete_credential();
        }
    }

    fn token(&self) -> Result<String, CloudError> {
        Self::stored_token().ok_or(CloudError::NotSignedIn)
    }

    pub async fn request_email_code(&self, email: &str) -> Result<(), CloudError> {
        self.post_unauthorized("/v1/auth/email", &json!({ "email": email }))
            .await?;
        Ok(())
    }

    pub async fn verify_email_code(&self, email: &str, code: &str) -> Result<(), CloudError> {
        let json = self
            .post_unauthorized(
                "/v1/auth/email/verify",
                &json!({ "email": email, "code": code }),
            )
            .await?;
        let token = json
            .get("token")
            .and_then(|v| v.as_str())
            .ok_or(CloudError::Malformed)?;
        Self::store_token(token)
    }

    pub async fn refresh_account(&self) -> Result<Account, CloudError> {
        let token = self.token()?;
        let response = self
            .http
            .get(format!("{}/v1/me", self.base_url))
            .bearer_auth(token)
            .send()
            .await
            .map_err(|e| CloudError::Network(e.to_string()))?;
        let json = Self::parse(response).await?;
        serde_json::from_value(json).map_err(|_| CloudError::Malformed)
    }

    pub async fn checkout_url(&self, annual: bool) -> Result<String, CloudError> {
        let json = self
            .post_authorized(
                "/v1/billing/checkout",
                &json!({ "interval": if annual { "annual" } else { "monthly" } }),
            )
            .await?;
        json.get("url")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or(CloudError::Malformed)
    }

    pub async fn portal_url(&self) -> Result<String, CloudError> {
        let json = self
            .post_authorized("/v1/billing/portal", &json!({}))
            .await?;
        json.get("url")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or(CloudError::Malformed)
    }

    /// Uploads a WAV clip for transcription. Mirrors
    /// `CloudTranscriptionEngine.transcribe` — raw audio body, not multipart,
    /// with the same query parameters the server already expects.
    pub async fn transcribe(
        &self,
        wav_bytes: Vec<u8>,
        duration_seconds: f64,
        language: Option<&str>,
        prompt: Option<&str>,
    ) -> Result<String, CloudError> {
        let token = self.token()?;
        let mut url = reqwest::Url::parse(&format!("{}/v1/transcribe", self.base_url))
            .map_err(|_| CloudError::Malformed)?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("durationSeconds", &duration_seconds.to_string());
            if let Some(language) = language {
                q.append_pair("language", language);
            }
            if let Some(prompt) = prompt {
                if !prompt.is_empty() {
                    q.append_pair("prompt", prompt);
                }
            }
        }

        let response = self
            .http
            .post(url)
            .bearer_auth(token)
            .header("Content-Type", "audio/wav")
            .body(wav_bytes)
            .send()
            .await
            .map_err(|e| CloudError::Network(e.to_string()))?;
        let json = Self::parse(response).await?;
        json.get("text")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or(CloudError::Malformed)
    }

    /// Polishes a transcript, mirroring `CloudCleanupService.clean` — the
    /// same `/v1/cleanup` proxy the Mac client uses, vocabulary hint and all.
    pub async fn cleanup(&self, transcript: &str, terms: Option<&str>) -> Result<String, CloudError> {
        let mut body = json!({ "transcript": transcript });
        if let Some(terms) = terms {
            body["terms"] = json!(terms);
        }
        let json = self.post_authorized("/v1/cleanup", &body).await?;
        json.get("text")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or(CloudError::Malformed)
    }

    async fn post_authorized(
        &self,
        path: &str,
        body: &serde_json::Value,
    ) -> Result<serde_json::Value, CloudError> {
        let token = self.token()?;
        let response = self
            .http
            .post(format!("{}{}", self.base_url, path))
            .bearer_auth(token)
            .json(body)
            .send()
            .await
            .map_err(|e| CloudError::Network(e.to_string()))?;
        Self::parse(response).await
    }

    async fn post_unauthorized(
        &self,
        path: &str,
        body: &serde_json::Value,
    ) -> Result<serde_json::Value, CloudError> {
        let response = self
            .http
            .post(format!("{}{}", self.base_url, path))
            .json(body)
            .send()
            .await
            .map_err(|e| CloudError::Network(e.to_string()))?;
        Self::parse(response).await
    }

    async fn parse(response: reqwest::Response) -> Result<serde_json::Value, CloudError> {
        let status = response.status();
        let json: serde_json::Value = response
            .json()
            .await
            .unwrap_or(serde_json::Value::Object(Default::default()));

        if status.is_success() {
            return Ok(json);
        }
        if status.as_u16() == 402 {
            let sub_status = json
                .get("status")
                .and_then(|v| v.as_str())
                .unwrap_or("none")
                .to_string();
            return Err(CloudError::NoSubscription(sub_status));
        }
        let message = json
            .get("error")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        Err(CloudError::Http {
            status: status.as_u16(),
            message,
        })
    }
}

impl Default for CloudClient {
    fn default() -> Self {
        Self::new()
    }
}

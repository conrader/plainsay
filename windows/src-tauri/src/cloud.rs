//! Client for the same Plainsay Cloud API the Mac app speaks
//! (`PlainsayCloud.swift`, `CloudTranscriptionEngine.swift`,
//! `CloudCleanupService.swift`). No new backend work — this just re-implements
//! that contract in Rust.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::time::Duration;

pub const DEFAULT_BASE_URL: &str = "https://api.plainsay.app";

/// Windows Credential Manager, mirroring the Mac client's rule: this is the
/// only thing about a Cloud session that ever touches disk. Provider keys
/// never existed on this client either way — both transcription and cleanup
/// are proxied through the server with this token.
const KEYRING_SERVICE: &str = "com.plainsay.dictation";
const KEYRING_ACCOUNT: &str = "cloud-session-token";

// Match the corresponding macOS clients: account/auth/billing requests get
// 20 seconds, transcription gets 30, and cleanup gets 15. A shorter connect
// timeout keeps an unreachable endpoint from consuming the whole request
// budget before any bytes are exchanged.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const API_TIMEOUT: Duration = Duration::from_secs(20);
const TRANSCRIPTION_TIMEOUT: Duration = Duration::from_secs(30);
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UploadMetadata<'a> {
    duration_seconds: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    language: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt: Option<&'a str>,
}

/// Encodes upload metadata exactly like the Mac client: compact JSON wrapped
/// in unpadded Base64URL. Keeping vocabulary/language out of the query string
/// prevents reverse-proxy access logs from recording them.
fn encode_upload_metadata(
    duration_seconds: f64,
    language: Option<&str>,
    prompt: Option<&str>,
) -> Result<String, CloudError> {
    if !duration_seconds.is_finite() || duration_seconds < 0.0 {
        return Err(CloudError::Malformed);
    }

    let metadata = UploadMetadata {
        duration_seconds,
        language: language.filter(|value| !value.is_empty()),
        prompt: prompt.filter(|value| !value.is_empty()),
    };
    let json = serde_json::to_vec(&metadata).map_err(|_| CloudError::Malformed)?;
    Ok(URL_SAFE_NO_PAD.encode(json))
}

fn non_empty_trimmed_text(json: &serde_json::Value) -> Option<String> {
    json.get("text")
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_string)
}

fn strip_paired_annotation(mut text: String, open: char, close: char) -> String {
    let mut search_from = 0;
    while let Some(relative_open) = text[search_from..].find(open) {
        let open_index = search_from + relative_open;
        let content_start = open_index + open.len_utf8();
        let Some(relative_close) = text[content_start..].find(close) else {
            break;
        };
        let close_index = content_start + relative_close + close.len_utf8();
        text.replace_range(open_index..close_index, "");
        search_from = open_index;
    }
    text
}

/// Mirrors the Mac client's `normalizeTranscript`: remove common ASR sound
/// annotations, collapse whitespace, and discard bare silence markers before
/// either cleanup or clipboard insertion sees the text.
pub fn normalize_transcript(raw: &str) -> String {
    let mut text = raw.trim().to_string();
    text = strip_paired_annotation(text, '[', ']');
    text = strip_paired_annotation(text, '(', ')');
    text = strip_paired_annotation(text, '♪', '♪');
    text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if matches!(text.as_str(), "" | "." | "-" | "...") {
        String::new()
    } else {
        text
    }
}

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
    #[error("Windows Credential Manager error: {0}")]
    Credential(String),
    #[error("unexpected response from Plainsay Cloud")]
    Malformed,
}

pub struct CloudClient {
    base_url: String,
    http: reqwest::Client,
    auth_lock: tokio::sync::Mutex<()>,
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
        let http = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .build()
            // The configuration above is static and valid. If the selected TLS
            // backend nevertheless cannot initialize, retain a usable client;
            // per-request total timeouts below still remain in force.
            .unwrap_or_else(|_| reqwest::Client::new());
        Self {
            base_url: DEFAULT_BASE_URL.to_string(),
            http,
            auth_lock: tokio::sync::Mutex::new(()),
        }
    }

    pub fn is_signed_in(&self) -> Result<bool, CloudError> {
        Ok(Self::stored_token()?.is_some())
    }

    fn stored_token() -> Result<Option<String>, CloudError> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
            .map_err(|error| CloudError::Credential(error.to_string()))?;
        match entry.get_password() {
            Ok(token) if !token.is_empty() => Ok(Some(token)),
            Ok(_) | Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(CloudError::Credential(error.to_string())),
        }
    }

    fn store_token(token: &str) -> Result<(), CloudError> {
        if token.is_empty() {
            return Err(CloudError::Malformed);
        }
        keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
            .map_err(|e| CloudError::Credential(e.to_string()))?
            .set_password(token)
            .map_err(|e| CloudError::Credential(e.to_string()))
    }

    fn delete_stored_token() -> Result<(), CloudError> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_ACCOUNT)
            .map_err(|e| CloudError::Credential(e.to_string()))?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(CloudError::Credential(e.to_string())),
        }
    }

    async fn delete_token_if_current(&self, rejected_token: &str) -> Result<bool, CloudError> {
        let _auth_guard = self.auth_lock.lock().await;
        if Self::stored_token()?.as_deref() == Some(rejected_token) {
            Self::delete_stored_token()?;
            return Ok(true);
        }
        Ok(false)
    }

    /// Revokes the server-side session before removing its Credential Manager
    /// entry. A network/server failure deliberately preserves the local token
    /// so the user can retry instead of leaving an orphaned live session.
    pub async fn sign_out(&self) -> Result<(), CloudError> {
        let _auth_guard = self.auth_lock.lock().await;
        if Self::stored_token()?.is_none() {
            return Ok(());
        }

        match self
            .post_authorized("/v1/auth/signout", &json!({}), API_TIMEOUT)
            .await
        {
            Ok(_) | Err(CloudError::Http { status: 401, .. }) => Self::delete_stored_token(),
            Err(error) => Err(error),
        }
    }

    fn token(&self) -> Result<String, CloudError> {
        Self::stored_token()?.ok_or(CloudError::NotSignedIn)
    }

    pub async fn request_email_code(&self, email: &str) -> Result<(), CloudError> {
        self.post_unauthorized("/v1/auth/email", &json!({ "email": email }))
            .await?;
        Ok(())
    }

    pub async fn verify_email_code(&self, email: &str, code: &str) -> Result<(), CloudError> {
        // Keep verification and sign-out mutually exclusive so one request
        // cannot accidentally delete the fresh token written by the other.
        let _auth_guard = self.auth_lock.lock().await;
        let json = self
            .post_unauthorized(
                "/v1/auth/email/verify",
                &json!({ "email": email, "code": code }),
            )
            .await?;
        let token = json
            .get("token")
            .and_then(|v| v.as_str())
            .filter(|token| !token.is_empty())
            .ok_or(CloudError::Malformed)?;
        Self::store_token(token)
    }

    pub async fn refresh_account(&self) -> Result<Account, CloudError> {
        let token = self.token()?;
        let response = self
            .http
            .get(format!("{}/v1/me", self.base_url))
            .bearer_auth(&token)
            .timeout(API_TIMEOUT)
            .send()
            .await
            .map_err(|e| CloudError::Network(e.to_string()))?;
        let json = match Self::parse(response).await {
            Err(error @ CloudError::Http { status: 401, .. }) => {
                // Delete only the token the server rejected. A concurrent
                // verification may already have installed a fresh session.
                if self.delete_token_if_current(&token).await? {
                    return Err(CloudError::NotSignedIn);
                }
                return Err(error);
            }
            result => result?,
        };
        serde_json::from_value(json).map_err(|_| CloudError::Malformed)
    }

    pub async fn checkout_url(&self, annual: bool) -> Result<String, CloudError> {
        let json = self
            .post_authorized(
                "/v1/billing/checkout",
                &json!({ "interval": if annual { "annual" } else { "monthly" } }),
                API_TIMEOUT,
            )
            .await?;
        json.get("url")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or(CloudError::Malformed)
    }

    /// Uploads an AAC/m4a clip for transcription. Mirrors
    /// `CloudTranscriptionEngine.transcribe`: raw `audio/mp4` body plus a
    /// privacy-preserving `X-Plainsay-Metadata` header, not multipart or query
    /// parameters.
    pub async fn transcribe(
        &self,
        audio_bytes: Vec<u8>,
        duration_seconds: f64,
        language: Option<&str>,
        prompt: Option<&str>,
    ) -> Result<String, CloudError> {
        let token = self.token()?;
        let url = reqwest::Url::parse(&format!("{}/v1/transcribe", self.base_url))
            .map_err(|_| CloudError::Malformed)?;
        let metadata = encode_upload_metadata(duration_seconds, language, prompt)?;

        let response = self
            .http
            .post(url)
            .bearer_auth(token)
            .header(reqwest::header::CONTENT_TYPE, "audio/mp4")
            .header("X-Plainsay-Metadata", metadata)
            .timeout(TRANSCRIPTION_TIMEOUT)
            .body(audio_bytes)
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
    pub async fn cleanup(
        &self,
        transcript: &str,
        terms: Option<&str>,
    ) -> Result<String, CloudError> {
        let mut body = json!({ "transcript": transcript });
        if let Some(terms) = terms {
            body["terms"] = json!(terms);
        }
        let json = self
            .post_authorized("/v1/cleanup", &body, CLEANUP_TIMEOUT)
            .await?;
        non_empty_trimmed_text(&json).ok_or(CloudError::Malformed)
    }

    async fn post_authorized(
        &self,
        path: &str,
        body: &serde_json::Value,
        timeout: Duration,
    ) -> Result<serde_json::Value, CloudError> {
        let token = self.token()?;
        let response = self
            .http
            .post(format!("{}{}", self.base_url, path))
            .bearer_auth(token)
            .json(body)
            .timeout(timeout)
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
            .timeout(API_TIMEOUT)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upload_metadata_is_unpadded_base64url_json() {
        let encoded = encode_upload_metadata(2.25, Some("pl"), Some("Plainsay")).unwrap();

        assert!(encoded
            .chars()
            .all(|character| !matches!(character, '+' | '/' | '=')));
        let decoded = URL_SAFE_NO_PAD.decode(encoded).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&decoded).unwrap();
        assert_eq!(json["durationSeconds"], 2.25);
        assert_eq!(json["language"], "pl");
        assert_eq!(json["prompt"], "Plainsay");
    }

    #[test]
    fn upload_metadata_omits_empty_optional_fields() {
        let encoded = encode_upload_metadata(1.0, Some(""), None).unwrap();
        let decoded = URL_SAFE_NO_PAD.decode(encoded).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&decoded).unwrap();

        assert_eq!(json["durationSeconds"], 1.0);
        assert!(json.get("language").is_none());
        assert!(json.get("prompt").is_none());
    }

    #[test]
    fn upload_metadata_rejects_non_finite_or_negative_duration() {
        assert!(matches!(
            encode_upload_metadata(f64::NAN, None, None),
            Err(CloudError::Malformed)
        ));
        assert!(matches!(
            encode_upload_metadata(-0.1, None, None),
            Err(CloudError::Malformed)
        ));
    }

    #[test]
    fn cleanup_text_must_be_non_empty_after_trimming() {
        assert_eq!(
            non_empty_trimmed_text(&json!({ "text": "  cleaned text\n" })),
            Some("cleaned text".to_string())
        );
        assert_eq!(non_empty_trimmed_text(&json!({ "text": " \n\t" })), None);
        assert_eq!(non_empty_trimmed_text(&json!({})), None);
    }

    #[test]
    fn transcript_normalization_matches_the_mac_client() {
        assert_eq!(normalize_transcript("[BLANK_AUDIO]"), "");
        assert_eq!(normalize_transcript("(upbeat music)"), "");
        assert_eq!(normalize_transcript("♪ la la ♪"), "");
        assert_eq!(
            normalize_transcript("  [INAUDIBLE] hello   there "),
            "hello there"
        );
        assert_eq!(
            normalize_transcript("hello   [noise]   world"),
            "hello world"
        );
        assert_eq!(normalize_transcript("Thank you."), "Thank you.");
        assert_eq!(normalize_transcript("you"), "you");
        assert_eq!(normalize_transcript("..."), "");
    }
}

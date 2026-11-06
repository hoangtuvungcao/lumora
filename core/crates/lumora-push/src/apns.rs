//! Minimal APNs provider client: HTTP/2 + token (JWT, ES256) authentication.
//!
//! * `https://…` → TLS with ALPN `h2` (Apple's servers).
//! * `http://…`  → cleartext HTTP/2 with prior knowledge (only for the test mock).
//! * dry-run: append each push as a JSON line to a file instead of sending (local tests).

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use parking_lot::Mutex;
use ring::rand::SystemRandom;
use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};

pub const APNS_PRODUCTION: &str = "https://api.push.apple.com";
pub const APNS_SANDBOX: &str = "https://api.sandbox.push.apple.com";

#[derive(Clone)]
pub struct ApnsConfig {
    pub production_url: String,
    pub sandbox_url: String,
    /// 10-character key id of the `.p8` key (App Store Connect › Keys).
    pub key_id: String,
    pub team_id: String,
    /// PKCS#8 DER of the `.p8` key (None only in dry-run mode).
    pub key_pkcs8: Option<Vec<u8>>,
    /// Dry run: write pushes here as JSON lines, send nothing.
    pub dry_run_log: Option<PathBuf>,
}

/// One push to send.
pub struct Push<'a> {
    pub sandbox: bool,
    pub device_token: &'a str,
    pub topic: &'a str,
    /// "alert" | "voip" | "background"
    pub push_type: &'a str,
    pub priority: u8,
    /// Unix seconds; 0 = deliver now or never (calls).
    pub expiration: u64,
    pub payload: &'a [u8],
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Sent,
    /// The token is dead (410 Unregistered, BadDeviceToken, DeviceTokenNotForTopic).
    Dead(String),
    /// Anything else (throttled by Apple, server error, network).
    Failed(String),
}

pub struct ApnsClient {
    cfg: ApnsConfig,
    key: Option<EcdsaKeyPair>,
    rng: SystemRandom,
    jwt: Mutex<Option<(String, Instant)>>,
    conns: tokio::sync::Mutex<HashMap<String, h2::client::SendRequest<Bytes>>>,
}

fn b64url(b: &[u8]) -> String {
    data_encoding::BASE64URL_NOPAD.encode(b)
}

/// Read a `.p8` file (PEM "PRIVATE KEY") or raw DER.
pub fn load_p8(bytes: &[u8]) -> anyhow_like::Result<Vec<u8>> {
    let s = String::from_utf8_lossy(bytes);
    if s.contains("-----BEGIN") {
        let body: String = s.lines().filter(|l| !l.starts_with("-----")).map(str::trim).collect();
        return data_encoding::BASE64.decode(body.as_bytes()).map_err(|e| anyhow_like::err(format!("bad .p8 base64: {e}")));
    }
    Ok(bytes.to_vec())
}

impl ApnsClient {
    pub fn new(cfg: ApnsConfig) -> anyhow_like::Result<Self> {
        let rng = SystemRandom::new();
        let key = match &cfg.key_pkcs8 {
            Some(der) => Some(
                EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, der, &rng)
                    .map_err(|e| anyhow_like::err(format!("APNs key is not a P-256 PKCS#8 (.p8) key: {e}")))?,
            ),
            None if cfg.dry_run_log.is_some() => None,
            None => return Err(anyhow_like::err("an APNs .p8 key is required unless --apns-log (dry run) is set")),
        };
        Ok(ApnsClient { cfg, key, rng, jwt: Mutex::new(None), conns: tokio::sync::Mutex::new(HashMap::new()) })
    }

    pub fn is_dry_run(&self) -> bool {
        self.cfg.dry_run_log.is_some()
    }

    /// Provider token. Apple: valid for 1 h, refresh at most every 20 min → we use 40 min.
    fn jwt(&self) -> anyhow_like::Result<String> {
        let mut g = self.jwt.lock();
        if let Some((t, at)) = g.as_ref() {
            if at.elapsed() < Duration::from_secs(40 * 60) {
                return Ok(t.clone());
            }
        }
        let key = self.key.as_ref().ok_or_else(|| anyhow_like::err("no APNs key"))?;
        let iat = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let header = b64url(serde_json::json!({"alg": "ES256", "kid": self.cfg.key_id}).to_string().as_bytes());
        let claims = b64url(serde_json::json!({"iss": self.cfg.team_id, "iat": iat}).to_string().as_bytes());
        let signing_input = format!("{header}.{claims}");
        let sig = key.sign(&self.rng, signing_input.as_bytes()).map_err(|_| anyhow_like::err("ES256 signing failed"))?;
        let t = format!("{signing_input}.{}", b64url(sig.as_ref()));
        *g = Some((t.clone(), Instant::now()));
        Ok(t)
    }

    async fn connect(base: &str) -> anyhow_like::Result<h2::client::SendRequest<Bytes>> {
        let (tls, rest) = if let Some(r) = base.strip_prefix("https://") {
            (true, r)
        } else if let Some(r) = base.strip_prefix("http://") {
            (false, r)
        } else {
            return Err(anyhow_like::err("APNs URL must start with https:// or http://"));
        };
        let authority = rest.split('/').next().unwrap_or(rest);
        let (host, port) = match authority.rsplit_once(':') {
            Some((h, p)) if !h.ends_with(']') || h.starts_with('[') => (h.trim_matches(['[', ']']).to_string(), p.parse().unwrap_or(443)),
            _ => (authority.to_string(), if tls { 443 } else { 80 }),
        };
        let tcp = tokio::time::timeout(Duration::from_secs(10), tokio::net::TcpStream::connect((host.as_str(), port)))
            .await
            .map_err(|_| anyhow_like::err("APNs connect timeout"))?
            .map_err(|e| anyhow_like::err(format!("APNs connect: {e}")))?;
        let _ = tcp.set_nodelay(true);
        if tls {
            let mut roots = tokio_rustls::rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let mut cc = tokio_rustls::rustls::ClientConfig::builder_with_provider(Arc::new(tokio_rustls::rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .map_err(|e| anyhow_like::err(format!("tls: {e}")))?
                .with_root_certificates(roots)
                .with_no_client_auth();
            cc.alpn_protocols = vec![b"h2".to_vec()];
            let name = tokio_rustls::rustls::pki_types::ServerName::try_from(host.clone()).map_err(|e| anyhow_like::err(format!("tls name: {e}")))?;
            let stream = tokio_rustls::TlsConnector::from(Arc::new(cc))
                .connect(name, tcp)
                .await
                .map_err(|e| anyhow_like::err(format!("APNs TLS: {e}")))?;
            let (send, conn) = h2::client::handshake(stream).await.map_err(|e| anyhow_like::err(format!("APNs h2: {e}")))?;
            tokio::spawn(async move {
                let _ = conn.await;
            });
            Ok(send)
        } else {
            let (send, conn) = h2::client::handshake(tcp).await.map_err(|e| anyhow_like::err(format!("APNs h2c: {e}")))?;
            tokio::spawn(async move {
                let _ = conn.await;
            });
            Ok(send)
        }
    }

    pub async fn send(&self, p: &Push<'_>) -> Outcome {
        if let Some(path) = &self.cfg.dry_run_log {
            let line = serde_json::json!({
                "device_token": p.device_token, "topic": p.topic, "push_type": p.push_type,
                "priority": p.priority, "expiration": p.expiration, "sandbox": p.sandbox,
                "payload": serde_json::from_slice::<serde_json::Value>(p.payload).unwrap_or_default(),
            });
            use std::io::Write;
            let r = std::fs::OpenOptions::new().create(true).append(true).open(path).and_then(|mut f| writeln!(f, "{line}"));
            return match r {
                Ok(()) => Outcome::Sent,
                Err(e) => Outcome::Failed(format!("dry-run log: {e}")),
            };
        }
        let base = if p.sandbox { self.cfg.sandbox_url.clone() } else { self.cfg.production_url.clone() };
        // one retry on a fresh connection (APNs closes idle connections)
        for attempt in 0..2 {
            match self.try_send(&base, p).await {
                Ok(o) => return o,
                Err(e) => {
                    self.conns.lock().await.remove(&base);
                    if attempt == 1 {
                        return Outcome::Failed(e.0);
                    }
                }
            }
        }
        Outcome::Failed("unreachable".into())
    }

    async fn try_send(&self, base: &str, p: &Push<'_>) -> anyhow_like::Result<Outcome> {
        let jwt = self.jwt()?;
        let mut send = {
            let mut conns = self.conns.lock().await;
            match conns.get(base) {
                Some(s) => s.clone(),
                None => {
                    let s = Self::connect(base).await?;
                    conns.insert(base.to_string(), s.clone());
                    s
                }
            }
        };
        send = send.ready().await.map_err(|e| anyhow_like::err(format!("h2 not ready: {e}")))?;
        let uri = format!("{}/3/device/{}", base.trim_end_matches('/'), p.device_token);
        let mut req = http::Request::builder()
            .method(http::Method::POST)
            .uri(uri)
            .header("authorization", format!("bearer {jwt}"))
            .header("apns-topic", p.topic)
            .header("apns-push-type", p.push_type)
            .header("apns-priority", p.priority.to_string())
            .header("apns-expiration", p.expiration.to_string())
            .header("content-type", "application/json");
        if p.push_type == "voip" {
            req = req.header("apns-collapse-id", "lumora-call");
        }
        let req = req.body(()).map_err(|e| anyhow_like::err(format!("request: {e}")))?;
        let (resp, mut body) = send.send_request(req, false).map_err(|e| anyhow_like::err(format!("send: {e}")))?;
        body.send_data(Bytes::copy_from_slice(p.payload), true).map_err(|e| anyhow_like::err(format!("send body: {e}")))?;
        let resp = tokio::time::timeout(Duration::from_secs(15), resp)
            .await
            .map_err(|_| anyhow_like::err("APNs response timeout"))?
            .map_err(|e| anyhow_like::err(format!("APNs response: {e}")))?;
        let status = resp.status().as_u16();
        let mut rb = resp.into_body();
        let mut data = Vec::new();
        while let Some(chunk) = rb.data().await {
            let chunk = chunk.map_err(|e| anyhow_like::err(format!("body: {e}")))?;
            let _ = rb.flow_control().release_capacity(chunk.len());
            data.extend_from_slice(&chunk);
            if data.len() > 4096 {
                break;
            }
        }
        let reason = serde_json::from_slice::<serde_json::Value>(&data)
            .ok()
            .and_then(|v| v["reason"].as_str().map(String::from))
            .unwrap_or_default();
        Ok(match status {
            200 => Outcome::Sent,
            410 => Outcome::Dead(if reason.is_empty() { "Unregistered".into() } else { reason }),
            400 if matches!(reason.as_str(), "BadDeviceToken" | "DeviceTokenNotForTopic") => Outcome::Dead(reason),
            _ => Outcome::Failed(format!("APNs {status} {reason}")),
        })
    }
}

/// Tiny error type so the library needs no `anyhow`.
pub mod anyhow_like {
    #[derive(Debug)]
    pub struct Error(pub String);
    impl std::fmt::Display for Error {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str(&self.0)
        }
    }
    impl std::error::Error for Error {}
    pub type Result<T> = std::result::Result<T, Error>;
    pub fn err(s: impl Into<String>) -> Error {
        Error(s.into())
    }
}

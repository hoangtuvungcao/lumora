//! The HTTP side of the bridge: `POST /wake`, `GET /pubkey`, `GET /health`.
//!
//! Privacy rules enforced here:
//! * tokens arrive sealed and are opened only in memory; logs never contain them;
//! * the sender is not identified (no accounts, no sender field); its IP is used only
//!   for an in-memory rate limit;
//! * the push carries a localisation key (no text) plus the sender's opaque e2e blob.
//!
//! Abuse limits: sealed tokens expire ([`crate::TOKEN_TTL_SECS`]) and are revoked by a
//! newer registration generation (`POST /register`, or simply a wake carrying a newer
//! token); call wakes (PushKit rings the phone) are capped per device per minute and per
//! hour, and per sender address per device.

use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use axum::extract::{ConnectInfo, DefaultBodyLimit, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use parking_lot::Mutex;
use serde_json::json;

use crate::apns::{ApnsClient, Outcome, Push};
use crate::{b64, open_token, token_id, unb64, DeviceToken, KeyPair, RegisterRequest, WakeRequest, MAX_E2E, MAX_SEALED_TOKEN};

/// Token-bucket parameters: `burst` requests at once, then one per `every_secs`.
#[derive(Clone, Copy, Debug)]
pub struct Rate {
    pub burst: f64,
    pub every_secs: f64,
}

#[derive(Clone, Debug)]
pub struct Limits {
    /// Per device, message wakes. Senders already coalesce bursts; this protects users.
    pub msg: Rate,
    /// Per device, call wakes (each one rings the phone through PushKit).
    pub call: Rate,
    /// Per device, call wakes over an hour (the short-term limit alone would still allow
    /// a ring every 20 s, all day).
    pub call_hour: Rate,
    /// Per (sender address, device), call wakes: one caller can't use up the device's
    /// whole budget in a few seconds.
    pub call_sender: Rate,
    /// Per client IP, all requests.
    pub ip: Rate,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            msg: Rate { burst: 6.0, every_secs: 20.0 },
            // ≤ 3 rings at once, then one per 20 s; ≤ 20 per hour; one sender: 2, then 1/min
            call: Rate { burst: 3.0, every_secs: 20.0 },
            call_hour: Rate { burst: 20.0, every_secs: 180.0 },
            call_sender: Rate { burst: 2.0, every_secs: 60.0 },
            ip: Rate { burst: 60.0, every_secs: 1.0 },
        }
    }
}

pub struct BridgeConfig {
    pub keypair: KeyPair,
    /// Bundle ids this bridge serves (APNs topics). Tokens for other apps are refused.
    pub topics: Vec<String>,
    pub limits: Limits,
    /// Optional file that remembers dead token ids (hex, one per line) across restarts.
    pub dead_file: Option<PathBuf>,
    /// Optional file that remembers the newest registration generation per device token
    /// (`hex-id generation` per line) so revocations survive restarts.
    pub gen_file: Option<PathBuf>,
    /// Use the first `X-Forwarded-For` address as the client IP (behind a reverse proxy).
    pub trust_proxy: bool,
}

struct Bucket {
    tokens: f64,
    last: Instant,
}

#[derive(Default)]
pub struct Stats {
    pub accepted: u64,
    pub rate_limited: u64,
    pub dead: u64,
    pub failed: u64,
    pub bad: u64,
    /// Refused: the sealed token is past its expiry.
    pub expired: u64,
    /// Refused: a newer registration of the same device superseded the token.
    pub revoked: u64,
    pub registered: u64,
}

pub struct Bridge {
    cfg: BridgeConfig,
    apns: ApnsClient,
    buckets: Mutex<HashMap<(u8, [u8; 32]), Bucket>>,
    sender_buckets: Mutex<HashMap<(IpAddr, [u8; 32]), Bucket>>,
    ip_buckets: Mutex<HashMap<IpAddr, Bucket>>,
    dead: Mutex<HashSet<[u8; 32]>>,
    /// device token id → newest registration generation seen
    gens: Mutex<HashMap<[u8; 32], u64>>,
    pub stats: Mutex<Stats>,
}

/// Refill bucket `key` and return it (created full).
fn refill<K: std::hash::Hash + Eq + Copy>(map: &mut HashMap<K, Bucket>, key: K, r: Rate) -> &mut Bucket {
    let now = Instant::now();
    if map.len() > 200_000 {
        // stale entries are full buckets anyway: forgetting them changes nothing
        map.retain(|_, b| now.duration_since(b.last).as_secs_f64() < r.every_secs * r.burst);
    }
    let b = map.entry(key).or_insert(Bucket { tokens: r.burst, last: now });
    b.tokens = (b.tokens + now.duration_since(b.last).as_secs_f64() / r.every_secs).min(r.burst);
    b.last = now;
    b
}

fn take<K: std::hash::Hash + Eq + Copy>(map: &mut HashMap<K, Bucket>, key: K, r: Rate) -> bool {
    let b = refill(map, key, r);
    if b.tokens >= 1.0 {
        b.tokens -= 1.0;
        true
    } else {
        false
    }
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn valid_device_hex(d: &str) -> bool {
    !d.is_empty() && d.len() <= 200 && d.bytes().all(|c| c.is_ascii_hexdigit())
}

impl Bridge {
    pub fn new(cfg: BridgeConfig, apns: ApnsClient) -> Arc<Self> {
        let mut dead = HashSet::new();
        if let Some(p) = &cfg.dead_file {
            if let Ok(s) = std::fs::read_to_string(p) {
                for l in s.lines() {
                    let mut id = [0u8; 32];
                    if l.len() == 64 && data_encoding::HEXLOWER.decode_mut(l.as_bytes(), &mut id).is_ok() {
                        dead.insert(id);
                    }
                }
            }
        }
        let mut gens: HashMap<[u8; 32], u64> = HashMap::new();
        if let Some(p) = &cfg.gen_file {
            if let Ok(s) = std::fs::read_to_string(p) {
                let mut lines = 0usize;
                for l in s.lines() {
                    lines += 1;
                    let Some((h, g)) = l.split_once(' ') else { continue };
                    let mut id = [0u8; 32];
                    if let (64, Ok(_), Ok(g)) = (h.len(), data_encoding::HEXLOWER.decode_mut(h.as_bytes(), &mut id), g.trim().parse::<u64>()) {
                        let e = gens.entry(id).or_insert(0);
                        *e = (*e).max(g);
                    }
                }
                // append-only between restarts: compact when mostly superseded lines
                if lines > 2 * gens.len() + 1000 {
                    let body: String = gens.iter().map(|(id, g)| format!("{} {g}\n", data_encoding::HEXLOWER.encode(id))).collect();
                    let tmp = p.with_extension("tmp");
                    if std::fs::write(&tmp, body).is_ok() {
                        let _ = std::fs::rename(&tmp, p);
                    }
                }
            }
        }
        Arc::new(Bridge {
            cfg,
            apns,
            buckets: Mutex::new(HashMap::new()),
            sender_buckets: Mutex::new(HashMap::new()),
            ip_buckets: Mutex::new(HashMap::new()),
            dead: Mutex::new(dead),
            gens: Mutex::new(gens),
            stats: Mutex::new(Stats::default()),
        })
    }

    /// Newest generation known for any of this token's device ids, after raising it to
    /// `dev.gen` (a token can only make older ones stale, never newer ones).
    fn note_generation(&self, dev: &DeviceToken) -> u64 {
        let ids: Vec<[u8; 32]> = [dev.apns.as_str(), dev.voip.as_str()].into_iter().filter(|d| !d.is_empty()).map(token_id).collect();
        let mut g = self.gens.lock();
        let newest = ids.iter().filter_map(|id| g.get(id).copied()).max().unwrap_or(0);
        if dev.gen > newest {
            for id in &ids {
                g.insert(*id, dev.gen);
            }
            drop(g);
            if let Some(p) = &self.cfg.gen_file {
                use std::io::Write;
                if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(p) {
                    for id in &ids {
                        let _ = writeln!(f, "{} {}", data_encoding::HEXLOWER.encode(id), dev.gen);
                    }
                }
            }
            return dev.gen;
        }
        newest
    }

    /// Open a sealed token and apply the token policy (app, expiry, revocation).
    fn open_checked(&self, token_b64: &str) -> Result<DeviceToken, (StatusCode, &'static str)> {
        let bad = |code| {
            self.stats.lock().bad += 1;
            Err((StatusCode::BAD_REQUEST, code))
        };
        let Some(sealed) = unb64(token_b64).filter(|s| s.len() <= MAX_SEALED_TOKEN) else { return bad("bad_token") };
        let Ok(dev) = open_token(&self.cfg.keypair, &sealed) else { return bad("bad_token") };
        if !self.cfg.topics.contains(&dev.topic) {
            self.stats.lock().bad += 1;
            return Err((StatusCode::FORBIDDEN, "wrong_app"));
        }
        if !valid_device_hex(&dev.apns) || !(dev.voip.is_empty() || valid_device_hex(&dev.voip)) {
            return bad("bad_token");
        }
        // generation first: an expired *newer* token still revokes the older ones
        // (that is how a phone unregisters)
        if dev.gen < self.note_generation(&dev) {
            self.stats.lock().revoked += 1;
            return Err((StatusCode::GONE, "revoked"));
        }
        if dev.expired(now_secs()) {
            self.stats.lock().expired += 1;
            return Err((StatusCode::GONE, "expired"));
        }
        Ok(dev)
    }

    /// `POST /register`: record the token's generation (revoking older ones).
    pub fn register(&self, client: IpAddr, req: &RegisterRequest) -> (StatusCode, &'static str) {
        if !take(&mut self.ip_buckets.lock(), client, self.cfg.limits.ip) {
            self.stats.lock().rate_limited += 1;
            return (StatusCode::TOO_MANY_REQUESTS, "rate_limited");
        }
        match self.open_checked(&req.token) {
            Ok(_) => {
                self.stats.lock().registered += 1;
                (StatusCode::ACCEPTED, "ok")
            }
            Err(e) => e,
        }
    }

    pub fn public_key(&self) -> [u8; 32] {
        self.cfg.keypair.public
    }

    fn mark_dead(&self, id: [u8; 32]) {
        if self.dead.lock().insert(id) {
            if let Some(p) = &self.cfg.dead_file {
                use std::io::Write;
                if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(p) {
                    let _ = writeln!(f, "{}", data_encoding::HEXLOWER.encode(&id));
                }
            }
        }
    }

    /// Handle one wake request; returns (HTTP status, short machine-readable code).
    pub async fn wake(&self, client: IpAddr, req: &WakeRequest) -> (StatusCode, &'static str) {
        if !take(&mut self.ip_buckets.lock(), client, self.cfg.limits.ip) {
            self.stats.lock().rate_limited += 1;
            return (StatusCode::TOO_MANY_REQUESTS, "rate_limited");
        }
        let kind: u8 = match req.kind.as_str() {
            "msg" => 0,
            "call" => 1,
            _ => {
                self.stats.lock().bad += 1;
                return (StatusCode::BAD_REQUEST, "bad_kind");
            }
        };
        let dev = match self.open_checked(&req.token) {
            Ok(d) => d,
            Err(e) => return e,
        };
        let e2e = if req.e2e.is_empty() {
            None
        } else {
            match unb64(&req.e2e) {
                Some(b) if b.len() <= MAX_E2E => Some(b64(&b)),
                _ => {
                    self.stats.lock().bad += 1;
                    return (StatusCode::BAD_REQUEST, "bad_e2e");
                }
            }
        };
        // calls ring through PushKit when the device registered a VoIP token,
        // otherwise they fall back to an ordinary "incoming call" notification
        let voip = kind == 1 && !dev.voip.is_empty();
        let device = if voip { dev.voip.as_str() } else { dev.apns.as_str() };
        let id = token_id(device);
        if self.dead.lock().contains(&id) {
            self.stats.lock().dead += 1;
            return (StatusCode::GONE, "unregistered");
        }
        let allowed = if kind == 1 {
            // every call limit must have room; only then is one token taken from each
            let l = &self.cfg.limits;
            let mut b = self.buckets.lock();
            let mut sb = self.sender_buckets.lock();
            let ok = refill(&mut b, (1, id), l.call).tokens >= 1.0
                && refill(&mut b, (2, id), l.call_hour).tokens >= 1.0
                && refill(&mut sb, (client, id), l.call_sender).tokens >= 1.0;
            if ok {
                refill(&mut b, (1, id), l.call).tokens -= 1.0;
                refill(&mut b, (2, id), l.call_hour).tokens -= 1.0;
                refill(&mut sb, (client, id), l.call_sender).tokens -= 1.0;
            }
            ok
        } else {
            take(&mut self.buckets.lock(), (0, id), self.cfg.limits.msg)
        };
        if !allowed {
            self.stats.lock().rate_limited += 1;
            return (StatusCode::TOO_MANY_REQUESTS, "rate_limited");
        }
        let now = now_secs();
        let mut lumora = json!({"k": if kind == 1 { "call" } else { "msg" }});
        if let Some(e) = &e2e {
            lumora["e2e"] = json!(e);
        }
        let (payload, topic, push_type, expiration) = if voip {
            (json!({"aps": {}, "lumora": lumora}), format!("{}.voip", dev.topic), "voip", 0)
        } else {
            let key = if kind == 1 { "PUSH_INCOMING_CALL" } else { "PUSH_NEW_MESSAGE" };
            (
                json!({"aps": {"alert": {"loc-key": key}, "sound": "default", "mutable-content": 1, "thread-id": "lumora"}, "lumora": lumora}),
                dev.topic.clone(),
                "alert",
                if kind == 1 { now + 60 } else { now + 86_400 },
            )
        };
        let body = payload.to_string();
        let outcome = self
            .apns
            .send(&Push { sandbox: dev.sandbox, device_token: device, topic: &topic, push_type, priority: 10, expiration, payload: body.as_bytes() })
            .await;
        match outcome {
            Outcome::Sent => {
                self.stats.lock().accepted += 1;
                (StatusCode::ACCEPTED, "ok")
            }
            Outcome::Dead(reason) => {
                tracing::info!("token unregistered by APNs ({reason})");
                self.mark_dead(id);
                self.stats.lock().dead += 1;
                (StatusCode::GONE, "unregistered")
            }
            Outcome::Failed(e) => {
                tracing::warn!("APNs: {e}");
                self.stats.lock().failed += 1;
                (StatusCode::BAD_GATEWAY, "apns_failed")
            }
        }
    }
}

fn client_ip(b: &Bridge, peer: SocketAddr, headers: &HeaderMap) -> IpAddr {
    if b.cfg.trust_proxy {
        if let Some(ip) = headers
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split(',').next())
            .and_then(|v| v.trim().parse().ok())
        {
            return ip;
        }
    }
    peer.ip()
}

async fn register_handler(
    State(b): State<Arc<Bridge>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let Ok(req) = serde_json::from_slice::<RegisterRequest>(&body) else {
        b.stats.lock().bad += 1;
        return (StatusCode::BAD_REQUEST, Json(json!({"ok": false, "code": "bad_json"}))).into_response();
    };
    let (status, code) = b.register(client_ip(&b, peer, &headers), &req);
    (status, Json(json!({"ok": status == StatusCode::ACCEPTED, "code": code}))).into_response()
}

async fn wake_handler(
    State(b): State<Arc<Bridge>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let Ok(req) = serde_json::from_slice::<WakeRequest>(&body) else {
        b.stats.lock().bad += 1;
        return (StatusCode::BAD_REQUEST, Json(json!({"ok": false, "code": "bad_json"}))).into_response();
    };
    let (status, code) = b.wake(client_ip(&b, peer, &headers), &req).await;
    (status, Json(json!({"ok": status == StatusCode::ACCEPTED, "code": code}))).into_response()
}

pub fn router(bridge: Arc<Bridge>) -> Router {
    Router::new()
        .route("/wake", post(wake_handler))
        .route("/register", post(register_handler))
        .route(
            "/pubkey",
            get(|State(b): State<Arc<Bridge>>| async move { Json(json!({"public_key": b64(&b.public_key()), "topics": b.cfg.topics})) }),
        )
        .route(
            "/health",
            get(|State(b): State<Arc<Bridge>>| async move {
                let s = b.stats.lock();
                Json(json!({"ok": true, "dry_run": b.apns.is_dry_run(), "accepted": s.accepted, "rate_limited": s.rate_limited,
                            "dead": s.dead, "failed": s.failed, "bad": s.bad, "expired": s.expired, "revoked": s.revoked,
                            "registered": s.registered}))
            }),
        )
        .layer(DefaultBodyLimit::max(8 * 1024))
        .with_state(bridge)
}

/// Serve until the listener fails.
pub async fn serve(listener: tokio::net::TcpListener, bridge: Arc<Bridge>) -> std::io::Result<()> {
    axum::serve(listener, router(bridge).into_make_service_with_connect_info::<SocketAddr>()).await
}

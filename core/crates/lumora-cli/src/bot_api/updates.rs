//! Pending updates (Bot API `Update` objects) with increasing `update_id`s, handed out by
//! `getUpdates` or pushed to the webhook. Kept in `<data>/bot_api.json` (with the webhook
//! settings) so a restart of the runner loses nothing: at most 1000 updates, 24 hours.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

pub const MAX_PENDING: usize = 1000;
pub const MAX_AGE_MS: u64 = 24 * 3600 * 1000;

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct Webhook {
    pub url: String,
    #[serde(default)]
    pub secret_token: Option<String>,
    #[serde(default = "default_max_conn")]
    pub max_connections: u32,
    #[serde(default)]
    pub allowed_updates: Option<Vec<String>>,
}

fn default_max_conn() -> u32 {
    40
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Pending {
    /// when it was queued (ms)
    pub at: u64,
    pub update: Value,
}

impl Pending {
    pub fn id(&self) -> i64 {
        self.update["update_id"].as_i64().unwrap_or(0)
    }
    pub fn kind(&self) -> &str {
        self.update.as_object().and_then(|o| o.keys().find(|k| *k != "update_id")).map(|k| k.as_str()).unwrap_or("")
    }
}

#[derive(Serialize, Deserialize, Default)]
pub struct State {
    pub next_update_id: i64,
    #[serde(default)]
    pub pending: VecDeque<Pending>,
    #[serde(default)]
    pub webhook: Option<Webhook>,
    /// `allowed_updates` of the last getUpdates call (kept for later calls)
    #[serde(default)]
    pub poll_allowed: Option<Vec<String>>,
    #[serde(skip)]
    pub last_error_date: Option<i64>,
    #[serde(skip)]
    pub last_error_message: Option<String>,
    /// bumped by every getUpdates / setWebhook: an older long poll still waiting ends
    #[serde(skip)]
    pub poll_gen: u64,
}

pub struct Store {
    pub state: Mutex<State>,
    /// wakes long polls and the webhook sender (new update, settings changed)
    pub notify: tokio::sync::Notify,
    path: Option<PathBuf>,
    dirty: AtomicBool,
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

impl Store {
    pub fn open(path: Option<PathBuf>) -> Store {
        let mut st: State = path
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        if st.next_update_id <= 0 {
            st.next_update_id = 1;
        }
        let cutoff = now_ms().saturating_sub(MAX_AGE_MS);
        st.pending.retain(|p| p.at >= cutoff);
        Store { state: Mutex::new(st), notify: tokio::sync::Notify::new(), path, dirty: AtomicBool::new(false) }
    }

    pub fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn mark_dirty(&self) {
        self.dirty.store(true, Ordering::SeqCst);
    }

    /// Queue an update (`kind` → payload); returns its id.
    pub fn push(&self, kind: &str, payload: Value) -> i64 {
        let id = {
            let mut st = self.lock();
            let id = st.next_update_id;
            st.next_update_id += 1;
            let mut u = serde_json::Map::new();
            u.insert("update_id".into(), Value::from(id));
            u.insert(kind.into(), payload);
            st.pending.push_back(Pending { at: now_ms(), update: Value::Object(u) });
            let cutoff = now_ms().saturating_sub(MAX_AGE_MS);
            while st.pending.len() > MAX_PENDING || st.pending.front().map(|p| p.at < cutoff).unwrap_or(false) {
                st.pending.pop_front();
            }
            id
        };
        self.mark_dirty();
        self.notify.notify_waiters();
        id
    }

    /// Forget updates with an id below `offset` (getUpdates confirmation / delivered).
    pub fn confirm(&self, offset: i64) {
        let mut st = self.lock();
        let before = st.pending.len();
        st.pending.retain(|p| p.id() >= offset);
        if st.pending.len() != before {
            self.mark_dirty();
        }
    }

    /// Write the state file when something changed (called periodically).
    pub fn flush(&self) {
        let Some(path) = &self.path else { return };
        if !self.dirty.swap(false, Ordering::SeqCst) {
            return;
        }
        let bytes = match serde_json::to_vec(&*self.lock()) {
            Ok(b) => b,
            Err(_) => return,
        };
        let tmp = path.with_extension("json.tmp");
        let ok = (|| -> std::io::Result<()> {
            let mut o = std::fs::OpenOptions::new();
            o.write(true).create(true).truncate(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                o.mode(0o600); // holds the webhook secret
            }
            let mut f = o.open(&tmp)?;
            std::io::Write::write_all(&mut f, &bytes)?;
            f.sync_all()?;
            std::fs::rename(&tmp, path)
        })();
        if let Err(e) = ok {
            tracing::warn!("bot api: could not save {}: {e}", path.display());
            self.mark_dirty();
        }
    }
}

/// Is an update of `kind` wanted by this `allowed_updates` list (`None`/empty = default set)?
pub fn allowed(list: &Option<Vec<String>>, kind: &str) -> bool {
    match list {
        Some(l) if !l.is_empty() => l.iter().any(|k| k == kind),
        _ => true,
    }
}

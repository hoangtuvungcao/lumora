//! Locked chats ("Khoá cuộc trò chuyện"): which chats sit behind the PIN.
//!
//! The list is an account setting (`privacy.locked_chats`, synced to every device of
//! the account), so a chat locked on the phone is hidden on the laptop too and its
//! notifications show no name or text there. The PIN itself stays per device
//! (`ui_secret` "ui.pin"). The app keeps a copy of the list only as a cache; the
//! encrypted database is the source of truth.

use super::*;
use crate::store::Store;

pub const LOCKED_CHATS_KEY: &str = "privacy.locked_chats";
const MAX_CHATS: usize = 1000;
const MAX_CONV_LEN: usize = 200;

/// The locked chats; `None` when no device of the account has saved a list yet.
pub fn locked_chats(store: &Store) -> Option<Vec<String>> {
    store.kv_get(LOCKED_CHATS_KEY).and_then(|v| serde_json::from_slice::<Vec<String>>(&v).ok())
}

/// Replaces the list (an empty list is kept as such: "nothing locked" is a value
/// too, it must win over older lists on other devices).
pub fn set_locked_chats(store: &Store, chats: &[String]) -> Result<Vec<String>> {
    let mut out: Vec<String> = vec![];
    for c in chats.iter().map(|c| c.trim()) {
        anyhow::ensure!(!c.is_empty() && c.len() <= MAX_CONV_LEN, "bad conversation id");
        if !out.iter().any(|x| x == c) {
            out.push(c.to_string());
        }
    }
    anyhow::ensure!(out.len() <= MAX_CHATS, "too many locked chats (max {MAX_CHATS})");
    store.kv_set(LOCKED_CHATS_KEY, &serde_json::to_vec(&out)?)?;
    Ok(out)
}

pub fn is_chat_locked(store: &Store, conv: &str) -> bool {
    !conv.is_empty() && locked_chats(store).is_some_and(|l| l.iter().any(|c| c == conv))
}

impl Node {
    /// Whether `conv` is a locked chat (events about it carry `"locked": true`, so every
    /// device hides its notification content even before its cached list catches up).
    pub fn chat_locked(&self, conv: &str) -> bool {
        is_chat_locked(&self.store, conv)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::sync::{kv_synced, SyncItem, K_KV};

    #[test]
    fn locked_chats_are_an_account_setting() {
        let phone = Store::open_memory().unwrap();
        phone.set_sync_enabled(true);
        let me = Identity::generate().peer_id();
        assert_eq!(locked_chats(&phone), None, "never saved");
        let l = set_locked_chats(&phone, &["d:A".into(), " d:A ".into(), "g:B".into()]).unwrap();
        assert_eq!(l, vec!["d:A".to_string(), "g:B".to_string()]);
        assert!(is_chat_locked(&phone, "d:A") && !is_chat_locked(&phone, "d:C") && !is_chat_locked(&phone, ""));
        assert!(set_locked_chats(&phone, &["".into()]).is_err());
        assert!(set_locked_chats(&phone, &["x".repeat(MAX_CONV_LEN + 1)]).is_err());
        assert!(set_locked_chats(&phone, &(0..=MAX_CHATS).map(|i| format!("d:{i}")).collect::<Vec<_>>()).is_err());
        assert_eq!(locked_chats(&phone).unwrap().len(), 2, "a refused list changes nothing");

        // the laptop gets it live and in a new device's bootstrap
        assert!(kv_synced(LOCKED_CHATS_KEY));
        let laptop = Store::open_memory().unwrap();
        laptop.set_sync_enabled(true);
        let it = phone.sync_export(K_KV, LOCKED_CHATS_KEY.as_bytes()).unwrap();
        laptop.sync_import(&it, &me, true).unwrap();
        assert!(is_chat_locked(&laptop, "g:B"));
        assert!(phone.bootstrap_items().iter().any(|i| matches!(i, SyncItem::Kv { key, .. } if key == LOCKED_CHATS_KEY)));

        // unlocking everything on the laptop is a value too: it reaches the phone
        set_locked_chats(&laptop, &[]).unwrap();
        let it = laptop.sync_export(K_KV, LOCKED_CHATS_KEY.as_bytes()).unwrap();
        phone.sync_import(&it, &me, true).unwrap();
        assert_eq!(locked_chats(&phone), Some(vec![]));
        assert!(!is_chat_locked(&phone, "d:A"));
    }
}

//! Checklists ("Danh sách việc") and reminders ("Nhắc hẹn").
//!
//! Both are ordinary signed chat messages; their changing state (ticks, "seen", cancelled)
//! lives in the message's reactions JSON under "__" keys and is driven by signed `MsgAction`s,
//! so it syncs the same way reactions and poll votes do (1-1, groups, offline outbox).

use super::*;
use crate::proto::{Body, ChatMsg, CheckItem, MsgAction, MsgMeta};
use crate::store::StoredMessage;

pub const MAX_CHECK_ITEMS: usize = 100;
const MAX_TEXT: usize = 200;
const MAX_NOTE: usize = 1000;
/// Upper bound on reminders waiting to fire on this device.
const MAX_PENDING: usize = 2000;
/// A reminder that is more than this late (device was off, message arrived late) is not raised.
const STALE_MS: u64 = 24 * 3600 * 1000;
/// Received reminders further ahead than this are not scheduled (the UI allows ≤ 1 year).
const MAX_AHEAD_MS: u64 = 366 * 86_400_000;
/// Reminders from one other person waiting on this device (a flood can't fill the list).
const MAX_PER_SENDER: usize = 50;
const PENDING_KEY: &str = "reminders.pending";

/// Serialises read-modify-write of the pending list (sender, receiver and scheduler tasks).
static PENDING_LOCK: Mutex<()> = parking_lot::const_mutex(());

#[derive(Serialize, Deserialize, Clone, Debug)]
struct PendingReminder {
    id: String,
    conv: String,
    at: u64,
    #[serde(default)]
    author: String,
}

fn clean_text(s: &str, max: usize) -> String {
    s.trim().chars().take(max).collect::<String>().trim().to_string()
}

fn clean_items(items: &[String]) -> Vec<String> {
    items.iter().map(|t| clean_text(t, MAX_TEXT)).filter(|t| !t.is_empty()).collect()
}

fn item_ids(m: &StoredMessage) -> Vec<u32> {
    m.body["items"].as_array().map(|a| a.iter().filter_map(|i| i["id"].as_u64()).map(|x| x as u32).collect()).unwrap_or_default()
}

/// Plain-text copy of a checklist / reminder for peers on an older app (in the sender's language).
pub(super) fn fallback_body(body: &Body) -> Option<Body> {
    match body {
        Body::Checklist { title, items } => {
            let mut t = crate::i18n::trf("pv.checklist", &[("title", title)]);
            for it in items {
                t.push_str(&format!("\n• {}", it.text));
            }
            Some(Body::Text { text: t })
        }
        Body::Reminder { title, at_ms, note } => {
            let mut t = crate::i18n::trf("pv.reminder", &[("title", title)]);
            t.push('\n');
            t.push_str(&crate::i18n::trf("pv.reminder_at", &[("time", &crate::util::fmt_utc_time(*at_ms))]));
            if !note.is_empty() {
                t.push('\n');
                t.push_str(note);
            }
            Some(Body::Text { text: t })
        }
        _ => None,
    }
}

/// Actions only peers on protocol v2+ understand.
pub(super) fn action_is_v2(a: &MsgAction) -> bool {
    matches!(
        a,
        MsgAction::ChecklistToggle { .. } | MsgAction::ChecklistAdd { .. } | MsgAction::ReminderCancel { .. } | MsgAction::ReminderSeen { .. }
    )
}

impl Node {
    /// Remember the protocol version a peer announced (persisted: decisions are also made
    /// while it is offline).
    pub(super) fn record_peer_proto(&self, p: &PeerId, version: u32) {
        // Persisted only for devices we keep something about (own, contacts, known
        // devices, co-members): a stranger's Hello must not grow the database — its version
        // lives in a bounded in-memory cache (see `peer_proto`).
        let acc = self.account_of(p);
        let known = acc == self.me
            || self.store.contact(&acc).map(|c| c.status > 0).unwrap_or(false)
            || self.store.device_get(p).is_some()
            || self.groups.read().values().any(|g| g.is_member(&self.me) && g.is_member(&acc));
        if !known {
            self.stranger_proto.lock().put(*p, version);
            return;
        }
        let k = format!("peer.proto.{}", p.to_base32());
        if self.store.kv_get(&k).map(|v| v != version.to_le_bytes()).unwrap_or(true) {
            let _ = self.store.kv_set(&k, &version.to_le_bytes());
        }
    }

    /// Whether `p` is known to understand checklists, reminders, silent messages and wake requests.
    pub(super) fn peer_speaks_v2(&self, p: &PeerId) -> bool {
        self.peer_proto(p) >= crate::proto::PROTO_V2
    }

    /// A message of `kind` in `conv` (user-facing "no longer exists" otherwise).
    fn task_msg(&self, conv: &str, id: &[u8; 16], kind: &str) -> Result<StoredMessage> {
        let m = self.store.message(id).ok_or_else(|| crate::i18n::user_err("err.message_not_found"))?;
        anyhow::ensure!(m.conv == conv && m.kind == kind && !m.deleted, crate::i18n::user_err("err.message_not_found"));
        Ok(m)
    }

    // ------------------------------------------------------------ checklist

    pub async fn send_checklist(self: &Arc<Self>, conv: &str, title: &str, items: &[String], meta: MsgMeta) -> Result<Value> {
        let title = clean_text(title, MAX_TEXT);
        anyhow::ensure!(!title.is_empty(), crate::i18n::user_err("err.checklist_title"));
        let items = clean_items(items);
        anyhow::ensure!(
            (1..=MAX_CHECK_ITEMS).contains(&items.len()),
            crate::i18n::user_err("err.checklist_items").with("max", MAX_CHECK_ITEMS)
        );
        let items = items.into_iter().enumerate().map(|(i, text)| CheckItem { id: i as u32 + 1, text }).collect();
        self.send_body_meta(conv, Body::Checklist { title, items }, None, None, meta).await
    }

    pub async fn checklist_toggle(self: &Arc<Self>, conv: &str, msg_id: [u8; 16], item: u32, done: bool) -> Result<()> {
        let m = self.task_msg(conv, &msg_id, "checklist")?;
        anyhow::ensure!(item_ids(&m).contains(&item), crate::i18n::user_err("err.checklist_item_missing"));
        let action = MsgAction::ChecklistToggle { target: msg_id, item, done, at: now_ms() };
        self.message_action(conv, msg_id, action).await
    }

    pub async fn checklist_add(self: &Arc<Self>, conv: &str, msg_id: [u8; 16], items: &[String]) -> Result<()> {
        let m = self.task_msg(conv, &msg_id, "checklist")?;
        anyhow::ensure!(m.author == self.me.to_base32(), crate::i18n::user_err("err.checklist_owner_only"));
        let ids = item_ids(&m);
        let items = clean_items(items);
        anyhow::ensure!(
            !items.is_empty() && ids.len() + items.len() <= MAX_CHECK_ITEMS,
            crate::i18n::user_err("err.checklist_items").with("max", MAX_CHECK_ITEMS)
        );
        let next = ids.iter().copied().max().unwrap_or(0) + 1;
        let items = items.into_iter().enumerate().map(|(i, text)| CheckItem { id: next + i as u32, text }).collect();
        self.message_action(conv, msg_id, MsgAction::ChecklistAdd { target: msg_id, items }).await
    }

    // ------------------------------------------------------------ reminders

    pub async fn send_reminder(self: &Arc<Self>, conv: &str, title: &str, at_ms: u64, note: &str, meta: MsgMeta) -> Result<Value> {
        let title = clean_text(title, MAX_TEXT);
        anyhow::ensure!(!title.is_empty(), crate::i18n::user_err("err.reminder_title"));
        let now = now_ms();
        anyhow::ensure!(at_ms > now && at_ms < now + MAX_AHEAD_MS, crate::i18n::user_err("err.reminder_past"));
        let note = clean_text(note, MAX_NOTE);
        self.send_body_meta(conv, Body::Reminder { title, at_ms, note }, None, None, meta).await
    }

    pub async fn reminder_cancel(self: &Arc<Self>, conv: &str, msg_id: [u8; 16]) -> Result<()> {
        let m = self.task_msg(conv, &msg_id, "reminder")?;
        anyhow::ensure!(m.author == self.me.to_base32(), crate::i18n::user_err("err.reminder_owner_only"));
        self.message_action(conv, msg_id, MsgAction::ReminderCancel { target: msg_id }).await
    }

    pub async fn reminder_seen(self: &Arc<Self>, conv: &str, msg_id: [u8; 16]) -> Result<()> {
        self.task_msg(conv, &msg_id, "reminder")?;
        self.message_action(conv, msg_id, MsgAction::ReminderSeen { target: msg_id }).await
    }

    /// Upcoming reminders on this device (soonest first).
    pub fn reminders(&self) -> Vec<Value> {
        let mut list: Vec<PendingReminder> = self.store.kv_get_json(PENDING_KEY).unwrap_or_default();
        list.sort_by_key(|r| r.at);
        list.into_iter()
            .filter_map(|r| {
                let id = hex::decode(&r.id).ok()?;
                let m = self.store.message(&id).filter(|m| !m.deleted && m.reactions.get("__cancelled").is_none())?;
                Some(json!({
                    "conv": r.conv, "msg_id": r.id, "at_ms": r.at, "title": m.body["title"], "note": m.body["note"], "author": m.author,
                }))
            })
            .collect()
    }

    /// Remember a newly stored reminder message so the scheduler raises it on time.
    pub(super) fn track_reminder(&self, conv: &str, m: &ChatMsg) {
        let Body::Reminder { at_ms, .. } = &m.body else { return };
        self.track_reminder_at(conv, &m.id, *at_ms, &m.author);
    }

    /// The same for a reminder copied from another of my devices (self-sync, history): it
    /// rings on every device of the account, like one that came from the network.
    pub(super) fn track_reminder_row(&self, m: &crate::store::StoredMessage) {
        if m.kind != "reminder" || m.deleted || m.reactions.get("__cancelled").is_some() {
            return;
        }
        let (Some(at), Ok(id), Ok(author)) = (m.body["at_ms"].as_u64(), hex::decode(&m.id), PeerId::from_str_any(&m.author)) else { return };
        let Ok(id) = <[u8; 16]>::try_from(id.as_slice()) else { return };
        self.track_reminder_at(&m.conv, &id, at, &author);
    }

    fn track_reminder_at(&self, conv: &str, id: &[u8; 16], at_ms: u64, author: &PeerId) {
        let now = now_ms();
        // long past, or absurdly far ahead (a sender could otherwise park thousands)
        if at_ms.saturating_add(STALE_MS) < now || at_ms > now + MAX_AHEAD_MS {
            return;
        }
        let _g = PENDING_LOCK.lock();
        let mut list: Vec<PendingReminder> = self.store.kv_get_json(PENDING_KEY).unwrap_or_default();
        let id = hex::encode(id);
        if list.iter().any(|r| r.id == id) {
            return;
        }
        let mine = *author == self.me;
        let author = author.to_base32();
        if list.len() >= MAX_PENDING {
            // make room from reminders whose message is gone (deleted, cleared, expired)
            list.retain(|r| hex::decode(&r.id).ok().and_then(|i| self.store.message(&i)).map(|m| !m.deleted).unwrap_or(false));
        }
        let from_sender = list.iter().filter(|r| r.author == author).count();
        if list.len() >= MAX_PENDING || (!mine && from_sender >= MAX_PER_SENDER) {
            return;
        }
        list.push(PendingReminder { id, conv: conv.to_string(), at: at_ms, author });
        let _ = self.store.kv_set_json(PENDING_KEY, &list);
    }

    /// Forget waiting reminders whose message is gone (history cleared, chat deleted).
    pub(super) fn prune_reminders(&self) {
        let _g = PENDING_LOCK.lock();
        let mut list: Vec<PendingReminder> = self.store.kv_get_json(PENDING_KEY).unwrap_or_default();
        let n = list.len();
        list.retain(|r| hex::decode(&r.id).ok().and_then(|i| self.store.message(&i)).map(|m| !m.deleted).unwrap_or(false));
        if list.len() != n {
            let _ = self.store.kv_set_json(PENDING_KEY, &list);
        }
    }

    #[cfg(test)]
    pub(super) fn reminders_raw(&self) -> Vec<String> {
        self.store.kv_get_json::<Vec<PendingReminder>>(PENDING_KEY).unwrap_or_default().into_iter().map(|r| r.id).collect()
    }

    pub(super) fn untrack_reminder(&self, id: &[u8; 16]) {
        let _g = PENDING_LOCK.lock();
        let mut list: Vec<PendingReminder> = self.store.kv_get_json(PENDING_KEY).unwrap_or_default();
        let id = hex::encode(id);
        let n = list.len();
        list.retain(|r| r.id != id);
        if list.len() != n {
            let _ = self.store.kv_set_json(PENDING_KEY, &list);
        }
    }

    /// Fires `reminder_due` for reminders whose time has come (checked every second).
    pub(super) fn spawn_reminders(self: Arc<Self>) {
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                let now = now_ms();
                let due = {
                    let _g = PENDING_LOCK.lock();
                    let list: Vec<PendingReminder> = self.store.kv_get_json(PENDING_KEY).unwrap_or_default();
                    if !list.iter().any(|r| r.at <= now) {
                        continue;
                    }
                    let (due, rest): (Vec<_>, Vec<_>) = list.into_iter().partition(|r| r.at <= now);
                    let _ = self.store.kv_set_json(PENDING_KEY, &rest);
                    due
                };
                for r in due {
                    let Some(m) = hex::decode(&r.id).ok().and_then(|id| self.store.message(&id)) else { continue };
                    if m.deleted || m.kind != "reminder" || m.reactions.get("__cancelled").is_some() || r.at + STALE_MS < now {
                        continue;
                    }
                    self.emit("reminder_due", json!({
                        "conv": r.conv, "msg_id": r.id, "title": m.body["title"], "note": m.body["note"],
                        "at_ms": r.at, "author": m.author, "mine": m.author == self.me.to_base32(),
                        "late": now.saturating_sub(r.at) > 60_000,
                    }));
                }
            }
        });
    }

    // ------------------------------------------------------------ applying actions

    /// Apply a checklist/reminder action from `actor` (already authorised for the conversation).
    /// `hlc`: the action's signed time (the same on every receiver).
    pub(super) fn apply_task_action(&self, conv: &str, actor: &PeerId, action: &MsgAction, hlc: u64) -> Result<()> {
        let who = actor.to_base32();
        let emit_state = |target: &[u8; 16], r: Value| {
            if !r.is_null() {
                self.emit("message_update", json!({"conv": conv, "id": hex::encode(target), "reactions": r}));
            }
        };
        match action {
            MsgAction::ChecklistToggle { target, item, done, at } => {
                let Some(m) = self.store.message(target).filter(|m| m.kind == "checklist") else { return Ok(()) };
                if !item_ids(&m).contains(item) {
                    return Ok(());
                }
                // a device with a clock far ahead must not pin an item forever: bounded by the
                // action's own signed time — the same bound on every member (a receiver's
                // own clock would let members disagree on who wins)
                let at = (*at).min(crate::util::hlc_to_ms(hlc));
                let r = self.store.patch_state(target, "checklist", |st| {
                    let checks = st.entry("__checks".to_string()).or_insert_with(|| json!({}));
                    let Some(obj) = checks.as_object_mut() else { return false };
                    let key = item.to_string();
                    if let Some(prev) = obj.get(&key) {
                        // last writer wins, everywhere (ties broken by the person's id)
                        let prev_key = (prev["at"].as_u64().unwrap_or(0), prev["by"].as_str().unwrap_or("").to_string());
                        if prev_key >= (at, who.clone()) {
                            return false;
                        }
                    }
                    obj.insert(key, json!({"done": done, "by": who, "at": at}));
                    true
                })?;
                emit_state(target, r);
            }
            MsgAction::ChecklistAdd { target, items } => {
                let Some(m) = self.store.message(target).filter(|m| m.kind == "checklist" && m.author == who && !m.deleted) else {
                    return Ok(());
                };
                let mut ids = item_ids(&m);
                let mut body = m.body.clone();
                let Some(list) = body["items"].as_array_mut() else { return Ok(()) };
                let mut changed = false;
                for it in items {
                    let text = clean_text(&it.text, MAX_TEXT);
                    if list.len() >= MAX_CHECK_ITEMS || text.is_empty() || ids.contains(&it.id) {
                        continue;
                    }
                    ids.push(it.id);
                    list.push(json!({"id": it.id, "text": text}));
                    changed = true;
                }
                if changed && self.store.update_body(target, actor, &body)? {
                    self.emit("message_update", json!({"conv": conv, "id": hex::encode(target), "body": body}));
                }
            }
            MsgAction::ReminderCancel { target } => {
                if self.store.message(target).map(|m| m.kind == "reminder" && m.author == who).unwrap_or(false) {
                    let r = self.store.patch_state(target, "reminder", |st| {
                        if st.contains_key("__cancelled") {
                            return false;
                        }
                        st.insert("__cancelled".into(), json!({"by": who, "at": now_ms()}));
                        true
                    })?;
                    self.untrack_reminder(target);
                    emit_state(target, r);
                }
            }
            MsgAction::ReminderSeen { target } => {
                let r = self.store.patch_state(target, "reminder", |st| {
                    let seen = st.entry("__seen".to_string()).or_insert_with(|| json!({}));
                    match seen.as_object_mut() {
                        Some(o) if !o.contains_key(&who) && o.len() < 1024 => {
                            o.insert(who.clone(), json!(now_ms()));
                            true
                        }
                        _ => false,
                    }
                })?;
                emit_state(target, r);
            }
            _ => {}
        }
        Ok(())
    }
}

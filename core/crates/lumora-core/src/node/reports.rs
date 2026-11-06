//! "Báo cáo / Report" without a server or a moderation team: a report goes to the
//! people who can act on it.
//!
//! * A message or a member of a group → the group's owner and admins (co-members, so the
//!   address gate lets it through), as `Ext GROUP_REPORT` through the outbox: every
//!   device of every admin gets it, offline devices later. The admin's device checks it
//!   (current member, the message / member really belongs to that group, rate limit per
//!   reporter, duplicates), keeps it until handled (kv `group.reports`, this device) and
//!   emits `group_report`. The excerpt shown is the admin's own copy of the message,
//!   never the reporter's text. Reporters never learn about each other.
//! * Handled on one admin device (dismissed / acted on) → `Ext GROUP_REPORT_DONE` to the
//!   account's other devices, which drop it too (`group_report_handled`).
//! * A whole group → leave it and block it: `privacy.blocked_groups`, an account setting
//!   synced to every device. A blocked group is hidden, left on every device, missing
//!   from public-group search, and its invites / join links are refused.
//! * "Hide this member's messages" → `privacy.hidden_members` (synced, the app hides
//!   their messages in every group).

use super::*;

pub const BLOCKED_GROUPS_KEY: &str = "privacy.blocked_groups";
pub const HIDDEN_MEMBERS_KEY: &str = "privacy.hidden_members";
/// Reports waiting for this (admin) device to handle them (local, never synced: every
/// device of the admin receives its own copy).
const REPORTS_KEY: &str = "group.reports";
/// Ids of reports already handled (on any device of the account): a late copy is dropped.
const REPORTS_DONE_KEY: &str = "group.reports_done";
pub const REPORT_REASONS: &[&str] = &["spam", "harassment", "adult", "other"];
const MAX_EXCERPT: usize = 200;
const MAX_NOTE: usize = 300;
const MAX_PENDING: usize = 200;
const MAX_DONE: usize = 1000;
const MAX_BLOCKED_GROUPS: usize = 500;
const MAX_HIDDEN: usize = 1000;
/// Reports one member may make an admin device take: 5, then one every 2 minutes
/// (5 per 10 minutes on average).
const REPORT_BURST: f64 = 5.0;
const REPORT_PER_S: f64 = 5.0 / 600.0;
const LIMIT_REPORT: u8 = 5;
/// A group blocked on another device: its Leave normally arrives with the setting; if
/// it doesn't, this device leaves itself after this long.
const BLOCK_LEAVE_WAIT: Duration = if cfg!(test) { Duration::from_millis(200) } else { Duration::from_secs(30) };

/// Pending-report list updates (read-modify-write of one kv value).
static REPORTS_LOCK: Mutex<()> = parking_lot::const_mutex(());

/// `Ext GROUP_REPORT` (member → each owner / admin of the group).
#[derive(Serialize, Deserialize, Default, Clone, Debug)]
pub(crate) struct GroupReportMsg {
    #[serde(default, with = "serde_bytes")]
    pub id: Vec<u8>,
    #[serde(default, with = "serde_bytes")]
    pub gid: Vec<u8>,
    /// The reported message (empty: the member as a whole).
    #[serde(default, with = "serde_bytes")]
    pub msg_id: Vec<u8>,
    /// ≤ 200 chars of the message's text, as the reporter saw it (informative only).
    #[serde(default)]
    pub excerpt: String,
    /// The reported member.
    #[serde(default, with = "serde_bytes")]
    pub member: Vec<u8>,
    /// One of [`REPORT_REASONS`].
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub note: String,
    #[serde(default)]
    pub ts: u64,
}

/// `Ext GROUP_REPORT_DONE` (own devices only): reports handled on the sender.
#[derive(Serialize, Deserialize, Default, Clone, Debug)]
pub(crate) struct GroupReportDoneMsg {
    #[serde(default)]
    pub ids: Vec<String>,
}

/// A report kept on an admin device until handled.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
struct StoredReport {
    id: String,
    gid: String,
    #[serde(default)]
    msg_id: Option<String>,
    #[serde(default)]
    excerpt: String,
    member: String,
    reporter: String,
    reason: String,
    #[serde(default)]
    note: String,
    ts: u64,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct BlockedGroup {
    pub gid: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub at: u64,
}

pub fn blocked_groups(store: &Store) -> Vec<BlockedGroup> {
    store.kv_get_json(BLOCKED_GROUPS_KEY).unwrap_or_default()
}

pub fn is_group_blocked(store: &Store, gid: &Gid) -> bool {
    let h = hex::encode(gid);
    blocked_groups(store).iter().any(|b| b.gid == h)
}

pub fn hidden_members(store: &Store) -> Vec<String> {
    store.kv_get_json(HIDDEN_MEMBERS_KEY).unwrap_or_default()
}

fn clip(s: &str, n: usize) -> String {
    s.trim().chars().take(n).collect()
}

/// Whether `conv` is one of the chats of group `gid` (main chat or a channel).
fn conv_in_group(conv: &str, gid: &Gid) -> bool {
    let main = conv_for(gid, "");
    conv == main || conv.strip_prefix(main.as_str()).is_some_and(|r| r.starts_with('#'))
}

/// The text of a stored message to show in a report (text messages only).
fn excerpt_of(m: &crate::store::StoredMessage) -> String {
    if m.kind != "text" || m.deleted {
        return String::new();
    }
    m.body.get("text").and_then(|t| t.as_str()).map(|t| clip(t, MAX_EXCERPT)).unwrap_or_default()
}

fn hex16(s: &str) -> Option<[u8; 16]> {
    hex::decode(s).ok().and_then(|v| v.try_into().ok())
}

impl Node {
    // ------------------------------------------------------------ reporter side

    /// Report a message (`msg_id`) or a member of a group to its owner and admins.
    /// `hide`: also hide the member's messages on all my devices.
    pub async fn group_report(self: &Arc<Self>, gid: Gid, msg_id: Option<[u8; 16]>, member: Option<PeerId>, reason: &str, note: &str, hide: bool) -> Result<Value> {
        let st = self.groups.read().get(&gid).cloned().ok_or_else(|| crate::i18n::user_err("err.group_not_found"))?;
        anyhow::ensure!(st.is_member(&self.me), crate::i18n::user_err("err.not_member"));
        anyhow::ensure!(REPORT_REASONS.contains(&reason), crate::i18n::user_err("err.report_reason"));
        let mut member = member;
        let mut excerpt = String::new();
        if let Some(mid) = msg_id {
            let m = self.store.message(&mid).ok_or_else(|| crate::i18n::user_err("err.message_not_found"))?;
            anyhow::ensure!(conv_in_group(&m.conv, &gid), crate::i18n::user_err("err.report_target"));
            let author = PeerId::from_str_any(&m.author)?;
            anyhow::ensure!(member.map(|p| p == author).unwrap_or(true), crate::i18n::user_err("err.report_target"));
            member = Some(author);
            excerpt = excerpt_of(&m);
        }
        let member = member.ok_or_else(|| crate::i18n::user_err("err.report_target"))?;
        anyhow::ensure!(member != self.me && (st.is_member(&member) || st.left.contains(&member)), crate::i18n::user_err("err.report_target"));
        // owner + admins, never the reported person (it would learn who reported it)
        let admins: Vec<PeerId> = st.members.iter().filter(|(p, r)| **r >= Role::Admin && **p != self.me && **p != member).map(|(p, _)| *p).collect();
        anyhow::ensure!(!admins.is_empty(), crate::i18n::user_err("err.report_no_admins"));
        let id: [u8; 16] = crate::crypto::random_bytes();
        let body = GroupReportMsg {
            id: id.to_vec(),
            gid: gid.to_vec(),
            msg_id: msg_id.map(|m| m.to_vec()).unwrap_or_default(),
            excerpt,
            member: member.0.to_vec(),
            reason: reason.to_string(),
            note: clip(note, MAX_NOTE),
            ts: now_ms(),
        };
        let msg = proto::ext(proto::ext::GROUP_REPORT, &body);
        // every device of every admin, reliably (outbox; offline devices get it later)
        for a in &admins {
            self.deliver(*a, id, msg.clone(), true).await;
        }
        if hide {
            self.set_member_hidden(&member, true)?;
        }
        tracing::info!("group {}: reported {member:?} to {} admins", hex::encode(gid), admins.len());
        Ok(json!({"id": hex::encode(id), "sent_to": admins.len()}))
    }

    /// "Hide this member's messages" (all groups, all my devices: an account setting).
    pub fn set_member_hidden(&self, peer: &PeerId, hidden: bool) -> Result<Vec<String>> {
        anyhow::ensure!(*peer != self.me, crate::i18n::user_err("err.own_id"));
        let p = peer.to_base32();
        let mut list = hidden_members(&self.store);
        list.retain(|x| *x != p);
        if hidden {
            list.push(p);
        }
        while list.len() > MAX_HIDDEN {
            list.remove(0);
        }
        self.store.kv_set_json(HIDDEN_MEMBERS_KEY, &list)?;
        self.emit("settings", json!({"key": HIDDEN_MEMBERS_KEY}));
        Ok(list)
    }

    // ------------------------------------------------------------ admin side

    /// `Ext GROUP_REPORT` from account `from` (connection or offline mail).
    pub(crate) fn on_group_report(&self, from: PeerId, body: &[u8]) -> Result<()> {
        let m: GroupReportMsg = proto::ext_body(body)?;
        let id: [u8; 16] = m.id.as_slice().try_into().map_err(|_| anyhow!("bad report id"))?;
        let gid: Gid = m.gid.as_slice().try_into().map_err(|_| anyhow!("bad gid"))?;
        let Some(st) = self.groups.read().get(&gid).cloned() else { return Ok(()) };
        let why = |w: &str| {
            tracing::info!("report from {from:?} in group {} dropped: {w}", hex::encode(gid));
            Ok(())
        };
        if st.role(&self.me).unwrap_or(Role::Member) < Role::Admin {
            return why("not an admin here");
        }
        if from == self.me || !st.is_member(&from) {
            return why("not a member");
        }
        if !REPORT_REASONS.contains(&m.reason.as_str()) {
            return why("unknown reason");
        }
        let mut member: Option<PeerId> = <[u8; 32]>::try_from(m.member.as_slice()).ok().map(PeerId);
        let mut msg_id = None;
        let mut excerpt = String::new();
        if !m.msg_id.is_empty() {
            let Ok(mid) = <[u8; 16]>::try_from(m.msg_id.as_slice()) else { return why("bad message id") };
            // checked against our own copy: the message must be in this group, by the
            // reported member (a message we don't have can't be checked)
            let Some(sm) = self.store.message(&mid) else { return why("unknown message") };
            if !conv_in_group(&sm.conv, &gid) {
                return why("message of another chat");
            }
            let Ok(author) = PeerId::from_str_any(&sm.author) else { return why("bad author") };
            if member.is_some_and(|p| p != author) {
                return why("message of someone else");
            }
            member = Some(author);
            msg_id = Some(hex::encode(mid));
            excerpt = excerpt_of(&sm);
        }
        let Some(member) = member else { return why("no target") };
        if member == from || !(st.is_member(&member) || st.left.contains(&member) || st.banned.contains(&member)) {
            return why("not a member of this group");
        }
        let id_hex = hex::encode(id);
        let rep = StoredReport {
            id: id_hex.clone(),
            gid: hex::encode(gid),
            msg_id,
            excerpt,
            member: member.to_base32(),
            reporter: from.to_base32(),
            reason: m.reason.clone(),
            note: clip(&m.note, MAX_NOTE),
            ts: now_ms(),
        };
        {
            let _g = REPORTS_LOCK.lock();
            let done: Vec<String> = self.store.kv_get_json(REPORTS_DONE_KEY).unwrap_or_default();
            let mut pending: Vec<StoredReport> = self.store.kv_get_json(REPORTS_KEY).unwrap_or_default();
            // the same report again (another path, a retry), or the same thing reported
            // twice by the same person
            if done.contains(&id_hex)
                || pending.iter().any(|p| p.id == id_hex || (p.reporter == rep.reporter && p.gid == rep.gid && p.member == rep.member && p.msg_id == rep.msg_id))
            {
                return why("duplicate");
            }
            if !super::group_bucket((LIMIT_REPORT, self.device, from, [0; 16]), REPORT_BURST, REPORT_PER_S) {
                return why("too many reports");
            }
            pending.push(rep.clone());
            if pending.len() > MAX_PENDING {
                let n = pending.len() - MAX_PENDING;
                pending.drain(..n);
            }
            self.store.kv_set_json(REPORTS_KEY, &pending)?;
        }
        if let Some(v) = self.report_json(&rep) {
            self.emit("group_report", v);
        }
        Ok(())
    }

    fn report_json(&self, r: &StoredReport) -> Option<Value> {
        let gid: Gid = hex16(&r.gid)?;
        let st = self.groups.read().get(&gid).cloned()?;
        let member = PeerId::from_str_any(&r.member).ok()?;
        let reporter = PeerId::from_str_any(&r.reporter).ok()?;
        // still there? (deleted / removed already: the admin sees the buttons it needs)
        let msg_exists = r.msg_id.as_deref().and_then(hex16).and_then(|m| self.store.message(&m)).map(|m| !m.deleted).unwrap_or(false);
        let conv = r.msg_id.as_deref().and_then(hex16).and_then(|m| self.store.message(&m)).map(|m| m.conv).unwrap_or_else(|| st.conv_id());
        Some(json!({
            "id": r.id, "gid": r.gid, "conv": conv, "group_name": st.name,
            "msg_id": r.msg_id, "excerpt": r.excerpt, "msg_exists": msg_exists,
            "member": r.member, "member_name": self.display(&member), "member_in_group": st.is_member(&member),
            "reporter": r.reporter, "reporter_name": self.display(&reporter),
            "reason": r.reason, "note": r.note, "ts": r.ts,
        }))
    }

    /// Reports waiting on this device (groups I still administer).
    pub fn group_reports(&self) -> Vec<Value> {
        let pending: Vec<StoredReport> = self.store.kv_get_json(REPORTS_KEY).unwrap_or_default();
        pending
            .iter()
            .filter(|r| {
                hex16(&r.gid).and_then(|g| self.groups.read().get(&g).map(|st| st.role(&self.me).unwrap_or(Role::Member) >= Role::Admin)).unwrap_or(false)
            })
            .filter_map(|r| self.report_json(r))
            .rev()
            .collect()
    }

    /// Handled here (dismissed, or the admin acted): gone on all my devices.
    pub async fn group_report_done(self: &Arc<Self>, ids: &[String]) -> Result<()> {
        let ids: Vec<String> = ids.iter().map(|i| i.trim().to_lowercase()).filter(|i| hex16(i).is_some()).take(100).collect();
        anyhow::ensure!(!ids.is_empty(), "no report ids");
        self.mark_reports_done(&ids)?;
        if !self.siblings().is_empty() {
            let id: [u8; 16] = crate::crypto::random_bytes();
            self.deliver(self.me, id, proto::ext(proto::ext::GROUP_REPORT_DONE, &GroupReportDoneMsg { ids }), true).await;
        }
        Ok(())
    }

    /// `Ext GROUP_REPORT_DONE` from `from` (only my own account counts).
    pub(crate) fn on_group_report_done(&self, from: PeerId, body: &[u8]) -> Result<()> {
        if from != self.me {
            return Ok(());
        }
        let m: GroupReportDoneMsg = proto::ext_body(body)?;
        let ids: Vec<String> = m.ids.into_iter().filter(|i| hex16(i).is_some()).take(100).collect();
        if !ids.is_empty() {
            self.mark_reports_done(&ids)?;
        }
        Ok(())
    }

    fn mark_reports_done(&self, ids: &[String]) -> Result<()> {
        {
            let _g = REPORTS_LOCK.lock();
            let mut done: Vec<String> = self.store.kv_get_json(REPORTS_DONE_KEY).unwrap_or_default();
            for i in ids {
                if !done.contains(i) {
                    done.push(i.clone());
                }
            }
            if done.len() > MAX_DONE {
                let n = done.len() - MAX_DONE;
                done.drain(..n);
            }
            self.store.kv_set_json(REPORTS_DONE_KEY, &done)?;
            let mut pending: Vec<StoredReport> = self.store.kv_get_json(REPORTS_KEY).unwrap_or_default();
            pending.retain(|p| !ids.contains(&p.id));
            self.store.kv_set_json(REPORTS_KEY, &pending)?;
        }
        self.emit("group_report_handled", json!({"ids": ids}));
        Ok(())
    }

    // ------------------------------------------------------------ blocked groups

    pub fn group_blocked(&self, gid: &Gid) -> bool {
        is_group_blocked(&self.store, gid)
    }

    /// Report a whole group: leave it and block it on all my devices.
    pub async fn group_block(self: &Arc<Self>, gid: Gid, name: &str) -> Result<Value> {
        let st = self.groups.read().get(&gid).cloned();
        let name = st.as_ref().map(|g| g.name.clone()).unwrap_or_else(|| clip(name, 64));
        let h = hex::encode(gid);
        let mut list = blocked_groups(&self.store);
        if !list.iter().any(|b| b.gid == h) {
            list.push(BlockedGroup { gid: h, name, at: now_ms() });
            while list.len() > MAX_BLOCKED_GROUPS {
                list.remove(0);
            }
            self.store.kv_set_json(BLOCKED_GROUPS_KEY, &list)?;
        }
        if st.as_ref().is_some_and(|g| g.is_member(&self.me)) {
            if let Err(e) = self.group_leave(gid).await {
                // still blocked and hidden; another device (or a retry) leaves
                tracing::warn!("blocking group {}: leave failed: {e:#}", hex::encode(gid));
            }
        }
        self.hide_blocked_group(&gid);
        self.emit("settings", json!({"key": BLOCKED_GROUPS_KEY}));
        Ok(json!(list))
    }

    /// Settings › Privacy: the blocked groups (newest first is up to the app).
    pub fn blocked_groups_list(&self) -> Value {
        json!(blocked_groups(&self.store))
    }

    pub fn hidden_members_list(&self) -> Value {
        json!(hidden_members(&self.store))
    }

    pub fn group_unblock(&self, gid: &Gid) -> Result<Value> {
        let h = hex::encode(gid);
        let mut list = blocked_groups(&self.store);
        list.retain(|b| b.gid != h);
        self.store.kv_set_json(BLOCKED_GROUPS_KEY, &list)?;
        self.emit("settings", json!({"key": BLOCKED_GROUPS_KEY}));
        Ok(json!(list))
    }

    /// The group's chats go away on this device (like leaving it).
    fn hide_blocked_group(&self, gid: &Gid) {
        let main = conv_for(gid, "");
        if !self.store.group_convs(&main).is_empty() {
            self.forget_left_group(gid);
            self.emit("group_removed", json!({"gid": hex::encode(gid), "conv": main, "left": true}));
        }
    }

    /// `privacy.blocked_groups` changed on another of my devices.
    pub(crate) fn on_blocked_groups_synced(self: &Arc<Self>) {
        for b in blocked_groups(&self.store) {
            let Some(gid) = hex16(&b.gid) else { continue };
            let member = self.groups.read().get(&gid).map(|g| g.is_member(&self.me)).unwrap_or(false);
            self.hide_blocked_group(&gid);
            if member {
                // the other device's Leave normally arrives with it; if not, leave here
                let me = self.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(BLOCK_LEAVE_WAIT).await;
                    let still = me.groups.read().get(&gid).map(|g| g.is_member(&me.me)).unwrap_or(false);
                    if still && me.group_blocked(&gid) {
                        let _ = me.group_leave(gid).await;
                    }
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::devices::{DeviceEntry, DeviceListBody};
    use crate::identity::Identity;

    async fn quiet_node(dir: &std::path::Path) -> Arc<Node> {
        Node::start(NodeConfig {
            data_dir: dir.join("data"),
            downloads_dir: Some(dir.join("dl")),
            enable_lan: false,
            enable_upnp: false,
            enable_dht: false,
            enable_nostr: false,
            relays: Some(vec![]),
            nostr: Some(vec![]),
            stun: Some(vec![]),
            ..Default::default()
        })
        .await
        .unwrap()
    }

    fn gid_of(v: &Value) -> Gid {
        hex::decode(v["gid"].as_str().unwrap()).unwrap().try_into().unwrap()
    }

    fn drain(rx: &mut broadcast::Receiver<Value>) -> Vec<Value> {
        let mut v = vec![];
        while let Ok(e) = rx.try_recv() {
            v.push(e);
        }
        v
    }

    fn report(gid: &Gid, msg: Option<[u8; 16]>, member: Option<PeerId>, reason: &str) -> Vec<u8> {
        let id: [u8; 16] = crate::crypto::random_bytes();
        rmp_serde::to_vec_named(&GroupReportMsg {
            id: id.to_vec(),
            gid: gid.to_vec(),
            msg_id: msg.map(|m| m.to_vec()).unwrap_or_default(),
            excerpt: "whatever the reporter claims".into(),
            member: member.map(|m| m.0.to_vec()).unwrap_or_default(),
            reason: reason.into(),
            note: "n".into(),
            ts: now_ms(),
        })
        .unwrap()
    }

    /// Ext messages of `kind` queued for device `dev`.
    fn queued(n: &Node, dev: &PeerId, kind: u16) -> usize {
        n.store
            .outbox_for(dev)
            .unwrap()
            .into_iter()
            .filter(|(_, p)| matches!(rmp_serde::from_slice::<PeerMsg>(p), Ok(PeerMsg::Wrapped { inner, .. }) if matches!(*inner, PeerMsg::Ext { kind: k, .. } if k == kind)))
            .count()
    }

    fn give_devices(n: &Node, account: PeerId, devs: &[PeerId]) {
        let body = DeviceListBody {
            v: 1,
            account,
            version: 1,
            devices: devs.iter().map(|d| DeviceEntry::new(*d, "d", 0, 0, now_ms())).collect(),
            revoked: vec![],
        };
        n.store.device_list_put(b"list", &body).unwrap();
    }

    /// The admin side keeps only reports it can check: from a current member, about a
    /// message of this group by the reported member, a known reason; the excerpt is its
    /// own copy; duplicates are dropped and each reporter is rate limited.
    #[tokio::test(flavor = "multi_thread")]
    async fn admin_validates_dedupes_and_rate_limits_reports() {
        let tmp = tempfile::tempdir().unwrap();
        let n = quiet_node(tmp.path()).await; // owner
        let bob = Identity::generate().peer_id();
        let carol = Identity::generate().peer_id();
        let stranger = Identity::generate().peer_id();
        let gid = gid_of(&n.create_group("G", vec![bob, carol], 0).await.unwrap());
        let other = gid_of(&n.create_group("Other", vec![bob, carol], 0).await.unwrap());
        let conv = conv_for(&gid, "");
        for i in 0..8u8 {
            n.store.insert_message(&[i; 16], &conv, &carol, n.hlc.tick(), "text", &json!({"text": format!("spam {i}")}), 2, None, None).unwrap();
        }
        n.store.insert_message(&[50; 16], &conv_for(&other, ""), &carol, n.hlc.tick(), "text", &json!({"text": "x"}), 2, None, None).unwrap();
        let mut ev = n.subscribe();

        // refused: stranger, bad reason, message of another group, wrong member, self, no target
        n.on_group_report(stranger, &report(&gid, Some([0; 16]), None, "spam")).unwrap();
        n.on_group_report(bob, &report(&gid, Some([0; 16]), None, "because")).unwrap();
        n.on_group_report(bob, &report(&gid, Some([50; 16]), None, "spam")).unwrap();
        n.on_group_report(bob, &report(&gid, Some([0; 16]), Some(n.me), "spam")).unwrap();
        n.on_group_report(bob, &report(&gid, None, Some(bob), "spam")).unwrap();
        n.on_group_report(bob, &report(&gid, None, Some(stranger), "spam")).unwrap();
        n.on_group_report(bob, &report(&gid, None, None, "spam")).unwrap();
        n.on_group_report(bob, &report(&gid, Some([77; 16]), None, "spam")).unwrap();
        assert!(drain(&mut ev).iter().all(|e| e["event"] != "group_report"), "an invalid report got through");
        assert!(n.group_reports().is_empty());

        // valid
        n.on_group_report(bob, &report(&gid, Some([0; 16]), None, "harassment")).unwrap();
        let evs = drain(&mut ev);
        let r = evs.iter().find(|e| e["event"] == "group_report").expect("no group_report");
        assert_eq!(r["member"], carol.to_base32());
        assert_eq!(r["reporter"], bob.to_base32());
        assert_eq!(r["excerpt"], "spam 0", "the admin shows its own copy");
        assert_eq!(r["msg_exists"], true);
        assert_eq!(r["conv"], conv.as_str());
        // the same message again by the same person: one report
        n.on_group_report(bob, &report(&gid, Some([0; 16]), None, "spam")).unwrap();
        // the same body twice (two paths): one report
        let b = report(&gid, Some([1; 16]), None, "spam");
        n.on_group_report(bob, &b).unwrap();
        n.on_group_report(bob, &b).unwrap();
        assert_eq!(n.group_reports().len(), 2);
        // rate limit: 5 per reporter, then nothing for a while
        for i in 2..8u8 {
            n.on_group_report(bob, &report(&gid, Some([i; 16]), None, "spam")).unwrap();
        }
        assert_eq!(n.group_reports().len(), 5, "rate limit not applied");
        // someone else's reports are counted on their own
        n.on_group_report(carol, &report(&gid, None, Some(bob), "other")).unwrap();
        assert_eq!(n.group_reports().len(), 6);
        // a member (not an admin) ignores reports
        let st = n.groups.read().get(&gid).cloned().unwrap();
        let tmp2 = tempfile::tempdir().unwrap();
        let m = quiet_node(tmp2.path()).await;
        let mut st2 = st.clone();
        st2.members.insert(m.me, Role::Member);
        m.groups.write().insert(gid, st2);
        m.store.insert_message(&[0; 16], &conv, &carol, m.hlc.tick(), "text", &json!({"text": "spam"}), 2, None, None).unwrap();
        m.on_group_report(bob, &report(&gid, Some([0; 16]), None, "spam")).unwrap();
        assert!(m.group_reports().is_empty());
        n.shutdown();
        m.shutdown();
    }

    /// A report goes to every device of the owner and of each admin — nobody else, never
    /// the reported member — through the outbox.
    #[tokio::test(flavor = "multi_thread")]
    async fn report_reaches_every_admin_device_only() {
        let tmp = tempfile::tempdir().unwrap();
        let n = quiet_node(tmp.path()).await; // the reporter (plain member)
        let owner = Identity::generate().peer_id();
        let admin = Identity::generate().peer_id();
        let admin2 = Identity::generate().peer_id(); // reported admin: must not get it
        let member = Identity::generate().peer_id();
        let (phone, laptop) = (Identity::generate().peer_id(), Identity::generate().peer_id());
        give_devices(&n, admin, &[admin, phone, laptop]);
        // the group as the reporter sees it
        let gid = gid_of(&n.create_group("G", vec![owner, admin, admin2, member], 0).await.unwrap());
        {
            let mut g = n.groups.write();
            let st = g.get_mut(&gid).unwrap();
            st.members.insert(owner, Role::Owner);
            st.members.insert(admin, Role::Admin);
            st.members.insert(admin2, Role::Admin);
            st.members.insert(n.me, Role::Member);
        }
        let conv = conv_for(&gid, "");
        n.store.insert_message(&[3; 16], &conv, &admin2, n.hlc.tick(), "text", &json!({"text": "rude"}), 2, None, None).unwrap();
        for d in [owner, admin, phone, laptop, admin2, member] {
            assert_eq!(queued(&n, &d, proto::ext::GROUP_REPORT), 0);
        }
        let r = n.group_report(gid, Some([3; 16]), None, "harassment", "  please look  ", true).await.unwrap();
        assert_eq!(r["sent_to"], 2);
        for d in [owner, admin, phone, laptop] {
            assert_eq!(queued(&n, &d, proto::ext::GROUP_REPORT), 1, "an admin device got no report");
        }
        assert_eq!(queued(&n, &admin2, proto::ext::GROUP_REPORT), 0, "the reported admin learned about it");
        assert_eq!(queued(&n, &member, proto::ext::GROUP_REPORT), 0, "a plain member got the report");
        // the body: what the admins need
        let raw = n.store.outbox_for(&owner).unwrap().pop().unwrap().1;
        let Ok(PeerMsg::Wrapped { inner, .. }) = rmp_serde::from_slice::<PeerMsg>(&raw) else { panic!() };
        let PeerMsg::Ext { body, .. } = *inner else { panic!() };
        let m: GroupReportMsg = proto::ext_body(&body).unwrap();
        assert_eq!((m.gid.as_slice(), m.msg_id.as_slice(), m.member.as_slice()), (&gid[..], &[3u8; 16][..], &admin2.0[..]));
        assert_eq!((m.excerpt.as_str(), m.reason.as_str(), m.note.as_str()), ("rude", "harassment", "please look"));
        // "also hide this member's messages": an account setting
        assert_eq!(hidden_members(&n.store), vec![admin2.to_base32()]);
        assert!(crate::store::sync::kv_synced(HIDDEN_MEMBERS_KEY));
        // refused: own message, a message of another chat, bad reason
        n.store.insert_message(&[4; 16], &conv, &n.me, n.hlc.tick(), "text", &json!({"text": "mine"}), 1, None, None).unwrap();
        assert!(n.group_report(gid, Some([4; 16]), None, "spam", "", false).await.is_err());
        n.store.insert_message(&[5; 16], "d:someone", &member, n.hlc.tick(), "text", &json!({"text": "dm"}), 2, None, None).unwrap();
        assert!(n.group_report(gid, Some([5; 16]), None, "spam", "", false).await.is_err());
        assert!(n.group_report(gid, None, Some(member), "nope", "", false).await.is_err());
        n.shutdown();
    }

    /// Handled on one admin device → the account's other devices are told (reliably) and
    /// drop the report; a late copy of a handled report stays gone; only my own account
    /// can say so.
    #[tokio::test(flavor = "multi_thread")]
    async fn handled_reports_follow_the_admin_to_every_device() {
        let tmp = tempfile::tempdir().unwrap();
        let n = quiet_node(tmp.path()).await; // owner, main device
        let laptop = Identity::generate().peer_id();
        give_devices(&n, n.me, &[n.me, laptop]);
        let bob = Identity::generate().peer_id();
        let carol = Identity::generate().peer_id();
        let gid = gid_of(&n.create_group("G", vec![bob, carol], 0).await.unwrap());
        let a = report(&gid, None, Some(carol), "spam");
        let b = report(&gid, None, Some(bob), "spam");
        n.on_group_report(bob, &a).unwrap();
        n.on_group_report(carol, &b).unwrap();
        let ids: Vec<String> = n.group_reports().iter().map(|r| r["id"].as_str().unwrap().to_string()).collect();
        assert_eq!(ids.len(), 2);
        let id_a = hex::encode(proto::ext_body::<GroupReportMsg>(&a).unwrap().id);
        let id_b = hex::encode(proto::ext_body::<GroupReportMsg>(&b).unwrap().id);

        let mut ev = n.subscribe();
        n.group_report_done(std::slice::from_ref(&id_a)).await.unwrap();
        assert_eq!(n.group_reports().len(), 1);
        assert!(drain(&mut ev).iter().any(|e| e["event"] == "group_report_handled" && e["ids"][0] == id_a.as_str()));
        assert_eq!(queued(&n, &laptop, proto::ext::GROUP_REPORT_DONE), 1, "my other device was not told");
        // a late copy (another path) of the handled report doesn't come back
        n.on_group_report(bob, &a).unwrap();
        assert_eq!(n.group_reports().len(), 1);

        // the receiving side: from another account → ignored; from my own → dropped + event
        let done_b = rmp_serde::to_vec_named(&GroupReportDoneMsg { ids: vec![id_b.clone()] }).unwrap();
        n.on_group_report_done(bob, &done_b).unwrap();
        assert_eq!(n.group_reports().len(), 1);
        n.on_group_report_done(n.me, &done_b).unwrap();
        assert!(n.group_reports().is_empty());
        assert!(drain(&mut ev).iter().any(|e| e["event"] == "group_report_handled" && e["ids"][0] == id_b.as_str()));
        n.shutdown();
    }

    /// A blocked group: left and hidden, invites / join links / public joins refused, gone
    /// from search, an add by a friend ignored — and the setting reaches my other devices.
    #[tokio::test(flavor = "multi_thread")]
    async fn blocked_group_is_left_hidden_and_refused_everywhere() {
        let t1 = tempfile::tempdir().unwrap();
        let t2 = tempfile::tempdir().unwrap();
        let t3 = tempfile::tempdir().unwrap();
        let n = quiet_node(t1.path()).await; // owner
        let c = quiet_node(t2.path()).await; // member
        let laptop = quiet_node(t3.path()).await; // stands in for c's other device
        let v = n.create_group("Spam", vec![c.me, laptop.me], 0).await.unwrap();
        let gid = gid_of(&v);
        n.group_visibility(gid, true, "spamgroup").await.unwrap();
        // c joins (as its welcome would)
        let k0 = n.store.group_key_get(&gid, 0).unwrap();
        let st = n.groups.read().get(&gid).cloned().unwrap();
        c.store.group_key_put(&gid, 0, &k0).unwrap();
        c.save_group(&st).unwrap();
        c.store.ensure_conv(&st.conv_id(), 1, "Spam").unwrap();
        let link = n.create_invite(gid, 24).unwrap();

        let mut ev = c.subscribe();
        let list = c.group_block(gid, "").await.unwrap();
        assert_eq!(list.as_array().unwrap().len(), 1);
        assert_eq!(list[0]["name"], "Spam");
        assert!(c.group_blocked(&gid));
        assert!(!c.groups.read().get(&gid).unwrap().is_member(&c.me), "not left");
        assert!(!c.store.conversations().unwrap().iter().any(|x| x.id == st.conv_id()), "chat still there");
        let evs = drain(&mut ev);
        assert!(evs.iter().any(|e| e["event"] == "group_removed"));
        assert!(evs.iter().any(|e| e["event"] == "settings" && e["key"] == BLOCKED_GROUPS_KEY));
        assert!(c.groups_list().iter().all(|g| g["gid"] != hex::encode(gid)));
        // join link / public join refused with a clear message
        let e = c.join_invite(&link).await.unwrap_err();
        assert_eq!(crate::i18n::find_user_err(&e).map(|u| u.key), Some("err.group_blocked"));
        assert_eq!(c.inspect_invite(&link).unwrap()["blocked"], true);
        let e = c.join_public(gid, n.me).await.unwrap_err();
        assert_eq!(crate::i18n::find_user_err(&e).map(|u| u.key), Some("err.group_blocked"));
        // hidden from public-group search
        assert!(c.search_groups("@spamgroup").await.unwrap().is_empty());
        assert_eq!(n.search_groups("@spamgroup").await.unwrap().len(), 1);
        // a welcome (re-added by an admin who is a friend) is ignored
        n.store.upsert_contact(&c.me, Some("c"), Some(3)).unwrap();
        c.store.upsert_contact(&n.me, Some("n"), Some(3)).unwrap();
        let st_n = n.groups.read().get(&gid).cloned().unwrap();
        let w = rmp_serde::to_vec(&crate::group::Welcome { gid, ops: st_n.compact_ops(), epoch: st_n.epoch, key: k0 }).unwrap();
        c.on_group_welcome(n.device, &seal_to(&n.id, &c.device, &w).unwrap()).await.unwrap();
        assert!(!c.groups.read().get(&gid).map(|g| g.is_member(&c.me)).unwrap_or(false));
        assert!(!c.store.conversations().unwrap().iter().any(|x| x.id == st.conv_id()));

        // my other device: the synced setting hides the group at once and leaves it
        laptop.store.group_key_put(&gid, 0, &k0).unwrap();
        laptop.save_group(&st).unwrap();
        laptop.store.ensure_conv(&st.conv_id(), 1, "Spam").unwrap();
        laptop.store.set_sync_enabled(true);
        c.store.set_sync_enabled(true);
        c.group_unblock(&gid).unwrap();
        c.group_block(gid, "").await.unwrap();
        let item = c.store.sync_export(crate::store::sync::K_KV, BLOCKED_GROUPS_KEY.as_bytes()).unwrap();
        laptop.store.sync_import(&item, &laptop.me, true).unwrap();
        let mut lev = laptop.subscribe();
        laptop.on_blocked_groups_synced();
        assert!(laptop.group_blocked(&gid));
        assert!(!laptop.store.conversations().unwrap().iter().any(|x| x.id == st.conv_id()), "still shown on the other device");
        assert!(drain(&mut lev).iter().any(|e| e["event"] == "group_removed"));
        tokio::time::sleep(BLOCK_LEAVE_WAIT * 3).await;
        assert!(!laptop.groups.read().get(&gid).unwrap().is_member(&laptop.me), "the other device didn't leave");
        // unblock: allowed again
        c.group_unblock(&gid).unwrap();
        assert!(!c.group_blocked(&gid));
        assert!(blocked_groups(&c.store).is_empty());
        n.shutdown();
        c.shutdown();
        laptop.shutdown();
    }
}
